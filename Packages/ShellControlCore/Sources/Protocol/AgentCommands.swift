import Foundation

/// The separate agent command union. It reuses the envelope fields and the
/// signing scheme of `shell-control/1` but never broadens the legacy
/// decoder's accepted types (docs/specs/agent-relay.md section 7.1).
public enum AgentCommandType: String, Sendable, Hashable, CaseIterable {
    case inputRespond = "input.respond"
    /// Managed-session commands: separately granted, opt-in, and only for a
    /// managed session that negotiated them (docs/specs/agent-relay.md section 15).
    case agentMessage = "agent.message"
    case turnCancel = "agent.turn.cancel"

    public var isSupported: Bool { true }

    /// The grant a device needs to sign this command type.
    public var requiredGrantName: String {
        switch self {
        case .inputRespond: return "agent.inputs.respond"
        case .agentMessage: return "agent.messages.send"
        case .turnCancel: return "agent.turns.cancel"
        }
    }
}

/// `v`, `type`, `command_id`, `device_id`, exact enrolled `aud`,
/// `issued_at`, and `not_after`, validated as in the base protocol.
public struct AgentCommandEnvelope: Sendable, Hashable {
    public let version: Int
    public let type: AgentCommandType
    public let commandID: ControlID
    public let deviceID: ControlID
    public let audience: String
    public let issuedAt: ControlTimestamp
    public let notAfter: ControlTimestamp

    public init(
        version: Int = 1,
        type: AgentCommandType,
        commandID: ControlID,
        deviceID: ControlID,
        audience: String,
        issuedAt: ControlTimestamp,
        notAfter: ControlTimestamp
    ) throws {
        guard version == 1 else { throw ValidationError.unsupported("command version \(version)") }
        guard notAfter > issuedAt else { throw ValidationError.invalid("not_after", "must be after issued_at") }
        guard audience.hasPrefix("shell-control:"), audience.count <= 128 else {
            throw ValidationError.invalid("aud", "must be shell-control:<account_id>")
        }
        self.version = version
        self.type = type
        self.commandID = commandID
        self.deviceID = deviceID
        self.audience = audience
        self.issuedAt = issuedAt
        self.notAfter = notAfter
    }

    init(reader: inout JSONReader, expecting type: AgentCommandType) throws {
        let version = Int(try reader.integer("v"))
        let typeText = try reader.string("type", maxLength: 64)
        guard typeText == type.rawValue else { throw ValidationError.unsupported("command type \(typeText)") }
        try self.init(
            version: version,
            type: type,
            commandID: try reader.id("command_id"),
            deviceID: try reader.id("device_id"),
            audience: try reader.string("aud", maxLength: 128),
            issuedAt: try reader.timestamp("issued_at"),
            notAfter: try reader.timestamp("not_after")
        )
    }

    var members: [String: JSONValue] {
        [
            "v": .number(.int(Int64(version))),
            "type": .string(type.rawValue),
            "command_id": JSONValue(commandID),
            "device_id": JSONValue(deviceID),
            "aud": .string(audience),
            "issued_at": JSONValue(issuedAt),
            "not_after": JSONValue(notAfter)
        ]
    }
}

/// `input.respond`: binds the exact request digest, the observed versions,
/// the review challenge, and the actual answer (docs/specs/agent-relay.md 7.1).
public struct InputRespondCommand: Sendable, Hashable {
    public let envelope: AgentCommandEnvelope
    public let requestID: ControlID
    public let requestHash: String
    public let expectedStateVersion: Int64
    public let policyVersion: Int64
    public let challengeID: String
    public let response: InputResponse

    public init(
        envelope: AgentCommandEnvelope,
        requestID: ControlID,
        requestHash: String,
        expectedStateVersion: Int64,
        policyVersion: Int64,
        challengeID: String,
        response: InputResponse
    ) throws {
        guard envelope.type == .inputRespond else { throw ValidationError.unsupported("command type") }
        guard requestHash.hasPrefix(ContentDigest.prefix),
              ASCIIHex.isSHA256(String(requestHash.dropFirst(ContentDigest.prefix.count))) else {
            throw ValidationError.invalid("request_hash", "must be sha256:<64 lowercase hex>")
        }
        guard !challengeID.isEmpty, challengeID.count <= 128 else {
            throw ValidationError.invalid("challenge_id", "must be 1...128 characters")
        }
        self.envelope = envelope
        self.requestID = requestID
        self.requestHash = requestHash
        self.expectedStateVersion = expectedStateVersion
        self.policyVersion = policyVersion
        self.challengeID = challengeID
        self.response = response
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let envelope = try AgentCommandEnvelope(reader: &reader, expecting: .inputRespond)
        let requestID = try reader.id("request_id")
        let requestHash = try reader.string("request_hash", maxLength: 80)
        let stateVersion = try reader.integer("expected_state_version")
        let policyVersion = try reader.integer("policy_version")
        let challengeID = try reader.string("challenge_id", maxLength: 128)
        let action = try reader.string("action", maxLength: 16)
        let response: InputResponse
        switch action {
        case "answer":
            guard let items = try reader.value("answers").arrayValue, items.count <= AgentPolicy.maximumQuestions else {
                throw ValidationError.invalid("answers", "must be an array of at most \(AgentPolicy.maximumQuestions)")
            }
            response = .answer(try items.map(InputAnswer.init(json:)))
        case "decline":
            // `decline` carries no answers at all, not an empty list.
            response = .decline
        default:
            throw ValidationError.unsupported("response action \(action)")
        }
        try reader.rejectUnknownMembers()
        try self.init(
            envelope: envelope, requestID: requestID, requestHash: requestHash,
            expectedStateVersion: stateVersion, policyVersion: policyVersion,
            challengeID: challengeID, response: response
        )
    }

