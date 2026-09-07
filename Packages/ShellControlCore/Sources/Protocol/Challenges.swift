import Foundation

/// What the device says it is about to decide.
public struct ReviewChallengeRequest: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        case approval(requestID: ControlID, requestHash: String, expectedStateVersion: Int64, policyVersion: Int64)
        case job(jobID: ControlID, runID: ControlID, expectedJobVersion: Int64)
    }

    public let target: Target
    public let action: ControlCommandType

    public init(target: Target, action: ControlCommandType) throws {
        guard action.requiresReviewChallenge else {
            throw ValidationError.invalid("action", "does not use a review challenge")
        }
        self.target = target
        self.action = action
    }

    public var json: JSONValue {
        switch target {
        case .approval(let requestID, let requestHash, let stateVersion, let policyVersion):
            return .object([
                "target": "approval",
                "action": .string(action.rawValue),
                "request_id": JSONValue(requestID),
                "request_hash": .string(requestHash),
                "expected_state_version": .number(.int(stateVersion)),
                "policy_version": .number(.int(policyVersion)),
            ])
        case .job(let jobID, let runID, let jobVersion):
            return .object([
                "target": "job",
                "action": .string(action.rawValue),
                "job_id": JSONValue(jobID),
                "run_id": JSONValue(runID),
                "expected_job_version": .number(.int(jobVersion)),
            ])
        }
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let target = try reader.string("target", maxLength: 16)
        let actionText = try reader.string("action", maxLength: 32)
        guard let action = ControlCommandType(rawValue: actionText) else {
            throw ValidationError.unsupported("action \(actionText)")
        }
        switch target {
        case "approval":
            let requestID = try reader.id("request_id")
            let requestHash = try reader.string("request_hash", maxLength: 80)
            let stateVersion = try reader.integer("expected_state_version")
            let policyVersion = try reader.integer("policy_version")
            try reader.rejectUnknownMembers()
            try self.init(
                target: .approval(
                    requestID: requestID,
                    requestHash: requestHash,
                    expectedStateVersion: stateVersion,
                    policyVersion: policyVersion
                ),
                action: action
            )
        case "job":
            let jobID = try reader.id("job_id")
            let runID = try reader.id("run_id")
            let jobVersion = try reader.integer("expected_job_version")
            try reader.rejectUnknownMembers()
            try self.init(target: .job(jobID: jobID, runID: runID, expectedJobVersion: jobVersion), action: action)
        default:
            throw ValidationError.unsupported("challenge target \(target)")
        }
    }
}

/// A one-use, device-bound challenge. TTL is at most 60 seconds and never
/// exceeds the approval deadline (spec.watch.md section 11).
public struct ReviewChallenge: Sendable, Hashable {
    public let challengeID: String
    public let deviceID: ControlID
    public let action: ControlCommandType
    public let expiresAt: ControlTimestamp

    public init(challengeID: String, deviceID: ControlID, action: ControlCommandType, expiresAt: ControlTimestamp) {
        self.challengeID = challengeID
        self.deviceID = deviceID
        self.action = action
        self.expiresAt = expiresAt
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        challengeID = try reader.string("challenge_id", maxLength: 128)
        deviceID = try reader.id("device_id")
        let actionText = try reader.string("action", maxLength: 32)
        guard let action = ControlCommandType(rawValue: actionText) else {
            throw ValidationError.unsupported("action \(actionText)")
        }
        self.action = action
        expiresAt = try reader.timestamp("expires_at")
        try reader.rejectUnknownMembers(allowing: ["server_time"])
    }

    public var json: JSONValue {
        .object([
            "challenge_id": .string(challengeID),
            "device_id": JSONValue(deviceID),
            "action": .string(action.rawValue),
            "expires_at": JSONValue(expiresAt),
        ])
    }
}

/// The recorded outcome of a submitted command. `recorded` is about durable
/// commit at the broker, never about the originating program resuming
/// (spec.watch.md section 11).
public struct CommandResult: Sendable, Hashable {
    public let recorded: Bool
    public let commandID: ControlID
    public let decisionID: ControlID?
    public let requestID: ControlID?
    public let stateVersion: Int64?
    public let resolution: Resolution?
    public let dispatch: Dispatch?
    public let serverTime: ControlTimestamp

    public init(
        recorded: Bool,
        commandID: ControlID,
        decisionID: ControlID? = nil,
        requestID: ControlID? = nil,
        stateVersion: Int64? = nil,
        resolution: Resolution? = nil,
        dispatch: Dispatch? = nil,
        serverTime: ControlTimestamp
    ) {
        self.recorded = recorded
        self.commandID = commandID
        self.decisionID = decisionID
        self.requestID = requestID
        self.stateVersion = stateVersion
        self.resolution = resolution
        self.dispatch = dispatch
        self.serverTime = serverTime
    }

    public var json: JSONValue {
        JSONWriter.object([
            "recorded": .bool(recorded),
            "command_id": JSONValue(commandID),
            "decision_id": decisionID.map { JSONValue($0) },
            "request_id": requestID.map { JSONValue($0) },
            "state_version": stateVersion.map { .number(.int($0)) },
            "resolution": resolution.map { .string($0.rawValue) },
            "dispatch": dispatch.map { .string($0.rawValue) },
            "server_time": JSONValue(serverTime),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        recorded = try reader.bool("recorded")
        commandID = try reader.id("command_id")
        decisionID = try reader.optionalID("decision_id")
        requestID = try reader.optionalID("request_id")
        stateVersion = try reader.optionalInteger("state_version")
        if let text = try reader.optionalString("resolution", maxLength: 16) {
            guard let value = Resolution(rawValue: text) else { throw ValidationError.unsupported("resolution \(text)") }
            resolution = value
        } else {
            resolution = nil
        }
        if let text = try reader.optionalString("dispatch", maxLength: 24) {
            guard let value = Dispatch(rawValue: text) else { throw ValidationError.unsupported("dispatch \(text)") }
            dispatch = value
        } else {
            dispatch = nil
        }
        serverTime = try reader.timestamp("server_time")
        // A current projection may accompany the recorded result; it is
        // labelled separately and never overwrites the recorded decision.
        try reader.rejectUnknownMembers(allowing: ["current_projection", "job_state"])
    }
}
