import Foundation
import Testing
@testable import DerivateKit

struct SealTests {
    private let context = Data("Derivate secrets 1\n".utf8)

    /// Binary data, with zero bytes, opens as it was sealed. Each seal
    /// takes a new nonce.
    @Test func roundTrip() throws {
        let key = try cachedKey()
        let data = Data((0...255).map(UInt8.init))
        let sealed = try key.seal(data, context: context)
        #expect(try key.open(sealed, context: context) == data)
        #expect(try key.seal(data, context: context) != sealed)
        #expect(try key.open(key.seal(Data())) == Data())
    }

    /// A file Derivate sealed before opens the same way: users' secrets
    /// files hold data like it.
    @Test func opensWhatItSealedBefore() throws {
        let sealed = try #require(Data(base64Encoded: "Ddcya2o4JUftITkONhI3D24L7f2qmPYBJk0hKOAVOgcQ9sXIU6nmyNisTPE="))
        #expect(try cachedKey().open(sealed, context: context) == Data("Developer ID\u{0}\u{1}\u{FF}".utf8))
    }

    /// Another user's key, another context or a changed byte do not open
    /// it.
    @Test func refusesWhatChanged() throws {
        let key = try cachedKey()
        let sealed = try key.seal(Data("p12 password".utf8), context: context)
        #expect(throws: SpectreError.undecryptable) { try cachedKey("⛄", banana).open(sealed, context: context) }
        #expect(throws: SpectreError.undecryptable) { try key.open(sealed) }
        var changed = sealed
        changed[changed.count / 2] ^= 1
        #expect(throws: SpectreError.undecryptable) { try key.open(changed, context: context) }
        #expect(throws: SpectreError.undecryptable) { try key.open(sealed.prefix(20), context: context) }
    }
}
