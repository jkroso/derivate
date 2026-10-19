import CommonCrypto
import CryptoKit
import Foundation

/// A user's key, derived from their name and secret: it derives the results
/// of their sites. Wipe it when done.
public final class Key: @unchecked Sendable {
    /// The key of versions 0 to 2, which count the letters of the name.
    private var byCharacters: [UInt8]
    /// The key of version 3, which counts its bytes. For a name in ASCII
    /// they are the same key.
    private var byBytes: [UInt8]

    /// Derives the key of a user. It runs scrypt, once for a name in ASCII
    /// and twice otherwise, which takes a moment: call it off the main
    /// thread.
    public init(fullName: String, secret: String) throws {
        guard !fullName.isEmpty, !secret.isEmpty else { throw SpectreError.missingNameOrSecret }
        let characters = fullName.unicodeScalars.count, bytes = fullName.utf8.count
        byCharacters = Self.userKey(fullName, secret, nameLength: characters)
        byBytes = bytes == characters ? byCharacters : Self.userKey(fullName, secret, nameLength: bytes)
    }

    /// A copy of another key, which wipes apart from it: the arrays copy
    /// as either is written to.
    init(copying other: Key) {
        byCharacters = other.byCharacters
        byBytes = other.byBytes
    }

    deinit { wipe() }

    private static func userKey(_ fullName: String, _ secret: String, nameLength: Int) -> [UInt8] {
        let salt = Array(Purpose.scope.utf8) + UInt32(nameLength).bigEndianBytes + Array(fullName.utf8)
        return Scrypt.key(password: Array(secret.utf8), salt: salt, n: 32768, r: 8, p: 2, length: 64)
    }

    /// The key's identifier for an algorithm, as export files keep it: the
    /// SHA-256 of the key, in upper-case hex.
    public func id(for algorithm: Algorithm) -> String {
        SHA256.hash(data: key(for: algorithm)).map { String(format: "%02X", $0) }.joined()
    }

    /// Whether the key has the ID an export file keeps.
    public func matches(id: String, algorithm: Algorithm) -> Bool {
        let mine = Array(self.id(for: algorithm).utf8), theirs = Array(id.uppercased().utf8)
        guard mine.count == theirs.count else { return false }
        return zip(mine, theirs).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 // in constant time
    }

    /// Overwrites the key.
    public func wipe() {
        for i in byCharacters.indices { byCharacters[i] = 0 }
        for i in byBytes.indices { byBytes[i] = 0 }
    }

    func key(for algorithm: Algorithm) -> [UInt8] {
        algorithm < .v3 ? byCharacters : byBytes
    }

