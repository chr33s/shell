import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// `shell-agent/1` device-side reads and signed responses. Authorization
/// filtering is identical for snapshots, changes, and direct fetches
/// (docs/specs/agent-relay.md section 14.2).
extension BrokerStore {
    // MARK: Visibility

    func isVisible(input entry: InputEntry, to principal: Principal) -> Bool {
        guard entry.accountID == principal.accountID else { return false }
        switch principal {
        case .device, .admin: return true
        case .origin(let originID, _): return entry.spec.originID == originID
        }
    }

    func isVisible(session entry: AgentSessionEntry, to principal: Principal) -> Bool {
        guard entry.accountID == principal.accountID else { return false }
        switch principal {
        case .device(_, _, let grants): return grants.contains(.agentSessionsRead)
        case .admin: return true
        case .origin(let originID, _): return entry.originID == originID
        }
    }

    func isVisibleAgent(_ event: AgentChangeEvent, to principal: Principal) -> Bool {
        guard let scope = agent.scopes[event.eventID], scope.accountID == principal.accountID else { return false }
        switch principal {
        case .device(_, _, let grants):
            // Session records — and the commands sent to sessions, which
            // carry instruction text — are visible only with the session
            // grant.
            switch event.type {
            case .sessionStarted, .sessionEnded, .statusChanged, .turnStarted, .turnCompleted, .turnFailed:
                return grants.contains(.agentSessionsRead)
            case .deliveryUpdated where agent.sessionCommands[event.resourceID] != nil:
                return grants.contains(.agentSessionsRead)
            default:
                return true
            }
        case .admin: return true
        case .origin(let originID, _): return scope.originID == originID
        }
    }

    // MARK: Reads

    public func agentSession(_ id: ControlID, principal: Principal) throws -> AgentSessionProjection {
        guard let entry = agent.sessions[id], isVisible(session: entry, to: principal) else {
            throw ControlError(code: .notFound, message: "no such agent session")
        }
        return entry.projection
    }

    public func input(_ requestID: ControlID, principal: Principal) throws -> InputRecord {
        sweepExpired()
        guard var entry = agent.inputs[requestID], isVisible(input: entry, to: principal) else {
            throw ControlError(code: .notFound, message: "no such input")
        }
        refreshPresence(for: &entry)
        agent.inputs[requestID] = entry
        return entry.record
    }

    /// Resolved history older than this is left out of snapshots; the change
    /// feed still carries every transition after the cut.
    static let agentSnapshotRecentWindow: TimeInterval = 24 * 60 * 60

