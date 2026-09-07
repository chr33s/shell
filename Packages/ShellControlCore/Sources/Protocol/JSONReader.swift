import Foundation

/// Typed, fail-closed accessors over a parsed JSON object.
///
/// Missing or mistyped authorization-relevant fields are errors; there is no
/// defaulting and no silent coercion (spec.watch.md section 8).
public struct JSONReader: Sendable {
    public enum ReadError: Error, Equatable, Sendable {
        case notAnObject
        case missing(String)
        case wrongType(String, expected: String)
        case invalidValue(String, reason: String)
        case unknownMembers([String])
    }

    public let members: [String: JSONValue]
    private var consumed: Set<String> = []

    public init(_ value: JSONValue) throws {
        guard let members = value.objectValue else { throw ReadError.notAnObject }
        self.members = members
    }

    public mutating func value(_ name: String) throws -> JSONValue {
        consumed.insert(name)
        guard let value = members[name] else { throw ReadError.missing(name) }
        return value
    }

    public mutating func optionalValue(_ name: String) -> JSONValue? {
        consumed.insert(name)
        let value = members[name]
        if let value, value.isNull { return nil }
        return value
    }

    public mutating func string(_ name: String, maxLength: Int = 4096) throws -> String {
        guard let text = try value(name).stringValue else { throw ReadError.wrongType(name, expected: "string") }
        guard text.unicodeScalars.count <= maxLength else {
            throw ReadError.invalidValue(name, reason: "longer than \(maxLength)")
        }
        return text
    }

    public mutating func optionalString(_ name: String, maxLength: Int = 4096) throws -> String? {
        guard let raw = optionalValue(name) else { return nil }
        guard let text = raw.stringValue else { throw ReadError.wrongType(name, expected: "string") }
        guard text.unicodeScalars.count <= maxLength else {
            throw ReadError.invalidValue(name, reason: "longer than \(maxLength)")
        }
        return text
    }

    public mutating func integer(_ name: String) throws -> Int64 {
        guard let number = try value(name).int64Value else { throw ReadError.wrongType(name, expected: "safe integer") }
        return number
    }

    public mutating func optionalInteger(_ name: String) throws -> Int64? {
        guard let raw = optionalValue(name) else { return nil }
        guard let number = raw.int64Value else { throw ReadError.wrongType(name, expected: "safe integer") }
        return number
    }

    public mutating func bool(_ name: String) throws -> Bool {
        guard let flag = try value(name).boolValue else { throw ReadError.wrongType(name, expected: "boolean") }
        return flag
    }

    public mutating func optionalBool(_ name: String) throws -> Bool? {
        guard let raw = optionalValue(name) else { return nil }
        guard let flag = raw.boolValue else { throw ReadError.wrongType(name, expected: "boolean") }
        return flag
    }

    public mutating func id(_ name: String) throws -> ControlID {
        let text = try string(name, maxLength: 36)
        guard let value = ControlID(text) else {
            throw ReadError.invalidValue(name, reason: "not a canonical lowercase UUID")
        }
        return value
    }

    public mutating func optionalID(_ name: String) throws -> ControlID? {
        guard let text = try optionalString(name, maxLength: 36) else { return nil }
        guard let value = ControlID(text) else {
            throw ReadError.invalidValue(name, reason: "not a canonical lowercase UUID")
        }
        return value
    }

    public mutating func timestamp(_ name: String) throws -> ControlTimestamp {
        let text = try string(name, maxLength: 40)
        guard let value = ControlTimestamp.lenient(text) else {
            throw ReadError.invalidValue(name, reason: "not an RFC 3339 UTC timestamp")
        }
        return value
    }

    public mutating func optionalTimestamp(_ name: String) throws -> ControlTimestamp? {
        guard let text = try optionalString(name, maxLength: 40) else { return nil }
        guard let value = ControlTimestamp.lenient(text) else {
            throw ReadError.invalidValue(name, reason: "not an RFC 3339 UTC timestamp")
        }
        return value
    }

    public mutating func stringArray(_ name: String, maxCount: Int = 256, maxLength: Int = 4096) throws -> [String] {
        guard let elements = try value(name).arrayValue else { throw ReadError.wrongType(name, expected: "array") }
        guard elements.count <= maxCount else { throw ReadError.invalidValue(name, reason: "more than \(maxCount) elements") }
        return try elements.map { element in
            guard let text = element.stringValue else { throw ReadError.wrongType(name, expected: "array of strings") }
            guard text.unicodeScalars.count <= maxLength else {
                throw ReadError.invalidValue(name, reason: "element longer than \(maxLength)")
            }
            return text
        }
    }

    public mutating func object(_ name: String) throws -> JSONReader {
        try JSONReader(try value(name))
    }

    public mutating func optionalObject(_ name: String) throws -> JSONReader? {
        guard let raw = optionalValue(name) else { return nil }
        return try JSONReader(raw)
    }

    /// Rejects members the schema does not define.
    ///
    /// Unknown command or operation types fail closed for mutations; only
    /// members explicitly specified as non-authorizing extension data may be
    /// ignored (spec.watch.md section 8).
    public func rejectUnknownMembers(allowing extensions: Set<String> = []) throws {
        let unknown = Set(members.keys).subtracting(consumed).subtracting(extensions)
        guard unknown.isEmpty else { throw ReadError.unknownMembers(unknown.sorted()) }
    }
}

public enum JSONWriter {
    /// Builds an object, dropping members whose value is `nil`.
    public static func object(_ members: [String: JSONValue?]) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for (name, value) in members {
            if let value { result[name] = value }
        }
        return .object(result)
    }
}

extension JSONValue {
    public init(_ id: ControlID) { self = .string(id.rawValue) }
    public init(_ timestamp: ControlTimestamp) { self = .string(timestamp.rfc3339) }
    public init(_ sequence: LogSequence) { self = .string(sequence.decimalString) }
    public init(strings: [String]) { self = .array(strings.map { .string($0) }) }
}
