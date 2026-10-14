import Foundation

// Spectre's exports come in two formats, which `User(importing:)` reads both of:
//
//  - JSON (.mpjson): format 1 from Master Password 2, format 2 from Spectre's
//    apps (3.1, on the App Store), format 3 from Spectre's latest code, which
//    renames default_type to result_type.
//  - Text (.mpsites): formats 0, 1 and 2, from Master Password before JSON.
//    Some JSON exports have this extension too.
//
// `exportData()` writes JSON format 2, which the Spectre apps import, with
// what this library does not read of a file written back as it was.

extension User {
    /// Reads a Spectre export.
    public init(importing data: Data) throws {
        var bytes = ArraySlice(data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes = bytes.dropFirst(3)
        }
        let isSpace: (UInt8) -> Bool = { [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D].contains($0) }
        let text = Array(bytes.drop(while: isSpace).reversed().drop(while: isSpace).reversed())
        do {
            switch text.first {
            case UInt8(ascii: "{"): self = try Self.importJSON(text)
            case UInt8(ascii: "#"): self = try Self.importFlat(text)
            default: throw ImportProblem("This is not a Spectre export: it is neither JSON nor Spectre's text format.")
            }
        } catch let problem as ImportProblem {
            throw SpectreError.invalidExport(problem.message)
        }
    }

    // MARK: JSON

    private static func importJSON(_ text: [UInt8]) throws -> User {
        let document: JSON
        do {
            document = try JSON(parsing: text)
        } catch {
            throw ImportProblem("The export's JSON does not read: \(error).")
        }
        guard var file = document.object else { throw ImportProblem("The export's JSON is not an object.") }
        var problems: [String] = []
        var export = file.take("export", as: \.object, kind: "an object", problems: &problems) ?? JSONObject()
        let userFields = file.take("user", as: \.object, kind: "an object", problems: &problems)
        let sites = file.take("sites", as: \.object, kind: "an object", problems: &problems) ?? JSONObject()
        // Spectre's builds of 2020 kept sites as services.
        let services = file.take("services", as: \.object, kind: "an object", problems: &problems) ?? JSONObject()
        let format = export.take("format", as: { $0.integer(Int.self) }, kind: "a whole number", problems: &problems) ?? 0
        let redacted = export.take("redacted", as: \.bool, kind: "true or false", problems: &problems) ?? true
        export["date"] = nil
        guard problems.isEmpty else { throw ImportProblem(doesNotRead: problems) }
        guard var fields = userFields else { throw ImportProblem("The export names no user.") }
        guard (1...3).contains(format) else {
            throw ImportProblem("The export is of format \(format), which this app does not read.")
        }

        var user = User(name: fields.takeString("full_name", problems: &problems) ?? "")
        user.isRedacted = redacted
        user.fileExtras = file
        user.exportExtras = export
        user.avatar = fields.takeInteger("avatar", as: Int.self, problems: &problems) ?? 0
        user.identicon = fields.takeString("identicon", problems: &problems).nonEmpty
        user.lastUsed = Timestamp.parse(fields.takeString("last_used", problems: &problems))
        user.keyID = fields.takeString("key_id", problems: &problems).nonEmpty
        let algorithm = fields.takeInteger("algorithm", as: Int.self, problems: &problems) ?? Algorithm.current.rawValue
        var defaultType = fields.takeInteger("default_type", as: UInt32.self, problems: &problems) ?? ResultType.long.rawValue
        if let resultType = fields.takeInteger("result_type", as: UInt32.self, problems: &problems) {
            defaultType = resultType
        }
        let loginType = fields.takeInteger("login_type", as: UInt32.self, problems: &problems) ?? 0
        user.loginState = fields.takeString("login_name", problems: &problems).nonEmpty
        user.extras = fields
        try user.validate(algorithm: algorithm, defaultType: defaultType, loginType: loginType)
        if user.loginType?.isStateful != true {
            user.loginState = nil // made by the login type, which an export in the clear shows
        }

        for member in sites.members + services.members {
            let name = member.key
            if member.value != .null, member.value.object == nil {
                problems.append("site \(name) is not an object")
                continue
            }
            var fields = member.value.object ?? JSONObject()
            var record = SiteRecord(name: name, type: user.defaultType, algorithm: algorithm)
            record.type = fields.takeInteger("type", as: UInt32.self, problems: &problems).map(ResultType.init) ?? record.type
            record.counter = fields.takeInteger("counter", as: UInt32.self, problems: &problems) ?? 1
            record.algorithm = fields.takeInteger("algorithm", as: Int.self, problems: &problems) ?? algorithm
            record.state = fields.takeString("password", problems: &problems).nonEmpty
            record.loginType = fields.takeInteger("login_type", as: UInt32.self, problems: &problems) ?? 0
            record.loginState = fields.takeString("login_name", problems: &problems).nonEmpty
            record.uses = fields.takeInteger("uses", as: UInt32.self, problems: &problems) ?? 0
            record.lastUsed = Timestamp.parse(fields.takeString("last_used", problems: &problems))
            let questions = fields.take("questions", as: \.object, kind: "an object", problems: &problems) ?? JSONObject()
            // Spectre keeps a site's website in _ext_spectre, Master Password
            // in _ext_mpw.
            record.url = ["_ext_spectre", "_ext_mpw"].compactMap { fields[$0]?.object?["url"]?.string.nonEmpty }.first
            if format == 1 && record.loginType == ResultType.name.rawValue {
                // Master Password named the login it generates for each
                // site; Spectre takes it from the user's.
                record.loginType = 0
            }
            if format == 1 && record.loginType == 0 && record.loginState != nil {
                record.loginType = ResultType.personal.rawValue
            }

            var site: Site
            do {
                site = try record.site()
            } catch let problem as ImportProblem {
                problems.append(problem.message)
                continue
            }
            for question in questions.members {
                if question.value != .null, question.value.object == nil { continue }
                var fields = question.value.object ?? JSONObject()
                var type = ResultType.phrase
                if let raw = fields.takeInteger("type", as: UInt32.self, problems: &problems) {
                    type = ResultType(rawValue: raw)
                }
                var state = fields.takeString("answer", problems: &problems).nonEmpty
                if !type.isKnown {
                    problems.append("site \(name): question \"\(question.key)\" is of type \(type.rawValue), which this app does not know")
                }
                if !type.isStateful {
                    state = nil
                }
                var answer = Question(keyword: question.key, type: type, state: state)
                answer.extras = fields
                site.questions.append(answer)
            }
            site.extras = fields
            // A site in both sites and services keeps the one used last.
            if let i = user.sites.firstIndex(where: { $0.name == site.name }) {
                if site.lastUsed.isAfter(user.sites[i].lastUsed) {
                    user.sites[i] = site
                }
            } else {
                user.sites.append(site)
            }
        }
        guard problems.isEmpty else { throw ImportProblem(doesNotRead: problems) }
        return user
    }

