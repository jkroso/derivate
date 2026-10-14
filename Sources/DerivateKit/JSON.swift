import Foundation

/// A JSON value that keeps what it read as it was: the order of an
/// object's keys, and the text of its numbers. Export files go through it,
/// so that what this library does not read of them writes back unchanged.
enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// A number, as its literal text.
    case number(String)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    var bool: Bool? {
        if case .bool(let bool) = self { bool } else { nil }
    }

    var object: JSONObject? {
        if case .object(let object) = self { object } else { nil }
    }

    /// The number as an integer of type T, if it is a whole number in T's
    /// range, written without a fraction or an exponent.
    func integer<T: FixedWidthInteger>(_: T.Type = T.self) -> T? {
        if case .number(let text) = self { T(text, radix: 10) } else { nil }
    }
}

/// A JSON object: its members in their order. A key that appears twice
/// keeps both members; reading it gives the last, as most readers do.
struct JSONObject: Sendable, Equatable {
    struct Member: Sendable, Equatable {
        var key: String
        var value: JSON
    }

    private(set) var members: [Member] = []

    init(_ members: [Member] = []) { self.members = members }

    var isEmpty: Bool { members.isEmpty }

    /// The value of a key. Setting it replaces the key's value where it is,
    /// or adds it at the end; setting nil removes it.
    subscript(key: String) -> JSON? {
        get { members.last { $0.key == key }?.value }
        set {
            guard let newValue else {
                members.removeAll { $0.key == key }
                return
            }
            if let i = members.firstIndex(where: { $0.key == key }) {
                members[i].value = newValue
                // A later member of the key would hide this one.
                members = members.enumerated().filter { $0.offset <= i || $0.element.key != key }.map(\.element)
            } else {
                members.append(Member(key: key, value: newValue))
            }
        }
    }

    /// Removes a key, and returns its value.
    @discardableResult
    mutating func removeValue(forKey key: String) -> JSON? {
        defer { self[key] = nil }
        return self[key]
    }

    /// This object's members, then those of another whose keys it does not
    /// have.
    func appending(_ other: JSONObject) -> JSONObject {
        JSONObject(members + other.members.filter { self[$0.key] == nil })
    }
}

// MARK: - Reading

struct JSONSyntaxError: Error, CustomStringConvertible {
    let message: String
    let offset: Int

    var description: String { "\(message) at byte \(offset + 1)" }
}

extension JSON {
    /// Reads a JSON text.
    init(parsing bytes: some Collection<UInt8>) throws {
        var parser = JSONParser(bytes: Array(bytes))
        self = try parser.document()
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var offset = 0
    var depth = 0

    mutating func document() throws -> JSON {
        let value = try self.value()
        skipWhitespace()
        guard offset == bytes.count else { throw error("text after the JSON value") }
        return value
    }

    private func error(_ message: String) -> JSONSyntaxError {
        JSONSyntaxError(message: message, offset: offset)
    }

    private var next: UInt8? { offset < bytes.count ? bytes[offset] : nil }

    private mutating func skipWhitespace() {
        while let byte = next, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
            offset += 1
        }
    }

    private mutating func expect(_ literal: String) throws {
        let literal = Array(literal.utf8)
        guard bytes[offset...].starts(with: literal) else { throw error("not a JSON value") }
        offset += literal.count
    }

    private mutating func value() throws -> JSON {
        skipWhitespace()
        guard let byte = next else { throw error("unexpected end of JSON") }
        switch byte {
        case UInt8(ascii: "{"): return .object(try nested { try $0.object() })
        case UInt8(ascii: "["): return .array(try nested { try $0.array() })
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        default: throw error("not a JSON value")
        }
    }

    private mutating func nested<T>(_ read: (inout JSONParser) throws -> T) throws -> T {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 512 else { throw error("JSON nested too deep") }
        return try read(&self)
    }

    private mutating func object() throws -> JSONObject {
        offset += 1 // {
        var members: [JSONObject.Member] = []
        skipWhitespace()
        if next == UInt8(ascii: "}") {
            offset += 1
            return JSONObject(members)
        }
        while true {
            skipWhitespace()
            guard next == UInt8(ascii: "\"") else { throw error("expected a key") }
            let key = try string()
            skipWhitespace()
            guard next == UInt8(ascii: ":") else { throw error("expected ':'") }
            offset += 1
            members.append(.init(key: key, value: try value()))
            skipWhitespace()
            switch next {
            case UInt8(ascii: ","): offset += 1
            case UInt8(ascii: "}"): offset += 1; return JSONObject(members)
            default: throw error("expected ',' or '}'")
            }
        }
    }

