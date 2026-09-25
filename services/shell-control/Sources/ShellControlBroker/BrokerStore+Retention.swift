import Foundation
import ShellControlProtocol

extension BrokerStore {
    /// How often ``purgeRetained()`` runs at most, from ``commit()``.
    static let purgeInterval: TimeInterval = 60 * 60

    func purgeRetainedIfDue() {
        let now = now()
        if let last = lastPurgeAt, now.timeIntervalSince(last) < BrokerStore.purgeInterval { return }
        lastPurgeAt = now
        purgeRetained()
    }

    /// Drops detailed records once their retention has passed, so the ledger
    /// stays bounded. Command, receipt, and notification records are kept for
    /// 30 days; a purged request leaves a compact tombstone so its ID can never
    /// be reused; mutation IDs are kept for the origin enrollment's lifetime
    /// (spec.watch.md section 15).
    func purgeRetained() {
        let now = timestamp
        // Trimmed here as well as on append, so an idle ledger ages out too.
        trimChangeLog()
        let cutoff = now.adding(-ApprovalPolicy.commandRetention)

        for (id, entry) in approvals where entry.spec.expiresAt < cutoff {
            // Past its deadline by the whole retention period, the request is
            // terminal whatever its last recorded state.
            if tombstones[id] == nil {
                tombstones[id] = Tombstone(
                    requestID: id,
                    requestHash: entry.requestHash,
                    resolution: entry.projection.resolution == .pending ? .expired : entry.projection.resolution,
                    consumedBy: entry.consumedBy
                )
            }
            approvals.removeValue(forKey: id)
            itemSequences.removeValue(forKey: id)
        }
        for (id, event) in notifications where event.occurredAt < cutoff {
            notifications.removeValue(forKey: id)
            notificationAccounts.removeValue(forKey: id)
            itemSequences.removeValue(forKey: id)
            // The mutation ID stays, so a replay is still recognized; the body
            // it would have returned is gone with the event.
            let key = OriginMutationRecord.key(.notify, originID: event.originID, mutationID: id)
            if let record = originMutations[key] {
                originMutations[key] = OriginMutationRecord(
                    kind: record.kind,
                    originID: record.originID,
                    mutationID: record.mutationID,
                    bodyHash: record.bodyHash,
                    result: .object([:])
                )
            }
        }
        // A command's deadline is at most a challenge lifetime, so a retry past
        // retention can never re-execute: it fails the deadline check instead.
        idempotency = idempotency.filter { $0.value.recordedAt >= cutoff }
        receipts = receipts.filter { $0.value >= cutoff }

        purgeAgentRetained(cutoff: cutoff)

        let referencedRuns = Set(approvals.values.map(\.spec.runID)).union(agent.inputs.values.map(\.spec.runID))
        for (id, run) in runs where !referencedRuns.contains(id) {
            if let lastSeen = run.lastSeenAt, lastSeen >= cutoff { continue }
            if run.lastSeenAt == nil, run.registration.startedAt >= cutoff { continue }
            runs.removeValue(forKey: id)
        }

        // Tokens: a spent refresh token is kept only while its rotation can
        // still be replayed; after that, absent and spent answer the same.
        accessTokens = accessTokens.filter { !$0.value.revoked && now < $0.value.expiresAt }
        refreshTokens = refreshTokens.filter { _, record in
            guard now < record.expiresAt else { return false }
            guard record.revoked else { return true }
            guard let rotatedAt = record.rotatedAt else { return false }
            return now < rotatedAt.adding(BrokerStore.refreshReplayGrace)
        }
        enrollmentTokens = enrollmentTokens.filter { now < $0.value.expiresAt }
    }
}

extension BrokerStore {
    /// The agent ledger ages out on the base floors: seven days of change
    /// history and thirty days of command evidence. A purged input leaves a
    /// tombstone so its ID is never reused (spec.agent-relay.md section 18).
    func purgeAgentRetained(cutoff: ControlTimestamp) {
        trimAgentChangeLog()
        for (id, entry) in agent.inputs where entry.spec.expiresAt < cutoff {
            agent.inputTombstones[id] = entry.requestHash
            agent.inputs.removeValue(forKey: id)
            agent.itemSequences.removeValue(forKey: id)
        }
        for (id, _) in agent.approvals where approvals[id] == nil {
            agent.approvals.removeValue(forKey: id)
            agent.itemSequences.removeValue(forKey: id)
        }
        for (id, entry) in agent.sessions {
            // An ended session ages out; so does an "active" one whose origin
            // never reported its end (the agent was killed) and that has not
            // been seen for the whole retention period.
            let last = entry.projection.endedAt ?? entry.projection.lastSeenAt ?? entry.projection.registration.startedAt
            guard last < cutoff else { continue }
            let referenced = agent.inputs.values.contains { $0.spec.source.agentSessionID == id }
                || agent.approvals.values.contains { $0.reference.agentSessionID == id }
            guard !referenced else { continue }
            agent.sessions.removeValue(forKey: id)
            agent.itemSequences.removeValue(forKey: id)
        }
        agent.idempotency = agent.idempotency.filter { $0.value.recordedAt >= cutoff }
        agent.sessionCommands = agent.sessionCommands.filter { $0.value.record.recordedAt >= cutoff }
        agent.mutations = agent.mutations.filter { $0.value.recordedAt >= cutoff }
    }
}
