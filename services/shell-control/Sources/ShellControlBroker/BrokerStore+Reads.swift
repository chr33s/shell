import Foundation
import ShellControlProtocol

extension BrokerStore {
    /// `GET /v1/snapshot`: a consistent, paginated projection plus a high-water
    /// cursor. Pages share a snapshot token and expire together
    /// (spec.watch.md section 15).
    public func snapshot(
        principal: Principal,
        pageToken: String? = nil,
        limit: Int = SnapshotPage.maximumItems
    ) throws -> SnapshotPage {
        sweepExpired()
        let limit = max(1, min(limit, SnapshotPage.maximumItems))
        let highWater = LogSequence(currentSequence)
        var offset = 0
        if let pageToken {
            let parts = pageToken.split(separator: "@", maxSplits: 1)
            guard parts.count == 2, let parsedOffset = Int(parts[0]) else {
                throw ControlError(code: .cursorExpired, message: "page token is not readable")
            }
            let anchor = try CursorCodec.decodeSnapshotToken(String(parts[1]), principal: principal, secret: cursorSecret)
            // Changes during pagination stay in the log after the anchor, so the
            // client can catch up after applying the completed snapshot.
            guard anchor.value <= highWater.value else {
                throw ControlError(code: .cursorExpired, message: "snapshot expired")
            }
            offset = parsedOffset
        }
        let anchorSequence = pageToken.flatMap { token -> LogSequence? in
            let parts = token.split(separator: "@", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return try? CursorCodec.decodeSnapshotToken(String(parts[1]), principal: principal, secret: cursorSecret)
        } ?? highWater

        // Paging is over the items that existed at the anchor, ordered
        // stably. Recomputing an unfiltered list per page would let an
        // approval created mid-pagination shift every later item forward and
        // silently drop one — and because that item predates the anchor, the
        // change stream would never redeliver it either.
        var visibleApprovals = approvals.values
            .filter { isVisible(approval: $0, to: principal) }
            .filter { (itemSequences[$0.spec.requestID] ?? 0) <= anchorSequence.value }
            .sorted { lhs, rhs in
                let left = itemSequences[lhs.spec.requestID] ?? 0
                let right = itemSequences[rhs.spec.requestID] ?? 0
                return left == right ? lhs.spec.requestID.rawValue < rhs.spec.requestID.rawValue : left < right
            }
        for index in visibleApprovals.indices { refreshPresence(for: &visibleApprovals[index]) }
        let visibleNotifications = notifications.values
            .filter { notificationAccounts[$0.eventID] == principal.accountID }
            .filter { (itemSequences[$0.eventID] ?? 0) <= anchorSequence.value }
            .sorted { lhs, rhs in
                let left = itemSequences[lhs.eventID] ?? 0
                let right = itemSequences[rhs.eventID] ?? 0
                return left == right ? lhs.eventID.rawValue < rhs.eventID.rawValue : left < right
            }

        let items: [Either] = visibleApprovals.map { .approval($0.record) } + visibleNotifications.map { .notification($0) }
        let page = Array(items.dropFirst(offset).prefix(limit))
        let consumed = offset + page.count
        let snapshotToken = CursorCodec.encodeSnapshotToken(sequence: anchorSequence, principal: principal, secret: cursorSecret)
        return SnapshotPage(
            approvals: page.compactMap { if case .approval(let record) = $0 { return record } else { return nil } },
            notifications: page.compactMap { if case .notification(let event) = $0 { return event } else { return nil } },
            snapshotToken: snapshotToken,
            nextPageToken: consumed < items.count ? "\(consumed)@\(snapshotToken)" : nil,
            cursor: CursorCodec.encodeCursor(sequence: anchorSequence, principal: principal, secret: cursorSecret),
            serverTime: timestamp
        )
    }

    enum Either {
        case approval(ApprovalRecord)
        case notification(InformationalEvent)
    }

    var currentSequence: UInt64 { changeLog.last.map { $0.sequence.value } ?? 0 }

    var earliestSequence: UInt64 { changeLog.first.map { $0.sequence.value } ?? 0 }

    func isVisible(approval entry: ApprovalRecordEntry, to principal: Principal) -> Bool {
        guard entry.accountID == principal.accountID else { return false }
        switch principal {
        case .device, .admin: return true
        case .origin(let originID, _): return entry.spec.originID == originID
        }
    }

    /// `GET /v1/changes`: ordered authorized deltas after `cursor`.
    public func changes(
        principal: Principal,
        cursor: ChangeCursor,
        limit: Int = ChangePage.maximumEvents
    ) throws -> ChangePage {
        sweepExpired()
        let sequence = try CursorCodec.decodeCursor(cursor, principal: principal, secret: cursorSecret)
        // A cursor older than the retained log cannot be honoured.
        if sequence.value > 0, sequence.value + 1 < earliestSequence {
            throw ControlError(code: .cursorExpired, message: "cursor is older than the retained log")
        }
        let limit = max(1, min(limit, ChangePage.maximumEvents))
        // A scoped stream may have sequence gaps because of filtering; that is
        // not data loss (spec.watch.md section 15).
        let events = changeLog
            .filter { $0.sequence.value > sequence.value && isVisible($0, to: principal) }
            .prefix(limit)
        let nextSequence = events.last?.sequence ?? sequence
        return ChangePage(
            events: Array(events),
            cursor: CursorCodec.encodeCursor(sequence: nextSequence, principal: principal, secret: cursorSecret),
            serverTime: timestamp
        )
    }

    /// `GET /v1/approvals/{request_id}`. Object-level authorization is enforced
    /// on every fetch: another account guessing an ID learns nothing
    /// (spec.watch.md sections 4 and 19).
    public func approval(_ requestID: ControlID, principal: Principal) throws -> ApprovalRecord {
        sweepExpired()
        guard var entry = approvals[requestID], isVisible(approval: entry, to: principal) else {
            throw ControlError(code: .notFound, message: "no such request")
        }
        refreshPresence(for: &entry)
        approvals[requestID] = entry
        return entry.record
    }

    /// `GET /v1/commands/{command_id}`: only the submitting device may read it.
    public func commandResult(_ commandID: ControlID, principal: Principal) throws -> CommandResult {
        guard let deviceID = principal.deviceID,
              let record = idempotency[BrokerStore.idempotencyKey(account: principal.accountID, device: deviceID, command: commandID)]
        else {
            throw ControlError(code: .notFound, message: "no such command")
        }
        return record.result
    }

    static func idempotencyKey(account: ControlID, device: ControlID, command: ControlID) -> String {
        "\(account.rawValue)|\(device.rawValue)|\(command.rawValue)"
    }
}
