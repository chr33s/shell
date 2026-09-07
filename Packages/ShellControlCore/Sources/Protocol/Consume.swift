import Foundation

/// An origin's claim on one recorded approval, for the exact still-waiting
/// operation (spec.watch.md section 12).
public struct ConsumeRequest: Sendable, Hashable {
    public let consumeID: ControlID
    public let decisionID: ControlID
    public let requestHash: String
    public let runID: ControlID

    public init(consumeID: ControlID, decisionID: ControlID, requestHash: String, runID: ControlID) {
        self.consumeID = consumeID
        self.decisionID = decisionID
        self.requestHash = requestHash
        self.runID = runID
    }

    public var json: JSONValue {
        .object([
            "consume_id": JSONValue(consumeID),
            "decision_id": JSONValue(decisionID),
            "request_hash": .string(requestHash),
            "run_id": JSONValue(runID),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        consumeID = try reader.id("consume_id")
        decisionID = try reader.id("decision_id")
        requestHash = try reader.string("request_hash", maxLength: 80)
        runID = try reader.id("run_id")
        try reader.rejectUnknownMembers()
    }
}

/// The one-use grant. It can never be renewed silently, and failing to apply
/// before `applyBefore` means no authorization to run
/// (spec.watch.md section 12).
public struct ConsumePermit: Sendable, Hashable {
    public let consumeID: ControlID
    public let decisionID: ControlID
    public let originID: ControlID
    public let runID: ControlID
    public let requestHash: String
    public let applyBefore: ControlTimestamp
    public let decision: ControlDecision
    /// The original device decision JWS, so the host can verify the authority
    /// it is acting on rather than trusting the broker's summary.
    public let decisionJWS: String

    public init(
        consumeID: ControlID,
        decisionID: ControlID,
        originID: ControlID,
        runID: ControlID,
        requestHash: String,
        applyBefore: ControlTimestamp,
        decision: ControlDecision,
        decisionJWS: String
    ) {
        self.consumeID = consumeID
        self.decisionID = decisionID
        self.originID = originID
        self.runID = runID
        self.requestHash = requestHash
        self.applyBefore = applyBefore
        self.decision = decision
        self.decisionJWS = decisionJWS
    }

    public var json: JSONValue {
        .object([
            "consume_id": JSONValue(consumeID),
            "decision_id": JSONValue(decisionID),
            "origin_id": JSONValue(originID),
            "run_id": JSONValue(runID),
            "request_hash": .string(requestHash),
            "apply_before": JSONValue(applyBefore),
            "decision": .string(decision.rawValue),
            "decision_jws": .string(decisionJWS),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        consumeID = try reader.id("consume_id")
        decisionID = try reader.id("decision_id")
        originID = try reader.id("origin_id")
        runID = try reader.id("run_id")
        requestHash = try reader.string("request_hash", maxLength: 80)
        applyBefore = try reader.timestamp("apply_before")
        let decisionText = try reader.string("decision", maxLength: 16)
        guard let decision = ControlDecision(rawValue: decisionText) else {
            throw ValidationError.unsupported("decision \(decisionText)")
        }
        self.decision = decision
        decisionJWS = try reader.string("decision_jws", maxLength: 8192)
        try reader.rejectUnknownMembers(allowing: ["server_time"])
    }

    /// A conservative deadline check: uncertain time validity fails closed
    /// (spec.watch.md section 12).
    public func isApplicable(at now: ControlTimestamp, clockUncertainty: TimeInterval = 2) -> Bool {
        now.date.addingTimeInterval(clockUncertainty) < applyBefore.date
    }
}

/// What an origin reports after touching the permission gate.
public enum ReceiptResult: String, Sendable, Hashable, CaseIterable {
    case applied
    case notApplied = "not_applied"
    /// The host cannot safely determine whether dispatch happened; never
    /// blindly rerun (spec.watch.md section 12).
    case unknown
}

public struct Receipt: Sendable, Hashable {
    public let receiptID: ControlID
    public let decisionID: ControlID?
    /// A rejection receipt carries no consume ID, because rejection grants no
    /// execution permission (spec.watch.md section 12).
    public let consumeID: ControlID?
    public let commandID: ControlID?
    public let requestHash: String?
    public let jobID: ControlID?
    public let runID: ControlID
    public let result: ReceiptResult
    public let reasonCode: String
    public let occurredAt: ControlTimestamp
    public let jobState: String?

    public init(
        receiptID: ControlID,
        decisionID: ControlID? = nil,
        consumeID: ControlID? = nil,
        commandID: ControlID? = nil,
        requestHash: String? = nil,
        jobID: ControlID? = nil,
        runID: ControlID,
        result: ReceiptResult,
        reasonCode: String,
        occurredAt: ControlTimestamp,
        jobState: String? = nil
    ) {
        self.receiptID = receiptID
        self.decisionID = decisionID
        self.consumeID = consumeID
        self.commandID = commandID
        self.requestHash = requestHash
        self.jobID = jobID
        self.runID = runID
        self.result = result
        self.reasonCode = reasonCode
        self.occurredAt = occurredAt
        self.jobState = jobState
    }

    public var json: JSONValue {
        JSONWriter.object([
            "receipt_id": JSONValue(receiptID),
            "decision_id": decisionID.map { JSONValue($0) },
            "consume_id": consumeID.map { JSONValue($0) },
            "command_id": commandID.map { JSONValue($0) },
            "request_hash": requestHash.map { .string($0) },
            "job_id": jobID.map { JSONValue($0) },
            "run_id": JSONValue(runID),
            "result": .string(result.rawValue),
            "reason_code": .string(reasonCode),
            "occurred_at": JSONValue(occurredAt),
            "job_state": jobState.map { .string($0) },
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        receiptID = try reader.id("receipt_id")
        decisionID = try reader.optionalID("decision_id")
        consumeID = try reader.optionalID("consume_id")
        commandID = try reader.optionalID("command_id")
        requestHash = try reader.optionalString("request_hash", maxLength: 80)
        jobID = try reader.optionalID("job_id")
        runID = try reader.id("run_id")
        let resultText = try reader.string("result", maxLength: 24)
        guard let result = ReceiptResult(rawValue: resultText) else {
            throw ValidationError.unsupported("receipt result \(resultText)")
        }
        self.result = result
        reasonCode = try reader.string("reason_code", maxLength: 64)
        occurredAt = try reader.timestamp("occurred_at")
        jobState = try reader.optionalString("job_state", maxLength: 32)
        try reader.rejectUnknownMembers()
    }
}
