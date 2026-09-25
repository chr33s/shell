import Foundation
import ShellControlProtocol

/// Managed-session commands: new instructions, steering, and cancellation
/// (spec.agent-relay.md section 16). Each is signed against the exact action
/// digest the device committed in its challenge, recorded once, and claimed at
/// most once by the session's origin; a stale session version, a busy or idle
/// mismatch, or a changed turn refuses it rather than queueing it.
extension BrokerStore {
    func recordSessionCommand(_ command: AgentSessionCommand, principal: Principal, jws: String) throws -> AgentCommandResult {
        try principal.requireGrant(Self.grant(for: command.envelope.type))
        sweepExpired()
        let action = command.action
        guard let challenge = agent.challenges[command.challengeID],
              challenge.deviceID == principal.deviceID, challenge.accountID == principal.accountID,
              challenge.request.action == command.envelope.type, challenge.consumedAt == nil,
              timestamp < challenge.expiresAt else {
            throw ControlError(code: .challengeExpired, message: "challenge is not usable")
        }
        // The challenge committed the action digest before signing; the
        // signed action must be exactly that action.
        guard case .session(let sessionID, let version, let digest) = challenge.request.target,
              sessionID == action.agentSessionID, version == action.expectedSessionVersion,
              ContentDigest.matches(digest, command.actionDigest) else {
            throw ControlError(code: .staleVersion, message: "challenge does not match this command")
        }
        guard command.envelope.notAfter <= challenge.expiresAt else {
            throw ControlError(code: .invalidPayload, message: "command outlives its challenge")
        }
        var session = try commandableSession(sessionID, principal: principal, action: command.envelope.type)
        let projection = session.projection
        guard projection.sessionVersion == action.expectedSessionVersion else {
            throw ControlError(code: .staleVersion, message: "session version changed", currentProjection: projection.json)
        }
        guard projection.registration.runID == action.runID else {
            throw ControlError(code: .nativeContextChanged, message: "the session's run changed", currentProjection: projection.json)
        }
        switch action {
        case .message(_, _, _, .newTurn, _, _):
            guard projection.turnState == .idle else {
                throw ControlError(code: .staleVersion, message: "a turn is already running", currentProjection: projection.json)
            }
        case .message(_, _, _, .steer, let expectedTurnID, _):
            guard projection.turnState == .active, projection.activeTurnID == expectedTurnID else {
                throw ControlError(code: .staleVersion, message: "the active turn changed", currentProjection: projection.json)
            }
        case .cancel(_, _, _, let turnID):
            guard projection.turnState == .active, projection.activeTurnID == turnID else {
                throw ControlError(code: .staleVersion, message: "the turn is no longer active", currentProjection: projection.json)
            }
        }
        agent.challenges[challenge.challengeID]?.consumedAt = timestamp
        // Recording moves the session version, so a racing second command
        // against the same state is refused instead of queued.
        session.projection.sessionVersion += 1
        agent.sessions[sessionID] = session
        let record = AgentSessionCommandRecord(
            commandID: command.envelope.commandID, action: action, deviceID: principal.deviceID ?? .random(),
            recordedAt: timestamp, notAfter: command.envelope.notAfter
        )
        agent.sessionCommands[record.commandID] = SessionCommandEntry(
            accountID: principal.accountID, originID: session.originID, record: record, commandJWS: jws, permit: nil
        )
        appendAgent(.deliveryUpdated, resourceID: record.commandID, version: record.version, projection: record.json,
                    accountID: principal.accountID, originID: session.originID)
        appendAgent(.statusChanged, resourceID: sessionID, version: session.projection.sessionVersion,
                    projection: session.projection.json, accountID: principal.accountID, originID: session.originID)
        return AgentCommandResult(
            recorded: true, commandID: record.commandID, stateVersion: record.version,
            dispatch: record.dispatch, serverTime: timestamp
        )
    }

