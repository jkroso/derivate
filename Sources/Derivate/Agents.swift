import AppKit
import Foundation
import Security
import DerivateKit

/// When Derivate asks the user before it answers an AI agent.
enum AgentAccess: String, CaseIterable, Codable, Sendable {
    case off
    case ask
    case askOnce = "ask-once"
    case allow

    var title: String {
        switch self {
        case .off: "Off"
        case .ask: "Ask each time"
        case .askOnce: "Ask once per session"
        case .allow: "Never ask"
        }
    }

    var explanation: String {
        switch self {
        case .off: "Agents cannot connect to Derivate."
        case .ask: "Derivate asks you before it gives an agent a password or adds a site for it."
        case .askOnce: "Derivate asks once for each agent session. After you allow it, that session gets passwords without asking until you lock Derivate."
        case .allow: "An agent with the key gets any password while Derivate is unlocked. When it is locked, Derivate asks for your master password."
        }
    }
}

/// What an agent asks Derivate to do.
enum AgentAction: Equatable, Sendable {
    /// Give the password and login name of a site.
    case password(site: String)
    /// Add a site, with a password of the type (nil for the user's default),
    /// or with the password the agent gives.
    case create(site: String, login: String?, url: String?, type: ResultType?, givesPassword: Bool)

    var site: String {
        switch self {
        case .password(let site), .create(let site, _, _, _, _): site
        }
    }
}

/// A request that waits for the user to allow it.
struct AgentRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let agent: Agent
    let action: AgentAction
}

/// How a request that waited ended.
enum AgentAnswer: Sendable {
    case allowed, refused, timedOut, cancelled, locked, closed, off

    /// Why the tool failed, for the agent.
    var failure: String {
        switch self {
        case .allowed: ""
        case .refused: "The user refused this request in Derivate. Do not ask again unless the user tells you to."
        case .timedOut: "The user did not answer in Derivate within 2 minutes."
        case .cancelled: "The request was cancelled."
        case .locked: "The user locked Derivate before answering."
        case .closed: "The user closed Derivate without answering."
        case .off: "The user turned off agent access in Derivate."
        }
    }
}

extension AppModel {
    // MARK: The server

    static let agentInstructions = """
        Derivate is the user's password manager. Use find_sites to learn a site's exact name, then get_password. \
        Derivate can ask the user to unlock it or to allow a request, so a call can wait up to 2 minutes. \
        Use a password only for the task the user gave you. Do not show it in replies or write it to files unless the user asks.
        """

