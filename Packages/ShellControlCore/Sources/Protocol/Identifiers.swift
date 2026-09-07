import Foundation

/// A canonical lowercase UUID string (spec.watch.md section 8).
///
/// The distinct wrappers exist so a view UUID, surface pointer, tab selection,
/// tmux pane number, or terminal title can never be passed where an
/// authorization identifier is required (spec.watch.md section 2).
public struct ControlID: Sendable, Hashable, CustomStringConvertible, Codable {
    public let rawValue: String

    public init?(_ rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        let canonical = uuid.uuidString.lowercased()
        guard canonical == rawValue else { return nil }
        self.rawValue = canonical
    }

    public init(_ uuid: UUID) {
        self.rawValue = uuid.uuidString.lowercased()
    }

    public static func random() -> ControlID { ControlID(UUID()) }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = ControlID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a canonical UUID"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A UTC RFC 3339 timestamp rendered with a `Z` offset and second precision.
public struct ControlTimestamp: Sendable, Hashable, Comparable, CustomStringConvertible, Codable {
    public let date: Date

    public init(_ date: Date) {
        // Whole seconds only: the wire form is what gets signed, so a value
        // that does not round-trip must never reach a digest.
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    public init?(rfc3339 text: String) {
        guard let date = RFC3339.parse(text) else { return nil }
        self.date = date
    }

    public var rfc3339: String { RFC3339.format(date) }
    public var description: String { rfc3339 }

    public static func < (lhs: ControlTimestamp, rhs: ControlTimestamp) -> Bool { lhs.date < rhs.date }

    public func adding(_ seconds: TimeInterval) -> ControlTimestamp {
        ControlTimestamp(date.addingTimeInterval(seconds))
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = ControlTimestamp(rfc3339: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an RFC 3339 UTC timestamp"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rfc3339)
    }
}

extension ControlTimestamp {
    /// Fractional-second inputs are accepted on the wire but normalised, so a
    /// peer cannot widen a deadline by adding sub-second precision.
    public static func lenient(_ text: String) -> ControlTimestamp? {
        guard let date = RFC3339.parse(text) else { return nil }
        return ControlTimestamp(date)
    }
}

/// UTC RFC 3339 formatting and parsing without a shared, non-`Sendable`
/// formatter: the wire form is what gets signed, so it must be exact and
/// usable from any isolation domain.
enum RFC3339 {
    static func format(_ date: Date) -> String {
        let total = Int64(date.timeIntervalSince1970.rounded(.down))
        var days = total / 86400
        var remainder = total % 86400
        if remainder < 0 { remainder += 86400; days -= 1 }
        let (year, month, day) = civilFromDays(days)
        let hour = remainder / 3600
        let minute = (remainder % 3600) / 60
        let second = remainder % 60
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            year, month, day, hour, minute, second
        )
    }

    static func parse(_ text: String) -> Date? {
        let scalars = Array(text.utf8)
        // YYYY-MM-DDTHH:MM:SS, optional fractional seconds, then a literal Z.
        guard scalars.count >= 20 else { return nil }
        func digits(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = scalars[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard scalars[4] == UInt8(ascii: "-"), scalars[7] == UInt8(ascii: "-"),
              scalars[10] == UInt8(ascii: "T"), scalars[13] == UInt8(ascii: ":"),
              scalars[16] == UInt8(ascii: ":"),
              let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
              let hour = digits(11..<13), let minute = digits(14..<16), let second = digits(17..<19)
        else { return nil }
        var index = 19
        if index < scalars.count, scalars[index] == UInt8(ascii: ".") {
            index += 1
            let fractionStart = index
            while index < scalars.count, scalars[index] >= 48, scalars[index] <= 57 { index += 1 }
            guard index > fractionStart else { return nil }
        }
        guard index == scalars.count - 1, scalars[index] == UInt8(ascii: "Z") else { return nil }
        guard month >= 1, month <= 12, day >= 1, day <= 31, hour <= 23, minute <= 59, second <= 60 else { return nil }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86400 + Int64(hour * 3600 + minute * 60 + min(second, 59))
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Howard Hinnant's civil-calendar algorithms, which are exact for the
    /// proleptic Gregorian calendar and need no time-zone database.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        var year = year
        year -= month <= 2 ? 1 : 0
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era) * 146_097 + Int64(dayOfEra) - 719_468
    }

    static func civilFromDays(_ days: Int64) -> (Int, Int, Int) {
        var z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        z -= era * 146_097
        let dayOfEra = z
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        return (Int(year + (month <= 2 ? 1 : 0)), Int(month), Int(day))
    }
}

/// The ordered change-log sequence, carried as a decimal string so a large
/// value never loses precision in a JSON number (spec.watch.md section 8).
public struct LogSequence: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) { self.value = value }

    public init?(decimalString text: String) {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if text.count > 1 && text.hasPrefix("0") { return nil }
        guard let value = UInt64(text) else { return nil }
        self.value = value
    }

    public var decimalString: String { String(value) }
    public var description: String { decimalString }
    public static func < (lhs: LogSequence, rhs: LogSequence) -> Bool { lhs.value < rhs.value }
}
