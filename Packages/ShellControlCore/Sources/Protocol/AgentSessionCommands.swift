import Foundation

/// Whether a session is between turns or running one. Only managed sessions
/// report it, from the provider's own turn events
/// (docs/specs/agent-relay.md section 15).
public enum AgentTurnState: String, Sendable, Hashable {
    case idle
    case active
}

public enum AgentMessageMode: String, Sendable, Hashable {
    /// Start a new turn; valid only while the session is idle.
    case newTurn = "new_turn"
    /// Add to the active turn; valid only while that exact turn is active.
    case steer
}

/// The exact action a session command performs. Its digest is committed in
/// the review challenge before signing and again in the signed command, so a
/// command targeting mutable session state is still bound to exactly what the
/// user confirmed (docs/specs/agent-relay.md section 15.1).
public enum AgentSessionAction: Sendable, Hashable {
    case message(agentSessionID: ControlID, runID: ControlID, expectedSessionVersion: Int64, mode: AgentMessageMode, expectedTurnID: String?, text: String)
    case cancel(agentSessionID: ControlID, runID: ControlID, expectedSessionVersion: Int64, turnID: String)

    public static let maximumTextBytes = 4096

    public var commandType: AgentCommandType {
        switch self {
        case .message: return .agentMessage
        case .cancel: return .turnCancel
        }
    }

    public var agentSessionID: ControlID {
        switch self {
        case .message(let id, _, _, _, _, _), .cancel(let id, _, _, _): return id
        }
    }

    public var runID: ControlID {
        switch self {
        case .message(_, let id, _, _, _, _), .cancel(_, let id, _, _): return id
        }
    }

    public var expectedSessionVersion: Int64 {
        switch self {
        case .message(_, _, let version, _, _, _), .cancel(_, _, let version, _): return version
        }
    }

    /// Plain text only: no caller-controlled model, directory, sandbox,
    /// permission, tool, prompt, or executable overrides exist in this shape.
    public func validate() throws {
        switch self {
        case .message(_, _, _, let mode, let expectedTurnID, let text):
            guard !text.isEmpty, text.utf8Count <= Self.maximumTextBytes else {
                throw ValidationError.invalid("text", "must be 1...\(Self.maximumTextBytes) bytes")
            }
            guard !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }) else {
                throw ValidationError.invalid("text", "must not contain control characters")
            }
            switch mode {
            case .newTurn:
                guard expectedTurnID == nil else { throw ValidationError.invalid("expected_turn_id", "a new turn names no turn") }
            case .steer:
                guard let expectedTurnID, !expectedTurnID.isEmpty, expectedTurnID.utf8Count <= 256 else {
                    throw ValidationError.invalid("expected_turn_id", "steering names the active turn")
                }
            }
        case .cancel(_, _, _, let turnID):
            guard !turnID.isEmpty, turnID.utf8Count <= 256 else { throw ValidationError.invalid("turn_id", "must be 1...256 bytes") }
        }
    }

    /// The members the action contributes to the signed command.
    var members: [String: JSONValue] {
        switch self {
        case .message(let session, let run, let version, let mode, let turn, let text):
            return JSONWriter.object([
                "agent_session_id": JSONValue(session),
                "run_id": JSONValue(run),
                "expected_session_version": .number(.int(version)),
                "mode": .string(mode.rawValue),
                "expected_turn_id": turn.map { .string($0) },
                "text": .string(text)
            ]).objectValue ?? [:]
        case .cancel(let session, let run, let version, let turn):
            return [
                "agent_session_id": JSONValue(session),
                "run_id": JSONValue(run),
                "expected_session_version": .number(.int(version)),
                "turn_id": .string(turn)
            ]
        }
    }

    public var json: JSONValue {
        var members = self.members
        members["type"] = .string(commandType.rawValue)
        return .object(members)
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let type = try reader.string("type", maxLength: 32)
        try self.init(reader: &reader, type: type)
        try reader.rejectUnknownMembers()
    }

    init(reader: inout JSONReader, type: String) throws {
        let session = try reader.id("agent_session_id")
        let run = try reader.id("run_id")
        let version = try reader.integer("expected_session_version")
        switch type {
        case AgentCommandType.agentMessage.rawValue:
            let modeText = try reader.string("mode", maxLength: 16)
            guard let mode = AgentMessageMode(rawValue: modeText) else { throw ValidationError.unsupported("message mode \(modeText)") }
            self = .message(agentSessionID: session, runID: run, expectedSessionVersion: version, mode: mode,
                            expectedTurnID: try reader.optionalString("expected_turn_id", maxLength: 256),
                            text: try reader.string("text", maxLength: Self.maximumTextBytes))
        case AgentCommandType.turnCancel.rawValue:
            self = .cancel(agentSessionID: session, runID: run, expectedSessionVersion: version,
                           turnID: try reader.string("turn_id", maxLength: 256))
        default:
            throw ValidationError.unsupported("session action \(type)")
        }
        try validate()
    }

    /// `sha256:` over the canonical action, including its type.
    public var digest: String {
        (try? ContentDigest.digest(ofCanonical: json)) ?? ContentDigest.digest(of: Data())
    }
}