    // MARK: Text

    /// Reads Master Password's text format: "# Name: value" lines between
    /// two "##" lines, then a site a line.
    private static func importFlat(_ text: [UInt8]) throws -> User {
        var user = User(name: "")
        var algorithm = Algorithm.current.rawValue, defaultType = ResultType.long.rawValue
        var format = 0
        var inHeader = false, headerDone = false
        for (index, rawLine) in text.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let rawLine = rawLine.droppingCarriageReturns
            let line = String(decoding: rawLine, as: UTF8.self)
            if !headerDone {
                if line == "##" {
                    headerDone = inHeader
                    inHeader.toggle()
                } else if inHeader, line.hasPrefix("#") {
                    let entry = line.dropFirst().drop(while: { $0 == " " })
                    guard let colon = entry.firstIndex(of: ":") else { continue }
                    let key = entry[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let value = entry[entry.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    func number<T: FixedWidthInteger>(_: T.Type, _ what: String) throws -> T {
                        guard let number = T(goSyntax: value) else {
                            throw ImportProblem("Line \(lineNumber): the \(what) \"\(value)\" is not a number.")
                        }
                        return number
                    }
                    switch key {
                    case "format": format = Int(value) ?? 0
                    case "full name", "user name": user.name = value
                    case "avatar": user.avatar = try Int(number(Int32.self, "avatar"))
                    case "identicon": user.identicon = value.nonEmpty
                    case "key id": user.keyID = value.nonEmpty
                    case "algorithm": algorithm = try Int(number(Int32.self, "algorithm"))
                    case "default type", "result type": defaultType = try number(UInt32.self, "default type")
                    case "passwords": user.isRedacted = value.caseInsensitiveCompare("VISIBLE") != .orderedSame
                    default: break
                    }
                }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            do {
                try user.sites.append(flatSite(rawLine, format: format, algorithm: algorithm).site())
            } catch let problem as ImportProblem {
                throw ImportProblem("Line \(lineNumber): \(problem.message)")
            }
        }
        guard headerDone else { throw ImportProblem("The export has no header: it is not a Spectre export.") }
        guard (0...2).contains(format) else {
            throw ImportProblem("The export is of format \(format), which this app does not read.")
        }
        try user.validate(algorithm: algorithm, defaultType: defaultType, loginType: 0)
        user.lastUsed = user.sites.compactMap(\.lastUsed).max()
        return user
    }

    /// Reads a site's line: when it was used last and how many times,
    /// type:algorithm(:counter), then, apart by tabs, the login name
    /// (formats 1 and 2), the site's name and its stored password.
    private static func flatSite(_ line: ArraySlice<UInt8>, format: Int, algorithm: Int) throws -> SiteRecord {
        var rest = line
        func field(_ delimiters: [UInt8]) -> String {
            rest = rest.drop(while: { $0 == 0x20 })
            guard let end = rest.firstIndex(where: delimiters.contains) else {
                defer { rest = [] }
                return String(decoding: rest, as: UTF8.self)
            }
            defer { rest = rest[(end + 1)...] }
            return String(decoding: rest[..<end], as: UTF8.self)
        }
        func number(_ what: String, _ text: Substring) throws -> UInt32 {
            guard let number = UInt32(goSyntax: String(text)) else {
                throw ImportProblem("the site's \(what) \"\(text)\" is not a number")
            }
            return number
        }
        let lastUsed = field([0x20, 0x09]), uses = field([0x20, 0x09])[...], typeAndAlgorithm = field([0x20, 0x09])
        var record = SiteRecord(name: "", type: .long, algorithm: algorithm)
        record.lastUsed = Timestamp.parse(lastUsed)
        record.uses = try number("uses", uses)
        let parts = typeAndAlgorithm.split(separator: ":", omittingEmptySubsequences: false)
        record.type = try ResultType(rawValue: number("type", parts[0]))
        if parts.count > 1 {
            record.algorithm = try Int(number("algorithm", parts[1]))
        }
        if parts.count > 2 && format >= 1 {
            record.counter = try number("counter", parts[2])
        }
        if format >= 1, let login = field([0x09]).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            // Master Password's apps kept login names in the clear, even
            // where the passwords are encrypted.
            record.loginType = ResultType.personal.rawValue
            record.loginState = login
            record.hasPlainLogin = !Key.isSealed(login)
        }
        record.name = field([0x09]).trimmingCharacters(in: .whitespacesAndNewlines)
        record.state = String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if record.type.isStateful && record.counter == 0 {
            record.counter = 1 // old apps wrote 0 for stored passwords
        }
        guard !record.name.isEmpty else { throw ImportProblem("a site has no name") }
        return record
    }

    /// Checks what Spectre would not read of the user, and takes the values
    /// it reads.
    private mutating func validate(algorithm: Int, defaultType: UInt32, loginType: UInt32) throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ImportProblem("The export's user has no name.")
        }
        guard let algorithm = Algorithm(rawValue: algorithm) else {
            throw ImportProblem("The export's user is of algorithm \(algorithm), which this app does not know.")
        }
        guard avatar >= 0 else { throw ImportProblem("The export's user has avatar \(avatar), which is not one.") }
        let type = ResultType(rawValue: defaultType)
        guard type.isKnown else {
            throw ImportProblem("The export's user has default type \(defaultType), which this app does not know.")
        }
        let login = loginType == 0 ? nil : ResultType(rawValue: loginType)
        if let login, !login.isKnown {
            throw ImportProblem("The export's user has login type \(loginType), which this app does not know.")
        }
        self.algorithm = algorithm
        self.defaultType = type
        self.loginType = login
    }
}