    public var json: JSONValue {
        var members = envelope.members
        members["request_id"] = JSONValue(requestID)
        members["request_hash"] = .string(requestHash)
        members["expected_state_version"] = .number(.int(expectedStateVersion))
        members["policy_version"] = .number(.int(policyVersion))
        members["challenge_id"] = .string(challengeID)
        // The response members sit inside the signed payload itself.
        if let responseMembers = response.json.objectValue {
            for (name, value) in responseMembers { members[name] = value }
        }
        return .object(members)
    }
}

/// A signed agent command. Unknown or reserved types fail closed.
public enum AgentCommand: Sendable, Hashable {
    case inputRespond(InputRespondCommand)
    case session(AgentSessionCommand)

    public var envelope: AgentCommandEnvelope {
        switch self {
        case .inputRespond(let command): return command.envelope
        case .session(let command): return command.envelope
        }
    }

    public var json: JSONValue {
        switch self {
        case .inputRespond(let command): return command.json
        case .session(let command): return command.json
        }
    }

    public static func decode(_ value: JSONValue) throws -> AgentCommand {
        var reader = try JSONReader(value)
        let typeText = try reader.string("type", maxLength: 64)
        guard let type = AgentCommandType(rawValue: typeText), type.isSupported else {
            throw ValidationError.unsupported("agent command type \(typeText)")
        }
        switch type {
        case .inputRespond: return .inputRespond(try InputRespondCommand(json: value))
        case .agentMessage, .turnCancel: return .session(try AgentSessionCommand(json: value))
        }
    }
}

/// What the device says it is about to do: answer an exact input, or send
/// an exact session action, bound to the versions it saw. A session command
/// targets mutable state, so its action digest is committed here, before
/// signing (docs/specs/agent-relay.md sections 7.2 and 15.1).
public struct AgentReviewChallengeRequest: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        case input(requestID: ControlID, requestHash: String, expectedStateVersion: Int64, policyVersion: Int64)
        case session(agentSessionID: ControlID, expectedSessionVersion: Int64, actionDigest: String)
    }

    public let action: AgentCommandType
    public let target: Target

    public init(action: AgentCommandType = .inputRespond, requestID: ControlID, requestHash: String, expectedStateVersion: Int64, policyVersion: Int64) throws {
        try self.init(action: action, target: .input(requestID: requestID, requestHash: requestHash,
                                                     expectedStateVersion: expectedStateVersion, policyVersion: policyVersion))
    }

    public init(action: AgentCommandType, target: Target) throws {
        switch (action, target) {
        case (.inputRespond, .input), (.agentMessage, .session), (.turnCancel, .session):
            break
        default:
            throw ValidationError.unsupported("challenge action \(action.rawValue) for this target")
        }
        self.action = action
        self.target = target
    }

    /// The session action a device is about to sign.
    public init(sessionAction: AgentSessionAction) throws {
        try self.init(action: sessionAction.commandType, target: .session(
            agentSessionID: sessionAction.agentSessionID,
            expectedSessionVersion: sessionAction.expectedSessionVersion,
            actionDigest: sessionAction.digest
        ))
    }

    public var requestID: ControlID? {
        if case .input(let id, _, _, _) = target { return id }
        return nil
    }

    public var json: JSONValue {
        switch target {
        case .input(let requestID, let requestHash, let stateVersion, let policyVersion):
            return .object([
                "target": "input",
                "action": .string(action.rawValue),
                "request_id": JSONValue(requestID),
                "request_hash": .string(requestHash),
                "expected_state_version": .number(.int(stateVersion)),
                "policy_version": .number(.int(policyVersion))
            ])
        case .session(let sessionID, let version, let digest):
            return .object([
                "target": "session",
                "action": .string(action.rawValue),
                "agent_session_id": JSONValue(sessionID),
                "expected_session_version": .number(.int(version)),
                "action_digest": .string(digest)
            ])
        }
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let targetText = try reader.string("target", maxLength: 16)
        let actionText = try reader.string("action", maxLength: 32)
        guard let action = AgentCommandType(rawValue: actionText) else {
            throw ValidationError.unsupported("action \(actionText)")
        }
        let target: Target
        switch targetText {
        case "input":
            target = .input(
                requestID: try reader.id("request_id"),
                requestHash: try reader.string("request_hash", maxLength: 80),
                expectedStateVersion: try reader.integer("expected_state_version"),
                policyVersion: try reader.integer("policy_version")
            )
        case "session":
            target = .session(
                agentSessionID: try reader.id("agent_session_id"),
                expectedSessionVersion: try reader.integer("expected_session_version"),
                actionDigest: try reader.digest("action_digest")
            )
        default:
            throw ValidationError.unsupported("agent challenge target \(targetText)")
        }
        try reader.rejectUnknownMembers()
        try self.init(action: action, target: target)
    }
}

