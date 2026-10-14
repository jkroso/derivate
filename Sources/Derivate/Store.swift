import Foundation
import DerivateKit

/// The app's preferences, in settings.json in its data folder.
struct Settings: Equatable {
    /// Opens the panel from any app; nil has none.
    var shortcut: Shortcut? = .standard
    /// How long a copied password stays on the clipboard, in seconds; 0
    /// keeps it.
    var clearAfter = 60
    /// The name of the user who unlocked last.
    var lastUser: String?
    /// When Derivate asks before it answers AI agents; off runs no server.
    var agents = AgentAccess.ask
    /// The key agents send, which the setup command gives them.
    var agentKey: String?
    /// The port of the server for agents, on 127.0.0.1.
    var agentPort = 39736
}

extension Settings: Codable {
    private enum CodingKeys: String, CodingKey { case shortcut, clearAfter, lastUser, agents, agentKey, agentPort }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try c.decodeIfPresent(String.self, forKey: .shortcut) {
            shortcut = Shortcut(text) // "" has none
        }
        clearAfter = try c.decodeIfPresent(Int.self, forKey: .clearAfter) ?? 60
        lastUser = try c.decodeIfPresent(String.self, forKey: .lastUser)
        agents = (try? c.decodeIfPresent(AgentAccess.self, forKey: .agents)) ?? .ask
        agentKey = try c.decodeIfPresent(String.self, forKey: .agentKey)
        agentPort = try c.decodeIfPresent(Int.self, forKey: .agentPort) ?? 39736
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shortcut?.text ?? "", forKey: .shortcut)
        try c.encode(clearAfter, forKey: .clearAfter)
        try c.encodeIfPresent(lastUser, forKey: .lastUser)
        try c.encode(agents, forKey: .agents)
        try c.encodeIfPresent(agentKey, forKey: .agentKey)
        try c.encode(agentPort, forKey: .agentPort)
    }
}

/// The app's files: each user is a Spectre export, users/<name>.mpjson,
/// with stored passwords encrypted, as Spectre keeps them. No secret or
/// key is ever written.
struct Store {
    let folder: URL

    /// The data folder: DERIVATE_DIR, else Application Support.
    static func standard() -> Store {
        if let dir = ProcessInfo.processInfo.environment["DERIVATE_DIR"], !dir.isEmpty {
            return Store(folder: URL(filePath: dir, directoryHint: .isDirectory))
        }
        return Store(folder: URL.applicationSupportDirectory.appending(path: "Derivate", directoryHint: .isDirectory))
    }

    /// Moves the data folder of SpectreBar, this app's old name, to this
    /// app's in Application Support, if that does not exist yet. Returns
    /// whether it moved it.
    static func moveFromSpectreBar() -> Bool {
        let support = URL.applicationSupportDirectory
        let old = support.appending(path: "SpectreBar", directoryHint: .isDirectory)
        let new = support.appending(path: "Derivate", directoryHint: .isDirectory)
        let files = FileManager.default
        guard !files.fileExists(atPath: new.path), files.fileExists(atPath: old.path) else { return false }
        return (try? files.moveItem(at: old, to: new)) != nil
    }

    private var usersFolder: URL { folder.appending(path: "users", directoryHint: .isDirectory) }
    private var settingsFile: URL { folder.appending(path: "settings.json") }

    func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsFile) else { return Settings() }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    func save(_ settings: Settings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? write(data, to: settingsFile)
        }
    }

    /// The users whose files read, by name.
    func loadUsers() -> [User] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: usersFolder.path)) ?? []
        return names.filter { $0.hasSuffix(".mpjson") }.compactMap { name in
            let file = usersFolder.appending(path: name)
            do {
                return try User(importing: Data(contentsOf: file))
            } catch {
                NSLog("Derivate: %@: %@", file.path, error.localizedDescription)
                return nil
            }
        }
        .sorted { $0.name < $1.name }
    }

    func save(_ user: User) throws {
        try write(user.exportData(), to: file(of: user))
    }

    func delete(_ user: User) throws {
        do {
            try FileManager.default.removeItem(at: file(of: user))
        } catch CocoaError.fileNoSuchFile {
        }
    }

    /// The user's file name: their name, without the characters file
    /// systems refuse.
    func file(of user: User) -> URL {
        let name = String(user.name.map { #"/\:*?"<>|"#.contains($0) || $0.isControl ? "_" : $0 })
        return usersFolder.appending(path: name + ".mpjson")
    }

    /// Replaces a file at once, readable by the user alone.
    private func write(_ data: Data, to file: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: [.atomic])
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private extension Character {
    var isControl: Bool { unicodeScalars.contains { $0.properties.generalCategory == .control } }
}
