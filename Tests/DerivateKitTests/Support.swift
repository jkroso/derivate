import Foundation
@testable import DerivateKit

// Vectors of Spectre's test files (mpw_tests.xml, spectre_tests.xml).
let robert = "Robert Lee Mitchell"
let banana = "banana colored duckling"
let mpw = "masterpasswordapp.com"

/// Derives each name and secret once: scrypt is slow on purpose.
final class KeyCache: @unchecked Sendable {
    static let shared = KeyCache()

    private let lock = NSLock()
    private var keys: [String: Key] = [:]

    /// The key of a name and secret: a copy, which a test may wipe.
    func key(_ name: String, _ secret: String) throws -> Key {
        try lock.withLock {
            let id = name + "\u{0}" + secret
            if let key = keys[id] {
                return Key(copying: key)
            }
            let key = try Key(fullName: name, secret: secret)
            keys[id] = key
            return Key(copying: key)
        }
    }
}

func cachedKey(_ name: String = robert, _ secret: String = banana) throws -> Key {
    try KeyCache.shared.key(name, secret)
}

extension User {
    /// Unlocks with a key of the cache.
    mutating func unlockCached(secret: String) throws -> Key {
        try unlock(secret: secret, key: KeyCache.shared.key(name, secret))
    }
}
