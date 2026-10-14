import Foundation
import Testing
@testable import DerivateKit

private func header(format: Int, passwords: String) -> String {
    """
    # Spectre site export
    #     Export of site names and stored passwords (unless device-private) encrypted with the user key.
    #
    ##
    # Format: \(format)
    # Date: 2021-10-31T00:00:00Z
    # User Name: Robert Lee Mitchell
    # Full Name: Robert Lee Mitchell
    # Avatar: 3
    # Key ID: 98EEF4D1DF46D849574A82A03C3177056B15DFFCA29BB3899DE4628453675302
    # Algorithm: 3
    # Default Type: 17
    # Passwords: \(passwords)
    ##
    #

    """
}

/// Imports an export and gives a site's password and login.
private func password(_ export: String, site name: String) throws -> (password: String, login: String) {
    var user = try User(importing: Data(export.utf8))
    let key = try user.unlockCached(secret: banana)
    let site = try #require(user.site(named: name), "no site \(name) in \(user.sites.map(\.name))")
    return (try key.password(for: site), (try? key.login(for: site, of: user)) ?? "")
}

private func expected(_ site: String, counter: UInt32, type: ResultType, algorithm: Algorithm) throws -> String {
    try cachedKey().result(for: site, counter: counter, purpose: .authentication, type: type, algorithm: algorithm)
}

@Test func importFlat() throws {
    let format0 = header(format: 0, passwords: "PROTECTED") +
        "2021-10-31T00:00:00Z         1      17:3                spectre.app\t\n"
    #expect(try password(format0, site: "spectre.app").password == "ReqoCenuXonu1?")

    // Format 1, from Master Password's apps: a counter, a login name in the
    // clear, and a stored password.
    let format1 = header(format: 1, passwords: "PROTECTED") +
        "2021-10-31T00:00:00Z         4    17:3:2               robert@example.com\t     spectre.app\t\n" +
        "2021-10-30T00:00:00Z         1  1056:3:1                                 \t     stored.site\tIfzlLN4J7XNazwSa17xB7A==\n" +
        "2021-10-29T00:00:00Z         1    17:0:1                                 \tmasterpasswordapp.com\t\n"
    let spectre = try password(format1, site: "spectre.app")
    #expect(spectre.password == (try expected("spectre.app", counter: 2, type: .long, algorithm: .v3)))
    #expect(spectre.login == "robert@example.com")
    #expect(try password(format1, site: "stored.site").password == "password")
    let old = try password(format1, site: mpw)
    #expect(old.password == "Feji5@ReduWosh" && old.login == "lozwajave", "format 1, algorithm 0")

    // Passwords in the clear are encrypted as the export is unlocked.
    let visible = header(format: 1, passwords: "VISIBLE") +
        "2021-10-30T00:00:00Z         1  1056:3:1                                 \t     stored.site\thunter2\n"
    let user = try User(importing: Data(visible.utf8))
    #expect(throws: SpectreError.passwordsInTheClear, "an export in the clear exports before it is unlocked") {
        try user.exportData()
    }
    #expect(try password(visible, site: "stored.site").password == "hunter2")
}

/// Master Password 2's JSON, format 1, with extensions of its own.
private let format1JSON = """
{
    "export": {"format": 1, "redacted": true, "date": "2018-05-10T03:41:18Z", "_ext_other": {"save": "me"}},
    "_ext_other": {"save": "me"},
    "user": {
        "avatar": 3,
        "full_name": "Robert Lee Mitchell",
        "last_used": "2018-05-10T03:41:18Z",
        "key_id": "98EEF4D1DF46D849574A82A03C3177056B15DFFCA29BB3899DE4628453675302",
        "algorithm": 3,
        "default_type": 17,
        "_ext_mpw": {"save": "me"}
    },
    "sites": {
        "masterpasswordapp.com": {
            "type": 17, "counter": 1, "algorithm": 3, "login_type": 30, "uses": 2,
            "last_used": "2018-05-10T03:41:18Z",
            "questions": {"": {"type": 31}, "mother": {"type": 31}},
            "_ext_mpw": {"url": "https://masterpasswordapp.com", "save": "me"}
        },
        "stored.site": {
            "type": 1056, "counter": 1, "algorithm": 3,
            "password": "IfzlLN4J7XNazwSa17xB7A==",
            "login_type": 30, "uses": 1, "last_used": "2018-05-10T03:48:35Z"
        }
    }
}
"""

@Test func importJSON() throws {
    let result = try password(format1JSON, site: mpw)
    #expect(result.password == "Jejr5[RepuSosp" && result.login == "wohzaqage", "format 1")
    #expect(try password(format1JSON, site: "stored.site").password == "password")

    var user = try User(importing: Data(format1JSON.utf8))
    let site = try #require(user.site(named: mpw))
    #expect(site.url == "https://masterpasswordapp.com")
    #expect(site.uses == 2 && site.questions.count == 2 && site.loginType == nil)
    let key = try user.unlockCached(secret: banana)
    #expect(try key.answer(to: site.questions[0], for: site) == "xin diyjiqoja hubu")

    // Spectre's latest format, 3, with result_type.
    let format3 = """
    {
      "export": { "date": "2021-10-31T00:00:00Z", "redacted": true, "format": 3 },
      "user": {"avatar": 3, "full_name": "Robert Lee Mitchell", "algorithm": 3,
        "key_id": "98EEF4D1DF46D849574A82A03C3177056B15DFFCA29BB3899DE4628453675302",
        "result_type": 21, "login_type": 30, "last_used": "2021-10-31T00:00:00Z"},
      "sites": {"spectre.app": {"last_used": "2021-10-31T00:00:00Z"}}
    }
    """
    let latest = try password(format3, site: "spectre.app")
    #expect(latest.password == (try expected("spectre.app", counter: 1, type: .pin, algorithm: .v3)), "a site of the user's default type")
    #expect(latest.login == "wesruqori")
}

