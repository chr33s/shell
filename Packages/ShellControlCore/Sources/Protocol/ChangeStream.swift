import Foundation

/// Ordered change-log event types (spec.watch.md section 15).
public enum ChangeEventType: String, Sendable, Hashable, CaseIterable {
    case approvalCreated = "approval.created"
    case approvalResolved = "approval.resolved"
    case approvalDispatchUpdated = "approval.dispatch_updated"
    case notificationCreated = "notification.created"
    case notificationAcknowledged = "notification.acknowledged"
    case jobUpdated = "job.updated"
    case originPresenceChanged = "origin.presence_changed"
}

/// One delta. Delivery is at least once: clients deduplicate by event ID and
/// ignore stale resource versions. A scoped stream may have sequence gaps
/// because of filtering, which is not data loss (spec.watch.md section 15).
public struct ChangeEvent: Sendable, Hashable {
    public let version: Int
    public let eventID: ControlID
    public let sequence: LogSequence
    public let type: ChangeEventType
    public let resourceID: ControlID
    public let resourceVersion: Int64
    public let serverTime: ControlTimestamp
    public let projection: JSONValue

    public init(
        version: Int = 1,
        eventID: ControlID,
        sequence: LogSequence,
        type: ChangeEventType,
        resourceID: ControlID,
        resourceVersion: Int64,
        serverTime: ControlTimestamp,
        projection: JSONValue
    ) {
        self.version = version
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
            "v": .number(.int(Int64(version))),
            "event_id": JSONValue(eventID),
            "sequence": JSONValue(sequence),
            "type": .string(type.rawValue),
            "resource_id": JSONValue(resourceID),
            "resource_version": .number(.int(resourceVersion)),
            "server_time": JSONValue(serverTime),
            "projection": projection,
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        version = try Int(reader.integer("v"))
        eventID = try reader.id("event_id")
        let sequenceText = try reader.string("sequence", maxLength: 20)
        guard let sequence = LogSequence(decimalString: sequenceText) else {
            throw ValidationError.invalid("sequence", "must be a decimal string")
        }
        self.sequence = sequence
        let typeText = try reader.string("type", maxLength: 48)
        guard let type = ChangeEventType(rawValue: typeText) else {
            throw ValidationError.unsupported("change type \(typeText)")
        }
        self.type = type
        resourceID = try reader.id("resource_id")
        resourceVersion = try reader.integer("resource_version")
        serverTime = try reader.timestamp("server_time")
        projection = try reader.value("projection")
        try reader.rejectUnknownMembers()
    }
}

/// A cursor is opaque to the client and scoped to the authenticated principal
/// (spec.watch.md section 8).
public struct ChangeCursor: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct ChangePage: Sendable, Hashable {
    public static let maximumEvents = 100

    public let events: [ChangeEvent]
    public let cursor: ChangeCursor
    public let serverTime: ControlTimestamp

    public init(events: [ChangeEvent], cursor: ChangeCursor, serverTime: ControlTimestamp) {
        self.events = events
        self.cursor = cursor
        self.serverTime = serverTime
    }

