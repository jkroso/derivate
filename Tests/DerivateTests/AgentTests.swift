import AppKit
import Carbon.HIToolbox
import Foundation
import os
import DerivateKit
import SwiftUI
import Testing
@testable import Derivate

private let robert = "Robert Lee Mitchell"
private let banana = "banana colored duckling"

/// The app's state, unlocked as Robert, with its server for agents on a
/// free port of this Mac: the requests go over HTTP, as an agent's do.
@MainActor
private final class AgentHarness {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let model: AppModel
    var server: AgentServer!
    var port: UInt16 = 0
    var shown = 0
    var closed = 0
    private var nextID = 0
    private let session = URLSession(configuration: .ephemeral)

    init(access: AgentAccess) async throws {
        model = AppModel(store: Store(folder: folder))
        model.clipboard = { _ in }
        model.showPanel = { [unowned self] _ in shown += 1 }
        model.closePanel = { [unowned self] in closed += 1; model.panelClosed() }
        model.settings.agents = access
        model.lockForm.name = robert
        model.lockForm.masterPassword = banana
        model.lockForm.confirm = banana
        model.unlock()
        try await until { self.model.isUnlocked }
        server = model.makeAgentServer()
        port = try await server.start(port: 0)
    }

    deinit { server?.stop() }

    /// Posts a JSON-RPC message to /mcp, and returns the status and the
    /// JSON the server answered.
    func post(_ method: String, _ params: [String: JSONValue] = [:], version: String = "2026-07-28", notification: Bool = false,
              headers: [String: String] = [:]) async throws -> (status: Int, body: JSONValue?) {
        var params = params
        if version == "2026-07-28" {
            params["_meta"] = [
                "io.modelcontextprotocol/protocolVersion": .string(version),
                "io.modelcontextprotocol/clientInfo": ["name": "derivate-tests", "title": "Derivate tests", "version": "1"],
            ]
        }
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method), "params": .object(params)]
        if !notification {
            nextID += 1
            message["id"] = .int(nextID)
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = JSONValue.object(message).data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue("Bearer \(model.settings.agentKey ?? "")", forHTTPHeaderField: "Authorization")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await send(request)
    }

    func send(_ request: URLRequest) async throws -> (status: Int, body: JSONValue?) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data.isEmpty ? nil : try JSONDecoder().decode(JSONValue.self, from: data))
    }

    /// Calls a tool, and returns its text and whether it failed.
    func call(_ tool: String, _ arguments: [String: JSONValue] = [:]) async throws -> (text: String, isError: Bool) {
        let (status, body) = try await post("tools/call", ["name": .string(tool), "arguments": .object(arguments)])
        #expect(status == 200)
        let result = try #require(body?["result"])
        let text = result["content"].flatMap { content -> String? in
            guard case .array(let items) = content else { return nil }
            return items.first?["text"]?.string
        }
        return (text ?? "", result["isError"] == .bool(true))
    }

    func press(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                     keyCode: UInt16(keyCode))!
        _ = model.handleKey(event)
    }
}

