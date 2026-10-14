import Testing
@testable import DerivateKit

struct Vector: Sendable, CustomTestStringConvertible {
    var algorithm: Algorithm
    var name = robert, secret = banana
    var site = mpw
    var counter: UInt32 = 1
    var type: ResultType = .long
    var purpose: Purpose = .authentication
    var context = "", state: String?
    var want: String

    var testDescription: String { "v\(algorithm.rawValue) \(name)/\(secret) \(site) #\(counter) \(type) \(purpose) \(context)" }
}

let vectors: [Vector] = [
    Vector(algorithm: .v3, want: "Jejr5[RepuSosp"),
    Vector(algorithm: .v2, want: "Jejr5[RepuSosp"),
    Vector(algorithm: .v1, want: "Jejr5[RepuSosp"),
    Vector(algorithm: .v0, want: "Feji5@ReduWosh"),
    Vector(algorithm: .v3, type: .maximum, want: "W6@692^B1#&@gVdSdLZ@"),
    Vector(algorithm: .v3, type: .medium, want: "Jej2$Quv"),
    Vector(algorithm: .v3, type: .basic, want: "WAo2xIg6"),
    Vector(algorithm: .v3, type: .short, want: "Jej2"),
    Vector(algorithm: .v3, type: .pin, want: "7662"),
    Vector(algorithm: .v3, type: .name, want: "jejraquvo"),
    Vector(algorithm: .v3, type: .phrase, want: "jejr quv cabsibu tam"),
    Vector(algorithm: .v3, type: .name, purpose: .identification, want: "wohzaqage"),
    Vector(algorithm: .v3, type: .phrase, purpose: .recovery, want: "xin diyjiqoja hubu"),
    Vector(algorithm: .v3, type: .phrase, purpose: .recovery, context: "question", want: "xogx tem cegyiva jab"),
    Vector(algorithm: .v3, counter: 4_294_967_295, want: "XambHoqo6[Peni"),
    Vector(algorithm: .v3, name: "⛄", want: "NopaDajh8=Fene"),
    Vector(algorithm: .v2, name: "⛄", want: "WaqoGuho2[Xaxw"),
    Vector(algorithm: .v3, secret: "⛄", want: "QesuHirv5-Xepl"),
    Vector(algorithm: .v2, site: "⛄", want: "LiheCuwhSerz6)"),
    Vector(algorithm: .v1, site: "⛄", want: "WawiYarp2@Kodh"),
    Vector(algorithm: .v0, type: .maximum, want: "w1!3bA3icmRAc)SS@lwl"),
    Vector(algorithm: .v0, type: .medium, want: "Fej7]Jug"),
    Vector(algorithm: .v0, type: .basic, want: "wvH7irC1"),
    Vector(algorithm: .v0, type: .short, want: "Fej7"),
    Vector(algorithm: .v0, type: .pin, want: "2117"),
    Vector(algorithm: .v0, type: .name, want: "fejrajugo"),
    Vector(algorithm: .v0, type: .phrase, want: "fejr jug gabsibu bax"),
    Vector(algorithm: .v0, type: .name, purpose: .identification, want: "lozwajave"),
    Vector(algorithm: .v0, type: .phrase, purpose: .recovery, want: "miy lirfijoja dubu"),
    Vector(algorithm: .v0, type: .phrase, purpose: .recovery, context: "question", want: "movm bex gevrica jaf"),
    Vector(algorithm: .v0, counter: 4_294_967_295, want: "QateDojh1@Hecn"),
    Vector(algorithm: .v0, name: "⛄", want: "HajrYudo7@Mamh"),
    Vector(algorithm: .v0, secret: "⛄", want: "MewmDini0]Meho"),
    Vector(algorithm: .v0, site: "⛄", want: "HahiVana2@Nole"),
    Vector(algorithm: .v3, site: "spectre.app", want: "ReqoCenuXonu1?"),
    Vector(algorithm: .v0, site: "spectre.app", want: "NejoKecuMocx6@"),
    Vector(algorithm: .v3, site: "spectre.app", type: .name, purpose: .identification, want: "wesruqori"),
    Vector(algorithm: .v3, site: "spectre.app", type: .phrase, purpose: .recovery, context: "question", want: "lek yubgiguko ruzo"),
    Vector(algorithm: .v3, site: "spectre.app", counter: 4_294_967_294, want: "LoqiWarcFetd6("),
    Vector(algorithm: .v3, name: "⛄", site: "spectre.app", want: "Wewa9$YaqdDaje"),
    Vector(algorithm: .v2, name: "⛄", site: "spectre.app", want: "KoyvTocoVeyx8*"),
    Vector(algorithm: .v0, name: "⛄", site: "spectre.app", want: "KovgXogoCevq8!"),
    Vector(algorithm: .v3, site: "spectre.app", type: .personal, state: "IfzlLN4J7XNazwSa17xB7A==", want: "password"),
    Vector(algorithm: .v0, site: "spectre.app", type: .personal, state: "det+TQ+yVcDxLZ30EE7hMw==", want: "⛄"),
]

