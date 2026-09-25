import Foundation

/// The normalized agent event vocabulary (spec.agent-relay.md section 12.1).
/// An unknown type from a newer peer is carried and ignored, never guessed.
public enum AgentEventType: Sendable, Hashable {
    case sessionStarted
    case sessionEnded
    case statusChanged
    case approvalCreated
    case inputCreated
    case requestResolved
    case deliveryUpdated
    /// A managed session's turn began; it is what makes steering possible.
    case turnStarted
    case turnCompleted
    case turnFailed
    case unknown(String)

    public static let known: [AgentEventType] = [
        .sessionStarted, .sessionEnded, .statusChanged, .approvalCreated, .inputCreated,
        .requestResolved, .deliveryUpdated, .turnStarted, .turnCompleted, .turnFailed
    ]

    public init(rawValue: String) {
        self = Self.known.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .sessionStarted: return "agent.session.started"
        case .sessionEnded: return "agent.session.ended"
        case .statusChanged: return "agent.status.changed"
        case .approvalCreated: return "agent.approval.created"
        case .inputCreated: return "agent.input.created"
        case .requestResolved: return "agent.request.resolved"
        case .deliveryUpdated: return "agent.delivery.updated"
        case .turnStarted: return "agent.turn.started"
        case .turnCompleted: return "agent.turn.completed"
        case .turnFailed: return "agent.turn.failed"
        case .unknown(let text): return text
        }
    }

    /// The events an origin may report itself. Request and delivery events
    /// are the broker's own record of authoritative transitions.
    public var isOriginReportable: Bool {
        switch self {
        case .sessionEnded, .statusChanged, .turnStarted, .turnCompleted, .turnFailed: return true
        default: return false
        }
    }
}

/// An informational event from an origin. It carries no executable
/// authority, cannot mutate an immutable request, and its provider time never
/// controls authorization expiry (spec.agent-relay.md 12.1).
public struct AgentEvent: Sendable, Hashable {
    public let eventID: ControlID
    public let type: AgentEventType
    public let originID: ControlID
    public let agentSessionID: ControlID
    public let runID: ControlID?
    public let requestID: ControlID?
    public let providerTurnID: String?
    public let occurredAt: ControlTimestamp
    public let observedAt: ControlTimestamp
    /// Bounded, agent-attributed text; it can never enable an action.
    public let summary: String?

    public init(
        eventID: ControlID = .random(),
        type: AgentEventType,
        originID: ControlID,
        agentSessionID: ControlID,
        runID: ControlID? = nil,
        requestID: ControlID? = nil,
        providerTurnID: String? = nil,
        occurredAt: ControlTimestamp,
        observedAt: ControlTimestamp,
        summary: String? = nil
    ) throws {
        if case .unknown(let text) = type {
            guard !text.isEmpty, text.utf8Count <= 64 else { throw ValidationError.invalid("type", "must be 1...64 bytes") }
        }
        if let summary {
            guard summary.unicodeScalars.count <= AgentPolicy.maximumSummaryScalars else {
                throw ValidationError.invalid("summary", "exceeds \(AgentPolicy.maximumSummaryScalars) characters")
            }
        }
        self.eventID = eventID
        self.type = type
        self.originID = originID
        self.agentSessionID = agentSessionID
        self.runID = runID
        self.requestID = requestID
        self.providerTurnID = providerTurnID
        self.occurredAt = occurredAt
        self.observedAt = observedAt
        self.summary = summary
    }