/// A site as an export holds it, before ``site()`` checks what Spectre would
/// read of it.
private struct SiteRecord {
    var name: String
    var type: ResultType
    var counter: UInt32 = 1
    var algorithm: Int
    var state: String?
    var loginType: UInt32 = 0
    var loginState: String?
    var hasPlainLogin = false
    var uses: UInt32 = 0
    var lastUsed: Date?
    var url: String?

    func site() throws -> Site {
        guard !name.isEmpty else { throw ImportProblem("a site has no name") }
        guard let algorithm = Algorithm(rawValue: algorithm) else {
            throw ImportProblem("site \(name) is of algorithm \(self.algorithm), which this app does not know")
        }
        guard type.isKnown else {
            throw ImportProblem("site \(name) is of type \(type.rawValue), which this app does not know")
        }
        let login = loginType == 0 ? nil : ResultType(rawValue: loginType)
        if let login, !login.isKnown {
            throw ImportProblem("site \(name) has login type \(loginType), which this app does not know")
        }
        guard counter <= ResultType.maxCounter else {
            throw ImportProblem("site \(name) has counter \(counter), above Spectre's highest")
        }
        var site = Site(name: name, type: type, counter: counter, algorithm: algorithm)
        site.state = type.isStateful ? state : nil // a generated password, which an export in the clear shows
        site.loginType = login
        site.loginState = login?.isStateful == true ? loginState : nil
        site.hasPlainLogin = site.loginState != nil && hasPlainLogin
        site.uses = uses
        site.lastUsed = lastUsed
        site.url = url
        return site
    }
}

