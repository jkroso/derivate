import Foundation
import Testing
@testable import DerivateKit

/// The cases of Spectre's own test files, which SPECTRE_TESTS names, apart
/// by commas: spectre_tests.xml of gitlab.com/spectre.app/cli and
/// mpw_tests.xml of Master Password. Cases with an export import it; cases
/// of a format go through the export and back. Spectre's cases that expect
/// an error expect one here.
///
///     SPECTRE_TESTS=spectre_tests.xml,mpw_tests.xml swift test --filter Conformance
@Suite struct Conformance {
    static let files = ProcessInfo.processInfo.environment["SPECTRE_TESTS"]?
        .split(separator: ",").map(String.init) ?? []

    @Test(.enabled(if: !Conformance.files.isEmpty, "SPECTRE_TESTS is not set"), arguments: Conformance.files)
    func spectreXML(_ file: String) throws {
        let cases = try Self.cases(of: file)
        var pass = 0, fail = 0, skip = 0
        for (id, fields) in cases {
            switch try check(id, fields) {
            case .pass: pass += 1
            case .skip: skip += 1
            case .fail(let why):
                fail += 1
                Issue.record("\(id): \(why)")
            }
        }
        print("\((file as NSString).lastPathComponent): \(pass) pass, \(fail) fail, \(skip) skipped")
        #expect(fail == 0)
    }

    enum Outcome { case pass, skip, fail(String) }

    private func check(_ id: String, _ m: [String: String]) throws -> Outcome {
        // As Go's Atoi, what does not read is 0; Spectre takes -1 for its
        // latest, and the latest stands for versions it does not know.
        let version = Int(m["algorithm"] ?? "") ?? 0
        let algorithm = version < 0 ? .current : Algorithm(rawValue: version) ?? .current
        let counter = UInt32(m["keyCounter"] ?? "") ?? 0
        let purpose: Purpose = switch m["keyPurpose"] {
        case "Identification": .identification
        case "Recovery": .recovery
        default: .authentication
        }
        let type = Self.types[m["resultType"] ?? ""] ?? ResultType(rawValue: 0)
        let want = m["result"] ?? ""
        let name = m["userName"] ?? "", secret = m["userSecret"] ?? "", siteName = m["siteName"] ?? ""

        if let input = m["input"] {
            let imported = Result { try User(importing: Data(input.utf8)) }
            if m["error"] != nil, !id.contains("TODO") {
                // Spectre fails some on unlock or on its stricter rules.
                guard case .success(var user) = imported, (try? user.unlockCached(secret: secret)) != nil else { return .pass }
                return .fail("expected an error (\(m["error"] ?? "")), imported fine")
            }
            var user: User
            do { user = try imported.get() } catch { return .fail("import: \(error)") }
            let key: Key
            do { key = try user.unlockCached(secret: secret) } catch { return .fail("unlock: \(error)") }
            if want.isEmpty { return .pass }
            guard let site = user.sites.first(where: { $0.name == siteName }) else { return .fail("no site \(siteName)") }
            let got = Result { try key.password(for: site) }
            return (try? got.get()) == want ? .pass : .fail("import gives \(got), want \(want)")
        }

        if let format = m["format"], !format.isEmpty, format != "none" {
            guard !want.isEmpty, purpose == .authentication else { return .skip }
            // A round trip through this library's export.
            var user = User(name: name)
            user.algorithm = algorithm
            var site = Site(name: siteName, type: type, counter: counter, algorithm: algorithm)
            site.state = m["resultParam"].nonEmpty
            user.sites.append(site)
            do { _ = try user.unlockCached(secret: secret) } catch { return .fail("\(error)") }
            let data: Data
            do { data = try user.exportData() } catch { return .fail("export: \(error)") }
            var back: User
            do { back = try User(importing: data) } catch { return .fail("import: \(error)\n\(String(decoding: data, as: UTF8.self))") }
            let key: Key
            do { key = try back.unlockCached(secret: secret) } catch { return .fail("unlock: \(error)") }
            let got = Result { try key.password(for: back.sites[0]) }
            return (try? got.get()) == want ? .pass : .fail("round trip gives \(got), want \(want)")
        }

        guard !want.isEmpty else { return .skip }
        let key: Key
        do { key = try cachedKey(name, secret) } catch { return .fail("\(error)") }
        if let id = m["keyID"], !id.isEmpty, !key.matches(id: id, algorithm: algorithm) {
            Issue.record("key ID \(key.id(for: algorithm)), want \(id)")
        }
        let got = Result {
            try key.result(for: siteName, counter: counter, purpose: purpose, context: m["keyContext"] ?? "",
                           type: type, state: m["resultParam"], algorithm: algorithm)
        }
        return (try? got.get()) == want ? .pass : .fail("\(got), want \(want)")
    }

    static let types: [String: ResultType] = Dictionary(
        uniqueKeysWithValues: (ResultType.passwordTypes + [.device]).map { ($0.title, $0) })

    /// Each case of a test file but the defaults, by its ID, with the fields
    /// of its parents under its own.
    static func cases(of file: String) throws -> [(id: String, fields: [String: String])] {
        let document = try XMLDocument(contentsOf: URL(fileURLWithPath: file))
        let aliases = ["fullName": "userName", "masterPassword": "userSecret", "siteCounter": "keyCounter"]
        var elements: [String: XMLElement] = [:]
        let all = try document.nodes(forXPath: "//case").compactMap { $0 as? XMLElement }
        for element in all {
            if let id = element.attribute(forName: "id")?.stringValue { elements[id] = element }
        }
        func fields(_ id: String) -> [String: String] {
            guard let element = elements[id] else { return [:] }
            var fields = element.attribute(forName: "parent")?.stringValue.map(fields) ?? [:]
            for child in element.children ?? [] {
                guard let child = child as? XMLElement, let name = child.name else { continue }
                fields[aliases[name] ?? name] = child.stringValue ?? ""
            }
            return fields
        }
        return all.compactMap { element in
            guard let id = element.attribute(forName: "id")?.stringValue, id != "default" else { return nil }
            return (id, fields(id))
        }
    }
}
