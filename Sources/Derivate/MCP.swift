import Foundation
import os

/// A JSON value, as MCP's messages carry them.
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    var object: [String: JSONValue]? {
        if case .object(let object) = self { object } else { nil }
    }

    /// The value as JSON text.
    var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let bool = try? c.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? c.decode(Int.self) {
            self = .int(int)
        } else if let double = try? c.decode(Double.self) {
            self = .double(double)
        } else if let string = try? c.decode(String.self) {
            self = .string(string)
        } else if let array = try? c.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let bool): try c.encode(bool)
        case .int(let int): try c.encode(int)
        case .double(let double): try c.encode(double)
        case .string(let string): try c.encode(string)
        case .array(let array): try c.encode(array)
        case .object(let object): try c.encode(object)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    /// The headers, by lower-case name.
    var headers: [String: String]
    var body: Data
    /// The ports of the connection: the client's, and this server's.
    var clientPort: UInt16 = 0
    var serverPort: UInt16 = 0
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)] = []
    var body = Data()

    static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: value.data)
    }
}

/// Who calls a tool: the agent's name, and the process it runs in when
/// Derivate finds it.
struct Agent: Sendable, Equatable {
    var name: String
    var process: PeerProcess?

    /// The folder the agent works in, with ~ for the home folder.
    var folder: String? {
        guard let path = process?.folder, path != "/" else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// What a tool gives the agent: text, or why it failed.
struct ToolResult: Sendable, Equatable {
    var text: String
    var isError = false

    static func failure(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }
}

/// The MCP endpoint's protocol: JSON-RPC over HTTP POST, as MCP's
/// Streamable HTTP transport has it. It speaks version 2026-07-28, where
/// each request names its client, and the versions before it, which start
/// with `initialize`. It keeps no sessions.
struct MCPEndpoint: Sendable {
    typealias Call = @Sendable (_ tool: String, _ arguments: [String: JSONValue], _ agent: Agent) async -> ToolResult

    static let versions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"]

    let tools: JSONValue
    let instructions: String
    let call: Call
    /// The names clients gave in `initialize`, by process, for the versions
    /// that name the client only there.
    private let names = OSAllocatedUnfairLock(initialState: [PeerProcess.ID: String]())

    init(tools: JSONValue, instructions: String, call: @escaping Call) {
        self.tools = tools
        self.instructions = instructions
        self.call = call
    }

    private var serverInfo: JSONValue {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return ["name": "Derivate", "title": "Derivate", "version": .string(version)]
    }

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: request.body),
              let method = message["method"]?.string else {
            return .json(Self.error(nil, -32700, "Derivate expects one JSON-RPC request or notification."), status: 400)
        }
        let params = message["params"]?.object ?? [:]
        let meta = params["_meta"]?.object ?? [:]
        let version = meta["io.modelcontextprotocol/protocolVersion"]?.string
        if let header = request.headers["mcp-protocol-version"], let version, header != version {
            return .json(Self.error(message["id"], -32020, "Header mismatch: MCP-Protocol-Version \(header) does not match \(version)."),
                         status: 400)
        }
        if let requested = version ?? request.headers["mcp-protocol-version"], !Self.versions.contains(requested) {
            return .json(Self.error(message["id"], -32022, "Unsupported protocol version",
                                    data: ["supported": .array(Self.versions.map(JSONValue.string)), "requested": .string(requested)]),
                         status: 400)
        }
        // A notification needs no answer.
        guard let id = message["id"] else {
            return HTTPResponse(status: 202)
        }
        // Version 2026-07-28 marks each result complete, and names the
        // server in it. Clients of older versions refuse fields they do not
        // know in some results: an empty ping result must stay empty.
        let modern = method == "server/discover" || (version ?? request.headers["mcp-protocol-version"]) == Self.versions[0]
        /// A result. One that is `cacheable` the client can keep for an
        /// hour, and for any user, as the tools are the same for everyone.
        func result(_ value: [String: JSONValue], cacheable: Bool = false) -> HTTPResponse {
            var value = value
            if modern {
                value["resultType"] = "complete"
                value["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo]
                if cacheable {
                    value["ttlMs"] = 3_600_000
                    value["cacheScope"] = "public"
                }
            }
            return .json(["jsonrpc": "2.0", "id": id, "result": .object(value)])
        }
        switch method {
        case "server/discover":
            return result([
                "supportedVersions": .array(Self.versions.map(JSONValue.string)),
                "capabilities": ["tools": [:]],
                "instructions": .string(instructions),
            ], cacheable: true)
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            if let client = Self.clientName(params["clientInfo"]),
               let process = PeerProcess.find(clientPort: request.clientPort, serverPort: request.serverPort) {
                names.withLock { $0[process.id] = client }
            }
            return result([
                "protocolVersion": .string(Self.versions.dropFirst().contains(asked) ? asked : Self.versions[1]),
                "capabilities": ["tools": [:]],
                "serverInfo": serverInfo,
                "instructions": .string(instructions),
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": tools], cacheable: true)
        case "tools/call":
            guard let name = params["name"]?.string,
                  tools.arrayValue.contains(where: { $0["name"]?.string == name }) else {
                return .json(Self.error(id, -32602, "Derivate has no tool named \(params["name"]?.string ?? "")."))
            }
            let process = PeerProcess.find(clientPort: request.clientPort, serverPort: request.serverPort)
            let agentName = Self.clientName(meta["io.modelcontextprotocol/clientInfo"])
                ?? process.flatMap { process in names.withLock { $0[process.id] } }
                ?? process?.name
                ?? "An agent"
            let outcome = await call(name, params["arguments"]?.object ?? [:], Agent(name: agentName, process: process))
            return result(["content": [["type": "text", "text": .string(outcome.text)]], "isError": .bool(outcome.isError)])
        default:
            return .json(Self.error(id, -32601, "Derivate has no method \(method)."), status: 404)
        }
    }

    /// The name a client gives itself: its title, else its name.
    private static func clientName(_ info: JSONValue?) -> String? {
        let name = info?["title"]?.string ?? info?["name"]?.string
        return name?.isEmpty == false ? name : nil
    }

    static func error(_ id: JSONValue?, _ code: Int, _ message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        error["data"] = data
        return ["jsonrpc": "2.0", "id": id ?? .null, "error": .object(error)]
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue] {
        if case .array(let array) = self { array } else { [] }
    }
}
