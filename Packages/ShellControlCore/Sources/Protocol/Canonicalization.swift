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
            return ecmaScriptString(value)
        }
    }

    /// ECMAScript `Number::toString(x)` (ECMA-262 section 6.1.6.1.20), which
    /// RFC 8785 section 3.2.2.3 mandates.
    ///
    /// Swift's `description` already yields the shortest digit string that
    /// round-trips (and the closest one when several do), so only the layout
    /// differs: ES switches to exponent form outside `1e-7 <= |x| < 1e21`,
    /// writes `e+`/`e-`, and never pads the exponent.
    private static func ecmaScriptString(_ value: Double) -> String {
        // -0 and +0 both serialize as "0".
        if value == 0 { return "0" }
        let (digits, pointPosition) = decimalDigits(of: value.magnitude)
        let sign = value < 0 ? "-" : ""
        // value = 0.d1d2...dk x 10^n with k = digits.count, n = pointPosition.
        let k = digits.count
        let n = pointPosition
        if k <= n && n <= 21 {
            return sign + digits + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            let split = digits.index(digits.startIndex, offsetBy: n)
            return sign + digits[..<split] + "." + digits[split...]
        }
        if -6 < n && n <= 0 {
            return sign + "0." + String(repeating: "0", count: -n) + digits
        }
        let exponent = n - 1
        let exponentText = (exponent < 0 ? "e-" : "e+") + String(exponent.magnitude)
        guard k > 1 else { return sign + digits + exponentText }
        return sign + digits.prefix(1) + "." + digits.dropFirst() + exponentText
    }

    /// Shortest round-trip decimal digits of a positive finite double, without
    /// leading or trailing zeros, and the position `n` of the decimal point
    /// relative to them (`x = 0.digits x 10^n`).
    private static func decimalDigits(of magnitude: Double) -> (digits: String, pointPosition: Int) {
        // `description` is either "123.456" or "1.23456e-07" / "1e+21" style.
        let text = magnitude.description
        var mantissa = Substring(text)
        var exponent = 0
        if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<marker]
            exponent = Int(text[text.index(after: marker)...]) ?? 0
        }
        let integerPart: Substring
        let fractionPart: Substring
        if let dot = mantissa.firstIndex(of: ".") {
            integerPart = mantissa[..<dot]
            fractionPart = mantissa[mantissa.index(after: dot)...]
        } else {
            integerPart = mantissa
            fractionPart = ""
        }
        var digits = Array(integerPart + fractionPart)
        var pointPosition = integerPart.count + exponent
        let leadingZeros = digits.prefix(while: { $0 == "0" }).count
        digits.removeFirst(leadingZeros)
        pointPosition -= leadingZeros
        while digits.last == "0" { digits.removeLast() }
        return (String(digits), pointPosition)
    }
}
