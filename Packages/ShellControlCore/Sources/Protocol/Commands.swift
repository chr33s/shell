import Foundation

/// The control commands a device may sign.
///
/// `approval.decide` is mandatory; `notification.ack` is not an approval, and
/// `job.cancel` is capability-gated (spec.watch.md section 13).
public enum ControlCommandType: String, Sendable, Hashable, CaseIterable {
    case approvalDecide = "approval.decide"
    case notificationAck = "notification.ack"
    case jobCancel = "job.cancel"
    case handoffRequest = "handoff.request"

    /// A handoff hint authorizes nothing and is never accepted by an execution
    /// adapter (spec.watch.md section 13).
    public var isAuthorizing: Bool { self != .handoffRequest }

    /// Only decisions bind a request digest and therefore need a challenge.
    public var requiresReviewChallenge: Bool {
        self == .approvalDecide || self == .jobCancel
    }
}

/// Fields every signed command carries.
public struct ControlCommandEnvelope: Sendable, Hashable {
    public let version: Int
    public let type: ControlCommandType
    public let commandID: ControlID
    public let deviceID: ControlID
    /// `shell-control:<account_id>`; a command signed for one broker/account is
    /// not replayable at another.
    public let audience: String
    public let issuedAt: ControlTimestamp
    public let notAfter: ControlTimestamp

    public init(
        version: Int = 1,
        type: ControlCommandType,
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
}

/// A signed control command payload. The signed payload is authoritative; the
/// broker never accepts a second unsigned copy of these fields
/// (spec.watch.md section 11).
public enum ControlCommand: Sendable, Hashable {
    case approvalDecide(ApprovalDecideCommand)
    case notificationAck(NotificationAckCommand)
    case jobCancel(JobCancelCommand)
    case handoffRequest(HandoffRequestCommand)

    public var envelope: ControlCommandEnvelope {
        switch self {
        case .approvalDecide(let command): return command.envelope
        case .notificationAck(let command): return command.envelope
        case .jobCancel(let command): return command.envelope
        case .handoffRequest(let command): return command.envelope
        }
    }

    public var json: JSONValue {
        switch self {
        case .approvalDecide(let command): return command.json
        case .notificationAck(let command): return command.json
        case .jobCancel(let command): return command.json
        case .handoffRequest(let command): return command.json
        }
    }

    /// Fails closed on an unknown command type (spec.watch.md section 8).
    public static func decode(_ value: JSONValue) throws -> ControlCommand {
        var reader = try JSONReader(value)
        let typeText = try reader.string("type", maxLength: 64)
        guard let type = ControlCommandType(rawValue: typeText) else {
            throw ValidationError.unsupported("command type \(typeText)")
        }
        switch type {
        case .approvalDecide: return .approvalDecide(try ApprovalDecideCommand(json: value))
        case .notificationAck: return .notificationAck(try NotificationAckCommand(json: value))
        case .jobCancel: return .jobCancel(try JobCancelCommand(json: value))
        case .handoffRequest: return .handoffRequest(try HandoffRequestCommand(json: value))
        }
    }
}

private func decodeEnvelope(_ reader: inout JSONReader, expecting type: ControlCommandType) throws -> ControlCommandEnvelope {
    let version = try Int(reader.integer("v"))
    let typeText = try reader.string("type", maxLength: 64)
    guard typeText == type.rawValue else { throw ValidationError.unsupported("command type \(typeText)") }
    return try ControlCommandEnvelope(
        version: version,
        type: type,
        commandID: try reader.id("command_id"),
        deviceID: try reader.id("device_id"),
        audience: try reader.string("aud", maxLength: 128),
        issuedAt: try reader.timestamp("issued_at"),
        notAfter: try reader.timestamp("not_after")
    )
}

private func envelopeMembers(_ envelope: ControlCommandEnvelope) -> [String: JSONValue] {
    [
        "v": .number(.int(Int64(envelope.version))),
        "type": .string(envelope.type.rawValue),
        "command_id": JSONValue(envelope.commandID),
        "device_id": JSONValue(envelope.deviceID),
        "aud": .string(envelope.audience),
        "issued_at": JSONValue(envelope.issuedAt),
        "not_after": JSONValue(envelope.notAfter),
    ]
}

/// Commits to the exact spec digest and the observed projection versions
/// (spec.watch.md section 9).
public struct ApprovalDecideCommand: Sendable, Hashable {
    public let envelope: ControlCommandEnvelope
    public let requestID: ControlID
    public let requestHash: String
    public let expectedStateVersion: Int64
    public let policyVersion: Int64
    public let decision: ControlDecision
    public let challengeID: String

