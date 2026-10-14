import Foundation
import Network
import os

/// Derivate's MCP server for AI agents, at http://127.0.0.1:<port>/mcp.
/// It answers only this Mac, only requests that hold its key, and no web
/// page: a page's request names its origin, which this server refuses.
final class AgentServer: @unchecked Sendable {
    enum Failure: LocalizedError {
        case listen(NWError)

        var errorDescription: String? {
            switch self {
            case .listen(.posix(.EADDRINUSE)): "Another app uses its port."
            case .listen(let error): error.localizedDescription
            }
        }
    }

    /// The biggest request it reads.
    static let maxRequest = 1 << 20

    private let keyLock: OSAllocatedUnfairLock<String>
    private let respond: @Sendable (HTTPRequest) async -> HTTPResponse
    private let queue = DispatchQueue(label: "dev.derivate.agents")
    private var listener: NWListener?
    // Only the queue touches these.
    private var port: UInt16 = 0
    private var links: [ObjectIdentifier: Link] = [:]
    private var starting: CheckedContinuation<UInt16, Error>?

    init(key: String, respond: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        keyLock = OSAllocatedUnfairLock(initialState: key)
        self.respond = respond
    }

    /// What agents send in their Authorization header, after "Bearer ".
    var key: String {
        get { keyLock.withLock { $0 } }
        set { keyLock.withLock { $0 = newValue } }
    }

    /// Listens on the port of this Mac's loopback, 0 for any free one, and
    /// returns the port.
    func start(port: UInt16) async throws -> UInt16 {
        // Bound to 127.0.0.1, the port is closed to other computers.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch let error as NWError {
            throw Failure.listen(error)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                starting = continuation
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state, listener) }
                listener.start(queue: queue)
            }
        }
    }

    private func listenerChanged(_ state: NWListener.State, _ listener: NWListener) {
        switch state {
        case .ready:
            port = listener.port?.rawValue ?? 0
            starting?.resume(returning: port)
            starting = nil
        case .failed(let error), .waiting(let error):
            listener.cancel()
            starting?.resume(throwing: Failure.listen(error))
            starting = nil
        case .cancelled:
            starting?.resume(throwing: CancellationError())
            starting = nil
        default:
            break
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [self] in
            for link in links.values { link.close() }
            links = [:]
        }
    }

    // MARK: Connections

    /// A connection, and the request it waits on. An agent cancels a request
    /// by closing its connection, which cancels the task that answers it.
    /// Only the server's queue touches it.
    private final class Link: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        var task: Task<Void, Never>?

        init(_ connection: NWConnection) { self.connection = connection }

        func close() {
            task?.cancel()
            task = nil
            connection.cancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint, Self.isLoopback(host) else {
            connection.cancel()
            return
        }
        let link = Link(connection)
        links[ObjectIdentifier(link)] = link
        connection.stateUpdateHandler = { [weak self, weak link] state in
            switch state {
            case .failed, .cancelled:
                guard let self, let link else { return }
                link.close()
                links[ObjectIdentifier(link)] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(link)
    }

    private func receive(_ link: Link) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                link.buffer.append(data)
            }
            if isComplete || error != nil {
                link.close()
                return
            }
            serveNext(link)
            receive(link)
        }
    }

    /// Answers the next request the connection holds, once it has all of it
    /// and the one before is answered.
    private func serveNext(_ link: Link) {
        guard link.task == nil else { return }
        switch HTTPParser.parse(&link.buffer) {
        case .incomplete:
            return
        case .invalid(let status):
            send(HTTPResponse(status: status), on: link, close: true)
        case .request(var request):
            if case .hostPort(_, let clientPort) = link.connection.endpoint {
                request.clientPort = clientPort.rawValue
            }
            request.serverPort = port
            if let refusal = refusal(of: request) {
                send(refusal, on: link, close: false)
                return
            }
            let respond = respond
            link.task = Task { [weak self] in
                let response = await respond(request)
                guard !Task.isCancelled, let self else { return }
                queue.async { self.send(response, on: link, close: false) }
            }
        }
    }

    private func send(_ response: HTTPResponse, on link: Link, close: Bool) {
        link.connection.send(content: HTTPParser.serialize(response, close: close), completion: .contentProcessed { [weak self] _ in
            if close {
                link.close()
            } else if let self {
                queue.async {
                    link.task = nil
                    self.serveNext(link)
                }
            }
        })
    }

    // MARK: Checks

    /// Why the server will not answer a request, as a response, or nil.
    func refusal(of request: HTTPRequest) -> HTTPResponse? {
        // A web page that reaches this port through a name of its own
        // (DNS rebinding) sends that name as the host and the origin.
        let host = request.headers["host"].map(Self.hostName) ?? ""
        guard ["127.0.0.1", "localhost", "[::1]"].contains(host) else {
            return HTTPResponse(status: 403)
        }
        if let origin = request.headers["origin"],
           !["127.0.0.1", "localhost", "[::1]"].contains(URL(string: origin)?.host().map(Self.hostName) ?? "") {
            return .json(MCPEndpoint.error(nil, -32600, "Derivate does not answer web pages."), status: 403)
        }
        guard Self.same(request.headers["authorization"] ?? "", "Bearer " + key) else {
            return HTTPResponse(status: 401, headers: [("WWW-Authenticate", #"Bearer realm="Derivate""#)])
        }
        guard request.path.split(separator: "?").first == "/mcp" else {
            return HTTPResponse(status: 404)
        }
        guard request.method == "POST" else {
            return HTTPResponse(status: 405, headers: [("Allow", "POST")])
        }
        return nil
    }

    private static func hostName(_ host: String) -> String {
        if host.hasPrefix("[") {
            return String(host.prefix { $0 != "]" }) + "]"
        }
        return String(host.prefix { $0 != ":" }).lowercased()
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): address.isLoopback
        case .ipv6(let address): address.isLoopback || address.asIPv4?.isLoopback == true
        case .name(let name, _): name == "localhost"
        @unknown default: false
        }
    }

    /// Whether two strings are the same, in a time that does not tell
    /// where they differ.
    private static func same(_ a: String, _ b: String) -> Bool {
        let (a, b) = (Array(a.utf8), Array(b.utf8))
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Reads HTTP/1.1 requests and writes responses.
enum HTTPParser {
    enum Result {
        case incomplete
        case invalid(status: Int)
        case request(HTTPRequest)
    }

    /// Takes the first whole request off the buffer.
    static func parse(_ buffer: inout Data) -> Result {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 16384 ? .invalid(status: 431) : .incomplete
        }
        var lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(status: 411) // agents send a length
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { return .invalid(status: 400) }
        guard length <= AgentServer.maxRequest else { return .invalid(status: 413) }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<bodyStart + length])
        buffer = Data(buffer[(bodyStart + length)...])
        return .request(HTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: body))
    }

    static func serialize(_ response: HTTPResponse, close: Bool) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += close ? "Connection: close\r\n" : ""
        head += "Server: Derivate\r\n\r\n"
        return Data(head.utf8) + response.body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}
