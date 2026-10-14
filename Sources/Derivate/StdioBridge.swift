import AppKit
import Foundation
import os

/// `Derivate mcp`: Derivate as an MCP server on standard input and
/// output, which any agent can run. It passes each message on to the app's
/// server for agents, with the key from the app's settings, so that no
/// agent's settings hold the key. Each agent session runs one of its own,
/// which is how "Ask once per session" tells sessions apart.
struct StdioBridge: Sendable {
    /// The app's settings, read again for each message: the port, the key,
    /// and whether agents are off.
    var settings: @Sendable () -> Settings
    /// Opens the app, when its server does not answer.
    var openApp: @Sendable () -> Void
    /// Writes a message, a line of JSON, to the agent.
    var write: @Sendable (Data) -> Void
    /// How long it waits for the app to open.
    var patience = Duration.seconds(15)
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300 // the user can take 2 minutes to answer
        return URLSession(configuration: configuration)
    }()

    init(settings: @escaping @Sendable () -> Settings, openApp: @escaping @Sendable () -> Void,
         write: @escaping @Sendable (Data) -> Void) {
        self.settings = settings
        self.openApp = openApp
        self.write = write
    }

    /// Serves standard input until it ends, then exits.
    static func run() -> Never {
        let store = Store.standard()
        let output = OSAllocatedUnfairLock()
        let bridge = StdioBridge(settings: { store.loadSettings() }, openApp: openThisApp) { line in
            output.withLock { FileHandle.standardOutput.write(line + Data("\n".utf8)) }
        }
        Task {
            await bridge.serve(FileHandle.standardInput.bytes.lines)
            exit(0)
        }
        dispatchMain()
    }

    /// Opens the app this command is in, without bringing it to the front.
    private static func openThisApp() {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    /// Answers each message, a line of JSON, as the app's server answers
    /// it. Messages wait for the user at the same time, and the agent
    /// cancels one with `notifications/cancelled`.
    func serve<Lines: AsyncSequence>(_ lines: Lines) async where Lines.Element == String {
        let waiting = OSAllocatedUnfairLock(initialState: [JSONValue: Task<Void, Never>]())
        do {
            for try await line in lines where !line.isEmpty {
                let body = Data(line.utf8)
                let message = try? JSONDecoder().decode(JSONValue.self, from: body)
                if message?["method"] == "notifications/cancelled" {
                    if let id = message?["params"]?["requestId"] {
                        waiting.withLock { $0.removeValue(forKey: id) }?.cancel()
                    }
                    continue
                }
                let id = message?["id"]
                let task = Task {
                    if let answer = await forward(body, id: id) {
                        write(answer)
                    }
                    if let id {
                        waiting.withLock { _ = $0.removeValue(forKey: id) }
                    }
                }
                if let id {
                    waiting.withLock { $0[id] = task }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("Derivate: \(error.localizedDescription)\n".utf8))
        }
        // The agent closed its input: what waits is no longer wanted.
        for task in waiting.withLock({ Array($0.values) }) {
            task.cancel()
        }
    }

    /// Posts a message to the app's server, opening the app if it does not
    /// answer, and returns the answer: nil for a notification.
    private func forward(_ body: Data, id: JSONValue?) async -> Data? {
        let deadline = ContinuousClock.now + patience
        var opened = false
        var refused = false
        while !Task.isCancelled {
            let settings = settings()
            guard settings.agents != .off else {
                return failure(id, "AI agents are off in Derivate's settings. Ask the user to turn them on.")
            }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.agentPort)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(settings.agentKey ?? "")", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 && !refused {
                    refused = true // the key changed as it was read: read it again
                    continue
                }
                if status == 202 || id == nil {
                    return nil
                }
                return data.isEmpty ? failure(id, "Derivate answered with HTTP status \(status).") : data
            } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
                // The app does not run, or its server has not started yet.
                if !opened {
                    openApp()
                    opened = true
                }
                guard ContinuousClock.now < deadline else {
                    return failure(id, "Derivate is not running. Ask the user to open it.")
                }
                try? await Task.sleep(for: .milliseconds(250))
            } catch {
                return Task.isCancelled ? nil : failure(id, "Derivate could not be reached: \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// A JSON-RPC error that answers a request, or nil for a notification.
    private func failure(_ id: JSONValue?, _ message: String) -> Data? {
        guard let id else { return nil }
        return MCPEndpoint.error(id, -32000, message).data
    }
}