    public init(
        envelope: ControlCommandEnvelope,
        requestID: ControlID,
        requestHash: String,
        expectedStateVersion: Int64,
        policyVersion: Int64,
        decision: ControlDecision,
        challengeID: String
    ) throws {
        guard envelope.type == .approvalDecide else { throw ValidationError.unsupported("command type") }
        guard requestHash.hasPrefix(ContentDigest.prefix),
              ExecOperation.isSHA256Hex(String(requestHash.dropFirst(ContentDigest.prefix.count)))
        else {
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
        self.decision = decision
        self.challengeID = challengeID
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let envelope = try decodeEnvelope(&reader, expecting: .approvalDecide)
        let requestID = try reader.id("request_id")
        let requestHash = try reader.string("request_hash", maxLength: 80)
        let expectedStateVersion = try reader.integer("expected_state_version")
        let policyVersion = try reader.integer("policy_version")
        let decisionText = try reader.string("decision", maxLength: 16)
        guard let decision = ControlDecision(rawValue: decisionText) else {
            throw ValidationError.unsupported("decision \(decisionText)")
        }
        let challengeID = try reader.string("challenge_id", maxLength: 128)
        try reader.rejectUnknownMembers()
        try self.init(
            envelope: envelope,
            requestID: requestID,
            requestHash: requestHash,
            expectedStateVersion: expectedStateVersion,
            policyVersion: policyVersion,
            decision: decision,
            challengeID: challengeID
        )
    }

    public var json: JSONValue {
        var members = envelopeMembers(envelope)
        members["request_id"] = JSONValue(requestID)
        members["request_hash"] = .string(requestHash)
        members["expected_state_version"] = .number(.int(expectedStateVersion))
        members["policy_version"] = .number(.int(policyVersion))
        members["decision"] = .string(decision.rawValue)
        members["challenge_id"] = .string(challengeID)
        return .object(members)
    }
}

/// Marks one informational notification acknowledged. Acknowledging is not
/// approving (spec.watch.md section 6).
public struct NotificationAckCommand: Sendable, Hashable {
    public let envelope: ControlCommandEnvelope
    public let notificationID: ControlID

    public init(envelope: ControlCommandEnvelope, notificationID: ControlID) throws {
        guard envelope.type == .notificationAck else { throw ValidationError.unsupported("command type") }
        self.envelope = envelope
        self.notificationID = notificationID
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let envelope = try decodeEnvelope(&reader, expecting: .notificationAck)
        let notificationID = try reader.id("notification_id")
        try reader.rejectUnknownMembers()
        try self.init(envelope: envelope, notificationID: notificationID)
    }

    public var json: JSONValue {
        var members = envelopeMembers(envelope)
        members["notification_id"] = JSONValue(notificationID)
        return .object(members)
    }
}

public enum JobCancelMode: String, Sendable, Hashable {
    /// V1 exposes no signals, kill-by-PID, keystrokes, pause/resume, or restart.
    case cooperative
}

public struct JobCancelCommand: Sendable, Hashable {
    public let envelope: ControlCommandEnvelope
    public let jobID: ControlID
    public let runID: ControlID
    public let expectedJobVersion: Int64
    public let mode: JobCancelMode
    public let challengeID: String

    public init(
        envelope: ControlCommandEnvelope,
        jobID: ControlID,
        runID: ControlID,
        expectedJobVersion: Int64,
        mode: JobCancelMode = .cooperative,
        challengeID: String
    ) throws {
        guard envelope.type == .jobCancel else { throw ValidationError.unsupported("command type") }
        guard !challengeID.isEmpty, challengeID.count <= 128 else {
            throw ValidationError.invalid("challenge_id", "must be 1...128 characters")
        }
        self.envelope = envelope
        self.jobID = jobID
        self.runID = runID
        self.expectedJobVersion = expectedJobVersion
        self.mode = mode
        self.challengeID = challengeID
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let envelope = try decodeEnvelope(&reader, expecting: .jobCancel)
        let jobID = try reader.id("job_id")
        let runID = try reader.id("run_id")
        let expectedJobVersion = try reader.integer("expected_job_version")
        let modeText = try reader.string("mode", maxLength: 16)
        guard let mode = JobCancelMode(rawValue: modeText) else {
            throw ValidationError.unsupported("cancel mode \(modeText)")
        }
        let challengeID = try reader.string("challenge_id", maxLength: 128)
        try reader.rejectUnknownMembers()
        try self.init(
            envelope: envelope,
            jobID: jobID,
            runID: runID,
            expectedJobVersion: expectedJobVersion,
            mode: mode,
            challengeID: challengeID
        )
    }

    public var json: JSONValue {
        var members = envelopeMembers(envelope)
        members["job_id"] = JSONValue(jobID)
        members["run_id"] = JSONValue(runID)
        members["expected_job_version"] = .number(.int(expectedJobVersion))
        members["mode"] = .string(mode.rawValue)
        members["challenge_id"] = .string(challengeID)
        return .object(members)
    }
}

/// A non-authorizing UI hint (spec.watch.md section 13).
public struct HandoffRequestCommand: Sendable, Hashable {
    public let envelope: ControlCommandEnvelope
    public let requestID: ControlID?
    public let jobID: ControlID?

    public init(envelope: ControlCommandEnvelope, requestID: ControlID?, jobID: ControlID?) throws {
        guard envelope.type == .handoffRequest else { throw ValidationError.unsupported("command type") }
        guard requestID != nil || jobID != nil else {
            throw ValidationError.invalid("handoff.request", "needs a request_id or job_id")
        }
        self.envelope = envelope
        self.requestID = requestID
        self.jobID = jobID
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let envelope = try decodeEnvelope(&reader, expecting: .handoffRequest)
        let requestID = try reader.optionalID("request_id")
        let jobID = try reader.optionalID("job_id")
        try reader.rejectUnknownMembers()
        try self.init(envelope: envelope, requestID: requestID, jobID: jobID)
    }

    public var json: JSONValue {
        var members = envelopeMembers(envelope)
        if let requestID { members["request_id"] = JSONValue(requestID) }
        if let jobID { members["job_id"] = JSONValue(jobID) }
        return .object(members)
    }
}