    /// `GET /v1/agent/snapshot`: a stable-cut paginated projection of what a
    /// client needs — everything still pending plus recent history, or with
    /// `pendingOnly` only what can still be answered. Pages continue after
    /// the last item's key, never at an offset, so an item that resolves or
    /// drops out between pages cannot shift and hide an unchanged one; a
    /// change after the cut arrives through the change feed.
    public func agentSnapshot(principal: Principal, pageToken: String?, limit: Int, pendingOnly: Bool = false) throws -> AgentSnapshotPage {
        sweepExpired()
        let limit = max(1, min(limit, AgentSnapshotPage.maximumItems))
        let highWater = LogSequence(agent.currentSequence)
        var anchor = highWater
        var after: (sequence: UInt64, id: String)?
        if let pageToken {
            let parts = pageToken.split(separator: "@", maxSplits: 1)
            let key = parts.first.map { $0.split(separator: ":", maxSplits: 1) } ?? []
            guard parts.count == 2, key.count == 2, let sequence = UInt64(key[0]), ControlID(String(key[1])) != nil else {
                throw ControlError(code: .cursorExpired, message: "page token is not readable")
            }
            anchor = try CursorCodec.decodeAgentSnapshotToken(String(parts[1]), principal: principal, secret: cursorSecret)
            guard anchor.value <= highWater.value else { throw ControlError(code: .cursorExpired, message: "snapshot expired") }
            after = (sequence, String(key[1]))
        }
        func sequence(_ id: ControlID) -> UInt64 { agent.itemSequences[id] ?? 0 }
        let recent = timestamp.adding(-Self.agentSnapshotRecentWindow)

        enum Item { case session(AgentSessionProjection), input(InputRecord), approval(AgentApprovalReference) }
        var items: [(ControlID, Item)] = []
        for entry in agent.sessions.values where isVisible(session: entry, to: principal) {
            let id = entry.projection.registration.agentSessionID
            let relevant = entry.projection.state == .active
                || (!pendingOnly && (entry.projection.endedAt.map { $0 >= recent } ?? false))
            if relevant, sequence(id) <= anchor.value { items.append((id, .session(entry.projection))) }
        }
        for var entry in agent.inputs.values where isVisible(input: entry, to: principal) {
            guard sequence(entry.spec.requestID) <= anchor.value else { continue }
            let pending = entry.projection.resolution == .pending
            guard pending || (!pendingOnly && max(entry.spec.createdAt, entry.projection.respondedAt ?? entry.spec.createdAt) >= recent) else { continue }
            refreshPresence(for: &entry)
            items.append((entry.spec.requestID, .input(entry.record)))
        }
        for entry in agent.approvals.values where entry.accountID == principal.accountID {
            if case .origin(let originID, _) = principal, entry.originID != originID { continue }
            let approval = approvals[entry.reference.requestID]
            let pending = approval?.projection.resolution == .pending
            let fresh = approval.map { $0.spec.createdAt >= recent } ?? false
            guard pending || (!pendingOnly && fresh) else { continue }
            if sequence(entry.reference.requestID) <= anchor.value {
                items.append((entry.reference.requestID, .approval(entry.reference)))
            }
        }
        items.sort { sequence($0.0) == sequence($1.0) ? $0.0.rawValue < $1.0.rawValue : sequence($0.0) < sequence($1.0) }
        if let after {
            items = items.filter { sequence($0.0) > after.sequence || (sequence($0.0) == after.sequence && $0.0.rawValue > after.id) }
        }
        let page = Array(items.prefix(limit))
        let token = CursorCodec.encodeAgentSnapshotToken(sequence: anchor, principal: principal, secret: cursorSecret)
        let next = items.count > page.count ? page.last.map { "\(sequence($0.0)):\($0.0.rawValue)@\(token)" } : nil
        return AgentSnapshotPage(
            sessions: page.compactMap { if case .session(let value) = $0.1 { return value } else { return nil } },
            inputs: page.compactMap { if case .input(let value) = $0.1 { return .supported(value) } else { return nil } },
            approvals: page.compactMap { if case .approval(let value) = $0.1 { return value } else { return nil } },
            snapshotToken: token,
            nextPageToken: next,
            cursor: CursorCodec.encodeAgentCursor(sequence: anchor, principal: principal, secret: cursorSecret),
            serverTime: timestamp
        )
    }

    /// `GET /v1/agent/changes`: authorized deltas after an agent-namespace
    /// cursor. A base-feed cursor is rejected here, and vice versa.
    public func agentChanges(principal: Principal, cursor: ChangeCursor, limit: Int) throws -> AgentChangePage {
        sweepExpired()
        let sequence = try CursorCodec.decodeAgentCursor(cursor, principal: principal, secret: cursorSecret)
        if sequence.value + 1 < agent.earliestSequence {
            throw ControlError(code: .cursorExpired, message: "cursor is older than the retained log")
        }
        let limit = max(1, min(limit, AgentChangePage.maximumEvents))
        let start = agent.changeLog.firstIndex { $0.sequence.value > sequence.value } ?? agent.changeLog.endIndex
        let events = agent.changeLog[start...].lazy.filter { self.isVisibleAgent($0, to: principal) }.prefix(limit)
        let next = events.last?.sequence ?? sequence
        return AgentChangePage(
            events: Array(events),
            cursor: CursorCodec.encodeAgentCursor(sequence: next, principal: principal, secret: cursorSecret),
            serverTime: timestamp
        )
    }

    // MARK: Challenges

