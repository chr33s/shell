import Foundation

/// The initial `agent.tool.v1` variants. Each needs its own feature token and
/// renderer; an unknown variant is carried but never approvable
/// (docs/specs/agent-relay.md section 5.1).
public enum AgentToolKind: Sendable, Hashable {
    case shell
    case fileChange
    case toolCall
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "shell": self = .shell
        case "file_change": self = .fileChange
        case "tool_call": self = .toolCall
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .shell: return "shell"
        case .fileChange: return "file_change"
        case .toolCall: return "tool_call"
        case .unknown(let text): return text
        }
    }
}

/// The only scope v1 approves remotely: one decision for one native gate. It
/// is not a promise of one subprocess, network request, or file write
/// (docs/specs/agent-relay.md section 5.3).
public enum AgentPermissionScope {
    public static let singleNativeGate = "single_native_gate"
}

/// A scalar authorization-relevant option exactly as the provider sent it
/// (`timeout`, `run_in_background`, ...). Nothing is re-encoded or guessed.
public enum AgentOptionValue: Sendable, Hashable {
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null

    init(json: JSONValue, field: String) throws {
        switch json {
        case .string(let text):
            guard text.utf8Count <= 1024 else { throw ValidationError.invalid(field, "longer than 1024 bytes") }
            self = .string(text)
        case .bool(let flag): self = .bool(flag)
        case .null: self = .null
        case .number:
            guard let value = json.int64Value else { throw ValidationError.invalid(field, "must be a safe integer") }
            self = .integer(value)
        default:
            throw ValidationError.invalid(field, "must be a scalar")
        }
    }

    public var json: JSONValue {
        switch self {
        case .string(let text): return .string(text)
        case .integer(let value): return .number(.int(value))
        case .bool(let flag): return .bool(flag)
        case .null: return .null
        }
    }

    public var displayText: String {
        switch self {
        case .string(let text): return text
        case .integer(let value): return String(value)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }
}

/// The exact shell request. A provider command string is never split into an
/// argument vector, and a shell the adapter cannot identify is reported as
/// unavailable rather than invented (docs/specs/agent-relay.md sections 5.1, 5.4).
public struct AgentShellRequest: Sendable, Hashable {
    public enum Representation: String, Sendable, Hashable {
        case commandString = "command_string"
        case argv
    }

    public let representation: Representation
    public let command: String?
    public let argv: [String]?
    public let shellIdentity: String?
    public let options: [String: AgentOptionValue]

    public init(
        representation: Representation,
        command: String? = nil,
        argv: [String]? = nil,
        shellIdentity: String? = nil,
        options: [String: AgentOptionValue] = [:]
    ) throws {
        switch representation {
        case .commandString:
            guard let command, !command.isEmpty, argv == nil else {
                throw ValidationError.invalid("shell_request", "command_string needs a nonempty command and no argv")
            }
        case .argv:
            guard let argv, !argv.isEmpty, command == nil else {
                throw ValidationError.invalid("shell_request", "argv needs a nonempty argument vector and no command")
            }
        }
        guard options.count <= 16, options.keys.allSatisfy(AgentIdentifier.isValid) else {
            throw ValidationError.invalid("shell_request.options", "must hold at most 16 identifier-named scalars")
        }
        self.representation = representation
        self.command = command
        self.argv = argv
        self.shellIdentity = shellIdentity
        self.options = options
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let text = try reader.string("representation", maxLength: 32)
        guard let representation = Representation(rawValue: text) else {
            throw ValidationError.unsupported("shell representation \(text)")
        }
        let command = try reader.optionalString("command", maxLength: AgentPolicy.maximumOperationBytes)
        let argv = try reader.optionalValue("argv").map { _ in
            try reader.stringArray("argv", maxCount: 256, maxLength: 4096)
        }
        let shellIdentity = try reader.optionalString("shell_identity", maxLength: 1024)
        var options: [String: AgentOptionValue] = [:]
        if let raw = reader.optionalValue("options") {
            guard let members = raw.objectValue else { throw ValidationError.invalid("shell_request.options", "must be an object") }
            for (name, value) in members { options[name] = try AgentOptionValue(json: value, field: "shell_request.options.\(name)") }
        }
        try reader.rejectUnknownMembers()
        try self.init(representation: representation, command: command, argv: argv, shellIdentity: shellIdentity, options: options)
    }