    static let agentTools: JSONValue = [
        [
            "name": "find_sites",
            "title": "Find sites",
            "description": "Finds sites in Derivate by part of their name and gives their exact names and websites. It gives no passwords and never asks the user.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Part of the site's name, such as \"github\". Leave it out to list all sites."],
                ],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_password",
            "title": "Get a password",
            "description": "Gives the password and login name of a site in Derivate. Derivate can ask the user first, so the call can wait up to 2 minutes. If the user refuses, do not ask again unless they tell you to.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "site": ["type": "string", "description": "The site's name, as find_sites gives it."],
                ],
                "required": ["site"],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "create_site",
            "title": "Add a site",
            "description": "Adds a site to Derivate and gives its password. Without `password`, Derivate makes the password from the user's master password, as Spectre does. With `password`, Derivate keeps that password, encrypted. It fails if the site exists: use get_password then. Derivate can ask the user first, so the call can wait up to 2 minutes.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "site": ["type": "string", "description": "The site's name, usually its domain, such as \"github.com\"."],
                    "login": ["type": "string", "description": "The username or email address for the site."],
                    "url": ["type": "string", "description": "The site's web address."],
                    "password": ["type": "string", "description": "A password to keep, such as one the site gave. Leave it out to let Derivate make one."],
                    "type": [
                        "type": "string",
                        "enum": ["maximum", "long", "medium", "basic", "short", "pin", "name", "phrase"],
                        "description": "The kind of password Derivate makes: maximum (20 characters), long (14), medium (8), basic (8 letters and digits), short (4), pin (4 digits), name (9 letters), phrase (words). Leave it out for the user's default.",
                    ],
                ],
                "required": ["site"],
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
    ]

    /// A server that gives agents this model's tools, with its key.
    func makeAgentServer() -> AgentServer {
        let endpoint = MCPEndpoint(tools: Self.agentTools, instructions: Self.agentInstructions) { [weak self] tool, arguments, agent in
            guard let self else { return .failure(AgentAnswer.off.failure) }
            return await callTool(tool, arguments: arguments, from: agent)
        }
        return AgentServer(key: settings.agentKey ?? "", respond: endpoint.respond)
    }

    /// The command that agents run to reach Derivate: this app's
    /// executable, with the argument `mcp`. It holds no key.
    static var agentCommand: String {
        let path = Bundle.main.executableURL?.path ?? "Derivate"
        return (path.contains(" ") ? "'\(path)'" : path) + " mcp"
    }

    func copyAgentCommand() {
        if let clipboard {
            clipboard(Self.agentCommand)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.agentCommand, forType: .string)
        }
        toast = "Copied. Add it to your agent's MCP settings."
    }

    static func newAgentKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("Derivate could not make a random key")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: The tools

    /// Runs a tool that an agent calls.
    func callTool(_ name: String, arguments: [String: JSONValue], from agent: Agent) async -> ToolResult {
        guard settings.agents != .off else { return .failure(AgentAnswer.off.failure) }
        switch name {
        case "find_sites": return findSites(matching: arguments["query"]?.string ?? "")
        case "get_password": return await givePassword(arguments, to: agent)
        case "create_site": return await createSite(arguments, for: agent)
        default: return .failure("Derivate has no tool named \(name).")
        }
    }

    /// The sites whose names hold the query. Their names are not secret,
    /// so this works when Derivate is locked too, and never asks.
    private func findSites(matching query: String) -> ToolResult {
        guard let user = exportUser else {
            return .failure("Derivate has no user yet. Ask the user to open Derivate and type their name and master password.")
        }
        let found = sites(matching: query, of: user)
        guard !found.isEmpty else {
            return ToolResult(text: query.isEmpty ? "Derivate has no sites yet." : "No site matches \"\(query)\". create_site adds one.")
        }
        let limit = 50
        var lines = found.prefix(limit).map { site in site.url.map { "\(site.name) (\($0))" } ?? site.name }
        if found.count > limit {
            lines.append("…and \(found.count - limit) more. Type more of the name to find them.")
        }
        return ToolResult(text: lines.joined(separator: "\n"))
    }

    private func givePassword(_ arguments: [String: JSONValue], to agent: Agent) async -> ToolResult {
        let name = Self.siteName(arguments["site"])
        guard !name.isEmpty else { return .failure("Give the site's name.") }
        guard let known = exportUser?.site(named: name) else {
            return .failure("Derivate has no site named \"\(name)\". Use find_sites to learn its exact name.")
        }
        let answer = await authorize(.password(site: known.name), by: agent)
        guard answer == .allowed else { return .failure(answer.failure) }
        guard let site = site(named: name) else {
            return .failure("Derivate has no site named \"\(name)\" now. Use find_sites to learn its exact name.")
        }
        guard let password = password(of: site) else {
            return .failure("\(site.name) has no password stored in Derivate.")
        }
        used(site)
        return ToolResult(text: Self.describe(site, password: password, login: login(of: site)))
    }

    private func createSite(_ arguments: [String: JSONValue], for agent: Agent) async -> ToolResult {
        let name = Self.siteName(arguments["site"])
        guard !name.isEmpty else { return .failure("Give the site's name.") }
        if let existing = exportUser?.site(named: name) {
            return .failure("Derivate already has a site named \"\(existing.name)\". Use get_password to get its password.")
        }
        func text(_ key: String) -> String? {
            let value = arguments[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        let given = arguments["password"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        var type: ResultType?
        if given == nil, let asked = text("type") {
            type = ResultType.passwordTypes.first { !$0.isStateful && $0.title.lowercased() == asked.lowercased() }
            guard type != nil else {
                return .failure("type must be one of maximum, long, medium, basic, short, pin, name or phrase.")
            }
        }
        let login = text("login"), url = text("url")
        let answer = await authorize(.create(site: name, login: login, url: url, type: type, givesPassword: given != nil), by: agent)
        guard answer == .allowed else { return .failure(answer.failure) }
        guard let user else { return .failure(AgentAnswer.locked.failure) }
        guard user.site(named: name) == nil else {
            return .failure("Derivate already has a site named \"\(name)\". Use get_password to get its password.")
        }

        var site = user.newSite(named: name)
        if let type {
            site.type = type
        }
        if let given {
            site.type = .personal
            guard let state = encrypt(given, algorithm: site.algorithm) else {
                return .failure("Derivate could not encrypt the password.")
            }
            site.state = state
        }
        site.url = url
        used(site)
        if let login {
            setLogin(login, for: name)
        }
        guard let saved = self.site(named: name), let password = password(of: saved) else {
            return .failure("Derivate could not make a password for \(name).")
        }
        return ToolResult(text: "Derivate added \(saved.name).\n" + Self.describe(saved, password: password, login: self.login(of: saved)))
    }

    private static func siteName(_ value: JSONValue?) -> String {
        (value?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func describe(_ site: Site, password: String, login: String?) -> String {
        var lines = ["Site: \(site.name)"]
        if let login {
            lines.append("Login: \(login)")
        }
        lines.append("Password: \(password)")
        if let url = site.url {
            lines.append("Website: \(url)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Asking the user

    /// Whether the user must allow a request of this agent first.
    func mustAsk(_ agent: Agent) -> Bool {
        switch settings.agents {
        case .ask: true
        case .askOnce: agent.process.map { !allowedAgents.contains($0.id) } ?? true
        case .allow, .off: false
        }
    }

    /// Waits until Derivate is unlocked, and the user allows the request
    /// when they must. The panel opens to ask them.
    func authorize(_ action: AgentAction, by agent: Agent) async -> AgentAnswer {
        if isUnlocked && !mustAsk(agent) {
            return .allowed
        }
        let request = AgentRequest(id: UUID(), agent: agent, action: action)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                agentAnswers[request.id] = continuation
                agentRequests.append(request)
                if agentRequests.count == 1 {
                    agentPromptChanged()
                }
                showPanel(true)
                let timeout = agentTimeout
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.answer(request.id, .timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answer(request.id, .cancelled) }
        }
    }

    /// Ends a request that waits. When none is left, the panel closes and
    /// the keyboard goes back to the app the user was in.
    func answer(_ id: UUID, _ answer: AgentAnswer) {
        guard let continuation = agentAnswers.removeValue(forKey: id) else { return }
        let first = agentRequests.first?.id == id
        if answer == .allowed, settings.agents == .askOnce,
           let process = agentRequests.first(where: { $0.id == id })?.agent.process {
            allowedAgents.insert(process.id)
        }
        agentRequests.removeAll { $0.id == id }
        continuation.resume(returning: answer)
        // Other requests of a session the user just allowed need no answer.
        if answer == .allowed, isUnlocked {
            for request in agentRequests where !mustAsk(request.agent) {
                self.answer(request.id, .allowed)
            }
        }
        if agentRequests.isEmpty {
            if answer != .closed {
                closePanel()
            }
        } else if first {
            agentPromptChanged()
        }
    }

    /// Ends every request that waits.
    func answerAll(_ answer: AgentAnswer) {
        for id in agentRequests.map(\.id) {
            self.answer(id, answer)
        }
    }

    /// Closing the panel refuses what waits.
    func panelClosed() {
        answerAll(.closed)
    }

    /// Allows what no longer needs asking once the user unlocks.
    func agentsUnlocked() {
        for request in agentRequests where !mustAsk(request.agent) {
            answer(request.id, .allowed)
        }
        agentPromptChanged()
    }

    /// Makes Enter wait a moment before it allows the request that shows:
    /// a key the user meant for another app must not allow it.
    func agentPromptChanged() {
        agentPrompt += 1
        agentRequestReady = false
        let prompt = agentPrompt
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, agentPrompt == prompt, !agentRequests.isEmpty else { return }
            agentRequestReady = true
        }
    }
}
