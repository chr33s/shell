import Foundation
import CryptoKit
import ShellControlProtocol
import ShellControlSecurity

extension BrokerStore {
    /// `POST /v1/review-challenges`: a one-use, device-bound challenge for an
    /// exact target, action, hash, and versions. The broker rejects stale
    /// preconditions rather than issuing a challenge against a moved target
    /// (spec.watch.md section 11).
    public func createChallenge(principal: Principal, request: ReviewChallengeRequest) throws -> ReviewChallenge {
        sweepExpired()
        guard let deviceID = principal.deviceID else {
            throw ControlError(code: .notAuthorized, message: "only devices request challenges")
        }
        let now = timestamp
        var expiry = now.adding(ApprovalPolicy.challengeLifetime)

        switch request.target {
        case .approval(let requestID, let requestHash, let expectedStateVersion, let expectedPolicyVersion):
            try principal.requireGrant(.approvalsDecide)
            guard var entry = approvals[requestID], isVisible(approval: entry, to: principal) else {
                throw ControlError(code: .notFound, message: "no such request")
            }
            refreshPresence(for: &entry)
            approvals[requestID] = entry
            // Resolution and expiry are reported before a version mismatch, so
            // a client that is merely behind is told what actually happened.
            guard entry.projection.resolution == .pending else {
                throw ControlError(code: .alreadyResolved, message: "already resolved", currentProjection: entry.record.json)
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
            guard entry.projection.policyVersion == expectedPolicyVersion else {
                throw ControlError(code: .policyChanged, message: "policy version moved", currentProjection: entry.record.json)
            }
            // A challenge never outlives the approval deadline.
            expiry = min(expiry, entry.spec.expiresAt)
        case .job(let jobID, let runID, let expectedJobVersion):
            try principal.requireGrant(.jobsCancel)
            guard let run = runs[runID], run.jobID == jobID,
                  origins[run.originID]?.accountID == principal.accountID
            else {
                throw ControlError(code: .notFound, message: "no such run")
            }
            guard run.jobVersion == expectedJobVersion else {
                throw ControlError(code: .staleVersion, message: "job version moved")
            }
        }

        // 256 bits of server randomness, bound to this device and target.
        var bytes = Data(count: 32)
        bytes.withUnsafeMutableBytes { buffer in
            for index in 0..<buffer.count { buffer[index] = UInt8.random(in: 0...255) }
        }
        let challengeID = Base64URL.encode(bytes)
        challenges[challengeID] = ChallengeRecord(
            challengeID: challengeID,
            accountID: principal.accountID,
            deviceID: deviceID,
            action: request.action,
            request: request,
            expiresAt: expiry
        )
        try commit()
        return ReviewChallenge(challengeID: challengeID, deviceID: deviceID, action: request.action, expiresAt: expiry)
    }

    /// `POST /v1/commands`: verify, then look for an already-recorded result,
    /// and only then evaluate preconditions for a new operation
    /// (spec.watch.md section 8).
    public func submitCommand(
        principal: Principal,
        signedCommand: String,
        idempotencyKey: ControlID
    ) throws -> (result: CommandResult, isReplay: Bool) {
        guard let deviceID = principal.deviceID else {
            throw ControlError(code: .notAuthorized, message: "only devices submit commands")
        }
        // The registry is read here, inside the actor, so signature verification
        // stays synchronous and cannot observe a half-applied mutation.
        let registry = devices.mapValues(\.publicJWK)
        let verified: ControlJWS.VerifiedCommand
        do {
            verified = try ControlJWS.verify(compactSerialization: signedCommand) { registry[$0] }
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

        // Recorded results come before expiry checks, so a legitimate retry
        // after expiry retrieves the outcome without re-executing anything.
        let key = BrokerStore.idempotencyKey(account: principal.accountID, device: deviceID, command: envelope.commandID)
        if let existing = idempotency[key] {
            guard ContentDigest.matches(existing.payloadHash, verified.payloadHash) else {
                throw ControlError(code: .idempotencyConflict, message: "command id reused with a different payload")
            }
            return (existing.result, true)
        }

        // The broker is authoritative for deadline checks: device clock skew
        // cannot extend authorization (spec.watch.md section 16).
        let now = timestamp
        guard now < envelope.notAfter else {
            throw ControlError(code: .challengeExpired, message: "command deadline passed")
        }

        let result: CommandResult
        switch verified.command {
        case .approvalDecide(let command):
            result = try recordDecision(command, principal: principal, jws: signedCommand, payloadHash: verified.payloadHash)
        case .notificationAck(let command):
            result = try recordAcknowledgement(command, principal: principal)
        case .jobCancel(let command):
            result = try recordJobCancellation(command, principal: principal)
        case .handoffRequest:
            // A handoff hint authorizes nothing and mutates no ledger state.
            result = CommandResult(recorded: true, commandID: envelope.commandID, serverTime: now)
        }

        idempotency[key] = IdempotencyRecord(
            accountID: principal.accountID,
            deviceID: deviceID,
            commandID: envelope.commandID,
            payloadHash: verified.payloadHash,
            result: result,
            recordedAt: now
        )
        try commit()
        return (result, false)
    }

    private func consumeChallenge(_ challengeID: String, principal: Principal, action: ControlCommandType) throws -> ChallengeRecord {
        guard let challenge = challenges[challengeID],
              challenge.deviceID == principal.deviceID,
              challenge.accountID == principal.accountID,
              challenge.action == action
        else {
            throw ControlError(code: .challengeExpired, message: "challenge is not usable")
        }
        guard challenge.consumedAt == nil else {
            throw ControlError(code: .challengeExpired, message: "challenge already used")
        }
        guard timestamp < challenge.expiresAt else {
            throw ControlError(code: .challengeExpired, message: "challenge expired")
        }
        return challenge
    }

    private func recordDecision(
        _ command: ApprovalDecideCommand,
        principal: Principal,
        jws: String,
        payloadHash: String
    ) throws -> CommandResult {
        try principal.requireGrant(.approvalsDecide)
        sweepExpired()
        guard var entry = approvals[command.requestID], isVisible(approval: entry, to: principal) else {
            throw ControlError(code: .notFound, message: "no such request")
        }
        refreshPresence(for: &entry)
        let challenge = try consumeChallenge(command.challengeID, principal: principal, action: .approvalDecide)
        guard case .approval(let target, let targetHash, let targetState, let targetPolicy) = challenge.request.target,
              target == command.requestID,
              ContentDigest.matches(targetHash, command.requestHash),
              targetState == command.expectedStateVersion,
              targetPolicy == command.policyVersion
        else {
            throw ControlError(code: .staleVersion, message: "challenge does not match this command")
        }
        // Exactly one pending-resolution transition: a racing second device
        // sees the recorded decision instead (spec.watch.md section 19).
        guard entry.projection.resolution == .pending else {
            throw ControlError(code: .alreadyResolved, message: "already resolved", currentProjection: entry.record.json)
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
        guard entry.spec.allowedDecisions.contains(command.decision) else {
            throw ControlError(code: .notAuthorized, message: "decision not allowed for this request")
        }
        if command.decision == .approve {
            guard entry.spec.minimumReview == .watch, entry.projection.watchReviewAllowed else {
                throw ControlError(code: .fullReviewRequired, message: "this request needs fuller review")
            }
            // Approve requires fresh source presence; Reject does not.
            guard entry.projection.presence.isFresh(at: timestamp) else {
                throw ControlError(code: .originUnavailable, message: "the waiting run is not present")
            }
        }

        challenges[challenge.challengeID]?.consumedAt = timestamp
        let decisionID = ControlID.random()
        entry.projection.resolution = command.decision == .approve ? .approved : .rejected
        entry.projection.dispatch = .awaitingOrigin
        entry.projection.decisionID = decisionID
        entry.projection.decidedByDeviceID = principal.deviceID
        entry.projection.decidedAt = timestamp
        entry.projection.stateVersion += 1
        entry.decisionJWS = jws
        approvals[command.requestID] = entry
        tombstones[command.requestID] = Tombstone(
            requestID: command.requestID,
            requestHash: entry.requestHash,
            resolution: entry.projection.resolution,
            consumedBy: nil
        )
        append(
            .approvalResolved,
            resourceID: command.requestID,
            version: entry.projection.stateVersion,
            projection: entry.record.json,
            accountID: entry.accountID,
            originID: entry.spec.originID
        )
        return CommandResult(
            recorded: true,
            commandID: command.envelope.commandID,
            decisionID: decisionID,
            requestID: command.requestID,
            stateVersion: entry.projection.stateVersion,
            resolution: entry.projection.resolution,
            dispatch: entry.projection.dispatch,
            serverTime: timestamp
        )
    }

    private func recordAcknowledgement(_ command: NotificationAckCommand, principal: Principal) throws -> CommandResult {
        try principal.requireGrant(.notificationsAck)
        guard var event = notifications[command.notificationID],
              notificationAccounts[command.notificationID] == principal.accountID
        else {
            throw ControlError(code: .notFound, message: "no such notification")
        }
        if event.acknowledgedAt == nil {
            event.acknowledgedAt = timestamp
            notifications[command.notificationID] = event
            append(
                .notificationAcknowledged,
                resourceID: command.notificationID,
                version: 2,
                projection: event.json,
                accountID: principal.accountID,
                originID: event.originID
            )
        }
        return CommandResult(recorded: true, commandID: command.envelope.commandID, serverTime: timestamp)
    }

    /// Cancellation is marked requested and pending/unconsumed approvals are
    /// invalidated in the same transaction (spec.watch.md section 13).
    private func recordJobCancellation(_ command: JobCancelCommand, principal: Principal) throws -> CommandResult {
        try principal.requireGrant(.jobsCancel)
        sweepExpired()
        let challenge = try consumeChallenge(command.challengeID, principal: principal, action: .jobCancel)
        guard case .job(let jobID, let runID, let jobVersion) = challenge.request.target,
              jobID == command.jobID, runID == command.runID, jobVersion == command.expectedJobVersion
        else {
            throw ControlError(code: .staleVersion, message: "challenge does not match this command")
        }
        guard var run = runs[command.runID], run.jobID == command.jobID,
              origins[run.originID]?.accountID == principal.accountID
        else {
            throw ControlError(code: .notFound, message: "no such run")
        }
        guard run.jobVersion == command.expectedJobVersion else {
            throw ControlError(code: .staleVersion, message: "job version moved")
        }
        challenges[challenge.challengeID]?.consumedAt = timestamp
        run.cancellationRequestedAt = timestamp
        run.jobState = .cancellationRequested
        run.jobVersion += 1
        runs[command.runID] = run

        for (id, var entry) in approvals where entry.spec.runID == command.runID {
            if entry.projection.resolution == .pending {
                entry.projection.resolution = .cancelled
                entry.projection.stateVersion += 1
                approvals[id] = entry
                append(.approvalResolved, resourceID: id, version: entry.projection.stateVersion, projection: entry.record.json, accountID: entry.accountID, originID: entry.spec.originID)
            } else if entry.projection.resolution == .approved,
                      entry.projection.dispatch == .awaitingOrigin,
                      entry.consumedBy == nil
            {
                // An unconsumed approval loses its grant; one already claimed is
                // left alone, because cancellation is best effort and must not
                // claim it prevented execution.
                entry.projection.dispatch = .notApplied
                entry.projection.stateVersion += 1
                approvals[id] = entry
                append(.approvalDispatchUpdated, resourceID: id, version: entry.projection.stateVersion, projection: entry.record.json, accountID: entry.accountID, originID: entry.spec.originID)
            }
        }
        append(
            .jobUpdated,
            resourceID: command.jobID,
            version: run.jobVersion,
            projection: .object([
                "job_id": JSONValue(command.jobID),
                "run_id": JSONValue(command.runID),
                "state": .string(run.jobState.rawValue),
                "job_version": .number(.int(run.jobVersion)),
            ]),
            accountID: principal.accountID,
            originID: run.originID
        )
        return CommandResult(recorded: true, commandID: command.envelope.commandID, serverTime: timestamp)
    }
}
