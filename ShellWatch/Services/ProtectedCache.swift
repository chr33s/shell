import Foundation
import ShellControlProtocol
import ShellControlClient

/// The Watch's small protected local cache.
///
/// Written with complete file protection so it is unreadable while the device
/// is locked, and cleared on logout or account change
/// (docs/specs/control-protocol.md section 11.5).
final class ProtectedInboxCache: InboxCacheStore, Sendable {
    private let url: URL

    init(directory: URL? = nil) throws {
        let base = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("control-inbox.json")
    }

    /// Parse limits with headroom over what ``InboxBounds`` lets a commit
    /// write, and over the 5000 seen event IDs older builds persisted, so a
    /// valid cache always loads.
    static let limits = JSONLimits(
        maxDocumentBytes: 8 << 20,
        maxStringCharacters: 1 << 16,
        maxNestingDepth: 32,
        maxCollectionElements: 8192
    )

    func load() throws -> InboxState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        return InboxBounds.bounded(try ProtectedInboxCache.decode(try JSONValue.parse(data, limits: Self.limits)))
    }

    func commit(_ state: InboxState) throws {
        let data = try JSONCanonicalization.canonicalize(ProtectedInboxCache.encode(InboxBounds.bounded(state)))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func clear() throws {
        try? FileManager.default.removeItem(at: url)
    }

    static func encode(_ state: InboxState) -> JSONValue {
        JSONWriter.object([
            "approvals": .array(state.approvals.values.map(\.json)),
            "notifications": .array(state.notifications.values.map(\.json)),
            "cursor": state.cursor.map { .string($0.rawValue) },
            "last_refreshed_at": state.lastRefreshedAt.map { JSONValue($0) },
            "seen_event_ids": JSONValue(strings: state.seenEventIDs.map(\.rawValue).sorted())
        ])
    }

    static func decode(_ value: JSONValue) throws -> InboxState {
        var reader = try JSONReader(value)
        var state = InboxState()
        for element in try reader.value("approvals").arrayValue ?? [] {
            // A cached record whose digest no longer verifies is dropped rather
            // than shown: stale display is fine, unverifiable display is not.
            if let record = try? ApprovalRecord(json: element) {
                state.approvals[record.spec.requestID] = record
            }
        }
        for element in try reader.value("notifications").arrayValue ?? [] {
            if let event = try? InformationalEvent(json: element) {
                state.notifications[event.eventID] = event
            }
        }
        state.lastRefreshedAt = try? reader.optionalTimestamp("last_refreshed_at")
        // Dedup bookkeeping and the cursor are recoverable: if either is
        // unreadable, keep the records and let the next refresh take a
        // fresh snapshot instead of discarding the whole cache.
        do {
            let seen = try reader.stringArray("seen_event_ids", maxCount: limits.maxCollectionElements, maxLength: 36)
            let cursor = try reader.optionalString("cursor", maxLength: 512)
            state.seenEventIDs = Set(seen.compactMap(ControlID.init))
            state.cursor = cursor.map(ChangeCursor.init)
        } catch {
            state.seenEventIDs = []
            state.cursor = nil
        }
        return state
    }
}

/// What the Watch keeps of the inbox, so the in-memory projection and the
/// persisted cache stay bounded and always parse within
/// ``ProtectedInboxCache/limits``. `InboxReconciler` only trims seen event
/// IDs past 5000 and never drops approvals or notifications; this is applied
/// after every reconcile and on every commit.
enum InboxBounds {
    /// Seen event IDs kept for at-least-once dedup. Trimmed *to* this cap.
    /// A reconcile applies at most one change page (100 events), so the
    /// reconciler's own 5000 threshold is never reached.
    static let maxSeenEventIDs = 2048
    /// Approvals kept: every pending one first (soonest expiry first), then
    /// the most recently decided.
    static let maxApprovals = 512
    /// Notifications kept: unacknowledged first, then the most recent.
    static let maxNotifications = 256

    static func bounded(_ state: InboxState) -> InboxState {
        var state = state
        if state.seenEventIDs.count > maxSeenEventIDs {
            // Unordered: which IDs go does not matter once the cursor that
            // covers their events is committed.
            state.seenEventIDs = Set(state.seenEventIDs.prefix(maxSeenEventIDs))
        }
        if state.approvals.count > maxApprovals {
            let kept = state.pendingApprovals + state.recentOutcomes
            state.approvals = Dictionary(
                kept.prefix(maxApprovals).map { ($0.spec.requestID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        if state.notifications.count > maxNotifications {
            let kept = state.notifications.values.sorted { lhs, rhs in
                if (lhs.acknowledgedAt == nil) != (rhs.acknowledgedAt == nil) { return lhs.acknowledgedAt == nil }
                return lhs.occurredAt > rhs.occurredAt
            }
            state.notifications = Dictionary(
                kept.prefix(maxNotifications).map { ($0.eventID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return state
    }
}
