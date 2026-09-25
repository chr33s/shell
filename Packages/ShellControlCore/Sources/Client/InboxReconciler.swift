import Foundation
import ShellControlProtocol
import Synchronization

/// The client's view of the ledger.
public struct InboxState: Sendable, Hashable {
    public var approvals: [ControlID: ApprovalRecord] = [:]
    public var notifications: [ControlID: InformationalEvent] = [:]
    public var cursor: ChangeCursor?
    /// When the projection was last confirmed against the server. Cached data
    /// must visibly say when it was last refreshed (docs/specs/control-protocol.md section 11.2).
    public var lastRefreshedAt: ControlTimestamp?
    /// Event IDs already applied, for at-least-once deduplication.
    public var seenEventIDs: Set<ControlID> = []

    public init() {}

    public var pendingApprovals: [ApprovalRecord] {
        approvals.values
            .filter { $0.projection.resolution == .pending }
            .sorted { $0.spec.expiresAt < $1.spec.expiresAt }
    }

    public var recentOutcomes: [ApprovalRecord] {
        approvals.values
            .filter { $0.projection.resolution.isTerminal }
            .sorted { ($0.projection.decidedAt ?? $0.spec.createdAt) > ($1.projection.decidedAt ?? $1.spec.createdAt) }
    }

    public var unacknowledgedNotifications: [InformationalEvent] {
        notifications.values
            .filter { $0.acknowledgedAt == nil }
            .sorted { $0.occurredAt > $1.occurredAt }
    }
}

/// Where the client persists its cache. Cache mutations and cursor advancement
/// commit atomically (docs/specs/control-protocol.md section 13.1).
public protocol InboxCacheStore: Sendable {
    func load() throws -> InboxState?
    func commit(_ state: InboxState) throws
    func clear() throws
}

public final class InMemoryInboxCache: InboxCacheStore, Sendable {
    private let state = Mutex<InboxState?>(nil)

    public init() {}

    public func load() throws -> InboxState? {
        state.withLock { $0 }
    }

    public func commit(_ state: InboxState) throws {
        self.state.withLock { $0 = state }
    }

    public func clear() throws {
        state.withLock { $0 = nil }
    }
}

/// Applies snapshots and deltas.
///
/// A completed snapshot is applied atomically before deltas after its cursor
/// are consumed; deltas are deduplicated by event ID and stale resource
/// versions are ignored (docs/specs/control-protocol.md section 13.1).
public struct InboxReconciler: Sendable {
    public private(set) var state: InboxState
    /// Highest applied version per resource, so an out-of-order redelivery
    /// cannot roll a record backwards.
    private var appliedVersions: [ControlID: Int64] = [:]

    public init(state: InboxState = InboxState()) {
        self.state = state
    }

    public enum ReconcileError: Error, Equatable, Sendable {
        case snapshotIncomplete
        case snapshotTokenChanged
    }

    /// Accumulates snapshot pages; nothing is visible until the last page.
    public struct SnapshotAccumulator: Sendable {
        public let snapshotToken: String
        var approvals: [ControlID: ApprovalRecord] = [:]
        var notifications: [ControlID: InformationalEvent] = [:]
        var cursor: ChangeCursor
        var isComplete = false

        public init(firstPage page: SnapshotPage) {
            snapshotToken = page.snapshotToken
            cursor = page.cursor
            absorb(page)
        }

        public mutating func absorb(_ page: SnapshotPage) {
            for record in page.approvals { approvals[record.spec.requestID] = record }
            for event in page.notifications { notifications[event.eventID] = event }
            cursor = page.cursor
            isComplete = page.isComplete
        }

        public mutating func append(_ page: SnapshotPage) throws {
            guard page.snapshotToken == snapshotToken else { throw ReconcileError.snapshotTokenChanged }
            absorb(page)
        }

        public var nextPageToken: String? { isComplete ? nil : "" }
    }

    /// Replaces local projection state with a completed snapshot.
    ///
    /// A permissions change may require this reset so stale unauthorized
    /// objects are removed; unresolved local command IDs are kept elsewhere and
    /// are unaffected (docs/specs/control-protocol.md section 13.1).
    public mutating func applyCompletedSnapshot(_ accumulator: SnapshotAccumulator, at serverTime: ControlTimestamp) throws {
        guard accumulator.isComplete else { throw ReconcileError.snapshotIncomplete }
        var next = InboxState()
        next.approvals = accumulator.approvals
        next.notifications = accumulator.notifications
        next.cursor = accumulator.cursor
        next.lastRefreshedAt = serverTime
        state = next
        appliedVersions = accumulator.approvals.mapValues { $0.projection.stateVersion }
    }

    @discardableResult
    public mutating func apply(_ page: ChangePage) -> Int {
        var applied = 0
        for event in page.events {
            if apply(event) { applied += 1 }
        }
        // The cursor advances with the mutations it covers, in one commit.
        state.cursor = page.cursor
        state.lastRefreshedAt = page.serverTime
        return applied
    }

    private mutating func apply(_ event: ChangeEvent) -> Bool {
        guard !state.seenEventIDs.contains(event.eventID) else { return false }
        if let applied = appliedVersions[event.resourceID], applied >= event.resourceVersion,
           event.type != .notificationAcknowledged {
            state.seenEventIDs.insert(event.eventID)
            return false
        }
        switch event.type {
        case .approvalCreated, .approvalResolved, .approvalDispatchUpdated:
            if let record = try? ApprovalRecord(json: event.projection) {
                state.approvals[record.spec.requestID] = record
                appliedVersions[event.resourceID] = event.resourceVersion
            } else if var existing = state.approvals[event.resourceID],
                      let projection = try? ApprovalProjection(json: event.projection) {
                // A projection-only delta updates the mutable half; the
                // immutable spec is never rewritten in place.
                existing.projection = projection
                state.approvals[event.resourceID] = existing
                appliedVersions[event.resourceID] = event.resourceVersion
            } else {
                // Unrenderable delta: leave the record to the next fetch rather
                // than guessing.
                return false
            }
        case .notificationCreated, .notificationAcknowledged:
            if let notification = try? InformationalEvent(json: event.projection) {
                state.notifications[notification.eventID] = notification
                appliedVersions[event.resourceID] = event.resourceVersion
            } else {
                return false
            }
        case .jobUpdated, .originPresenceChanged:
            // Presence and job state reach the UI through the approval
            // projection; nothing else is cached for them in v1.
            appliedVersions[event.resourceID] = event.resourceVersion
        }
        state.seenEventIDs.insert(event.eventID)
        if state.seenEventIDs.count > 2048 {
            // Bounded: the server retains the ordered log, so an old event ID
            // cannot be redelivered once its retention window has passed.
            state.seenEventIDs = Set(state.seenEventIDs.prefix(1024))
        }
        return true
    }
}