/// `agent.message` or `agent.turn.cancel`, signed by a device.
public struct AgentSessionCommand: Sendable, Hashable {
    public let envelope: AgentCommandEnvelope
    public let action: AgentSessionAction
    public let actionDigest: String
    public let challengeID: String

    public init(envelope: AgentCommandEnvelope, action: AgentSessionAction, challengeID: String) throws {
        guard envelope.type == action.commandType else { throw ValidationError.unsupported("command type") }
        try action.validate()
        guard !challengeID.isEmpty, challengeID.count <= 128 else {
            throw ValidationError.invalid("challenge_id", "must be 1...128 characters")
        }
        self.envelope = envelope
        self.action = action
        self.actionDigest = action.digest
        self.challengeID = challengeID
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let typeText = try reader.string("type", maxLength: 64)
        guard let type = AgentCommandType(rawValue: typeText), type != .inputRespond else {
            throw ValidationError.unsupported("session command type \(typeText)")
        }
        let envelope = try AgentCommandEnvelope(
            version: Int(try reader.integer("v")), type: type, commandID: try reader.id("command_id"),
            deviceID: try reader.id("device_id"), audience: try reader.string("aud", maxLength: 128),
            issuedAt: try reader.timestamp("issued_at"), notAfter: try reader.timestamp("not_after")
        )
        let action = try AgentSessionAction(reader: &reader, type: typeText)
        let digest = try reader.digest("action_digest")
        let challengeID = try reader.string("challenge_id", maxLength: 128)
        try reader.rejectUnknownMembers()
        try self.init(envelope: envelope, action: action, challengeID: challengeID)
        // The signed digest must be the digest of the signed action.
        guard ContentDigest.matches(digest, actionDigest) else {
            throw ValidationError.invalid("action_digest", "does not match the action")
        }
    }

    public var json: JSONValue {
        var members = envelope.members
        for (name, value) in action.members { members[name] = value }
        members["action_digest"] = .string(actionDigest)
        members["challenge_id"] = .string(challengeID)
        return .object(members)
    }
}

/// A recorded session command as devices and origins see it.
public struct AgentSessionCommandRecord: Sendable, Hashable {
    public let commandID: ControlID
    public let action: AgentSessionAction
    public let actionDigest: String
    public let deviceID: ControlID
    public let recordedAt: ControlTimestamp
    public let notAfter: ControlTimestamp
    public var dispatch: AgentDispatch
    public var evidence: String?
    public var version: Int64

    public init(commandID: ControlID, action: AgentSessionAction, deviceID: ControlID, recordedAt: ControlTimestamp,
                notAfter: ControlTimestamp, dispatch: AgentDispatch = .awaitingOrigin, evidence: String? = nil, version: Int64 = 1) {
        self.commandID = commandID
        self.action = action
        self.actionDigest = action.digest
        self.deviceID = deviceID
        self.recordedAt = recordedAt
        self.notAfter = notAfter
        self.dispatch = dispatch
        self.evidence = evidence
        self.version = version
    }

