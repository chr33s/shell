import Foundation

/// The operation an approval request is asking about.
///
/// Only negotiated schemas are approvable on the Watch; an unknown schema is
/// carried opaquely so the client can display "review on another device"
/// without ever rendering it as something it understands
/// (spec.watch.md section 9).
public enum ControlOperation: Sendable, Hashable {
    case exec(ExecOperation)
    case unknown(schema: String, raw: JSONValue)

    public var schema: String {
        switch self {
        case .exec: return ExecOperation.schema
        case .unknown(let schema, _): return schema
        }
    }

    public var isRecognized: Bool {
        if case .unknown = self { return false }
        return true
    }

    public var json: JSONValue {
        switch self {
        case .exec(let operation): return operation.json
        case .unknown(_, let raw): return raw
        }
    }

    public static func decode(_ value: JSONValue) throws -> ControlOperation {
        var reader = try JSONReader(value)
        let schema = try reader.string("schema", maxLength: 64)
        switch schema {
        case ExecOperation.schema:
            return .exec(try ExecOperation(json: value))
        default:
            return .unknown(schema: schema, raw: value)
        }
    }
}

/// `exec.v1`: a concrete argument vector at a concrete working directory.
///
/// Requires a nonempty argument array, an absolute executable path, an absolute
/// working directory, and an adapter-produced context commitment
/// (spec.watch.md section 9).
public struct ExecOperation: Sendable, Hashable {
    public static let schema = "exec.v1"

    public let argv: [String]
    public let cwd: String
    public let contextSHA256: String

    public init(argv: [String], cwd: String, contextSHA256: String) throws {
        guard let executable = argv.first, !argv.isEmpty else {
            throw ValidationError.invalid("operation.argv", "must be nonempty")
        }
        guard executable.hasPrefix("/") else {
            throw ValidationError.invalid("operation.argv[0]", "must be an absolute executable path")
        }
        guard cwd.hasPrefix("/") else {
            throw ValidationError.invalid("operation.cwd", "must be an absolute directory path")
        }
        guard ExecOperation.isSHA256Hex(contextSHA256) else {
            throw ValidationError.invalid("operation.context_sha256", "must be 64 lowercase hex characters")
        }
        self.argv = argv
        self.cwd = cwd
        self.contextSHA256 = contextSHA256
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let schema = try reader.string("schema", maxLength: 64)
        guard schema == ExecOperation.schema else {
            throw ValidationError.invalid("operation.schema", "expected \(ExecOperation.schema)")
        }
        let argv = try reader.stringArray("argv", maxCount: 256, maxLength: 4096)
        let cwd = try reader.string("cwd", maxLength: 4096)
        let context = try reader.string("context_sha256", maxLength: 64)
        try reader.rejectUnknownMembers()
        try self.init(argv: argv, cwd: cwd, contextSHA256: context)
    }

    public var json: JSONValue {
        .object([
            "schema": .string(ExecOperation.schema),
            "argv": JSONValue(strings: argv),
            "cwd": .string(cwd),
            "context_sha256": .string(contextSHA256),
        ])
    }

    static func isSHA256Hex(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

public enum ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(String, String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .invalid(let field, let reason): return "\(field) \(reason)"
        case .unsupported(let what): return "unsupported \(what)"
        }
    }
}