@Test(arguments: [
    ("not JSON", #"{"export": "#),
    ("no user", #"{"export": {"format": 2}, "sites": {}}"#),
    ("format 4", #"{"export": {"format": 4}, "user": {"full_name": "R", "last_used": "2021-10-31T00:00:00Z"}}"#),
    ("unknown type", #"{"export": {"format": 2}, "user": {"full_name": "R"}, "sites": {"a": {"type": 99}}}"#),
    ("empty name", #"{"export": {"format": 2}, "user": {"full_name": "R"}, "sites": {"": {"type": 17}}}"#),
    ("high counter", #"{"export": {"format": 2}, "user": {"full_name": "R"}, "sites": {"a": {"counter": 4294967295}}}"#),
    ("text", "Robert Lee Mitchell"),
    ("no flat users", "##\n# Format: 1\n##\n"),
])
func importRefuses(_ what: String, _ export: String) {
    #expect(throws: SpectreError.self, "\(what) imports") { try User(importing: Data(export.utf8)) }
}

/// What an export does not know of, it writes back as it was; what it
/// knows, Spectre's apps read.
@Test func exportRoundTrip() throws {
    var user = try User(importing: Data(format1JSON.utf8))
    let key = try user.unlockCached(secret: banana)
    var unicode = Site(name: "ünïcode.example", type: .personal)
    unicode.state = try key.encrypt("hunter2", algorithm: .v3)
    unicode.url = "https://ünïcode.example"
    user.sites.append(unicode)
    let data = try user.exportData()

    let document = try #require(JSON(parsing: data).object)
    #expect(document["_ext_other"]?.object?["save"] == .string("me"), "the file's own extension is kept")
    let export = try #require(document["export"]?.object), userFields = try #require(document["user"]?.object)
    #expect(export["format"] == .number("2") && export["_ext_other"] != nil)
    #expect(userFields["default_type"] == .number("17") && userFields["_ext_mpw"] != nil)
    let site = try #require(document["sites"]?.object?[mpw]?.object)
    #expect(site["_ext_spectre"]?.object?["url"] == .string("https://masterpasswordapp.com"))
    #expect(site["_ext_mpw"]?.object?["save"] == .string("me"))
    #expect(!String(decoding: data, as: UTF8.self).contains("hunter2"), "the export holds no stored password in the clear")

    var back = try User(importing: data)
    let backKey = try back.unlockCached(secret: banana)
    for site in user.sites {
        let other = try #require(back.site(named: site.name), "\(site.name) is gone")
        #expect(try key.password(for: site) == backKey.password(for: other))
        #expect(try key.login(for: site, of: user) == backKey.login(for: other, of: back))
        #expect(site.url == other.url && site.uses == other.uses && site.lastUsed == other.lastUsed)
        #expect(site.questions.count == other.questions.count)
    }
}

/// An export writes its JSON as it read it: keys in their order, numbers as
/// they were written.
@Test func jsonKeepsOrderAndNumbers() throws {
    let text = #"{"b": 1.50, "a": [1e3, -0, true, null], "c": {"z": "é\n\"/"}, "b": 2}"#
    let json = try JSON(parsing: Data(text.utf8))
    let object = try #require(json.object)
    #expect(object.members.map(\.key) == ["b", "a", "c", "b"])
    #expect(object["b"] == .number("2"), "the last of a key reads")
    #expect(json.formatted == """
    {
      "b": 1.50,
      "a": [
        1e3,
        -0,
        true,
        null
      ],
      "c": {
        "z": "é\\n\\"/"
      },
      "b": 2
    }

    """)
    #expect(throws: JSONSyntaxError.self) { try JSON(parsing: Data(#"{"a": 01}"#.utf8)) }
    #expect(throws: JSONSyntaxError.self) { try JSON(parsing: Data(#"{"a": 1} x"#.utf8)) }
}

@Test func timestamps() {
    #expect(Timestamp.format(Timestamp.parse("2021-10-31T00:00:00Z")) == "2021-10-31T00:00:00Z")
    #expect(Timestamp.format(Timestamp.parse("2021-10-31T11:00:00.75+11:00")) == "2021-10-31T00:00:00Z")
    #expect(Timestamp.parse("1970-01-01T00:00:00Z") == nil)
    #expect(Timestamp.parse("2021-02-30T00:00:00Z") == nil)
    #expect(Timestamp.format(nil) == "1970-01-01T00:00:00Z")
}

@Test func goIntegers() {
    #expect(UInt32(goSyntax: "0x10") == 16)
    #expect(UInt32(goSyntax: "010") == 8)
    #expect(UInt32(goSyntax: "1_000") == 1000)
    #expect(UInt32(goSyntax: "-1") == nil)
    #expect(UInt32(goSyntax: "+1") == nil)
    #expect(Int32(goSyntax: "-2147483648") == .min)
    #expect(Int32(goSyntax: "2147483648") == nil)
    #expect(Int32(goSyntax: "") == nil)
}
