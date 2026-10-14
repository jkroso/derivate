import Foundation

/// Spectre's times: RFC 3339, in UTC, to the second.
enum Timestamp {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// The time as Spectre writes it. No time is the start of 1970.
    static func format(_ date: Date?) -> String {
        let seconds = (date?.timeIntervalSince1970 ?? 0).rounded(.down)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: seconds))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
                      c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// A time in RFC 3339, with or without a fraction of a second: nil for
    /// text that is not one, and for times before 1970, which Spectre writes
    /// for no time.
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let b = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= b.count, b[range].allSatisfy(isDigit) else { return nil }
            return Int(String(decoding: b[range], as: UTF8.self))
        }
        func byte(_ i: Int, is character: Unicode.Scalar) -> Bool { i < b.count && b[i] == UInt8(ascii: character) }

        guard let year = number(0..<4), byte(4, is: "-"), let month = number(5..<7), byte(7, is: "-"),
              let day = number(8..<10), byte(10, is: "T"), let hour = number(11..<13), byte(13, is: ":"),
              let minute = number(14..<16), byte(16, is: ":"), let second = number(17..<19) else { return nil }
        var i = 19
        var fraction = 0.0
        if byte(i, is: ".") {
            let start = i + 1
            i = start
            while i < b.count, isDigit(b[i]) { i += 1 }
            guard i > start, let value = Double("0." + String(decoding: b[start..<i], as: UTF8.self)) else { return nil }
            fraction = value
        }
        var offset = 0
        if byte(i, is: "Z") {
            i += 1
        } else if byte(i, is: "+") || byte(i, is: "-") {
            guard let hours = number(i + 1..<i + 3), byte(i + 3, is: ":"), let minutes = number(i + 4..<i + 6),
                  hours < 24, minutes < 60 else { return nil }
            offset = (hours * 60 + minutes) * 60 * (byte(i, is: "-") ? -1 : 1)
            i += 6
        } else {
            return nil
        }
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                        year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard i == b.count, hour < 24, minute < 60, second < 60, components.isValidDate,
              let date = calendar.date(from: components) else { return nil }
        let time = date.timeIntervalSince1970 - Double(offset)
        guard time >= 1 else { return nil }
        return Date(timeIntervalSince1970: time + fraction)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