    public var json: JSONValue {
        JSONWriter.object([
            "representation": .string(representation.rawValue),
            "command": command.map { .string($0) },
            "argv": argv.map { JSONValue(strings: $0) },
            // An explicit null: the missing shell identity is a stated
            // limitation, not an omission.
            "shell_identity": shellIdentity.map { .string($0) } ?? .null,
            "options": options.isEmpty ? nil : .object(options.mapValues(\.json))
        ])
    }
}

/// One file the change touches, with the complete relevant diff and the
/// precondition hash the host rechecks before answering the gate
/// (docs/specs/agent-relay.md section 5.3).
public struct AgentFileChange: Sendable, Hashable {
    public enum Change: String, Sendable, Hashable {
        case create
        case modify
        case delete
    }

    public let path: String
    public let change: Change
    public let diff: String
    /// SHA-256 of the file before the change; nil only for `create`, where
    /// the precondition is that the path does not exist.
    public let baseSHA256: String?

    public init(path: String, change: Change, diff: String, baseSHA256: String?) throws {
        guard path.hasPrefix("/"), path.utf8Count <= 4096 else {
            throw ValidationError.invalid("file_change.path", "must be an absolute path")
        }
        if let baseSHA256 {
            guard ASCIIHex.isSHA256(baseSHA256) else {
                throw ValidationError.invalid("file_change.base_sha256", "must be 64 lowercase hex characters")
            }
        } else if change != .create {
            throw ValidationError.invalid("file_change.base_sha256", "is required unless the file is created")
        }
        self.path = path
        self.change = change
        self.diff = diff
        self.baseSHA256 = baseSHA256
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let path = try reader.string("path", maxLength: 4096)
        let changeText = try reader.string("change", maxLength: 16)
        guard let change = Change(rawValue: changeText) else { throw ValidationError.unsupported("file change \(changeText)") }
        let diff = try reader.string("diff", maxLength: AgentPolicy.maximumOperationBytes)
        let base = try reader.optionalString("base_sha256", maxLength: 64)
        try reader.rejectUnknownMembers()
        try self.init(path: path, change: change, diff: diff, baseSHA256: base)
    }

    public var json: JSONValue {
        .object([
            "path": .string(path),
            "change": .string(change.rawValue),
            "diff": .string(diff),
            "base_sha256": baseSHA256.map { .string($0) } ?? .null
        ])
    }
}

/// `agent.tool.v1`: an agent operation waiting at one native permission gate.
///
/// Every authorization-relevant field is inside this committed object, so it
/// is covered by the enclosing approval's request hash; nothing is appended as
/// unsigned decoration (docs/specs/agent-relay.md sections 5.2 and 5.4).
public struct AgentToolOperation: Sendable, Hashable {
    public static let schema = "agent.tool.v1"

    public let provider: String
    public let providerBuild: String
    public let adapterBuild: String
    public let agentSessionID: ControlID
    public let nativeWaitID: ControlID
    public let connectionEpoch: ControlID?
    public let providerSessionID: String?
    public let providerTurnID: String?
    public let providerRequestID: NativeIdentifier?
    public let providerToolUseID: String?
    public let kind: AgentToolKind
    public let toolName: String
    public let cwd: String?
    public let permissionScope: String
    /// The provider's own explanation. Untrusted display text; it has no
    /// protocol effect whatever it says.
    public let reason: String?
    public let shellRequest: AgentShellRequest?
    public let fileChanges: [AgentFileChange]?
    /// A `tool_call` payload is carried verbatim; v1 renders none.
    public let toolCall: JSONValue?
    /// Context the adapter could not observe, named rather than fabricated.
    public let unavailable: [String]
    public let nativeRequestSHA256: String
    public let contextSHA256: String