    /// `GET /v1/agent/sessions/{id}/commands`: the origin's unclaimed
    /// commands for its session, oldest first.
    public func pendingSessionCommands(principal: Principal, sessionID: ControlID) throws -> [AgentSessionCommandRecord] {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins read session commands")
        }
        sweepExpired()
        guard let session = agent.sessions[sessionID], session.originID == originID else {
            throw ControlError(code: .notFound, message: "no such agent session")
        }
        return agent.sessionCommands.values
            .filter { $0.originID == originID && $0.record.action.agentSessionID == sessionID && $0.record.dispatch == .awaitingOrigin }
            .map(\.record)
            .sorted { $0.recordedAt == $1.recordedAt ? $0.commandID.rawValue < $1.commandID.rawValue : $0.recordedAt < $1.recordedAt }
    }

    /// `POST /v1/agent/sessions/{id}/commands/{command}/claim`: one claim per
    /// command, for one connection, never past the signed deadline. The same
    /// mutation returns the same permit.
    public func claimSessionCommand(principal: Principal, sessionID: ControlID, request: AgentSessionClaimRequest) throws -> AgentSessionPermit {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins claim session commands")
        }
        sweepExpired()
        guard var entry = agent.sessionCommands[request.commandID], entry.originID == originID,
              entry.record.action.agentSessionID == sessionID else {
            throw ControlError(code: .notFound, message: "no such session command")
        }
        if let permit = entry.permit {
            guard permit.mutationID == request.mutationID else {
                throw ControlError(code: .alreadyClaimed, message: "the command was already claimed")
            }
            return permit
        }
        guard ContentDigest.matches(entry.record.actionDigest, request.actionDigest) else {
            throw ControlError(code: .hashMismatch, message: "claim describes another action")
        }
        guard entry.record.dispatch == .awaitingOrigin else {
            throw ControlError(code: .requestResolved, message: "the command is no longer available", currentProjection: entry.record.json)
        }
        guard let session = agent.sessions[sessionID], session.projection.state == .active else {
            throw ControlError(code: .nativeWaitGone, message: "the session has ended")
        }
        if devices[entry.record.deviceID]?.isRevoked ?? true {
            throw ControlError(code: .deviceRevoked, message: "the sending device was revoked")
        }
        let now = timestamp
        let applyBefore = min(now.adding(ApprovalPolicy.permitLifetime), entry.record.notAfter)
        guard now < applyBefore else {
            throw ControlError(code: .requestExpired, message: "the command deadline passed")
        }
        let backup = stateBackup()
        let permit = AgentSessionPermit(
            permitID: .random(), mutationID: request.mutationID, commandID: request.commandID,
            connectionEpoch: request.connectionEpoch, action: entry.record.action, commandJWS: entry.commandJWS,
            issuedAt: now, applyBefore: applyBefore
        )
        entry.permit = permit
        entry.record.dispatch = .claimed
        entry.record.version += 1
        agent.sessionCommands[request.commandID] = entry
        agent.mutations[AgentMutationRecord.key(.sessionClaim, originID: originID, mutationID: request.mutationID)] = AgentMutationRecord(
            kind: .sessionClaim, originID: originID, mutationID: request.mutationID,
            bodyHash: try ContentDigest.digest(ofCanonical: request.json), result: permit.json, recordedAt: now
        )
        appendAgent(.deliveryUpdated, resourceID: request.commandID, version: entry.record.version, projection: entry.record.json,
                    accountID: entry.accountID, originID: originID)
        try commit(restoring: backup)
        return permit
    }

    /// Delivery of a session command: `accepted` needs the provider's own
    /// correlated acceptance (its RPC result), never a later terminal screen.
    func applySessionCommandReceipt(_ receipt: AgentDeliveryReceipt, originID: ControlID) throws {
        guard var entry = agent.sessionCommands[receipt.requestID], entry.originID == originID else {
            throw ControlError(code: .notFound, message: "no such session command")
        }
        guard let permit = entry.permit, receipt.permitID == permit.permitID,
              receipt.nativeWaitID == permit.connectionEpoch,
              ContentDigest.matches(receipt.requestHash, entry.record.actionDigest),
              entry.record.action.runID == receipt.runID else {
            throw ControlError(code: .notAuthorized, message: "receipt does not match the recorded claim")
        }
        guard entry.record.dispatch.canTransition(to: receipt.dispatch) else {
            throw ControlError(code: .alreadyResolved,
                               message: "dispatch cannot move from \(entry.record.dispatch.rawValue) to \(receipt.dispatch.rawValue)")
        }
        entry.record.dispatch = receipt.dispatch
        entry.record.evidence = receipt.evidence
        entry.record.version += 1
        agent.sessionCommands[receipt.requestID] = entry
        appendAgent(.deliveryUpdated, resourceID: receipt.requestID, version: entry.record.version, projection: entry.record.json,
                    accountID: entry.accountID, originID: originID)
    }

    /// Recent session commands a device may see, for its outcome views.
    func visibleSessionCommands(to principal: Principal) -> [AgentSessionCommandRecord] {
        agent.sessionCommands.values
            .filter { $0.accountID == principal.accountID }
            .filter { entry in
                if case .origin(let originID, _) = principal { return entry.originID == originID }
                return true
            }
            .map(\.record)
    }
}