    /// `POST /v1/agent/review-challenges`: a one-use challenge for the exact
    /// input, hash, versions, signer, and action. Stale preconditions are
    /// rejected, never re-targeted.
    public func createAgentChallenge(principal: Principal, request: AgentReviewChallengeRequest) throws -> AgentReviewChallenge {
        sweepExpired()
        guard let deviceID = principal.deviceID else {
            throw ControlError(code: .notAuthorized, message: "only devices request challenges")
        }
        let now = timestamp
        let expiry: ControlTimestamp
        switch request.target {
        case .input(let requestID, let requestHash, let expectedStateVersion, let policyVersion):
            try principal.requireGrant(.agentInputsRespond)
            guard var entry = agent.inputs[requestID], isVisible(input: entry, to: principal) else {
                throw ControlError(code: .notFound, message: "no such input")
            }
            refreshPresence(for: &entry)
            agent.inputs[requestID] = entry
            guard entry.projection.resolution == .pending else {
                throw ControlError(code: .requestResolved, message: "already resolved", currentProjection: entry.record.json)
            }
            guard !entry.spec.isExpired(at: now) else {
                throw ControlError(code: .requestExpired, message: "request expired", currentProjection: entry.record.json)
            }
            guard ContentDigest.matches(entry.requestHash, requestHash) else {
                throw ControlError(code: .hashMismatch, message: "request hash does not match", currentProjection: entry.record.json)
            }
            guard entry.projection.stateVersion == expectedStateVersion else {
                throw ControlError(code: .staleVersion, message: "state version moved", currentProjection: entry.record.json)
            }
            guard entry.projection.policyVersion == policyVersion else {
                throw ControlError(code: .policyChanged, message: "policy version moved", currentProjection: entry.record.json)
            }
            expiry = min(now.adding(ApprovalPolicy.challengeLifetime), entry.spec.expiresAt)
        case .session(let sessionID, let expectedVersion, _):
            try principal.requireGrant(Self.grant(for: request.action))
            let session = try commandableSession(sessionID, principal: principal, action: request.action)
            guard session.projection.sessionVersion == expectedVersion else {
                throw ControlError(code: .staleVersion, message: "session version moved", currentProjection: session.projection.json)
            }
            expiry = now.adding(ApprovalPolicy.challengeLifetime)
        }
        let challengeID = Base64URL.encode(BrokerStore.randomBytes(32))
        agent.challenges[challengeID] = AgentChallengeRecord(
            challengeID: challengeID, accountID: principal.accountID, deviceID: deviceID,
            request: request, expiresAt: expiry
        )
        try commit()
        return AgentReviewChallenge(challengeID: challengeID, deviceID: deviceID, action: request.action, expiresAt: expiry)
    }

    static func grant(for action: AgentCommandType) -> DeviceGrant {
        switch action {
        case .inputRespond: return .agentInputsRespond
        case .agentMessage: return .agentMessagesSend
        case .turnCancel: return .agentTurnsCancel
        }
    }

    /// A session a device may command: same account, active, managed, and
    /// offering the command's feature (docs/specs/agent-relay.md 15).
    func commandableSession(_ sessionID: ControlID, principal: Principal, action: AgentCommandType) throws -> AgentSessionEntry {
        guard let session = agent.sessions[sessionID], session.accountID == principal.accountID else {
            throw ControlError(code: .notFound, message: "no such agent session")
        }
        let feature = action == .turnCancel ? AgentFeature.turnCancel : AgentFeature.messages
        guard session.projection.offers(feature) else {
            throw ControlError(code: .unsupportedOperation, message: "this session does not accept \(action.rawValue)", currentProjection: session.projection.json)
        }
        return session
    }

    // MARK: Commands