    public var json: JSONValue {
        .object([
            "events": .array(events.map(\.json)),
            "cursor": .string(cursor.rawValue),
            "server_time": JSONValue(serverTime),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard let rawEvents = try reader.value("events").arrayValue else {
            throw ValidationError.invalid("events", "must be an array")
        }
        events = try rawEvents.map { try ChangeEvent(json: $0) }
        cursor = ChangeCursor(try reader.string("cursor", maxLength: 512))
        serverTime = try reader.timestamp("server_time")
        try reader.rejectUnknownMembers()
    }
}

/// One page of the initial projection. Pages share a snapshot token and expire
/// together; the completed snapshot is applied atomically before deltas are
/// consumed (spec.watch.md section 15).
public struct SnapshotPage: Sendable, Hashable {
    public static let maximumItems = 50

    public let approvals: [ApprovalRecord]
    public let notifications: [InformationalEvent]
    public let snapshotToken: String
    public let nextPageToken: String?
    public let cursor: ChangeCursor
    public let serverTime: ControlTimestamp

    public init(
        approvals: [ApprovalRecord],
        notifications: [InformationalEvent],
        snapshotToken: String,
        nextPageToken: String?,
        cursor: ChangeCursor,
        serverTime: ControlTimestamp
    ) {
        self.approvals = approvals
        self.notifications = notifications
        self.snapshotToken = snapshotToken
        self.nextPageToken = nextPageToken
        self.cursor = cursor
        self.serverTime = serverTime
    }

    public var isComplete: Bool { nextPageToken == nil }

    public var json: JSONValue {
        JSONWriter.object([
            "approvals": .array(approvals.map(\.json)),
            "notifications": .array(notifications.map(\.json)),
            "snapshot_token": .string(snapshotToken),
            "next_page_token": nextPageToken.map { .string($0) },
            "cursor": .string(cursor.rawValue),
            "server_time": JSONValue(serverTime),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard let rawApprovals = try reader.value("approvals").arrayValue else {
            throw ValidationError.invalid("approvals", "must be an array")
        }
        approvals = try rawApprovals.map { try ApprovalRecord(json: $0) }
        guard let rawNotifications = try reader.value("notifications").arrayValue else {
            throw ValidationError.invalid("notifications", "must be an array")
        }
        notifications = try rawNotifications.map { try InformationalEvent(json: $0) }
        snapshotToken = try reader.string("snapshot_token", maxLength: 512)
        nextPageToken = try reader.optionalString("next_page_token", maxLength: 512)
        cursor = ChangeCursor(try reader.string("cursor", maxLength: 512))
        serverTime = try reader.timestamp("server_time")
        try reader.rejectUnknownMembers()
    }
}

/// A run registration: one execution attempt of a logical job.
///
/// A process restart creates a new run unless the adapter can prove durable
/// continuation; a transport reconnect alone does not
/// (spec.watch.md section 9).
public struct RunRegistration: Sendable, Hashable {
    public let runID: ControlID
    public let jobID: ControlID
    public let jobLabel: String
    public let adapter: String
    public let capabilities: [String]
    public let startedAt: ControlTimestamp

    public init(
        runID: ControlID,
        jobID: ControlID,
        jobLabel: String,
        adapter: String,
        capabilities: [String],
        startedAt: ControlTimestamp
    ) throws {
        guard !jobLabel.isEmpty, jobLabel.unicodeScalars.count <= 120 else {
            throw ValidationError.invalid("job_label", "must be 1...120 characters")
        }
        guard !adapter.isEmpty, adapter.count <= 64 else {
            throw ValidationError.invalid("adapter", "must be 1...64 characters")
        }
        self.runID = runID
        self.jobID = jobID
        self.jobLabel = jobLabel
        self.adapter = adapter
        self.capabilities = capabilities
        self.startedAt = startedAt
    }

    public var json: JSONValue {
        .object([
            "run_id": JSONValue(runID),
            "job_id": JSONValue(jobID),
            "job_label": .string(jobLabel),
            "adapter": .string(adapter),
            "capabilities": JSONValue(strings: capabilities),
            "started_at": JSONValue(startedAt),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let runID = try reader.id("run_id")
        let jobID = try reader.id("job_id")
        let jobLabel = try reader.string("job_label", maxLength: 120)
        let adapter = try reader.string("adapter", maxLength: 64)
        let capabilities = try reader.stringArray("capabilities", maxCount: 32, maxLength: 64)
        let startedAt = try reader.timestamp("started_at")
        try reader.rejectUnknownMembers()
        try self.init(
            runID: runID,
            jobID: jobID,
            jobLabel: jobLabel,
            adapter: adapter,
            capabilities: capabilities,
            startedAt: startedAt
        )
    }
}

public enum JobState: String, Sendable, Hashable, CaseIterable {
    case running
    case cancellationRequested = "cancellation_requested"
    case cancelled
    case completed
    case failed
}
