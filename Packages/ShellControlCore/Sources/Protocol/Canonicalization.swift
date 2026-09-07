import Foundation

/// RFC 8785 JSON Canonicalization Scheme.
///
/// This is the real JCS, not an ad hoc sorted-key encoder: object names are
/// ordered by their UTF-16 code units, strings keep their exact scalars with
/// minimal escaping, and numbers use the ECMAScript `Number::toString`
/// representation (spec.watch.md section 9).
public enum JSONCanonicalization {
    public static func canonicalize(_ value: JSONValue) throws -> Data {
        var output = String()
        try write(value, into: &output)
        return Data(output.utf8)
    }

    public static func canonicalString(_ value: JSONValue) throws -> String {
        String(decoding: try canonicalize(value), as: UTF8.self)
    }

    private static func write(_ value: JSONValue, into output: inout String) throws {
        switch value {
        case .null:
            output += "null"
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .number(let number):
            output += try serialize(number)
        case .string(let string):
            writeString(string, into: &output)
        case .array(let elements):
            output += "["
            for (offset, element) in elements.enumerated() {
                if offset > 0 { output += "," }
                try write(element, into: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (offset, name) in members.keys.sorted(by: utf16Less).enumerated() {
                if offset > 0 { output += "," }
                writeString(name, into: &output)
                output += ":"
                try write(members[name]!, into: &output)
            }
            output += "}"
        }
    }

    /// RFC 8785 orders names by UTF-16 code unit, which differs from Swift's
    /// default `String` ordering for characters outside the BMP.
    static func utf16Less(_ lhs: String, _ rhs: String) -> Bool {
        var left = lhs.utf16.makeIterator()
        var right = rhs.utf16.makeIterator()
        while true {
            switch (left.next(), right.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let a?, let b?):
                if a != b { return a < b }
            }
        }
    }

    private static func writeString(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    /// ECMAScript `Number::toString` for the values the protocol permits.
    static func serialize(_ number: JSONNumber) throws -> String {
        switch number {
        case .int(let value):
            guard value.magnitude <= UInt64(JSONLimits.maxSafeInteger) else { throw JSONError.numberOutOfRange }
            return String(value)
        case .double(let value):
            guard value.isFinite else { throw JSONError.numberOutOfRange }
            if value == 0 { return "0" }
            if value.rounded() == value, value.magnitude < 1e21 {
                // ES6 prints integral doubles without a fractional part.
                if value.magnitude <= Double(JSONLimits.maxSafeInteger) {
                    return String(Int64(value))
                }
            }
            return shortestRoundTrip(value)
        }
    }

    private static func shortestRoundTrip(_ value: Double) -> String {
        for precision in 1...17 {
            let candidate = String(format: "%.\(precision)g", value)
            if Double(candidate) == value { return normalizeExponent(candidate) }
        }
        return normalizeExponent(String(format: "%.17g", value))
    }

    private static func normalizeExponent(_ text: String) -> String {
        guard let range = text.range(of: "e", options: .caseInsensitive) else { return text }
        let mantissa = String(text[text.startIndex..<range.lowerBound])
        var exponent = String(text[range.upperBound...])
        var sign = "+"
        if exponent.hasPrefix("-") { sign = "-"; exponent.removeFirst() }
        else if exponent.hasPrefix("+") { exponent.removeFirst() }
        while exponent.count > 1 && exponent.hasPrefix("0") { exponent.removeFirst() }
        return "\(mantissa)e\(sign)\(exponent)"
    }
}
