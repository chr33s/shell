import Foundation

/// The `shell-agent/1` extension: native Claude Code and Codex integrations on
/// top of `shell-control/1` (spec.agent-relay.md).
///
/// Absence of the extension's discovery endpoint means the extension is
/// unsupported; nothing here changes the meaning of a base-protocol record
/// (spec.agent-relay.md section 15.1).
public enum AgentProtocol {
    public static let name = "shell-agent/1"

    /// Extension endpoints. The base approval endpoints still carry agent
    /// approvals once the operation schema is negotiated.
    public enum Path {
        public static let capabilities = "/v1/agent/capabilities"
        public static let sessions = "/v1/agent/sessions"
        public static let snapshot = "/v1/agent/snapshot"
        public static let changes = "/v1/agent/changes"
        public static let inputs = "/v1/agent/inputs"
        public static let reviewChallenges = "/v1/agent/review-challenges"
        public static let commands = "/v1/agent/commands"
        public static let receipts = "/v1/agent/receipts"
        public static let events = "/v1/agent/events"
        public static func sessionCommands(_ id: ControlID) -> String { "\(session(id))/commands" }
        public static func claimSessionCommand(_ id: ControlID, command: ControlID) -> String {
            "\(sessionCommands(id))/\(command.rawValue)/claim"
        }

        public static func session(_ id: ControlID) -> String { "\(sessions)/\(id.rawValue)" }
        public static func input(_ id: ControlID) -> String { "\(inputs)/\(id.rawValue)" }
        public static func withdrawInput(_ id: ControlID) -> String { "\(input(id))/withdraw" }
        public static func consumeInput(_ id: ControlID) -> String { "\(input(id))/consume" }
        public static func command(_ id: ControlID) -> String { "\(commands)/\(id.rawValue)" }
    }
}

/// Feature tokens of the extension. Each kind of agent operation is its own
/// token: support for the `agent.tool.v1` wrapper never implies support for a
/// kind (spec.agent-relay.md section 6.1).
public enum AgentFeature {
    public static let tool = "agent.tool.v1"
    public static let shell = "agent.shell.v1"
    public static let fileChange = "agent.file_change.v1"
    /// Reserved: disabled until a specific renderer/adapter pair is approved
    /// (spec.agent-relay.md section 6.3).
    public static let toolCall = "agent.tool_call.v1"
    public static let input = "agent.input.v1"
    public static let inputConsume = "agent.input.consume.v1"
    public static let delivery = "agent.delivery.v1"
    /// Managed-session capabilities, disabled by default: a session offers
    /// them only when an opt-in managed adapter negotiated them, and a device
    /// uses them only with the separate grants (spec.agent-relay.md 16).
    public static let messages = "agent.messages.v1"
    public static let turnCancel = "agent.turn.cancel.v1"

    /// The feature token for an operation kind.
    public static func token(for kind: AgentToolKind) -> String? {
        switch kind {
        case .shell: return shell
        case .fileChange: return fileChange
        case .toolCall: return toolCall
        case .unknown: return nil
        }
    }

    /// What this build of ShellControlCore renders and can answer.
    public static let supported: Set<String> = [tool, shell, fileChange, input, inputConsume, delivery, messages, turnCancel]
}

/// Product defaults of the extension. Negotiated lower limits and native
/// deadlines always take precedence (spec.agent-relay.md section 18).
public enum AgentPolicy {
    /// Permission/question review lifetime; never beyond native expiry.
    public static let defaultLifetime: TimeInterval = 300
    /// Only where the native integration supports it.
    public static let maximumLifetime: TimeInterval = 1800
    /// Hook internal hard deadline and the tested outer timeout.
    public static let hookInternalDeadline: TimeInterval = 330
    public static let hookOuterTimeout: Int = 360
    /// Host-side parsing cap for one native hook input.
    public static let maximumNativeInputBytes = 256 * 1024
    /// Inline review material for one agent operation.
    public static let maximumOperationBytes = 32 * 1024
    public static let maximumInputSpecBytes = 16 * 1024
    public static let maximumAnswerBytes = 4 * 1024
    public static let maximumQuestions = 16
    public static let maximumChoices = 16
    public static let maximumPromptBytes = 2048
    public static let maximumLabelBytes = 256
    public static let maximumDescriptionBytes = 1024
    public static let maximumTextAnswerBytes = 4096
    public static let maximumIdentifierLength = 64
    /// Watch question policy (spec.agent-relay.md section 13.2).
    public static let watchMaximumQuestions = 2
    public static let watchMaximumChoices = 4
    public static let watchMaximumTextBytes = 512
    /// Concurrent pending requests per run and per origin; exceeding the
    /// limit never auto-approves.
    public static let maximumPendingPerRun = 16
    public static let maximumPendingPerOrigin = 128
    public static let maximumSummaryScalars = 200
}

/// A bounded ASCII identifier chosen by an adapter: question IDs, choice IDs.
enum AgentIdentifier {
    static func isValid(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= AgentPolicy.maximumIdentifierLength else { return false }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
        }
    }

    static func require(_ text: String, field: String) throws {
        guard isValid(text) else {
            throw ValidationError.invalid(field, "must be 1...\(AgentPolicy.maximumIdentifierLength) ASCII [A-Za-z0-9_.-]")
        }
    }
}

extension String {
    /// UTF-8 length, the unit every agent byte limit is stated in.
    var utf8Count: Int { utf8.count }
}

/// A provider's native identifier with its JSON type preserved: a numeric
/// JSON-RPC ID `23` is not the string `"23"` (spec.agent-relay.md section 5.1).
public enum NativeIdentifier: Sendable, Hashable {
    case string(String)
    case integer(Int64)

    public init(json: JSONValue) throws {
        switch json {
        case .string(let text):
            guard !text.isEmpty, text.utf8Count <= 256 else {
                throw ValidationError.invalid("native identifier", "must be 1...256 bytes")
            }
            self = .string(text)
        case .number:
            guard let value = json.int64Value else {
                throw ValidationError.invalid("native identifier", "must be a safe integer")
            }
            self = .integer(value)
        default:
            throw ValidationError.invalid("native identifier", "must be a string or integer")
        }
    }

    public var json: JSONValue {
        switch self {
        case .string(let text): return .string(text)
        case .integer(let value): return .number(.int(value))
        }
    }

    public var displayText: String {
        switch self {
        case .string(let text): return text
        case .integer(let value): return String(value)
        }
    }
}

extension JSONReader {
    mutating func optionalNativeIdentifier(_ name: String) throws -> NativeIdentifier? {
        guard let value = optionalValue(name) else { return nil }
        return try NativeIdentifier(json: value)
    }

    mutating func sha256Hex(_ name: String) throws -> String {
        let text = try string(name, maxLength: 64)
        guard ASCIIHex.isSHA256(text) else {
            throw ValidationError.invalid(name, "must be 64 lowercase hex characters")
        }
        return text
    }

    mutating func digest(_ name: String) throws -> String {
        let text = try string(name, maxLength: 80)
        guard text.hasPrefix(ContentDigest.prefix),
              ASCIIHex.isSHA256(String(text.dropFirst(ContentDigest.prefix.count))) else {
            throw ValidationError.invalid(name, "must be sha256:<64 lowercase hex>")
        }
        return text
    }
}
