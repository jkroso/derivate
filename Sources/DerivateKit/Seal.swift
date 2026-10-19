import CryptoKit
import Foundation

extension Key {
    /// Encrypts data that Spectre's files do not hold, such as files the
    /// user keeps: AES-256 in GCM mode, with a key that HKDF derives from
    /// the user's key for this alone. Each call takes a new nonce, so the
    /// same data seals differently each time. `context` is not encrypted,
    /// but ``open(_:context:)`` needs the same one.
    public func seal(_ data: Data, context: Data = Data()) throws -> Data {
        guard let sealed = try AES.GCM.seal(data, using: sealingKey, authenticating: context).combined else {
            throw SpectreError.undecryptable
        }
        return sealed
    }

    /// Decrypts what ``seal(_:context:)`` made with this key and context,
    /// and fails if anything of it changed since.
    public func open(_ sealed: Data, context: Data = Data()) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: sealingKey, authenticating: context)
        } catch {
            throw SpectreError.undecryptable
        }
    }

    private var sealingKey: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key(for: .current)),
                               info: Data("Derivate sealing".utf8), outputByteCount: 32)
    }
}
