import Foundation

/// A strict JSON value.
///
/// The control protocol never round-trips documents through `JSONSerialization`
/// or `JSONEncoder` for authorization purposes: those accept duplicate object
/// names and re-encode numbers in ways that would change a signed digest.
/// `JSONValue` is parsed by ``JSONValue/parse(_:limits:)`` which fails closed on
/// duplicate names, invalid Unicode, and oversized or overly nested documents
/// (spec.watch.md sections 8 and 9).
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

/// A JSON number restricted to the interoperable range the protocol allows.
///
/// Counters used as JSON numbers stay inside the IEEE-754 safe-integer range
/// (spec.watch.md section 8), so integers are carried exactly and doubles are
/// only used for values a peer actually sent as fractional.
public enum JSONNumber: Sendable, Hashable {
    case int(Int64)
    case double(Double)

    public var int64Value: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value):
            guard value.rounded() == value, value.magnitude <= Double(JSONLimits.maxSafeInteger) else { return nil }
            return Int64(value)
        }
    }
}

/// Structural limits applied while parsing, so a hostile peer cannot exhaust
/// memory before validation runs (spec.watch.md section 8).
public struct JSONLimits: Sendable, Hashable {
    /// Maximum control/request document size.
    public static let maxDocumentBytes = 64 * 1024
    /// Largest integer that survives a JSON number round trip everywhere.
    public static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    public var maxDocumentBytes: Int
    public var maxStringCharacters: Int
    public var maxNestingDepth: Int
    public var maxCollectionElements: Int

    public init(
        maxDocumentBytes: Int = JSONLimits.maxDocumentBytes,
        maxStringCharacters: Int = 8192,
        maxNestingDepth: Int = 32,
        maxCollectionElements: Int = 1024
    ) {
        self.maxDocumentBytes = maxDocumentBytes
        self.maxStringCharacters = maxStringCharacters
        self.maxNestingDepth = maxNestingDepth
        self.maxCollectionElements = maxCollectionElements
    }

    public static let `default` = JSONLimits()
}

public enum JSONError: Error, Equatable, Sendable {
    case documentTooLarge(bytes: Int, limit: Int)
    case invalidUnicode
    case duplicateName(String)
    case depthExceeded(limit: Int)
    case stringTooLong(limit: Int)
    case tooManyElements(limit: Int)
    case numberOutOfRange
    case syntax(String)
    case trailingData
}

extension JSONValue {
    /// Parses UTF-8 bytes with the strict rules the protocol requires.
    public static func parse(_ bytes: Data, limits: JSONLimits = .default) throws -> JSONValue {
        guard bytes.count <= limits.maxDocumentBytes else {
            throw JSONError.documentTooLarge(bytes: bytes.count, limit: limits.maxDocumentBytes)
        }
        guard let text = String(data: bytes, encoding: .utf8) else { throw JSONError.invalidUnicode }
        var parser = StrictJSONParser(scalars: Array(text.unicodeScalars), limits: limits)
        let value = try parser.parseDocument()
        return value
    }

    public static func parse(_ text: String, limits: JSONLimits = .default) throws -> JSONValue {
        try parse(Data(text.utf8), limits: limits)
    }

    // MARK: Accessors