    /// `POST /v1/agent/commands`: authenticate and verify first, then look up
    /// an already-recorded result, and only then evaluate a new response. The
    /// first valid response wins (docs/specs/agent-relay.md 7.3).
    public func submitAgentCommand(principal: Principal, signedCommand: String, idempotencyKey: ControlID) throws -> (result: AgentCommandResult, isReplay: Bool) {
        guard let deviceID = principal.deviceID else {
            throw ControlError(code: .notAuthorized, message: "only devices submit commands")
        }
        let registry = devices.mapValues(\.publicJWK)
        let verified: ControlJWS.VerifiedAgentCommand
        do {
            verified = try ControlJWS.verifyAgent(compactSerialization: signedCommand) { registry[$0] }
        } catch {
            throw ControlError(code: .invalidPayload, message: "signature rejected: \(error)")
        }
        guard verified.deviceID == deviceID else {
            throw ControlError(code: .notAuthorized, message: "command is not bound to this device session")
        }
        let envelope = verified.command.envelope
        guard envelope.commandID == idempotencyKey else {
            throw ControlError(code: .invalidPayload, message: "Idempotency-Key must equal command_id")
        }
        guard envelope.audience == "shell-control:\(principal.accountID.rawValue)" else {
            throw ControlError(code: .notAuthorized, message: "audience mismatch")
        }
        let key = AgentIdempotencyRecord.key(account: principal.accountID, device: deviceID, command: envelope.commandID)
        if let existing = agent.idempotency[key] {
            guard ContentDigest.matches(existing.payloadHash, verified.payloadHash) else {
                throw ControlError(code: .idempotencyConflict, message: "command id reused with a different payload")
            }
            return (existing.result, true)
        }
        let now = timestamp
        guard now < envelope.notAfter else {
            throw ControlError(code: .challengeExpired, message: "command deadline passed")
        }
        let backup = stateBackup()
        let result: AgentCommandResult
        switch verified.command {
        case .inputRespond(let command):
            result = try recordInputResponse(command, principal: principal, jws: signedCommand)
        case .session(let command):
            result = try recordSessionCommand(command, principal: principal, jws: signedCommand)
        }
        agent.idempotency[key] = AgentIdempotencyRecord(
            accountID: principal.accountID, deviceID: deviceID, commandID: envelope.commandID,
            payloadHash: verified.payloadHash, result: result, recordedAt: now
        )
        try commit(restoring: backup)
        return (result, false)
    }

    private func recordInputResponse(_ command: InputRespondCommand, principal: Principal, jws: String) throws -> AgentCommandResult {
        try principal.requireGrant(.agentInputsRespond)
        sweepExpired()
        guard var entry = agent.inputs[command.requestID], isVisible(input: entry, to: principal) else {
            throw ControlError(code: .notFound, message: "no such input")
        }
        refreshPresence(for: &entry)
        guard let challenge = agent.challenges[command.challengeID],
              challenge.deviceID == principal.deviceID, challenge.accountID == principal.accountID,
              challenge.request.action == command.envelope.type, challenge.consumedAt == nil,
              timestamp < challenge.expiresAt else {
            throw ControlError(code: .challengeExpired, message: "challenge is not usable")
        }
        guard case .input(let requestID, let requestHash, let stateVersion, let policyVersion) = challenge.request.target,
              requestID == command.requestID,
              ContentDigest.matches(requestHash, command.requestHash),
              stateVersion == command.expectedStateVersion,
              policyVersion == command.policyVersion else {
            throw ControlError(code: .staleVersion, message: "challenge does not match this command")
        }
        guard command.envelope.notAfter <= challenge.expiresAt else {
            throw ControlError(code: .invalidPayload, message: "command outlives its challenge")
        }
        guard entry.projection.resolution == .pending else {
            throw ControlError(code: .requestResolved, message: "already resolved", currentProjection: entry.record.json)
        }
        guard !entry.spec.isExpired(at: timestamp) else {
            throw ControlError(code: .requestExpired, message: "request expired", currentProjection: entry.record.json)
        }
        guard ContentDigest.matches(entry.requestHash, command.requestHash) else {
            throw ControlError(code: .hashMismatch, message: "request hash changed", currentProjection: entry.record.json)
        }
        guard entry.projection.stateVersion == command.expectedStateVersion else {
            throw ControlError(code: .staleVersion, message: "state version changed", currentProjection: entry.record.json)
        }
        guard entry.projection.policyVersion == command.policyVersion else {
            throw ControlError(code: .policyChanged, message: "policy changed", currentProjection: entry.record.json)
        }
        do {
            try command.response.validate(against: entry.spec)
        } catch {
            throw ControlError(code: .responseInvalid, message: "\(error)")
        }
        // The review level comes from the broker's own device registration.
        let fullReview = principal.deviceID.flatMap { devices[$0] }?.isFullReviewClient ?? false
        guard fullReview || (entry.spec.permitsWatchReview && entry.projection.watchReviewAllowed) else {
            throw ControlError(code: .fullReviewRequired, message: "this question needs fuller review")
        }
        // An answer needs the live native wait; a decline, like a reject,
        // is safe to record while the source is briefly unreachable.
        if case .answer = command.response, !entry.projection.presence.isFresh(at: timestamp) {
            throw ControlError(code: .originUnavailable, message: "the waiting agent is not present")
        }

        agent.challenges[challenge.challengeID]?.consumedAt = timestamp
        let responseID = ControlID.random()
        entry.projection.resolution = command.response.action == .answer ? .answered : .declined
        entry.projection.dispatch = .awaitingOrigin
        entry.projection.responseID = responseID
        entry.projection.commandID = command.envelope.commandID
        entry.projection.respondedByDeviceID = principal.deviceID
        entry.projection.respondedAt = timestamp
        entry.projection.stateVersion += 1
        entry.response = command.response
        entry.responseHash = command.response.responseHash
        entry.commandJWS = jws
        entry.commandNotAfter = command.envelope.notAfter
        agent.inputs[command.requestID] = entry
        agent.inputTombstones[command.requestID] = entry.requestHash
        appendAgent(.requestResolved, resourceID: command.requestID, version: entry.projection.stateVersion,
                    projection: entry.record.json, accountID: entry.accountID, originID: entry.spec.originID)
        return AgentCommandResult(
            recorded: true, commandID: command.envelope.commandID, requestID: command.requestID,
            responseID: responseID, stateVersion: entry.projection.stateVersion,
            resolution: entry.projection.resolution, dispatch: entry.projection.dispatch, serverTime: timestamp
        )
    }