/// Waits until the condition holds, or fails after a minute: scrypt is
/// slow in debug builds, and slower while the other tests run it too.
@MainActor
private func until(_ condition: @MainActor () -> Bool, _ comment: Comment = "timed out") async throws {
    let deadline = Date.now.addingTimeInterval(60)
    while !condition() {
        guard Date.now < deadline else {
            Issue.record(comment)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
struct AgentTests {
    @Test func protocolAndTools() async throws {
        let h = try await AgentHarness(access: .allow)

        // Only requests with the key, from this Mac and not a web page.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(h.port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        #expect(try await h.send(request).status == 401)
        request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        #expect(try await h.send(request).status == 401)
        #expect(try await h.post("tools/list", headers: ["Origin": "https://evil.example"]).status == 403)
        let rebound = HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "evil.example:\(h.port)",
                                  "authorization": "Bearer \(h.model.settings.agentKey ?? "")"], body: Data())
        #expect(h.server.refusal(of: rebound)?.status == 403)
        request.httpMethod = "GET"
        request.httpBody = nil
        request.setValue("Bearer \(h.model.settings.agentKey ?? "")", forHTTPHeaderField: "Authorization")
        #expect(try await h.send(request).status == 405)

        // Version 2026-07-28 discovers; older versions initialize.
        let discover = try #require(try await h.post("server/discover").body?["result"])
        #expect(discover["supportedVersions"] == ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"])
        #expect(discover["capabilities"]?["tools"] != nil)
        #expect(discover["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "Derivate")
        let initialize = try await h.post("initialize", ["protocolVersion": "2025-06-18",
                                                         "clientInfo": ["name": "old-client", "version": "1"]], version: "2025-06-18")
        #expect(initialize.body?["result"]?["protocolVersion"] == "2025-06-18")
        #expect(try await h.post("notifications/initialized", version: "2025-06-18", notification: true).status == 202)
        // Older clients refuse fields of 2026-07-28 that they do not know:
        // Gemini CLI's refuses a ping result that is not empty.
        #expect(initialize.body?["result"]?["resultType"] == nil)
        #expect(try await h.post("ping", version: "2025-06-18").body?["result"] == [:])
        #expect(try await h.post("tools/list", version: "2025-06-18").body?["result"]?["ttlMs"] == nil)
        #expect(try await h.post("ping").body?["result"]?["resultType"] == "complete")
        let unsupported = try await h.post("tools/list", version: "1900-01-01")
        #expect(unsupported.status == 400)
        #expect(unsupported.body?["error"]?["code"] == .int(-32022))
        #expect(try await h.post("resources/list").status == 404)

        let listed = try #require(try await h.post("tools/list").body?["result"])
        // Version 2026-07-28 clients refuse a list without these.
        #expect(listed["ttlMs"] == 3_600_000)
        #expect(listed["cacheScope"] == "public")
        let tools = try #require(listed["tools"])
        guard case .array(let list) = tools else { throw CancellationError() }
        #expect(list.compactMap { $0["name"]?.string } == ["find_sites", "get_password", "create_site"])

        // A new site gets Spectre's password, as the panel gives it.
        let created = try await h.call("create_site", ["site": "masterpasswordapp.com"])
        #expect(!created.isError)
        #expect(created.text.contains("Password: Jejr5[RepuSosp"))
        #expect(try await h.call("create_site", ["site": "MasterPasswordApp.com"]).text.contains("already has a site"))
        #expect(try await h.call("find_sites", ["query": "mpw"]).text == "masterpasswordapp.com")
        let got = try await h.call("get_password", ["site": "masterpasswordapp.com"])
        #expect(got.text == "Site: masterpasswordapp.com\nPassword: Jejr5[RepuSosp")
        #expect(h.model.site(named: "masterpasswordapp.com")?.uses == 2)
        #expect(try await h.call("get_password", ["site": "nowhere.example"]).text.contains("no site named"))

        // A password the agent gives stays encrypted, with the login name.
        let stored = try await h.call("create_site", ["site": "bank.example", "password": "hunter2-correct-horse",
                                                      "login": "robert@example.com", "url": "https://bank.example"])
        #expect(!stored.isError)
        let bank = try await h.call("get_password", ["site": "bank.example"])
        #expect(bank.text == "Site: bank.example\nLogin: robert@example.com\nPassword: hunter2-correct-horse\nWebsite: https://bank.example")
        let file = try String(contentsOf: h.folder.appending(path: "users/\(robert).mpjson"), encoding: .utf8)
        #expect(file.contains("bank.example"))
        #expect(!file.contains("hunter2-correct-horse"))
        #expect(!file.contains("robert@example.com"))

        let pin = try await h.call("create_site", ["site": "door", "type": "pin"])
        #expect(h.model.site(named: "door")?.type == .pin)
        #expect(pin.text.range(of: #"Password: \d{4}$"#, options: .regularExpression) != nil)
        #expect(try await h.call("create_site", ["site": "x", "type": "huge"]).isError)
        let unknown = try await h.post("tools/call", ["name": "delete_everything", "arguments": [:]])
        #expect(unknown.body?["error"]?["code"] == .int(-32602))
        #expect(h.shown == 0) // nothing asked
    }

    @Test func askEachTime() async throws {
        let h = try await AgentHarness(access: .ask)
        let create = Task { try await h.call("create_site", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        #expect(h.model.agentRequests[0].action == .create(site: "github.com", login: nil, url: nil, type: nil, givesPassword: false))
        h.model.answer(h.model.agentRequests[0].id, .allowed)
        #expect(try await !create.value.isError)

        let call = Task { try await h.call("get_password", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        let request = h.model.agentRequests[0]
        #expect(request.action == .password(site: "github.com"))
        #expect(request.agent.name == "Derivate tests")
        // Derivate finds the agent's process: here, the tests'.
        #expect(request.agent.process?.id.pid == getpid())
        #expect(request.agent.process?.folder == FileManager.default.currentDirectoryPath)
        #expect(h.shown == 2)

        // Enter waits a moment, so that a key meant for another app does
        // not allow the request.
        h.press(kVK_Return)
        #expect(h.model.agentRequests.count == 1)
        try await until { h.model.agentRequestReady }
        h.press(kVK_Return)
        let allowed = try await call.value
        #expect(allowed.text.contains("Password: "))
        #expect(!allowed.isError)
        #expect(h.model.agentRequests.isEmpty)
        #expect(h.closed >= 2)

        let refused = Task { try await h.call("get_password", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        h.press(kVK_Escape)
        let answer = try await refused.value
        #expect(answer.isError)
        #expect(answer.text.contains("refused"))

        // ⌘L locks, which refuses too.
        let locking = Task { try await h.call("get_password", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        h.press(kVK_ANSI_L, .command)
        #expect(try await locking.value.text.contains("locked Derivate"))
        #expect(!h.model.isUnlocked)
    }

    @Test func askOncePerSession() async throws {
        let h = try await AgentHarness(access: .askOnce)
        let first = Task { try await h.call("create_site", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        h.model.answer(h.model.agentRequests[0].id, .allowed)
        #expect(try await !first.value.isError)

        // The same process, which is the same session, needs no answer.
        #expect(try await !h.call("get_password", ["site": "github.com"]).isError)
        #expect(h.model.agentRequests.isEmpty)
        #expect(h.shown == 1)

        // Locking forgets the sessions the user allowed.
        h.model.lock()
        h.model.lockForm.masterPassword = banana
        h.model.unlock()
        try await until { h.model.isUnlocked }
        let again = Task { try await h.call("get_password", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        h.model.answer(h.model.agentRequests[0].id, .refused)
        #expect(try await again.value.isError)
    }

    @Test func lockedWaitsForTheSecret() async throws {
        let h = try await AgentHarness(access: .allow)
        _ = try await h.call("create_site", ["site": "github.com"])
        h.model.lock()

        // Site names are not secret: they are found while locked.
        #expect(try await h.call("find_sites", ["query": "git"]).text == "github.com")

        let call = Task { try await h.call("get_password", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        #expect(h.shown == 1) // the panel opens on the lock screen
        h.model.lockForm.masterPassword = banana
        h.model.unlock()
        let answer = try await call.value
        #expect(!answer.isError)
        #expect(answer.text.contains("Password: "))
        #expect(h.model.agentRequests.isEmpty)
    }

    @Test func requestsEnd() async throws {
        let h = try await AgentHarness(access: .ask)
        let create = Task { try await h.call("create_site", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        h.model.answer(h.model.agentRequests[0].id, .allowed)
        _ = try await create.value

        // An agent that stops waiting closes its connection, which ends
        // the request.
        let cancelled = Task { try await h.call("get_password", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        cancelled.cancel()
        try await until({ h.model.agentRequests.isEmpty }, "the request outlived its connection")

        // Closing the panel refuses.
        let closing = Task { try await h.call("get_password", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        h.model.panelClosed()
        #expect(try await closing.value.text.contains("closed Derivate"))

        // A request the user does not answer ends.
        h.model.agentTimeout = .milliseconds(200)
        let slow = try await h.call("get_password", ["site": "github.com"])
        #expect(slow.text.contains("did not answer"))

        // Turning agents off refuses what waits.
        h.model.agentTimeout = .seconds(120)
        let off = Task { try await h.call("get_password", ["site": "github.com"]) }
        try await until { !h.model.agentRequests.isEmpty }
        h.model.settings.agents = .off
        #expect(try await off.value.text.contains("turned off"))
    }

    @Test func keyAndCommand() async throws {
        let h = try await AgentHarness(access: .ask)
        let key = try #require(h.model.settings.agentKey)
        #expect(key.count == 43)
        // The key outlives the app.
        #expect(AppModel(store: Store(folder: h.folder)).settings.agentKey == key)
        // The command holds no key: it reads it from the settings.
        #expect(AppModel.agentCommand.hasSuffix(" mcp"))
        #expect(!AppModel.agentCommand.contains(key))
    }

    /// `Derivate mcp` passes each line to the app's server, and its
    /// answer back, with the key from the settings.
    @Test func stdioBridge() async throws {
        let h = try await AgentHarness(access: .ask)
        var settings = h.model.settings
        settings.agentPort = Int(h.port)
        let lines = Lines()
        let fixed = settings
        let bridge = StdioBridge(settings: { fixed }, openApp: {}, write: { lines.append($0) })
        let (input, feed) = AsyncStream<String>.makeStream()
        let serving = Task { await bridge.serve(input) }
        func send(_ message: JSONValue) { feed.yield(String(decoding: message.data, as: UTF8.self)) }
        func answer(_ id: Int) async throws -> JSONValue {
            try await until { lines.find(id) != nil }
            return try #require(lines.find(id))
        }
        let meta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
                               "io.modelcontextprotocol/clientInfo": ["name": "agent", "title": "Some Agent"]]

        send(["jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": ["_meta": meta]])
        #expect(try await answer(1)["result"]?["supportedVersions"] != nil)
        send(["jsonrpc": "2.0", "method": "notifications/initialized"]) // no answer

        // A call waits for the user, as over HTTP.
        send(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
              "params": ["name": "create_site", "arguments": ["site": "github.com"], "_meta": meta]])
        try await until { !h.model.agentRequests.isEmpty }
        #expect(h.model.agentRequests[0].agent.name == "Some Agent")
        h.model.answer(h.model.agentRequests[0].id, .allowed)
        #expect(try await answer(2)["result"]?["isError"] == false)

        // The agent cancels a call that waits.
        send(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
              "params": ["name": "get_password", "arguments": ["site": "github.com"], "_meta": meta]])
        try await until { !h.model.agentRequests.isEmpty }
        send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 3]])
        try await until({ h.model.agentRequests.isEmpty }, "the cancelled request still waits")
        #expect(lines.find(3) == nil)

        feed.finish()
        await serving.value
        #expect(lines.count == 2)
    }

    /// When the app does not answer, the command opens it, then gives up.
    @Test func stdioBridgeWithoutTheApp() async throws {
        let lines = Lines()
        let opened = Lines()
        var settings = Settings()
        settings.agentPort = 9 // the discard port: nothing listens there
        settings.agentKey = "key"
        let fixed = settings
        var bridge = StdioBridge(settings: { fixed }, openApp: { opened.append(Data()) }, write: { lines.append($0) })
        bridge.patience = .milliseconds(600)
        let (input, feed) = AsyncStream<String>.makeStream()
        let serving = Task { await bridge.serve(input) }
        feed.yield(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#)
        try await until { lines.find(7) != nil }
        #expect(lines.find(7)?["error"]?["message"] == "Derivate is not running. Ask the user to open it.")
        #expect(opened.count == 1)

        settings.agents = .off
        let off = settings
        bridge.settings = { off }
        let (input2, feed2) = AsyncStream<String>.makeStream()
        let serving2 = Task { await bridge.serve(input2) }
        feed2.yield(#"{"jsonrpc":"2.0","id":8,"method":"tools/list"}"#)
        try await until { lines.find(8) != nil }
        #expect(lines.find(8)?["error"]?["message"]?.string?.contains("off") == true)
        feed.finish()
        feed2.finish()
        _ = await (serving.value, serving2.value)
    }
}

/// What the command writes, line by line.
private final class Lines: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [Data]())

    func append(_ line: Data) { lines.withLock { $0.append(line) } }

    var count: Int { lines.withLock { $0.count } }

    /// The answer to the request of an ID.
    func find(_ id: Int) -> JSONValue? {
        lines.withLock { $0 }
            .compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            .first { $0["id"] == .int(id) }
    }
}

/// Draws the screens for agents to PNG files in the folder that
/// DERIVATE_SNAPSHOT names, as AppTests' snapshot draws the others.
@MainActor
@Test func agentSnapshot() async throws {
    guard let out = ProcessInfo.processInfo.environment["DERIVATE_SNAPSHOT"] else { return }
    for dark in [false, true] {
        let h = try await AgentHarness(access: .ask)
        let model = h.model
        let mode = dark ? "dark" : "light"
        func shot(_ name: String) throws {
            let view = RootView().environment(model)
                .background(Color(nsColor: dark ? .darkGray : .lightGray))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: PanelMetrics.size)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(filePath: out).appending(path: "\(name)-\(mode).png"))
        }
        var site = try #require(model.user).newSite(named: "github.com")
        site.url = "https://github.com"
        model.user?.sites.append(site)
        model.setLogin("robert@example.com", for: "github.com")
        let agent = Agent(name: "Claude Code", process: PeerProcess(pid: getpid()))

        let get = Task { await model.authorize(.password(site: "github.com"), by: agent) }
        try await until { model.agentRequestReady }
        try shot("agent-password")
        model.answer(model.agentRequests[0].id, .refused)
        _ = await get.value

        let create = Task {
            await model.authorize(.create(site: "linear.app", login: "robert@example.com", url: "https://linear.app",
                                          type: nil, givesPassword: false), by: agent)
        }
        let second = Task { await model.authorize(.password(site: "github.com"), by: agent) }
        try await until { model.agentRequests.count == 2 }
        try shot("agent-create")
        model.lock()
        _ = await (create.value, second.value)

        let locked = Task { await model.authorize(.password(site: "github.com"), by: agent) }
        try await until { !model.agentRequests.isEmpty }
        try shot("agent-locked")
        model.panelClosed()
        _ = await locked.value

        model.lockForm.masterPassword = banana
        model.unlock()
        try await until { model.isUnlocked }
        model.screen = .settings
        try shot("agent-settings")
    }
}