    public var json: JSONValue {
        JSONWriter.object([
            "event_id": JSONValue(eventID),
            "type": .string(type.rawValue),
            "origin_id": JSONValue(originID),
            "agent_session_id": JSONValue(agentSessionID),
            "run_id": runID.map { JSONValue($0) },
            "request_id": requestID.map { JSONValue($0) },
            "provider_turn_id": providerTurnID.map { .string($0) },
            "occurred_at": JSONValue(occurredAt),
            "observed_at": JSONValue(observedAt),
            "summary": summary.map { .string($0) }
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let eventID = try reader.id("event_id")
        let type = AgentEventType(rawValue: try reader.string("type", maxLength: 64))
        let originID = try reader.id("origin_id")
        let sessionID = try reader.id("agent_session_id")
        let runID = try reader.optionalID("run_id")
        let requestID = try reader.optionalID("request_id")
        let turnID = try reader.optionalString("provider_turn_id", maxLength: 256)
        let occurredAt = try reader.timestamp("occurred_at")
        let observedAt = try reader.timestamp("observed_at")
        let summary = try reader.optionalString("summary", maxLength: AgentPolicy.maximumSummaryScalars)
        try reader.rejectUnknownMembers()
        try self.init(
            eventID: eventID, type: type, originID: originID, agentSessionID: sessionID, runID: runID,
            requestID: requestID, providerTurnID: turnID, occurredAt: occurredAt, observedAt: observedAt,
            summary: summary
        )
    }

    public func bodyHash() throws -> String { try ContentDigest.digest(ofCanonical: json) }
}

/// The agent projection of an agent approval: the approval itself stays in
/// the base feed; this adds session attribution and detailed delivery.
public struct AgentApprovalReference: Sendable, Hashable {
    public let requestID: ControlID
    public let agentSessionID: ControlID
    public var dispatch: AgentDispatch
    public var operation: AgentOperationState
    public var evidence: String?
    public var systemOutcome: Bool
    public var version: Int64

    public init(
        requestID: ControlID,
        agentSessionID: ControlID,
        dispatch: AgentDispatch = .none,
        operation: AgentOperationState = .notObserved,
        evidence: String? = nil,
        systemOutcome: Bool = false,
        version: Int64 = 1
    ) {
        self.requestID = requestID
        self.agentSessionID = agentSessionID
        self.dispatch = dispatch
        self.operation = operation
        self.evidence = evidence
        self.systemOutcome = systemOutcome
        self.version = version
    }

    public var json: JSONValue {
        JSONWriter.object([
            "request_id": JSONValue(requestID),
            "agent_session_id": JSONValue(agentSessionID),
            "dispatch": .string(dispatch.rawValue),
            "operation": .string(operation.rawValue),
            "evidence": evidence.map { .string($0) },
            "system_outcome": .bool(systemOutcome),
            "version": .number(.int(version))
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        requestID = try reader.id("request_id")
        agentSessionID = try reader.id("agent_session_id")
        let dispatchText = try reader.string("dispatch", maxLength: 32)
        guard let dispatch = AgentDispatch(rawValue: dispatchText) else { throw ValidationError.unsupported("dispatch \(dispatchText)") }
        self.dispatch = dispatch
        let operationText = try reader.string("operation", maxLength: 32)
        guard let operation = AgentOperationState(rawValue: operationText) else { throw ValidationError.unsupported("operation \(operationText)") }
        self.operation = operation
        evidence = try reader.optionalString("evidence", maxLength: 64)
        systemOutcome = try reader.optionalBool("system_outcome") ?? false
        version = try reader.integer("version")
        try reader.rejectUnknownMembers()
    }
}

/// An input as it appears in a page: parsed when this build understands it,
/// otherwise carried as unsupported so one newer record cannot make the whole
/// page unreadable — and can never be answered (spec.agent-relay.md 15.6).
public enum AgentInputItem: Sendable, Hashable {
    case supported(InputRecord)
    case unsupported(requestID: ControlID?, raw: JSONValue)

    public init(json: JSONValue) {
        if let record = try? InputRecord(json: json) {
            self = .supported(record)
        } else {
            let id = json["spec"]?["request_id"]?.stringValue.flatMap(ControlID.init)
            self = .unsupported(requestID: id, raw: json)
        }
    }

    public var json: JSONValue {
        switch self {
        case .supported(let record): return record.json
        case .unsupported(_, let raw): return raw
        }
    }

    public var requestID: ControlID? {
        switch self {
        case .supported(let record): return record.spec.requestID
        case .unsupported(let id, _): return id
        }
    }
}

/// One delta of the agent change feed. Its cursor namespace is separate from
/// the base feed, so neither cursor is accepted by the other's endpoint
/// (spec.agent-relay.md 15.6).
public struct AgentChangeEvent: Sendable, Hashable {
    public let eventID: ControlID
    public let sequence: LogSequence
    public let type: AgentEventType
    public let resourceID: ControlID
    public let resourceVersion: Int64
    public let serverTime: ControlTimestamp
    public let projection: JSONValue

    public init(eventID: ControlID, sequence: LogSequence, type: AgentEventType, resourceID: ControlID, resourceVersion: Int64, serverTime: ControlTimestamp, projection: JSONValue) {
        self.eventID = eventID
        self.sequence = sequence
        self.type = type
        self.resourceID = resourceID
        self.resourceVersion = resourceVersion
        self.serverTime = serverTime
        self.projection = projection
    }

    public var json: JSONValue {
        .object([
            "v": 1,
            "event_id": JSONValue(eventID),
            "sequence": JSONValue(sequence),
            "type": .string(type.rawValue),
            "resource_id": JSONValue(resourceID),
            "resource_version": .number(.int(resourceVersion)),
            "server_time": JSONValue(serverTime),
            "projection": projection
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard try reader.integer("v") == 1 else { throw ValidationError.unsupported("agent change version") }
        eventID = try reader.id("event_id")
        guard let sequence = LogSequence(decimalString: try reader.string("sequence", maxLength: 20)) else {
            throw ValidationError.invalid("sequence", "must be a decimal string")
        }
        self.sequence = sequence
        type = AgentEventType(rawValue: try reader.string("type", maxLength: 64))
        resourceID = try reader.id("resource_id")
        resourceVersion = try reader.integer("resource_version")
        serverTime = try reader.timestamp("server_time")
        projection = try reader.value("projection")
        try reader.rejectUnknownMembers()
    }
}

public struct AgentChangePage: Sendable, Hashable {
    public static let maximumEvents = 100

    public let events: [AgentChangeEvent]
    public let cursor: ChangeCursor
    public let serverTime: ControlTimestamp

    public init(events: [AgentChangeEvent], cursor: ChangeCursor, serverTime: ControlTimestamp) {
        self.events = events
        self.cursor = cursor
        self.serverTime = serverTime
    }

    public var json: JSONValue {
        .object([
            "events": .array(events.map(\.json)),
            "cursor": .string(cursor.rawValue),
            "server_time": JSONValue(serverTime)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard let raw = try reader.value("events").arrayValue else { throw ValidationError.invalid("events", "must be an array") }
        events = try raw.map(AgentChangeEvent.init(json:))
        cursor = ChangeCursor(try reader.string("cursor", maxLength: 512))
        serverTime = try reader.timestamp("server_time")
        try reader.rejectUnknownMembers()
    }
}

/// One page of the agent projection at a consistent sequence cut. Changes
/// start after that cut (spec.agent-relay.md 12.2).
public struct AgentSnapshotPage: Sendable, Hashable {
    public static let maximumItems = 50

    public let sessions: [AgentSessionProjection]
    public let inputs: [AgentInputItem]
    public let approvals: [AgentApprovalReference]
    public let snapshotToken: String
    public let nextPageToken: String?
    public let cursor: ChangeCursor
    public let serverTime: ControlTimestamp

    public init(
        sessions: [AgentSessionProjection],
        inputs: [AgentInputItem],
        approvals: [AgentApprovalReference],
        snapshotToken: String,
        nextPageToken: String?,
        cursor: ChangeCursor,
        serverTime: ControlTimestamp
    ) {
        self.sessions = sessions
        self.inputs = inputs
        self.approvals = approvals
        self.snapshotToken = snapshotToken
        self.nextPageToken = nextPageToken
        self.cursor = cursor
        self.serverTime = serverTime
    }

    public var isComplete: Bool { nextPageToken == nil }

    public var json: JSONValue {
        JSONWriter.object([
            "sessions": .array(sessions.map(\.json)),
            "inputs": .array(inputs.map(\.json)),
            "approvals": .array(approvals.map(\.json)),
            "snapshot_token": .string(snapshotToken),
            "next_page_token": nextPageToken.map { .string($0) },
            "cursor": .string(cursor.rawValue),
            "server_time": JSONValue(serverTime)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard let sessions = try reader.value("sessions").arrayValue,
              let inputs = try reader.value("inputs").arrayValue,
              let approvals = try reader.value("approvals").arrayValue else {
            throw ValidationError.invalid("agent snapshot", "sessions, inputs, and approvals must be arrays")
        }
        self.sessions = try sessions.map(AgentSessionProjection.init(json:))
        self.inputs = inputs.map(AgentInputItem.init(json:))
        self.approvals = try approvals.map(AgentApprovalReference.init(json:))
        snapshotToken = try reader.string("snapshot_token", maxLength: 512)
        nextPageToken = try reader.optionalString("next_page_token", maxLength: 512)
        cursor = ChangeCursor(try reader.string("cursor", maxLength: 512))
        serverTime = try reader.timestamp("server_time")
        try reader.rejectUnknownMembers()
    }
}