    public init(
        provider: String,
        providerBuild: String,
        adapterBuild: String,
        agentSessionID: ControlID,
        nativeWaitID: ControlID,
        connectionEpoch: ControlID? = nil,
        providerSessionID: String? = nil,
        providerTurnID: String? = nil,
        providerRequestID: NativeIdentifier? = nil,
        providerToolUseID: String? = nil,
        kind: AgentToolKind,
        toolName: String,
        cwd: String?,
        permissionScope: String = AgentPermissionScope.singleNativeGate,
        reason: String? = nil,
        shellRequest: AgentShellRequest? = nil,
        fileChanges: [AgentFileChange]? = nil,
        toolCall: JSONValue? = nil,
        unavailable: [String] = [],
        nativeRequestSHA256: String,
        contextSHA256: String
    ) throws {
        try AgentIdentifier.require(provider, field: "provider")
        for (field, text) in [("provider_build", providerBuild), ("adapter_build", adapterBuild)] {
            guard !text.isEmpty, text.utf8Count <= 64 else { throw ValidationError.invalid(field, "must be 1...64 bytes") }
        }
        guard !toolName.isEmpty, toolName.utf8Count <= 128 else {
            throw ValidationError.invalid("tool_name", "must be 1...128 bytes")
        }
        if let cwd {
            guard cwd.hasPrefix("/"), cwd.utf8Count <= 4096 else { throw ValidationError.invalid("cwd", "must be an absolute directory path") }
        }
        guard !permissionScope.isEmpty, permissionScope.utf8Count <= 64 else {
            throw ValidationError.invalid("permission_scope", "must be 1...64 bytes")
        }
        guard ASCIIHex.isSHA256(nativeRequestSHA256) else {
            throw ValidationError.invalid("native_request_sha256", "must be 64 lowercase hex characters")
        }
        guard ASCIIHex.isSHA256(contextSHA256) else {
            throw ValidationError.invalid("context_sha256", "must be 64 lowercase hex characters")
        }
        guard unavailable.count <= 16, unavailable.allSatisfy(AgentIdentifier.isValid) else {
            throw ValidationError.invalid("unavailable", "must name at most 16 identifier fields")
        }
        // The fields a kind-specific renderer needs must be present.
        switch kind {
        case .shell:
            guard shellRequest != nil, fileChanges == nil, toolCall == nil, cwd != nil else {
                throw ValidationError.invalid("kind", "shell needs shell_request and cwd, and nothing else")
            }
        case .fileChange:
            guard let fileChanges, !fileChanges.isEmpty, fileChanges.count <= 32, shellRequest == nil, toolCall == nil else {
                throw ValidationError.invalid("kind", "file_change needs 1...32 file_changes, and nothing else")
            }
        case .toolCall:
            guard toolCall != nil, shellRequest == nil, fileChanges == nil else {
                throw ValidationError.invalid("kind", "tool_call needs tool_call, and nothing else")
            }
        case .unknown:
            break
        }
        self.provider = provider
        self.providerBuild = providerBuild
        self.adapterBuild = adapterBuild
        self.agentSessionID = agentSessionID
        self.nativeWaitID = nativeWaitID
        self.connectionEpoch = connectionEpoch
        self.providerSessionID = providerSessionID
        self.providerTurnID = providerTurnID
        self.providerRequestID = providerRequestID
        self.providerToolUseID = providerToolUseID
        self.kind = kind
        self.toolName = toolName
        self.cwd = cwd
        self.permissionScope = permissionScope
        self.reason = reason
        self.shellRequest = shellRequest
        self.fileChanges = fileChanges
        self.toolCall = toolCall
        self.unavailable = unavailable
        self.nativeRequestSHA256 = nativeRequestSHA256
        self.contextSHA256 = contextSHA256
        let size = try JSONCanonicalization.canonicalize(json).count
        guard size <= AgentPolicy.maximumOperationBytes else {
            throw ValidationError.invalid("operation", "exceeds the \(AgentPolicy.maximumOperationBytes)-byte inline review limit")
        }
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard try reader.string("schema", maxLength: 64) == Self.schema else {
            throw ValidationError.invalid("operation.schema", "expected \(Self.schema)")
        }
        let provider = try reader.string("provider", maxLength: 64)
        let providerBuild = try reader.string("provider_build", maxLength: 64)
        let adapterBuild = try reader.string("adapter_build", maxLength: 64)
        let agentSessionID = try reader.id("agent_session_id")
        let nativeWaitID = try reader.id("native_wait_id")
        let connectionEpoch = try reader.optionalID("connection_epoch")
        let providerSessionID = try reader.optionalString("provider_session_id", maxLength: 256)
        let providerTurnID = try reader.optionalString("provider_turn_id", maxLength: 256)
        let providerRequestID = try reader.optionalNativeIdentifier("provider_request_id")
        let providerToolUseID = try reader.optionalString("provider_tool_use_id", maxLength: 256)
        let kind = AgentToolKind(rawValue: try reader.string("kind", maxLength: 32))
        let toolName = try reader.string("tool_name", maxLength: 128)
        let cwd = try reader.optionalString("cwd", maxLength: 4096)
        let permissionScope = try reader.string("permission_scope", maxLength: 64)
        let reason = try reader.optionalString("reason", maxLength: 2048)
        let shellRequest = try reader.optionalValue("shell_request").map(AgentShellRequest.init(json:))
        let fileChanges = try reader.optionalValue("file_changes").map { value -> [AgentFileChange] in
            guard let items = value.arrayValue else { throw ValidationError.invalid("file_changes", "must be an array") }
            return try items.map(AgentFileChange.init(json:))
        }
        let toolCall = reader.optionalValue("tool_call")
        let unavailable = try reader.optionalValue("unavailable").map { _ in
            try reader.stringArray("unavailable", maxCount: 16, maxLength: 64)
        } ?? []
        let nativeRequestSHA256 = try reader.sha256Hex("native_request_sha256")
        let contextSHA256 = try reader.sha256Hex("context_sha256")
        try reader.rejectUnknownMembers()
        try self.init(
            provider: provider, providerBuild: providerBuild, adapterBuild: adapterBuild,
            agentSessionID: agentSessionID, nativeWaitID: nativeWaitID, connectionEpoch: connectionEpoch,
            providerSessionID: providerSessionID, providerTurnID: providerTurnID,
            providerRequestID: providerRequestID, providerToolUseID: providerToolUseID,
            kind: kind, toolName: toolName, cwd: cwd, permissionScope: permissionScope, reason: reason,
            shellRequest: shellRequest, fileChanges: fileChanges, toolCall: toolCall, unavailable: unavailable,
            nativeRequestSHA256: nativeRequestSHA256, contextSHA256: contextSHA256
        )
    }