    /// The HMAC of a site's name, counter and context. Counter 0 is
    /// Spectre's time-based counter, which changes every 5 minutes.
    private func siteKey(_ siteName: String, counter: UInt32, purpose: Purpose, context: String, algorithm: Algorithm) -> [UInt8] {
        // Versions 0 and 1 count the letters of the name and the context,
        // later versions their bytes.
        func length(_ text: String) -> [UInt8] {
            UInt32(algorithm < .v2 ? text.unicodeScalars.count : text.utf8.count).bigEndianBytes
        }
        let counter = counter != 0 ? counter : UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970) / 300 * 300)
        var message = Array(purpose.scope.utf8) + length(siteName) + Array(siteName.utf8) + counter.bigEndianBytes
        if !context.isEmpty {
            message += length(context) + Array(context.utf8)
        }
        return Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key(for: algorithm))))
    }

    /// What a site's type makes of it: a password from a template, or the
    /// stored password `state` holds, decrypted.
    public func result(for siteName: String, counter: UInt32, purpose: Purpose, context: String = "",
                       type: ResultType, state: String? = nil, algorithm: Algorithm) throws -> String {
        if type.isTemplate {
            return try template(siteName, counter: counter, purpose: purpose, context: context, type: type, algorithm: algorithm)
        }
        if type.isStateful {
            guard let state, !state.isEmpty else { throw SpectreError.noStoredPassword }
            return try decrypt(state, algorithm: algorithm)
        }
        throw SpectreError.unsupportedType(type.rawValue)
    }

    private func template(_ siteName: String, counter: UInt32, purpose: Purpose, context: String,
                          type: ResultType, algorithm: Algorithm) throws -> String {
        let templates = type.templates
        guard !templates.isEmpty else { throw SpectreError.unsupportedType(type.rawValue) }
        let seed = siteKey(siteName, counter: counter, purpose: purpose, context: context, algorithm: algorithm)
        // Version 0 read the seed's bytes as signed chars, widened to 16 bits
        // and swapped to network order: index by what that made of them.
        func at(_ i: Int) -> Int {
            let byte = Int(seed[i])
            guard algorithm == .v0 else { return byte }
            return byte << 8 | (byte >= 0x80 ? 0xff : 0)
        }
        let template = templates[at(0) % templates.count]
        var password: [UInt8] = []
        for (i, letter) in template.enumerated() {
            guard let characters = ResultType.characterClasses[letter] else { throw SpectreError.unsupportedType(type.rawValue) }
            password.append(characters[at(i + 1) % characters.count])
        }
        return String(decoding: password, as: UTF8.self)
    }

    /// Encrypts a password to store for a site, as Spectre stores them:
    /// AES-128 in CBC mode with the first 16 bytes of the user's key, a zero
    /// IV and PKCS#7 padding, in base64.
    public func encrypt(_ plain: String, algorithm: Algorithm) throws -> String {
        var buffer = Array(plain.utf8)
        let padding = kCCBlockSizeAES128 - buffer.count % kCCBlockSizeAES128
        buffer += repeatElement(UInt8(padding), count: padding)
        return Data(try aes(CCOperation(kCCEncrypt), buffer, algorithm: algorithm)).base64EncodedString()
    }

    func decrypt(_ state: String, algorithm: Algorithm) throws -> String {
        let state = String(String.UnicodeScalarView(state.unicodeScalars.filter { !" \n\r\t\u{0B}".unicodeScalars.contains($0) }))
        // What is not base64 is text an old export kept in the clear, as
        // Spectre reads it: Master Password's login names were.
        guard state.utf8.count % 4 == 0 else { return state }
        guard let sealed = Data(base64Encoded: state), !sealed.isEmpty, sealed.count % kCCBlockSizeAES128 == 0 else {
            throw SpectreError.undecryptable
        }
        var plain = try aes(CCOperation(kCCDecrypt), Array(sealed), algorithm: algorithm)
        guard let padding = plain.last, (1...UInt8(kCCBlockSizeAES128)).contains(padding),
              plain.suffix(Int(padding)).allSatisfy({ $0 == padding }) else {
            throw SpectreError.undecryptable
        }
        plain.removeLast(Int(padding))
        if let end = plain.firstIndex(of: 0) {
            plain.removeSubrange(end...)
        }
        guard let text = String(bytes: plain, encoding: .utf8) else { throw SpectreError.undecryptable }
        return text
    }

    /// AES-128-CBC with a zero IV and no padding, over whole blocks.
    private func aes(_ operation: CCOperation, _ input: [UInt8], algorithm: Algorithm) throws -> [UInt8] {
        let key = Array(key(for: algorithm).prefix(kCCKeySizeAES128))
        let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { output in
            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), 0, key, key.count, iv,
                    input, input.count, output.baseAddress, output.count, &moved)
        }
        guard status == kCCSuccess, moved == input.count else { throw SpectreError.undecryptable }
        return output
    }

    /// Whether a stored value is what ``encrypt(_:algorithm:)`` makes: base64
    /// of whole AES blocks.
    static func isSealed(_ state: String) -> Bool {
        guard let data = Data(base64Encoded: state) else { return false }
        return !data.isEmpty && data.count % kCCBlockSizeAES128 == 0
    }
}

extension Key {
    /// The site's password.
    public func password(for site: Site) throws -> String {
        try result(for: site.name, counter: site.counter, purpose: .authentication,
                   type: site.type, state: site.state, algorithm: site.algorithm)
    }

    /// The site's login name. A site without a login type of its own takes
    /// the user's login type and name, made for the site's name, as
    /// Spectre's app does: with the type Name, each site has a login name of
    /// its own, as in Master Password.
    public func login(for site: Site, of user: User) throws -> String {
        let (type, state) = if let own = site.loginType {
            (own, site.loginState)
        } else {
            (user.loginType ?? .name, user.loginState)
        }
        return try result(for: site.name, counter: 1, purpose: .identification,
                          type: type, state: state, algorithm: site.algorithm)
    }

    /// The answer to a security question of the site.
    public func answer(to question: Question, for site: Site) throws -> String {
        let type = question.type.rawValue == 0 ? .phrase : question.type
        return try result(for: site.name, counter: 1, purpose: .recovery, context: question.keyword,
                          type: type, state: question.state, algorithm: site.algorithm)
    }
}