/// Why an export does not read, in English.
struct ImportProblem: Error {
    let message: String

    init(_ message: String) { self.message = message }

    init(doesNotRead problems: [String]) {
        message = "The export does not read: " + problems.joined(separator: "; ") + "."
    }
}

extension JSONObject {
    /// Removes a field and reads its value, as Spectre reads it: null reads
    /// as no value, and a value of another kind is a problem.
    mutating func take<T>(_ key: String, as read: (JSON) -> T?, kind: String, problems: inout [String]) -> T? {
        guard let value = removeValue(forKey: key), value != .null else { return nil }
        guard let result = read(value) else {
            problems.append("\(key) is not \(kind)")
            return nil
        }
        return result
    }

    mutating func takeString(_ key: String, problems: inout [String]) -> String? {
        take(key, as: \.string, kind: "text", problems: &problems)
    }

    mutating func takeInteger<T: FixedWidthInteger>(_ key: String, as type: T.Type, problems: inout [String]) -> T? {
        take(key, as: { $0.integer(T.self) }, kind: "a whole number from \(T.min) to \(T.max)", problems: &problems)
    }
}

extension ArraySlice<UInt8> {
    /// The line without the carriage returns at its end.
    var droppingCarriageReturns: ArraySlice<UInt8> {
        var line = self
        while line.last == 0x0D { line = line.dropLast() }
        return line
    }
}

extension Optional where Wrapped == String {
    /// The text, or nil for none.
    var nonEmpty: String? {
        if let self, !self.isEmpty { self } else { nil }
    }
}

extension String {
    /// The text, or nil for none.
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension FixedWidthInteger {
    /// Reads an integer as Go's strconv does with base 0, as Master
    /// Password's text exports wrote them: an optional sign (for signed
    /// types), then a prefix for the base (0x, 0o, 0b, or a leading 0 for
    /// octal), with underscores between digits.
    init?(goSyntax text: String) {
        var digits = Substring(text)
        var negative = false
        if Self.isSigned, let sign = digits.first, sign == "+" || sign == "-" {
            negative = sign == "-"
            digits = digits.dropFirst()
        }
        var radix = 10, prefixed = false
        let lower = digits.lowercased()
        for (prefix, base) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            radix = base
            prefixed = true
            digits = digits.dropFirst(2)
        }
        if !prefixed, digits.count > 1, digits.hasPrefix("0") {
            radix = 8
            prefixed = true
            digits = digits.dropFirst()
        }
        if digits.contains("_") {
            // An underscore goes between digits, or after a prefix.
            guard !digits.hasSuffix("_"), !digits.contains("__"), prefixed || !digits.hasPrefix("_") else { return nil }
            digits = Substring(digits.filter { $0 != "_" })
        }
        guard let first = digits.unicodeScalars.first, first.properties.isASCIIHexDigit,
              let magnitude = UInt64(digits, radix: radix) else { return nil }
        if negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
            self.init(exactly: magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude))
        } else {
            self.init(exactly: magnitude)
        }
    }
}
