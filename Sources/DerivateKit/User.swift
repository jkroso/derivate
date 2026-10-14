import CryptoKit
import Foundation

/// A Spectre user and their sites, as an export file holds them.
public struct User: Sendable, Equatable {
    public var name: String
    public var avatar: Int = 0
    /// "color:glyphs", which Spectre shows to check a secret as it is typed.
    public var identicon: String?
    public var algorithm: Algorithm = .current
    /// The ID of the user's key, which checks their secret; nil if unknown.
    public var keyID: String?
    /// The type of new sites.
    public var defaultType: ResultType = .long
    /// The type of the user's standard login name.
    public var loginType: ResultType?
    /// The standard login name, encrypted, when ``loginType`` is stateful.
    public var loginState: String?
    public var lastUsed: Date?
    public var sites: [Site] = []
    /// False for an export that holds stored passwords and login names in
    /// the clear: ``unlock(secret:)`` encrypts them.
    public var isRedacted = true

    // What this library does not read of the user, the export and the file,
    // written back as it was.
    var extras = JSONObject()
    var exportExtras = JSONObject()
    var fileExtras = JSONObject()

    /// A user who starts with no sites.
    public init(name: String) {
        self.name = name
        loginType = .name
    }

    /// The user's site of that name, in any case.
    public func site(named name: String) -> Site? {
        siteIndex(named: name).map { sites[$0] }
    }

    /// The index of the user's site of that name, in any case.
    public func siteIndex(named name: String) -> Int? {
        sites.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A site the user does not have yet, with their default type.
    public func newSite(named name: String) -> Site {
        Site(name: name, type: defaultType.rawValue == 0 ? .long : defaultType)
    }

    /// Adds the sites of another export of the user: a site both have keeps
    /// the one used last.
    public mutating func merge(_ other: User) {
        for site in other.sites {
            if let i = siteIndex(named: site.name) {
                if site.lastUsed.isAfter(sites[i].lastUsed) {
                    sites[i] = site
                }
            } else {
                sites.append(site)
            }
        }
        if other.lastUsed.isAfter(lastUsed) {
            lastUsed = other.lastUsed
        }
    }

    /// Derives the user's key from their secret and checks it against their
    /// key ID, which a new user takes from it, then encrypts what an export
    /// held in the clear. It runs scrypt: call it off the main thread.
    public mutating func unlock(secret: String) throws -> Key {
        try unlock(secret: secret, key: Key(fullName: name, secret: secret))
    }

    /// Unlocks with a key already derived from the user's name and secret.
    mutating func unlock(secret: String, key: Key) throws -> Key {
        if let keyID, !keyID.isEmpty {
            guard key.matches(id: keyID, algorithm: algorithm) else {
                key.wipe()
                throw SpectreError.wrongSecret
            }
        } else {
            keyID = key.id(for: algorithm)
        }
        if identicon?.isEmpty ?? true {
            identicon = Self.identicon(name: name, secret: secret)
        }
        do {
            try seal(with: key)
        } catch {
            key.wipe()
            throw error
        }
        return key
    }

    /// Encrypts what an export held in the clear.
    private mutating func seal(with key: Key) throws {
        func encrypt(_ state: inout String?, type: ResultType?, algorithm: Algorithm, inTheClear: Bool) throws {
            guard inTheClear, type?.isStateful == true, let plain = state, !plain.isEmpty else { return }
            state = try key.encrypt(plain, algorithm: algorithm)
        }
        let inTheClear = !isRedacted
        try encrypt(&loginState, type: loginType, algorithm: algorithm, inTheClear: inTheClear)
        for i in sites.indices {
            let algorithm = sites[i].algorithm
            try encrypt(&sites[i].state, type: sites[i].type, algorithm: algorithm, inTheClear: inTheClear)
            try encrypt(&sites[i].loginState, type: sites[i].loginType, algorithm: algorithm,
                        inTheClear: inTheClear || sites[i].hasPlainLogin)
            for j in sites[i].questions.indices {
                try encrypt(&sites[i].questions[j].state, type: sites[i].questions[j].type, algorithm: algorithm,
                            inTheClear: inTheClear)
            }
            sites[i].hasPlainLogin = false
        }
        isRedacted = true
    }

    /// Spectre's identicon of a name and secret, as "color:glyphs": the same
    /// name and secret always give the same one, so a user who knows theirs
    /// sees a mistyped secret before it unlocks. Colors run from 1 (red) to 7
    /// (mono).
    public static func identicon(name: String, secret: String) -> String {
        let seed = Array(HMAC<SHA256>.authenticationCode(for: Array(name.utf8), using: SymmetricKey(data: Array(secret.utf8))))
        let left = ["╔", "╚", "╰", "═"]
        let bodies = ["█", "░", "▒", "▓", "☺", "☻"]
        let right = ["╗", "╝", "╯", "═"]
        let accessories = [
            "◈", "◎", "◐", "◑", "◒", "◓", "☀", "☁", "☂", "☃", "☄", "★", "☆", "☎", "☏", "⎈", "⌂", "☘", "☢", "☣",
            "☕", "⌚", "⌛", "⏰", "⚡", "⛄", "⛅", "☔", "♔", "♕", "♖", "♗", "♘", "♙", "♚", "♛", "♜", "♝", "♞", "♟",
            "♨", "♩", "♪", "♫", "⚐", "⚑", "⚔", "⚖", "⚙", "⚠", "⌘", "⏎", "✄", "✆", "✈", "✉", "✌",
        ]
        func pick(_ glyphs: [String], _ byte: UInt8) -> String { glyphs[Int(byte) % glyphs.count] }
        return "\(seed[4] % 7 + 1):" + pick(left, seed[0]) + pick(bodies, seed[1]) + pick(right, seed[2]) + pick(accessories, seed[3])
    }
}

/// A site of a user.
public struct Site: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var type: ResultType
    public var counter: UInt32
    public var algorithm: Algorithm
    /// The stored password, encrypted, when ``type`` is stateful.
    public var state: String?
    /// The type of the site's own login name; nil for the user's standard
    /// login type and name.
    public var loginType: ResultType?
    /// The site's own login name, encrypted, when ``loginType`` is stateful.
    public var loginState: String?
    public var url: String?
    public var uses: UInt32 = 0
    public var lastUsed: Date?
    public var questions: [Question] = []

    /// ``loginState`` is in the clear, as old exports kept login names.
    var hasPlainLogin = false
    var extras = JSONObject()

    public init(name: String, type: ResultType = .long, counter: UInt32 = 1, algorithm: Algorithm = .current) {
        self.name = name
        self.type = type
        self.counter = counter
        self.algorithm = algorithm
    }
}

/// A security question of a site, by a keyword of it; the keyword ""
/// answers any question.
public struct Question: Sendable, Equatable {
    public var keyword: String
    public var type: ResultType
    public var state: String?

    var extras = JSONObject()

    public init(keyword: String, type: ResultType = .phrase, state: String? = nil) {
        self.keyword = keyword
        self.type = type
        self.state = state
    }
}

extension Optional where Wrapped == Date {
    /// Whether this time is after another, where no time is before all.
    func isAfter(_ other: Date?) -> Bool {
        (self ?? .distantPast) > (other ?? .distantPast)
    }
}