    public var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value } else { return nil } }
    public var int64Value: Int64? { if case .number(let value) = self { return value.int64Value } else { return nil } }
    public var intValue: Int? { int64Value.flatMap { Int(exactly: $0) } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

// MARK: - Literal conveniences

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .number(.int(value)) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object: [String: JSONValue] = [:]
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

// MARK: - Parser

private struct StrictJSONParser {
    let scalars: [Unicode.Scalar]
    let limits: JSONLimits
    var index = 0
    var depth = 0

    init(scalars: [Unicode.Scalar], limits: JSONLimits) {
        self.scalars = scalars
        self.limits = limits
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == scalars.count else { throw JSONError.trailingData }
        return value
    }

    private mutating func skipWhitespace() {
        while index < scalars.count {
            switch scalars[index] {
            case " ", "\t", "\n", "\r": index += 1
            default: return
            }
        }
    }

    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    private mutating func parseValue() throws -> JSONValue {
        guard let scalar = current else { throw JSONError.syntax("unexpected end of input") }
        switch scalar {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t": try expect("true"); return .bool(true)
        case "f": try expect("false"); return .bool(false)
        case "n": try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func expect(_ literal: String) throws {
        for expected in literal.unicodeScalars {
            guard index < scalars.count, scalars[index] == expected else {
                throw JSONError.syntax("expected \(literal)")
            }
            index += 1
        }
    }

    private mutating func enterContainer() throws {
        depth += 1
        guard depth <= limits.maxNestingDepth else { throw JSONError.depthExceeded(limit: limits.maxNestingDepth) }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        index += 1  // '{'
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if current == "}" { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard current == "\"" else { throw JSONError.syntax("object name must be a string") }
            let name = try parseString()
            // RFC 8785 signing requires that a duplicate name never silently
            // wins: mutations fail closed instead (spec.watch.md section 8).
            guard object[name] == nil else { throw JSONError.duplicateName(name) }
            skipWhitespace()
            guard current == ":" else { throw JSONError.syntax("expected ':'") }
            index += 1
            skipWhitespace()
            object[name] = try parseValue()
            guard object.count <= limits.maxCollectionElements else {
                throw JSONError.tooManyElements(limit: limits.maxCollectionElements)
            }
            skipWhitespace()
            switch current {
            case ",": index += 1
            case "}": index += 1; return .object(object)
            default: throw JSONError.syntax("expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enterContainer()
        defer { depth -= 1 }
        index += 1  // '['
        var array: [JSONValue] = []
        skipWhitespace()
        if current == "]" { index += 1; return .array(array) }
        while true {
            skipWhitespace()
            array.append(try parseValue())
            guard array.count <= limits.maxCollectionElements else {
                throw JSONError.tooManyElements(limit: limits.maxCollectionElements)
            }
            skipWhitespace()
            switch current {
            case ",": index += 1
            case "]": index += 1; return .array(array)
            default: throw JSONError.syntax("expected ',' or ']'")
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1  // opening quote
        var scalarsOut: [Unicode.Scalar] = []
        while true {
            guard let scalar = current else { throw JSONError.syntax("unterminated string") }
            index += 1
            switch scalar {
            case "\"":
                guard scalarsOut.count <= limits.maxStringCharacters else {
                    throw JSONError.stringTooLong(limit: limits.maxStringCharacters)
                }
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalarsOut)
                return String(view)
            case "\\":
                scalarsOut.append(try parseEscape())
            default:
                guard scalar.value >= 0x20 else { throw JSONError.syntax("unescaped control character") }
                scalarsOut.append(scalar)
            }
        }
    }

    private mutating func parseEscape() throws -> Unicode.Scalar {
        guard let scalar = current else { throw JSONError.syntax("unterminated escape") }
        index += 1
        switch scalar {
        case "\"": return "\""
        case "\\": return "\\"
        case "/": return "/"
        case "b": return Unicode.Scalar(0x08)!
        case "f": return Unicode.Scalar(0x0C)!
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "u":
            let first = try parseHex4()
            if first >= 0xD800 && first <= 0xDBFF {
                guard current == "\\" else { throw JSONError.invalidUnicode }
                index += 1
                guard current == "u" else { throw JSONError.invalidUnicode }
                index += 1
                let second = try parseHex4()
                guard second >= 0xDC00 && second <= 0xDFFF else { throw JSONError.invalidUnicode }
                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                guard let value = Unicode.Scalar(combined) else { throw JSONError.invalidUnicode }
                return value
            }
            // A lone surrogate cannot be represented and must not be smuggled
            // through a signed string.
            guard let value = Unicode.Scalar(first), !(first >= 0xDC00 && first <= 0xDFFF) else {
                throw JSONError.invalidUnicode
            }
            return value
        default:
            throw JSONError.syntax("invalid escape")
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let scalar = current, let digit = scalar.hexDigitValue else {
                throw JSONError.syntax("invalid \\u escape")
            }
            index += 1
            value = value << 4 | UInt32(digit)
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONNumber {
        let start = index
        if current == "-" { index += 1 }
        var isInteger = true
        while let scalar = current, ("0"..."9").contains(scalar) { index += 1 }
        if current == "." {
            isInteger = false
            index += 1
            while let scalar = current, ("0"..."9").contains(scalar) { index += 1 }
        }
        if current == "e" || current == "E" {
            isInteger = false
            index += 1
            if current == "+" || current == "-" { index += 1 }
            while let scalar = current, ("0"..."9").contains(scalar) { index += 1 }
        }
        guard index > start else { throw JSONError.syntax("invalid number") }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start..<index])
        let text = String(view)
        if isInteger, let value = Int64(text) {
            guard value.magnitude <= UInt64(JSONLimits.maxSafeInteger) else { throw JSONError.numberOutOfRange }
            return .int(value)
        }
        guard let value = Double(text), value.isFinite else { throw JSONError.numberOutOfRange }
        return .double(value)
    }
}

private extension Unicode.Scalar {
    var hexDigitValue: Int? {
        switch self {
        case "0"..."9": return Int(value - 0x30)
        case "a"..."f": return Int(value - 0x61) + 10
        case "A"..."F": return Int(value - 0x41) + 10
        default: return nil
        }
    }
}