    public var json: JSONValue {
        JSONWriter.object([
            "schema": .string(Self.schema),
            "provider": .string(provider),
            "provider_build": .string(providerBuild),
            "adapter_build": .string(adapterBuild),
            "agent_session_id": JSONValue(agentSessionID),
            "native_wait_id": JSONValue(nativeWaitID),
            "connection_epoch": connectionEpoch.map { JSONValue($0) },
            "provider_session_id": providerSessionID.map { .string($0) },
            "provider_turn_id": providerTurnID.map { .string($0) },
            "provider_request_id": providerRequestID?.json,
            "provider_tool_use_id": providerToolUseID.map { .string($0) },
            "kind": .string(kind.rawValue),
            "tool_name": .string(toolName),
            "cwd": cwd.map { .string($0) },
            "permission_scope": .string(permissionScope),
            "reason": reason.map { .string($0) },
            "shell_request": shellRequest?.json,
            "file_changes": fileChanges.map { .array($0.map(\.json)) },
            "tool_call": toolCall,
            "unavailable": unavailable.isEmpty ? nil : JSONValue(strings: unavailable),
            "native_request_sha256": .string(nativeRequestSHA256),
            "context_sha256": .string(contextSHA256)
        ])
    }

    /// The feature tokens an approval of this operation must require: the
    /// wrapper, the kind, and one-time consume (docs/specs/agent-relay.md 5.4).
    public var requiredFeatures: [String] {
        [Self.schema, AgentFeature.token(for: kind) ?? "agent.\(kind.rawValue).unsupported", ControlFeature.consume]
    }

    /// Whether this build could ever render the operation for a decision:
    /// a known kind at the one supported scope. Feature negotiation and
    /// review policy still apply on top.
    public var isRenderable: Bool {
        guard permissionScope == AgentPermissionScope.singleNativeGate else { return false }
        switch kind {
        case .shell, .fileChange: return true
        case .toolCall, .unknown: return false
        }
    }

    /// Whether a Watch-sized surface may approve this operation. File changes
    /// and broad scopes need the iPhone; shell commands need an explicitly
    /// narrow, single-line command (docs/specs/agent-relay.md sections 5.3, 12.2).
    public var isWatchEligible: Bool {
        guard isRenderable, case .shell = kind, let shellRequest else { return false }
        // Options such as `run_in_background` or `timeout` change what runs;
        // a Watch-sized review shows only the command, so they need the
        // iPhone.
        guard shellRequest.options.isEmpty else { return false }
        let text = shellRequest.command ?? shellRequest.argv?.joined(separator: " ") ?? ""
        guard text.utf8Count <= AgentReviewPolicy.watchShellMaximumBytes else { return false }
        return !text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}

/// The narrow Watch shell-approval policy. It applies only when the adapter
/// has also been configured to publish Watch-reviewable shell requests.
public enum AgentReviewPolicy {
    public static let watchShellMaximumBytes = 160
}