    private mutating func array() throws -> [JSON] {
        offset += 1 // [
        var values: [JSON] = []
        skipWhitespace()
        if next == UInt8(ascii: "]") {
            offset += 1
            return values
        }
        while true {
            values.append(try value())
            skipWhitespace()
            switch next {
            case UInt8(ascii: ","): offset += 1
            case UInt8(ascii: "]"): offset += 1; return values
            default: throw error("expected ',' or ']'")
            }
        }
    }

    private mutating func number() throws -> String {
        let start = offset
        func digits() -> Int {
            let from = offset
            while let byte = next, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { offset += 1 }
            return offset - from
        }
        if next == UInt8(ascii: "-") { offset += 1 }
        if next == UInt8(ascii: "0") {
            offset += 1
        } else if digits() == 0 {
            throw error("not a number")
        }
        if next == UInt8(ascii: ".") {
            offset += 1
            guard digits() > 0 else { throw error("not a number") }
        }
        if next == UInt8(ascii: "e") || next == UInt8(ascii: "E") {
            offset += 1
            if next == UInt8(ascii: "+") || next == UInt8(ascii: "-") { offset += 1 }
            guard digits() > 0 else { throw error("not a number") }
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    private mutating func string() throws -> String {
        offset += 1 // "
        var text: [UInt8] = []
        while true {
            guard let byte = next else { throw error("unterminated string") }
            offset += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: text, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let escaped = next else { throw error("unterminated string") }
                offset += 1
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): text.append(escaped)
                case UInt8(ascii: "b"): text.append(0x08)
                case UInt8(ascii: "f"): text.append(0x0C)
                case UInt8(ascii: "n"): text.append(0x0A)
                case UInt8(ascii: "r"): text.append(0x0D)
                case UInt8(ascii: "t"): text.append(0x09)
                case UInt8(ascii: "u"): text += String(try unicodeEscape()).utf8
                default: throw error("invalid escape in string")
                }
            case 0..<0x20:
                throw error("control character in string")
            default:
                text.append(byte)
            }
        }
    }

    /// The character of a \u escape, and of the low surrogate after a high
    /// one. A lone surrogate is U+FFFD.
    private mutating func unicodeEscape() throws -> Character {
        let unit = try hex4()
        if (0xD800..<0xDC00).contains(unit), bytes[offset...].starts(with: Array("\\u".utf8)) {
            let saved = offset
            offset += 2
            let low = try hex4()
            if (0xDC00..<0xE000).contains(low) {
                let scalar = 0x10000 + (unit - 0xD800) << 10 + (low - 0xDC00)
                return Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")
            }
            offset = saved
        }
        return Character(Unicode.Scalar(unit) ?? "\u{FFFD}")
    }

    private mutating func hex4() throws -> UInt32 {
        guard offset + 4 <= bytes.count,
              let unit = UInt32(String(decoding: bytes[offset..<offset + 4], as: UTF8.self), radix: 16) else {
            throw error("invalid \\u escape")
        }
        offset += 4
        return unit
    }
}

// MARK: - Writing

extension JSON {
    /// The value as JSON text, indented by two spaces, with a newline at the
    /// end.
    var formatted: String {
        var text = ""
        write(to: &text, indent: "")
        return text + "\n"
    }

    private func write(to text: inout String, indent: String) {
        switch self {
        case .null: text += "null"
        case .bool(let bool): text += bool ? "true" : "false"
        case .number(let number): text += number
        case .string(let string): Self.write(string, to: &text)
        case .array(let values):
            guard !values.isEmpty else { text += "[]"; return }
            text += "[\n"
            for (i, value) in values.enumerated() {
                text += indent + "  "
                value.write(to: &text, indent: indent + "  ")
                text += i < values.count - 1 ? ",\n" : "\n"
            }
            text += indent + "]"
        case .object(let object):
            guard !object.isEmpty else { text += "{}"; return }
            text += "{\n"
            for (i, member) in object.members.enumerated() {
                text += indent + "  "
                Self.write(member.key, to: &text)
                text += ": "
                member.value.write(to: &text, indent: indent + "  ")
                text += i < object.members.count - 1 ? ",\n" : "\n"
            }
            text += indent + "}"
        }
    }

    private static func write(_ string: String, to text: inout String) {
        text += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case "\u{2028}", "\u{2029}", "\u{0}"..."\u{1F}":
                text += String(format: "\\u%04x", scalar.value)
            default: text.unicodeScalars.append(scalar)
            }
        }
        text += "\""
    }
}