@Test(arguments: vectors)
func result(_ v: Vector) throws {
    let got = try cachedKey(v.name, v.secret).result(for: v.site, counter: v.counter, purpose: v.purpose, context: v.context,
                                               type: v.type, state: v.state, algorithm: v.algorithm)
    #expect(got == v.want)
}

@Test(arguments: [
    (Algorithm.v3, robert, banana, "98EEF4D1DF46D849574A82A03C3177056B15DFFCA29BB3899DE4628453675302"),
    (.v0, robert, banana, "98EEF4D1DF46D849574A82A03C3177056B15DFFCA29BB3899DE4628453675302"),
    (.v3, "⛄", banana, "1717AA1F9BF5BA56CD0965CDA3D78E6D2E6A1EA8C067A8EA621F3DDAD4A87EB8"),
    (.v2, "⛄", banana, "4D5851D0B093D65DE0CF13D94877270468C0B65A6E42CA50D393AC9B99C457B5"),
    (.v3, robert, "⛄", "351432B8528A5ABECAB768CA95015097DE76FE14C41E10AF36C67DCFB8917E08"),
])
func keyID(algorithm: Algorithm, name: String, secret: String, want: String) throws {
    let key = try cachedKey(name, secret)
    #expect(key.id(for: algorithm) == want)
    #expect(key.matches(id: want.lowercased(), algorithm: algorithm), "a lower-case key ID matches")
}

@Test func storedPasswords() throws {
    let key = try cachedKey()
    for plain in ["password", "⛄", "", "sixteen bytes!!!", String(repeating: "x", count: 100)] {
        let state = try key.encrypt(plain, algorithm: .v3)
        let got = plain.isEmpty
            ? try key.decrypt(state, algorithm: .v3)
            : try key.result(for: "any.site", counter: 1, purpose: .authentication, type: .personal, state: state, algorithm: .v3)
        #expect(got == plain, "\(plain) stored as \(state)")
    }
    #expect(try key.encrypt("password", algorithm: .v3) == "IfzlLN4J7XNazwSa17xB7A==", "as Spectre stores it")
    // Another user's key does not decrypt it.
    let other = try cachedKey(robert, "⛄")
    #expect(throws: (any Error).self) {
        try other.result(for: "any.site", counter: 1, purpose: .authentication, type: .personal,
                         state: "IfzlLN4J7XNazwSa17xB7A==", algorithm: .v3)
    }
    // Text an old export kept in the clear reads as it is.
    #expect(try key.result(for: "any.site", counter: 1, purpose: .identification, type: .personal, state: "robert", algorithm: .v3) == "robert")
}

@Test func identicon() {
    #expect(User.identicon(name: robert, secret: banana) == "2:╚☻╯⛄")
}

@Test func login() throws {
    let key = try cachedKey()
    var user = User(name: robert)
    var site = user.newSite(named: mpw)
    // A site without a login of its own takes the user's type, Name, for
    // its own name: Master Password's login for it.
    site.loginType = nil
    #expect(try key.login(for: site, of: user) == "wohzaqage")
    site.loginType = .personal
    site.loginState = try key.encrypt("robert@example.com", algorithm: site.algorithm)
    #expect(try key.login(for: site, of: user) == "robert@example.com")
    // A user whose standard login is stored has it on every site.
    user.loginType = .personal
    user.loginState = try key.encrypt("rlm", algorithm: user.algorithm)
    site.loginType = nil
    site.loginState = nil
    #expect(try key.login(for: site, of: user) == "rlm")
}

@Test func unlock() throws {
    var user = User(name: robert)
    user.keyID = "98EEF4D1DF46D849574A82A03C3177056B15DFFCA29BB3899DE4628453675302"
    #expect(throws: SpectreError.wrongSecret) { try user.unlockCached(secret: "banana colored ducklin") }
    let key = try user.unlockCached(secret: banana)
    key.wipe()
    var fresh = User(name: robert)
    _ = try fresh.unlockCached(secret: banana)
    #expect(fresh.keyID == user.keyID)
    #expect(fresh.identicon == "2:╚☻╯⛄")
}

@Test func newKeyNeedsANameAndASecret() {
    #expect(throws: SpectreError.missingNameOrSecret) { try Key(fullName: "", secret: banana) }
    #expect(throws: SpectreError.missingNameOrSecret) { try Key(fullName: robert, secret: "") }
}
