// DerivateKit derives passwords as Spectre (spectre.app), formerly Master
// Password, does: from a user's full name and secret, a site's name and a
// counter, with versions 0 to 3 of its algorithm. It also reads and writes
// Spectre's export files.

import Foundation

/// A version of Spectre's algorithm. Each site keeps the version it was
/// made with; new sites take ``current``.
public enum Algorithm: Int, Sendable, CaseIterable, Comparable {
    case v0 = 0, v1, v2, v3

    public static let current: Algorithm = .v3

    public static func < (a: Algorithm, b: Algorithm) -> Bool { a.rawValue < b.rawValue }
}

/// What a result is for, which seeds its key apart.
public enum Purpose: Sendable {
    /// A password.
    case authentication
    /// A login name.
    case identification
    /// A security answer.
    case recovery

    static let scope = "com.lyndir.masterpassword"

    var scope: String {
        switch self {
        case .authentication: Self.scope
        case .identification: Self.scope + ".login"
        case .recovery: Self.scope + ".answer"
        }
    }
}

public enum SpectreError: Error, Equatable, LocalizedError {
    /// The secret does not match the user's key ID.
    case wrongSecret
    case missingNameOrSecret
    /// The site's type stores its password, and it has none yet.
    case noStoredPassword
    case unsupportedType(UInt32)
    /// The stored password does not decrypt with this key.
    case undecryptable
    /// The user holds passwords in the clear, as an export showed them:
    /// unlock it before it exports.
    case passwordsInTheClear
    /// A file Spectre would not read, and why, in English.
    case invalidExport(String)

    public var errorDescription: String? {
        switch self {
        case .wrongSecret: "The master password does not match this user's key."
        case .missingNameOrSecret: "A name and a master password are needed."
        case .noStoredPassword: "The site has no stored password."
        case .unsupportedType(let type): "This app does not support result type \(type)."
        case .undecryptable: "The stored password does not decrypt with this key."
        case .passwordsInTheClear: "The user holds passwords in the clear. Unlock it before you export it."
        case .invalidExport(let message): message
        }
    }
}