    /// `GET /v1/agent/commands/{id}`: only the submitting device may read it.
    public func agentCommandResult(_ commandID: ControlID, principal: Principal) throws -> AgentCommandResult {
        guard let deviceID = principal.deviceID,
              let record = agent.idempotency[AgentIdempotencyRecord.key(account: principal.accountID, device: deviceID, command: commandID)]
        else {
            throw ControlError(code: .notFound, message: "no such command")
        }
        if let command = agent.sessionCommands[commandID] {
            return AgentCommandResult(
                recorded: record.result.recorded, commandID: commandID, stateVersion: command.record.version,
                dispatch: command.record.dispatch, serverTime: timestamp
            )
        }
        guard let requestID = record.result.requestID, let entry = agent.inputs[requestID] else { return record.result }
        // The recorded result, with the current dispatch alongside it.
        return AgentCommandResult(
            recorded: record.result.recorded, commandID: record.result.commandID, requestID: requestID,
            responseID: record.result.responseID, stateVersion: entry.projection.stateVersion,
            resolution: record.result.resolution, dispatch: entry.projection.dispatch, serverTime: timestamp
        )
    }
}

extension CursorCodec {
    /// The agent feed has its own cursor namespace and tag domain, so a base
    /// cursor never reads the agent feed and an agent cursor never reads the
    /// base feed (docs/specs/agent-relay.md 14.6).
    static func encodeAgentCursor(sequence: LogSequence, principal: Principal, secret: Data) -> ChangeCursor {
        let base = encodeCursor(sequence: sequence, principal: principal, secret: agentSecret(secret))
        return ChangeCursor("a1" + base.rawValue.dropFirst(2))
    }

    static func decodeAgentCursor(_ cursor: ChangeCursor, principal: Principal, secret: Data) throws -> LogSequence {
        guard cursor.rawValue.hasPrefix("a1.") else { throw ControlError(code: .cursorExpired, message: "not an agent cursor") }
        return try decodeCursor(ChangeCursor("c1" + cursor.rawValue.dropFirst(2)), principal: principal, secret: agentSecret(secret))
    }

    static func encodeAgentSnapshotToken(sequence: LogSequence, principal: Principal, secret: Data) -> String {
        "as1" + encodeSnapshotToken(sequence: sequence, principal: principal, secret: agentSecret(secret)).dropFirst(2)
    }

    static func decodeAgentSnapshotToken(_ token: String, principal: Principal, secret: Data) throws -> LogSequence {
        guard token.hasPrefix("as1.") else { throw ControlError(code: .cursorExpired, message: "not an agent snapshot token") }
        return try decodeSnapshotToken("s1" + token.dropFirst(3), principal: principal, secret: agentSecret(secret))
    }

    /// A distinct key per namespace: the same sequence number in the base
    /// feed and the agent feed yields unrelated tags.
    private static func agentSecret(_ secret: Data) -> Data {
        var material = Data("shell-agent/1 cursor:".utf8)
        material.append(secret)
        return Data(ContentDigest.sha256Hex(material).utf8)
    }
}