    public var json: JSONValue {
        JSONWriter.object([
            "command_id": JSONValue(commandID),
            "action": action.json,
            "action_digest": .string(actionDigest),
            "device_id": JSONValue(deviceID),
            "recorded_at": JSONValue(recordedAt),
            "not_after": JSONValue(notAfter),
            "dispatch": .string(dispatch.rawValue),
            "evidence": evidence.map { .string($0) },
            "version": .number(.int(version))
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        commandID = try reader.id("command_id")
        action = try AgentSessionAction(json: try reader.value("action"))
        actionDigest = try reader.digest("action_digest")
        guard ContentDigest.matches(actionDigest, action.digest) else {
            throw ValidationError.invalid("action_digest", "does not match the action")
        }
        deviceID = try reader.id("device_id")
        recordedAt = try reader.timestamp("recorded_at")
        notAfter = try reader.timestamp("not_after")
        let dispatchText = try reader.string("dispatch", maxLength: 32)
        guard let dispatch = AgentDispatch(rawValue: dispatchText) else { throw ValidationError.unsupported("dispatch \(dispatchText)") }
        self.dispatch = dispatch
        evidence = try reader.optionalString("evidence", maxLength: 64)
        version = try reader.integer("version")
        try reader.rejectUnknownMembers()
    }
}

/// The origin's claim on one recorded session command.
public struct AgentSessionClaimRequest: Sendable, Hashable {
    public let mutationID: ControlID
    public let commandID: ControlID
    public let actionDigest: String
    /// The managed connection the command will be written to.
    public let connectionEpoch: ControlID

    public init(mutationID: ControlID, commandID: ControlID, actionDigest: String, connectionEpoch: ControlID) {
        self.mutationID = mutationID
        self.commandID = commandID
        self.actionDigest = actionDigest
        self.connectionEpoch = connectionEpoch
    }

    public var json: JSONValue {
        .object([
            "mutation_id": JSONValue(mutationID),
            "command_id": JSONValue(commandID),
            "action_digest": .string(actionDigest),
            "connection_epoch": JSONValue(connectionEpoch)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        mutationID = try reader.id("mutation_id")
        commandID = try reader.id("command_id")
        actionDigest = try reader.digest("action_digest")
        connectionEpoch = try reader.id("connection_epoch")
        try reader.rejectUnknownMembers()
    }
}

/// A one-time grant to perform one session action on one connection, never
/// later than the signed deadline (docs/specs/agent-relay.md sections 7.2, 15).
public struct AgentSessionPermit: Sendable, Hashable {
    public let permitID: ControlID
    public let mutationID: ControlID
    public let commandID: ControlID
    public let connectionEpoch: ControlID
    public let action: AgentSessionAction
    public let actionDigest: String
    public let commandJWS: String
    public let issuedAt: ControlTimestamp
    public let applyBefore: ControlTimestamp

    public init(permitID: ControlID, mutationID: ControlID, commandID: ControlID, connectionEpoch: ControlID, action: AgentSessionAction,
                commandJWS: String, issuedAt: ControlTimestamp, applyBefore: ControlTimestamp) {
        self.permitID = permitID
        self.mutationID = mutationID
        self.commandID = commandID
        self.connectionEpoch = connectionEpoch
        self.action = action
        self.actionDigest = action.digest
        self.commandJWS = commandJWS
        self.issuedAt = issuedAt
        self.applyBefore = applyBefore
    }

    public var json: JSONValue {
        .object([
            "permit_id": JSONValue(permitID),
            "mutation_id": JSONValue(mutationID),
            "command_id": JSONValue(commandID),
            "connection_epoch": JSONValue(connectionEpoch),
            "action": action.json,
            "action_digest": .string(actionDigest),
            "command_jws": .string(commandJWS),
            "issued_at": JSONValue(issuedAt),
            "apply_before": JSONValue(applyBefore)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        permitID = try reader.id("permit_id")
        mutationID = try reader.id("mutation_id")
        commandID = try reader.id("command_id")
        connectionEpoch = try reader.id("connection_epoch")
        action = try AgentSessionAction(json: try reader.value("action"))
        actionDigest = try reader.digest("action_digest")
        commandJWS = try reader.string("command_jws", maxLength: 16384)
        issuedAt = try reader.timestamp("issued_at")
        applyBefore = try reader.timestamp("apply_before")
        try reader.rejectUnknownMembers()
    }

    public func isApplicable(at now: ControlTimestamp, clockUncertainty: TimeInterval = 2) -> Bool {
        now.date.addingTimeInterval(clockUncertainty) < applyBefore.date
    }

    /// The claimed action, its digest, and the signed command must agree.
    public func validate(connectionEpoch expectedEpoch: ControlID, agentSessionID: ControlID) throws {
        guard connectionEpoch == expectedEpoch, action.agentSessionID == agentSessionID,
              ContentDigest.matches(actionDigest, action.digest) else {
            throw ValidationError.invalid("permit", "does not match this session and connection")
        }
        let command = try AgentSessionCommand(json: try SignedPayloadReader.payload(ofCompactJWS: commandJWS))
        guard command.envelope.commandID == commandID, command.action == action else {
            throw ValidationError.invalid("permit", "signed command does not carry this action")
        }
    }
}
