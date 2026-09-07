import Foundation
import ShellControlProtocol

extension BrokerStore {
    /// `PUT /v1/origins/me/runs/{run_id}`: exact replacement semantics for a
    /// run registration (spec.watch.md section 10).
    public func registerRun(principal: Principal, registration: RunRegistration) throws {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins register runs")
        }
        if let existing = runs[registration.runID], existing.originID != originID {
            throw ControlError(code: .notAuthorized, message: "run belongs to another origin")
        }
        var run = runs[registration.runID] ?? RunRecord(
            runID: registration.runID,
            originID: originID,
            jobID: registration.jobID,
            registration: registration
        )
        run.registration = registration
        run.lastSeenAt = timestamp
        runs[registration.runID] = run
        append(
            .jobUpdated,
            resourceID: registration.jobID,
            version: run.jobVersion,
            projection: .object([
                "job_id": JSONValue(registration.jobID),
                "run_id": JSONValue(registration.runID),
                "state": .string(run.jobState.rawValue),
                "job_version": .number(.int(run.jobVersion)),
            ]),
            accountID: principal.accountID,
            originID: originID
        )
        try commit()
    }

    /// `POST /v1/origins/me/heartbeat`: replaceable presence observations, not
    /// authorizations (spec.watch.md section 10).
    public func heartbeat(principal: Principal, runIDs: [ControlID], waitingRequestIDs: [ControlID]) throws {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins send heartbeats")
        }
        let now = timestamp
        for runID in runIDs {
            guard var run = runs[runID], run.originID == originID else { continue }
            run.lastSeenAt = now
            run.waitingRequestIDs = Set(waitingRequestIDs.filter { approvals[$0]?.spec.runID == runID })
            runs[runID] = run
            append(
                .originPresenceChanged,
                resourceID: runID,
                version: Int64(now.date.timeIntervalSince1970),
                projection: .object([
                    "run_id": JSONValue(runID),
                    "last_seen_at": JSONValue(now),
                    "waiting": .bool(!run.waitingRequestIDs.isEmpty),
                ]),
                accountID: principal.accountID,
                originID: originID
            )
        }
        try commit()
    }

    /// `POST /v1/notifications`: idempotent by event ID and body hash
    /// (spec.watch.md section 10).
    public func createNotification(principal: Principal, event: InformationalEvent) throws -> InformationalEvent {
        guard let originID = principal.originID, event.originID == originID else {
            throw ControlError(code: .notAuthorized, message: "origins create only their own events")
        }
        let key = "notify|\(originID.rawValue)|\(event.eventID.rawValue)"
        let bodyHash = try event.bodyHash()
        if let existing = originMutations[key] {
            guard ContentDigest.matches(existing.bodyHash, bodyHash) else {
                throw ControlError(code: .idempotencyConflict, message: "event id reused with a different body")
            }
            return notifications[event.eventID] ?? event
        }
        // The event is persisted before any APNs attempt.
        notifications[event.eventID] = event
        notificationAccounts[event.eventID] = principal.accountID
        itemSequences[event.eventID] = nextSequence
        originMutations[key] = OriginMutationRecord(
            originID: originID,
            mutationID: event.eventID,
            bodyHash: bodyHash,
            result: event.json
        )
        append(
            .notificationCreated,
            resourceID: event.eventID,
            version: 1,
            projection: event.json,
            accountID: principal.accountID,
            originID: originID
        )
        try commit()
        enqueuePushes(accountID: principal.accountID, event: event)
        return event
    }

    /// `POST /v1/approvals`: the same request ID and hash returns the existing
    /// record; a different hash conflicts (spec.watch.md section 10).
    public func createApproval(principal: Principal, spec: ApprovalSpec) throws -> ApprovalRecord {
        guard let originID = principal.originID, spec.originID == originID else {
            throw ControlError(code: .notAuthorized, message: "origins create only their own requests")
        }
        let hash = try spec.requestHash()
        if let existing = approvals[spec.requestID] {
            guard ContentDigest.matches(existing.requestHash, hash) else {
                throw ControlError(code: .idempotencyConflict, message: "request id reused with a different spec")
            }
            return existing.record
        }
        if let tombstone = tombstones[spec.requestID] {
            // A purged-but-decided request cannot be recreated under its old ID.
            guard ContentDigest.matches(tombstone.requestHash, hash) else {
                throw ControlError(code: .idempotencyConflict, message: "request id was already used")
            }
            throw ControlError(code: .alreadyResolved, message: "request id was already resolved")
        }
        guard let run = runs[spec.runID], run.originID == originID, run.jobID == spec.jobID else {
            throw ControlError(code: .invalidPayload, message: "run is not registered for this origin and job")
        }
        guard run.cancellationRequestedAt == nil else {
            throw ControlError(code: .alreadyResolved, message: "job cancellation was requested")
        }
        var entry = ApprovalRecordEntry(
            spec: spec,
            requestHash: hash,
            accountID: principal.accountID,
            projection: ApprovalProjection(stateVersion: 1, policyVersion: policyVersion)
        )
        refreshPresence(for: &entry)
        approvals[spec.requestID] = entry
        itemSequences[spec.requestID] = nextSequence
        append(
            .approvalCreated,
            resourceID: spec.requestID,
            version: 1,
            projection: entry.record.json,
            accountID: principal.accountID,
            originID: originID
        )
        try commit()
        enqueueApprovalPushes(accountID: principal.accountID, spec: spec)
        return entry.record
    }

    /// `POST /v1/approvals/{id}/withdraw`.
    ///
    /// Withdrawal after approval preserves the historic `approved` resolution
    /// but marks an unconsumed dispatch `not_applied`; if consumption already
    /// won the race it reports `already_claimed`
    /// (spec.watch.md section 12).
    public func withdrawApproval(
        principal: Principal,
        requestID: ControlID,
        mutationID: ControlID,
        runID: ControlID,
        requestHash: String
    ) throws -> ApprovalRecord {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins withdraw requests")
        }
        sweepExpired()
        guard var entry = approvals[requestID], entry.spec.originID == originID else {
            throw ControlError(code: .notFound, message: "no such request")
        }
        guard entry.spec.runID == runID, ContentDigest.matches(entry.requestHash, requestHash) else {
            throw ControlError(code: .hashMismatch, message: "withdrawal describes another run or hash")
        }
        let key = "withdraw|\(originID.rawValue)|\(mutationID.rawValue)"
        if let existing = originMutations[key] {
            return (try? ApprovalRecord(json: existing.result)) ?? entry.record
        }
        if entry.projection.resolution == .approved, entry.consumedBy != nil {
            throw ControlError(code: .alreadyClaimed, message: "approval was already claimed", currentProjection: entry.record.json)
        }
        switch entry.projection.resolution {
        case .pending:
            entry.projection.resolution = .cancelled
            entry.projection.dispatch = .notApplied
        case .approved:
            entry.projection.dispatch = .notApplied
        case .rejected, .cancelled, .expired:
            break
        }
        entry.withdrawnAt = timestamp
        entry.projection.stateVersion += 1
        approvals[requestID] = entry
        originMutations[key] = OriginMutationRecord(
            originID: originID,
            mutationID: mutationID,
            bodyHash: requestHash,
            result: entry.record.json
        )
        append(
            .approvalResolved,
            resourceID: requestID,
            version: entry.projection.stateVersion,
            projection: entry.record.json,
            accountID: entry.accountID,
            originID: originID
        )
        try commit()
        return entry.record
    }

    /// `POST /v1/approvals/{id}/consume`.
    ///
    /// Only one consume ID may claim an approved request; retrying the same ID
    /// returns the same permit and deadline, and a new ID cannot obtain a
    /// second grant (spec.watch.md section 12).
    public func consumeApproval(principal: Principal, requestID: ControlID, request: ConsumeRequest) throws -> ConsumePermit {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins consume approvals")
        }
        sweepExpired()
        guard var entry = approvals[requestID], entry.spec.originID == originID else {
            throw ControlError(code: .notFound, message: "no such request")
        }
        if let permit = entry.permit, entry.consumedBy == request.consumeID {
            return permit
        }
        guard entry.consumedBy == nil else {
            throw ControlError(code: .alreadyClaimed, message: "approval was already claimed", currentProjection: entry.record.json)
        }
        guard entry.projection.resolution == .approved else {
            throw ControlError(code: .alreadyResolved, message: "request is not approved", currentProjection: entry.record.json)
        }
        guard entry.projection.decisionID == request.decisionID else {
            throw ControlError(code: .notFound, message: "decision does not belong to this request")
        }
        guard ContentDigest.matches(entry.requestHash, request.requestHash), entry.spec.runID == request.runID else {
            throw ControlError(code: .hashMismatch, message: "consume describes another run or hash")
        }
        guard entry.withdrawnAt == nil, entry.projection.dispatch == .awaitingOrigin else {
            throw ControlError(code: .alreadyResolved, message: "grant is no longer available", currentProjection: entry.record.json)
        }
        guard let run = runs[entry.spec.runID], run.cancellationRequestedAt == nil else {
            throw ControlError(code: .alreadyResolved, message: "job cancellation was requested")
        }
        // A device revoked after the decision but before consumption cannot
        // have its grant consumed (spec.watch.md section 19).
        if let deciding = entry.projection.decidedByDeviceID, devices[deciding]?.isRevoked ?? true {
            throw ControlError(code: .deviceRevoked, message: "the deciding device was revoked")
        }
        guard !entry.spec.isExpired(at: timestamp) else {
            throw ControlError(code: .requestExpired, message: "request expired", currentProjection: entry.record.json)
        }
        guard let jws = entry.decisionJWS else {
            throw ControlError(code: .notFound, message: "no recorded decision")
        }
        let applyBefore = min(timestamp.adding(ApprovalPolicy.permitLifetime), entry.spec.expiresAt)
        let permit = ConsumePermit(
            consumeID: request.consumeID,
            decisionID: request.decisionID,
            originID: originID,
            runID: request.runID,
            requestHash: entry.requestHash,
            applyBefore: applyBefore,
            decision: .approve,
            decisionJWS: jws
        )
        entry.consumedBy = request.consumeID
        entry.permit = permit
        entry.projection.dispatch = .claimed
        entry.projection.stateVersion += 1
        approvals[requestID] = entry
        tombstones[requestID] = Tombstone(
            requestID: requestID,
            requestHash: entry.requestHash,
            resolution: entry.projection.resolution,
            consumedBy: request.consumeID
        )
        append(
            .approvalDispatchUpdated,
            resourceID: requestID,
            version: entry.projection.stateVersion,
            projection: entry.record.json,
            accountID: entry.accountID,
            originID: originID
        )
        try commit()
        return permit
    }

    /// `POST /v1/receipts`: validated transitions, applied once, and rejected
    /// if they describe another run or hash (spec.watch.md section 12).
    public func recordReceipt(principal: Principal, receipt: Receipt) throws {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins report receipts")
        }
        guard !receipts.contains(receipt.receiptID) else { return }
        guard let run = runs[receipt.runID], run.originID == originID else {
            throw ControlError(code: .notFound, message: "no such run")
        }

        if let jobID = receipt.jobID, receipt.decisionID == nil {
            // A job-cancel receipt binds the command and job/run identity.
            guard run.jobID == jobID else {
                throw ControlError(code: .hashMismatch, message: "receipt describes another job")
            }
            var updated = run
            if let stateText = receipt.jobState, let state = JobState(rawValue: stateText) {
                updated.jobState = state
            }
            updated.jobVersion += 1
            runs[receipt.runID] = updated
            receipts.insert(receipt.receiptID)
            append(
                .jobUpdated,
                resourceID: jobID,
                version: updated.jobVersion,
                projection: .object([
                    "job_id": JSONValue(jobID),
                    "run_id": JSONValue(receipt.runID),
                    "state": .string(updated.jobState.rawValue),
                    "job_version": .number(.int(updated.jobVersion)),
                ]),
                accountID: principal.accountID,
                originID: originID
            )
            try commit()
            return
        }

        guard let decisionID = receipt.decisionID,
              var entry = approvals.values.first(where: { $0.projection.decisionID == decisionID }),
              entry.spec.originID == originID
        else {
            throw ControlError(code: .notFound, message: "no such decision")
        }
        guard entry.spec.runID == receipt.runID else {
            throw ControlError(code: .hashMismatch, message: "receipt describes another run")
        }
        if let hash = receipt.requestHash, !ContentDigest.matches(entry.requestHash, hash) {
            throw ControlError(code: .hashMismatch, message: "receipt describes another request hash")
        }
        if entry.projection.resolution == .approved {
            guard let consumeID = receipt.consumeID, entry.consumedBy == consumeID else {
                throw ControlError(code: .notAuthorized, message: "receipt does not match the recorded claim")
            }
        } else if entry.projection.resolution == .rejected {
            // Rejection receipts carry no consume ID.
            guard receipt.consumeID == nil else {
                throw ControlError(code: .invalidPayload, message: "a rejection receipt carries no consume id")
            }
        }
        let next: Dispatch
        switch receipt.result {
        case .applied: next = .applied
        case .notApplied: next = .notApplied
        case .unknown: next = .unknown
        }
        guard entry.projection.dispatch.canTransition(to: next) else {
            throw ControlError(
                code: .alreadyResolved,
                message: "dispatch cannot move from \(entry.projection.dispatch.rawValue) to \(next.rawValue)",
                currentProjection: entry.record.json
            )
        }
        entry.projection.dispatch = next
        entry.projection.stateVersion += 1
        entry.receiptID = receipt.receiptID
        approvals[entry.spec.requestID] = entry
        receipts.insert(receipt.receiptID)
        append(
            .approvalDispatchUpdated,
            resourceID: entry.spec.requestID,
            version: entry.projection.stateVersion,
            projection: entry.record.json,
            accountID: entry.accountID,
            originID: originID
        )
        try commit()
    }

    // MARK: Push outbox

    /// `PUT /v1/devices/me/push`. The server validates the topic against its
    /// configured app IDs (spec.watch.md section 10).
    public func registerPush(principal: Principal, registration: PushRegistration, allowedTopics: Set<String>) throws {
        guard let deviceID = principal.deviceID, var device = devices[deviceID] else {
            throw ControlError(code: .notAuthorized, message: "only devices register push tokens")
        }
        // Fails closed: with no configured app IDs there is no topic a device
        // may claim, so the operator's provider key can never be used to push
        // to an arbitrary topic (spec.watch.md section 10).
        guard allowedTopics.contains(registration.topic) else {
            throw ControlError(
                code: .notAuthorized,
                message: allowedTopics.isEmpty
                    ? "this service has no configured APNs topics"
                    : "topic is not configured for this service"
            )
        }
        guard registration.platform == device.platform else {
            throw ControlError(code: .invalidPayload, message: "platform does not match the enrolled device")
        }
        device.push = registration
        devices[deviceID] = device
        try commit()
    }

    /// Sends to every installed destination for the account, so the system can
    /// choose the appropriate presentation (spec.watch.md section 14).
    private func enqueueApprovalPushes(accountID: ControlID, spec: ApprovalSpec) {
        let payload = ApprovalPushPayload(eventID: .random(), requestID: spec.requestID)
        guard let body = try? payload.encoded() else { return }
        for device in devices.values where device.accountID == accountID && !device.isRevoked {
            guard let push = device.push else { continue }
            outbox.append(OutboxEntry(
                payload: body,
                headers: APNsRequestHeaders(topic: push.topic, expiresAt: spec.expiresAt, collapseID: payload.collapseID),
                token: push.token,
                platform: push.platform,
                environment: push.environment
            ))
        }
    }

    private func enqueuePushes(accountID: ControlID, event: InformationalEvent) {
        let json = JSONValue.object([
            "aps": .object([
                "alert": .object(["title": .string(event.title), "body": .string(event.body)]),
                "category": .string(PushCategory.informational),
                "thread-id": .string(event.jobID.map { "shell-job-\($0.rawValue)" } ?? "shell-events"),
            ]),
            "v": 1,
            "event_id": JSONValue(event.eventID),
        ])
        guard let body = try? JSONCanonicalization.canonicalize(json), body.count <= ApprovalPushPayload.maximumBytes else { return }
        for device in devices.values where device.accountID == accountID && !device.isRevoked {
            guard let push = device.push else { continue }
            outbox.append(OutboxEntry(
                payload: body,
                headers: APNsRequestHeaders(
                    topic: push.topic,
                    expiresAt: event.occurredAt.adding(ApprovalPolicy.maximumLifetime),
                    collapseID: "event.\(event.eventID.rawValue)"
                ),
                token: push.token,
                platform: push.platform,
                environment: push.environment
            ))
        }
    }

    public func drainOutbox() -> [OutboxEntry] {
        defer { outbox.removeAll() }
        return outbox
    }
}
