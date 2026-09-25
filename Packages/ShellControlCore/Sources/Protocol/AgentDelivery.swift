import Foundation

/// `POST /v1/agent/inputs/{id}/consume`: the origin's one-time claim on the
/// winning response, for the exact live native wait. The origin comes from
/// authentication, never from the body (docs/specs/agent-relay.md 14.3).
public struct InputConsumeRequest: Sendable, Hashable {
    public let mutationID: ControlID
    public let runID: ControlID
    public let nativeWaitID: ControlID
    public let requestHash: String
    public let commandID: ControlID
    public let responseHash: String

    public init(mutationID: ControlID, runID: ControlID, nativeWaitID: ControlID, requestHash: String, commandID: ControlID, responseHash: String) {
        self.mutationID = mutationID
        self.runID = runID
        self.nativeWaitID = nativeWaitID
        self.requestHash = requestHash
        self.commandID = commandID
        self.responseHash = responseHash
    }

    public var json: JSONValue {
        .object([
            "mutation_id": JSONValue(mutationID),
            "run_id": JSONValue(runID),
            "native_wait_id": JSONValue(nativeWaitID),
            "request_hash": .string(requestHash),
            "command_id": JSONValue(commandID),
            "response_hash": .string(responseHash)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        mutationID = try reader.id("mutation_id")
        runID = try reader.id("run_id")
        nativeWaitID = try reader.id("native_wait_id")
        requestHash = try reader.digest("request_hash")
        commandID = try reader.id("command_id")
        responseHash = try reader.digest("response_hash")
        try reader.rejectUnknownMembers()
    }
}

/// The one-time grant to write one response to one native wait. Repeating the
/// same consume returns this same permit and deadline; it is never renewed
/// (docs/specs/agent-relay.md 14.3).
public struct InputConsumePermit: Sendable, Hashable {
    public let permitID: ControlID
    public let mutationID: ControlID
    public let originID: ControlID
    public let runID: ControlID
    public let nativeWaitID: ControlID
    public let requestID: ControlID
    public let requestHash: String
    public let commandID: ControlID
    public let responseHash: String
    public let response: InputResponse
    /// The device's signed command, so the host checks the authority it acts
    /// on rather than trusting the broker's summary.
    public let commandJWS: String
    public let issuedAt: ControlTimestamp
    public let applyBefore: ControlTimestamp

    public init(
        permitID: ControlID,
        mutationID: ControlID,
        originID: ControlID,
        runID: ControlID,
        nativeWaitID: ControlID,
        requestID: ControlID,
        requestHash: String,
        commandID: ControlID,
        responseHash: String,
        response: InputResponse,
        commandJWS: String,
        issuedAt: ControlTimestamp,
        applyBefore: ControlTimestamp
    ) {
        self.permitID = permitID
        self.mutationID = mutationID
        self.originID = originID
        self.runID = runID
        self.nativeWaitID = nativeWaitID
        self.requestID = requestID
        self.requestHash = requestHash
        self.commandID = commandID
        self.responseHash = responseHash
        self.response = response
        self.commandJWS = commandJWS
        self.issuedAt = issuedAt
        self.applyBefore = applyBefore
    }

    public var json: JSONValue {
        .object([
            "permit_id": JSONValue(permitID),
            "mutation_id": JSONValue(mutationID),
            "origin_id": JSONValue(originID),
            "run_id": JSONValue(runID),
            "native_wait_id": JSONValue(nativeWaitID),
            "request_id": JSONValue(requestID),
            "request_hash": .string(requestHash),
            "command_id": JSONValue(commandID),
            "response_hash": .string(responseHash),
            "response": response.json,
            "command_jws": .string(commandJWS),
            "issued_at": JSONValue(issuedAt),
            "apply_before": JSONValue(applyBefore)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        permitID = try reader.id("permit_id")
        mutationID = try reader.id("mutation_id")
        originID = try reader.id("origin_id")
        runID = try reader.id("run_id")
        nativeWaitID = try reader.id("native_wait_id")
        requestID = try reader.id("request_id")
        requestHash = try reader.digest("request_hash")
        commandID = try reader.id("command_id")
        responseHash = try reader.digest("response_hash")
        response = try InputResponse(json: try reader.value("response"))
        commandJWS = try reader.string("command_jws", maxLength: 16384)
        issuedAt = try reader.timestamp("issued_at")
        applyBefore = try reader.timestamp("apply_before")
        try reader.rejectUnknownMembers(allowing: ["server_time"])
    }

    /// Fails closed under clock uncertainty, like the approval permit.
    public func isApplicable(at now: ControlTimestamp, clockUncertainty: TimeInterval = 2) -> Bool {
        now.date.addingTimeInterval(clockUncertainty) < applyBefore.date
    }

    /// Every binding the host must compare before writing to the provider
    /// (docs/specs/agent-relay.md 14.3). The response must also hash to what was
    /// claimed, and the signed command must carry exactly this response.
    public func validate(
        request: InputConsumeRequest,
        originID expectedOrigin: ControlID,
        requestID expectedRequest: ControlID
    ) throws {
        guard originID == expectedOrigin, runID == request.runID, nativeWaitID == request.nativeWaitID,
              requestID == expectedRequest, commandID == request.commandID,
              ContentDigest.matches(requestHash, request.requestHash),
              ContentDigest.matches(responseHash, request.responseHash),
              ContentDigest.matches(response.responseHash, responseHash)
        else {
            throw ValidationError.invalid("permit", "does not match the claimed wait, request, and response")
        }
        let payload = try SignedPayloadReader.payload(ofCompactJWS: commandJWS)
        let command = try InputRespondCommand(json: payload)
        guard command.envelope.commandID == commandID, command.requestID == requestID,
              ContentDigest.matches(command.requestHash, requestHash), command.response == response
        else {
            throw ValidationError.invalid("permit", "signed command does not carry this response")
        }
    }
}

/// Reads a compact JWS payload without verifying it. The broker verified the
/// signature; the host uses this only to compare bindings.
public enum SignedPayloadReader {
    public static func payload(ofCompactJWS jws: String) throws -> JSONValue {
        let segments = jws.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, let bytes = base64URLDecode(String(segments[1])) else {
            throw ValidationError.invalid("jws", "is not a compact serialization")
        }
        return try JSONValue.parse(bytes)
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}

/// What kind of request a delivery receipt reports on.
public enum AgentRequestKind: String, Sendable, Hashable {
    case approval
    case input
    /// A managed-session command: `request_id` is its command ID,
    /// `request_hash` its action digest, and `native_wait_id` the connection
    /// epoch it was written to.
    case sessionCommand = "session_command"
}

/// Correlated, idempotent `agent.delivery.v1` evidence. It never changes the
/// meaning of a legacy receipt field; the broker derives the conservative
/// legacy result from it (docs/specs/agent-relay.md 8.2).
public struct AgentDeliveryReceipt: Sendable, Hashable {
    public let receiptID: ControlID
    public let requestKind: AgentRequestKind
    public let requestID: ControlID
    public let requestHash: String
    public let runID: ControlID
    public let nativeWaitID: ControlID
    /// Approval: the recorded decision and, for an approval, its claim.
    public let decisionID: ControlID?
    public let consumeID: ControlID?
    /// Input: the winning command and its permit.
    public let commandID: ControlID?
    public let permitID: ControlID?
    public let dispatch: AgentDispatch
    /// A short machine code for the evidence behind `dispatch`.
    public let evidence: String
    /// True when the adapter itself produced the native answer (deadline,
    /// unavailability): a system outcome, never a user rejection.
    public let systemOutcome: Bool
    public let operation: AgentOperationState?
    public let occurredAt: ControlTimestamp

    public init(
        receiptID: ControlID = .random(),
        requestKind: AgentRequestKind,
        requestID: ControlID,
        requestHash: String,
        runID: ControlID,
        nativeWaitID: ControlID,
        decisionID: ControlID? = nil,
        consumeID: ControlID? = nil,
        commandID: ControlID? = nil,
        permitID: ControlID? = nil,
        dispatch: AgentDispatch,
        evidence: String,
        systemOutcome: Bool = false,
        operation: AgentOperationState? = nil,
        occurredAt: ControlTimestamp
    ) throws {
        switch dispatch {
        case .none, .awaitingOrigin, .claimed:
            throw ValidationError.invalid("dispatch", "a receipt reports dispatch_started or later")
        default: break
        }
        try AgentIdentifier.require(evidence, field: "evidence")
        self.receiptID = receiptID
        self.requestKind = requestKind
        self.requestID = requestID
        self.requestHash = requestHash
        self.runID = runID
        self.nativeWaitID = nativeWaitID
        self.decisionID = decisionID
        self.consumeID = consumeID
        self.commandID = commandID
        self.permitID = permitID
        self.dispatch = dispatch
        self.evidence = evidence
        self.systemOutcome = systemOutcome
        self.operation = operation
        self.occurredAt = occurredAt
    }

    public var json: JSONValue {
        JSONWriter.object([
            "receipt_id": JSONValue(receiptID),
            "request_kind": .string(requestKind.rawValue),
            "request_id": JSONValue(requestID),
            "request_hash": .string(requestHash),
            "run_id": JSONValue(runID),
            "native_wait_id": JSONValue(nativeWaitID),
            "decision_id": decisionID.map { JSONValue($0) },
            "consume_id": consumeID.map { JSONValue($0) },
            "command_id": commandID.map { JSONValue($0) },
            "permit_id": permitID.map { JSONValue($0) },
            "dispatch": .string(dispatch.rawValue),
            "evidence": .string(evidence),
            "system_outcome": .bool(systemOutcome),
            "operation": operation.map { .string($0.rawValue) },
            "occurred_at": JSONValue(occurredAt)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let receiptID = try reader.id("receipt_id")
        let kindText = try reader.string("request_kind", maxLength: 16)
        guard let kind = AgentRequestKind(rawValue: kindText) else { throw ValidationError.unsupported("request kind \(kindText)") }
        let requestID = try reader.id("request_id")
        let requestHash = try reader.digest("request_hash")
        let runID = try reader.id("run_id")
        let waitID = try reader.id("native_wait_id")
        let decisionID = try reader.optionalID("decision_id")
        let consumeID = try reader.optionalID("consume_id")
        let commandID = try reader.optionalID("command_id")
        let permitID = try reader.optionalID("permit_id")
        let dispatchText = try reader.string("dispatch", maxLength: 32)
        guard let dispatch = AgentDispatch(rawValue: dispatchText) else { throw ValidationError.unsupported("dispatch \(dispatchText)") }
        let evidence = try reader.string("evidence", maxLength: 64)
        let systemOutcome = try reader.optionalBool("system_outcome") ?? false
        let operation = try reader.optionalString("operation", maxLength: 32).map { text -> AgentOperationState in
            guard let state = AgentOperationState(rawValue: text) else { throw ValidationError.unsupported("operation \(text)") }
            return state
        }
        let occurredAt = try reader.timestamp("occurred_at")
        try reader.rejectUnknownMembers()
        try self.init(
            receiptID: receiptID, requestKind: kind, requestID: requestID, requestHash: requestHash,
            runID: runID, nativeWaitID: waitID, decisionID: decisionID, consumeID: consumeID,
            commandID: commandID, permitID: permitID, dispatch: dispatch, evidence: evidence,
            systemOutcome: systemOutcome, operation: operation, occurredAt: occurredAt
        )
    }
}