/// A one-use, device-bound agent challenge. It never outlives the request.
public struct AgentReviewChallenge: Sendable, Hashable {
    public let challengeID: String
    public let deviceID: ControlID
    public let action: AgentCommandType
    public let expiresAt: ControlTimestamp

    public init(challengeID: String, deviceID: ControlID, action: AgentCommandType, expiresAt: ControlTimestamp) {
        self.challengeID = challengeID
        self.deviceID = deviceID
        self.action = action
        self.expiresAt = expiresAt
    }

    public var json: JSONValue {
        .object([
            "challenge_id": .string(challengeID),
            "device_id": JSONValue(deviceID),
            "action": .string(action.rawValue),
            "expires_at": JSONValue(expiresAt)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        challengeID = try reader.string("challenge_id", maxLength: 128)
        deviceID = try reader.id("device_id")
        let actionText = try reader.string("action", maxLength: 32)
        guard let action = AgentCommandType(rawValue: actionText) else { throw ValidationError.unsupported("action \(actionText)") }
        self.action = action
        expiresAt = try reader.timestamp("expires_at")
        try reader.rejectUnknownMembers(allowing: ["server_time"])
    }
}

/// The recorded outcome of an agent command. `recorded` means the broker
/// committed the response, never that the agent accepted it.
public struct AgentCommandResult: Sendable, Hashable {
    public let recorded: Bool
    public let commandID: ControlID
    public let requestID: ControlID?
    public let responseID: ControlID?
    public let stateVersion: Int64?
    public let resolution: InputResolution?
    public let dispatch: AgentDispatch?
    public let serverTime: ControlTimestamp

    public init(
        recorded: Bool,
        commandID: ControlID,
        requestID: ControlID? = nil,
        responseID: ControlID? = nil,
        stateVersion: Int64? = nil,
        resolution: InputResolution? = nil,
        dispatch: AgentDispatch? = nil,
        serverTime: ControlTimestamp
    ) {
        self.recorded = recorded
        self.commandID = commandID
        self.requestID = requestID
        self.responseID = responseID
        self.stateVersion = stateVersion
        self.resolution = resolution
        self.dispatch = dispatch
        self.serverTime = serverTime
    }

    public var json: JSONValue {
        JSONWriter.object([
            "recorded": .bool(recorded),
            "command_id": JSONValue(commandID),
            "request_id": requestID.map { JSONValue($0) },
            "response_id": responseID.map { JSONValue($0) },
            "state_version": stateVersion.map { .number(.int($0)) },
            "resolution": resolution.map { .string($0.rawValue) },
            "dispatch": dispatch.map { .string($0.rawValue) },
            "server_time": JSONValue(serverTime)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        recorded = try reader.bool("recorded")
        commandID = try reader.id("command_id")
        requestID = try reader.optionalID("request_id")
        responseID = try reader.optionalID("response_id")
        stateVersion = try reader.optionalInteger("state_version")
        if let text = try reader.optionalString("resolution", maxLength: 16) {
            guard let value = InputResolution(rawValue: text) else { throw ValidationError.unsupported("resolution \(text)") }
            resolution = value
        } else {
            resolution = nil
        }
        if let text = try reader.optionalString("dispatch", maxLength: 32) {
            guard let value = AgentDispatch(rawValue: text) else { throw ValidationError.unsupported("dispatch \(text)") }
            dispatch = value
        } else {
            dispatch = nil
        }
        serverTime = try reader.timestamp("server_time")
        try reader.rejectUnknownMembers(allowing: ["current_projection"])
    }
}
