import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// `shell-agent/1` origin-side mutations: sessions, typed inputs, withdrawal,
/// one-time consume, delivery receipts, and informational events
/// (spec.agent-relay.md sections 5, 7, 9, 12, and 15).
extension BrokerStore {
    // MARK: Capabilities

    public func agentCapabilities() -> AgentCapabilities {
        AgentCapabilities(serverTime: timestamp)
    }

    // MARK: Change log

    func appendAgent(
        _ type: AgentEventType,
        resourceID: ControlID,
        version: Int64,
        projection: JSONValue,
        accountID: ControlID,
        originID: ControlID?
    ) {
        let event = AgentChangeEvent(
            eventID: .random(),
            sequence: LogSequence(agent.nextSequence),
            type: type,
            resourceID: resourceID,
            resourceVersion: version,
            serverTime: timestamp,
            projection: projection
        )
        agent.nextSequence += 1
        agent.changeLog.append(event)
        agent.scopes[event.eventID] = EventScope(accountID: accountID, originID: originID)
        trimAgentChangeLog()
    }

    func trimAgentChangeLog() {
        let cutoff = timestamp.adding(-ApprovalPolicy.changeLogRetention)
        let expired = agent.changeLog.prefix { $0.serverTime < cutoff }
        guard !expired.isEmpty else { return }
        for event in expired { agent.scopes.removeValue(forKey: event.eventID) }
        agent.changeLog.removeFirst(expired.count)
    }

    // MARK: Sessions

    /// `POST /v1/agent/sessions`: an idempotent upsert of one provider session
    /// instance. Its identity fields are immutable; a later hook invocation of
    /// the same session rebinds only its current run and location
    /// (spec.agent-relay.md 5.2).
    public func registerAgentSession(principal: Principal, registration: AgentSessionRegistration) throws -> AgentSessionProjection {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins register agent sessions")
        }
        guard let run = runs[registration.runID], run.originID == originID else {
            throw ControlError(code: .invalidPayload, message: "run is not registered for this origin")
        }
        _ = run
        let now = timestamp
        if var entry = agent.sessions[registration.agentSessionID] {
            let existing = entry.projection.registration
            guard entry.originID == originID else {
                throw ControlError(code: .notAuthorized, message: "session belongs to another origin")
            }
            guard existing.provider == registration.provider,
                  existing.providerBuild == registration.providerBuild,
                  existing.adapterBuild == registration.adapterBuild,
                  existing.profile == registration.profile,
                  existing.evidence == registration.evidence,
                  existing.operations == registration.operations,
                  existing.providerSessionID == registration.providerSessionID,
                  existing.policyFingerprint == registration.policyFingerprint
            else {
                // A changed build, profile, or policy is a new session, never
                // an update behind an existing one.
                throw ControlError(code: .idempotencyConflict, message: "agent session identity changed; register a new session")
            }
            guard entry.projection.state == .active else {
                throw ControlError(code: .requestResolved, message: "agent session has ended")
            }
            let material = existing.runID != registration.runID || existing.terminalLocation != registration.terminalLocation
            entry.projection = AgentSessionProjection(
                registration: registration,
                state: .active,
                sessionVersion: entry.projection.sessionVersion + (material ? 1 : 0),
                lastSeenAt: now,
                endedAt: nil,
                status: entry.projection.status,
                turnState: entry.projection.turnState ?? (registration.profile == .managed ? .idle : nil),
                activeTurnID: entry.projection.activeTurnID
            )
            agent.sessions[registration.agentSessionID] = entry
            if material {
                appendAgent(.statusChanged, resourceID: registration.agentSessionID, version: entry.projection.sessionVersion,
                            projection: entry.projection.json, accountID: principal.accountID, originID: originID)
                try commit()
            }
            return entry.projection
        }
        let entry = AgentSessionEntry(
            accountID: principal.accountID,
            originID: originID,
            projection: AgentSessionProjection(
                registration: registration, lastSeenAt: now,
                turnState: registration.profile == .managed ? .idle : nil
            )
        )
        agent.sessions[registration.agentSessionID] = entry
        agent.itemSequences[registration.agentSessionID] = agent.nextSequence
        appendAgent(.sessionStarted, resourceID: registration.agentSessionID, version: 1,
                    projection: entry.projection.json, accountID: principal.accountID, originID: originID)
        try commit()
        return entry.projection
    }

    // MARK: Agent approvals

    /// Checks an `agent.tool.v1` approval against its registered session
    /// before the base approval is created: the session must be active, belong
    /// to this origin, and have negotiated the operation kind; the approval
    /// must require the kind's feature token (spec.agent-relay.md 6.4).
    func validateAgentApproval(_ operation: AgentToolOperation, spec: ApprovalSpec, originID: ControlID) throws {
        guard let session = agent.sessions[operation.agentSessionID], session.originID == originID else {
            throw ControlError(code: .invalidPayload, message: "agent session is not registered for this origin")
        }
        guard session.projection.state == .active else {
            throw ControlError(code: .requestResolved, message: "agent session has ended")
        }
        let registration = session.projection.registration
        guard registration.provider == operation.provider, registration.providerBuild == operation.providerBuild,
              registration.adapterBuild == operation.adapterBuild else {
            throw ControlError(code: .nativeContextChanged, message: "operation does not match the registered session build")
        }
        guard let kindToken = AgentFeature.token(for: operation.kind),
              registration.operations.contains(kindToken) else {
            throw ControlError(code: .unsupportedOperation, message: "operation kind was not negotiated for this session")
        }
        for feature in operation.requiredFeatures where !spec.requiredFeatures.contains(feature) {
            throw ControlError(code: .invalidPayload, message: "approval must require \(feature)")
        }
        guard agent.approvals.values.allSatisfy({ $0.nativeWaitID != operation.nativeWaitID })
                && agent.inputs.values.allSatisfy({ $0.spec.source.nativeWaitID != operation.nativeWaitID }) else {
            // One native wait answers exactly one request.
            throw ControlError(code: .idempotencyConflict, message: "native wait already has a request")
        }
        try checkPendingLimits(runID: spec.runID, originID: originID)
    }

    func recordAgentApproval(_ operation: AgentToolOperation, spec: ApprovalSpec, accountID: ControlID) {
        let reference = AgentApprovalReference(requestID: spec.requestID, agentSessionID: operation.agentSessionID)
        agent.approvals[spec.requestID] = AgentApprovalEntry(
            accountID: accountID, originID: spec.originID, runID: spec.runID,
            nativeWaitID: operation.nativeWaitID, reference: reference
        )
        agent.itemSequences[spec.requestID] = agent.nextSequence
        appendAgent(.approvalCreated, resourceID: spec.requestID, version: reference.version,
                    projection: reference.json, accountID: accountID, originID: spec.originID)
    }

    /// Concurrent pending requests per run and per origin; exceeding the
    /// limit refuses publication and never auto-approves (spec 18).
    func checkPendingLimits(runID: ControlID, originID: ControlID) throws {
        let pendingApprovals = agent.approvals.values.compactMap { entry -> ApprovalRecordEntry? in
            guard let approval = approvals[entry.reference.requestID], approval.projection.resolution == .pending else { return nil }
            return approval
        }
        let pendingInputs = agent.inputs.values.filter { $0.projection.resolution == .pending }
        let perRun = pendingApprovals.filter { $0.spec.runID == runID }.count + pendingInputs.filter { $0.spec.runID == runID }.count
        let perOrigin = pendingApprovals.filter { $0.spec.originID == originID }.count + pendingInputs.filter { $0.spec.originID == originID }.count
        guard perRun < AgentPolicy.maximumPendingPerRun, perOrigin < AgentPolicy.maximumPendingPerOrigin else {
            throw ControlError(code: .limitExceeded, message: "too many pending agent requests")
        }
    }

    // MARK: Inputs

    /// `POST /v1/agent/inputs`: one immutable input spec. The same ID and hash
    /// returns the existing record; any other reuse of the ID fails.
    public func createInput(principal: Principal, spec: InputSpec) throws -> InputRecord {
        guard let originID = principal.originID, spec.originID == originID else {
            throw ControlError(code: .notAuthorized, message: "origins create only their own inputs")
        }
        let hash = try spec.requestHash()
        if let existing = agent.inputs[spec.requestID] {
            guard ContentDigest.matches(existing.requestHash, hash) else {
                throw ControlError(code: .idempotencyConflict, message: "request id reused with a different spec")
            }
            return existing.record
        }
        if let tombstone = agent.inputTombstones[spec.requestID] {
            throw ControlError(
                code: ContentDigest.matches(tombstone, hash) ? .requestResolved : .idempotencyConflict,
                message: "request id was already used"
            )
        }
        guard approvals[spec.requestID] == nil, tombstones[spec.requestID] == nil else {
            throw ControlError(code: .idempotencyConflict, message: "request id belongs to an approval")
        }
        guard let run = runs[spec.runID], run.originID == originID, run.jobID == spec.jobID else {
            throw ControlError(code: .invalidPayload, message: "run is not registered for this origin and job")
        }
        guard run.cancellationRequestedAt == nil else {
            throw ControlError(code: .requestResolved, message: "job cancellation was requested")
        }
        guard let session = agent.sessions[spec.source.agentSessionID], session.originID == originID else {
            throw ControlError(code: .invalidPayload, message: "agent session is not registered for this origin")
        }
        guard session.projection.state == .active else {
            throw ControlError(code: .requestResolved, message: "agent session has ended")
        }
        let registration = session.projection.registration
        guard registration.operations.contains(AgentFeature.input),
              registration.provider == spec.source.provider,
              registration.providerBuild == spec.source.providerBuild,
              registration.adapterBuild == spec.source.adapterBuild else {
            throw ControlError(code: .unsupportedInputSchema, message: "inputs were not negotiated for this session build")
        }
        guard spec.isAnswerableEffect else {
            throw ControlError(code: .unsupportedInputSchema, message: "only answer_question inputs are remotely answerable")
        }
        guard Set(spec.requiredFeatures).isSuperset(of: [AgentFeature.input, AgentFeature.inputConsume]) else {
            throw ControlError(code: .invalidPayload, message: "an input must require agent.input.v1 and agent.input.consume.v1")
        }
        guard agent.inputs.values.allSatisfy({ $0.spec.source.nativeWaitID != spec.source.nativeWaitID })
                && agent.approvals.values.allSatisfy({ $0.nativeWaitID != spec.source.nativeWaitID }) else {
            throw ControlError(code: .idempotencyConflict, message: "native wait already has a request")
        }
        try validateLifetime(createdAt: spec.createdAt, expiresAt: spec.expiresAt, cap: AgentPolicy.maximumLifetime)
        try checkPendingLimits(runID: spec.runID, originID: originID)

        var entry = InputEntry(
            spec: spec,
            requestHash: hash,
            accountID: principal.accountID,
            projection: InputProjection(stateVersion: 1, policyVersion: policyVersion)
        )
        refreshPresence(for: &entry)
        agent.inputs[spec.requestID] = entry
        agent.itemSequences[spec.requestID] = agent.nextSequence
        appendAgent(.inputCreated, resourceID: spec.requestID, version: 1, projection: entry.record.json,
                    accountID: principal.accountID, originID: originID)
        try commit()
        enqueueInputRelayPushes(accountID: principal.accountID, spec: spec)
        return entry.record
    }

    /// The broker is authoritative for deadlines: both ends are checked
    /// against its own clock, and out-of-range values are rejected.
    func validateLifetime(createdAt: ControlTimestamp, expiresAt: ControlTimestamp, cap: TimeInterval) throws {
        let now = timestamp
        guard createdAt <= now.adding(BrokerStore.originClockSkew) else {
            throw ControlError(code: .invalidPayload, message: "created_at is ahead of the broker clock")
        }
        guard expiresAt > now else { throw ControlError(code: .requestExpired, message: "expires_at has already passed") }
        guard expiresAt <= now.adding(cap) else {
            throw ControlError(code: .invalidPayload, message: "expires_at exceeds the \(Int(cap))s cap from now")
        }
    }

    func refreshPresence(for entry: inout InputEntry) {
        let run = runs[entry.spec.runID]
        entry.projection.presence = SourcePresence(
            lastSeenAt: run?.lastSeenAt,
            isWaiting: run?.waitingRequestIDs.contains(entry.spec.requestID) ?? false
        )
    }

    /// `POST /v1/agent/inputs/{id}/withdraw`. After a response, the recorded
    /// resolution stays and an unclaimed dispatch becomes `not_applied`; a
    /// response already claimed cannot be withdrawn.
    public func withdrawInput(
        principal: Principal,
        requestID: ControlID,
        mutationID: ControlID,
        runID: ControlID,
        requestHash: String
    ) throws -> InputRecord {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins withdraw inputs")
        }
        sweepExpired()
        guard var entry = agent.inputs[requestID], entry.spec.originID == originID else {
            throw ControlError(code: .notFound, message: "no such input")
        }
        guard entry.spec.runID == runID, ContentDigest.matches(entry.requestHash, requestHash) else {
            throw ControlError(code: .hashMismatch, message: "withdrawal describes another run or hash")
        }
        let key = AgentMutationRecord.key(.inputWithdraw, originID: originID, mutationID: mutationID)
        if let existing = agent.mutations[key] {
            return (try? InputRecord(json: existing.result)) ?? entry.record
        }
        if entry.permit != nil {
            throw ControlError(code: .alreadyClaimed, message: "the response was already claimed", currentProjection: entry.record.json)
        }
        let backup = stateBackup()
        withdraw(&entry)
        agent.inputs[requestID] = entry
        agent.mutations[key] = AgentMutationRecord(
            kind: .inputWithdraw, originID: originID, mutationID: mutationID,
            bodyHash: requestHash, result: entry.record.json, recordedAt: timestamp
        )
        try commit(restoring: backup)
        return entry.record
    }

    /// Withdraws a pending input, or marks an unclaimed response not applied.
    func withdraw(_ entry: inout InputEntry) {
        switch entry.projection.resolution {
        case .pending:
            entry.projection.resolution = .withdrawn
            entry.projection.dispatch = .notApplied
        case .answered, .declined:
            guard entry.permit == nil, entry.projection.dispatch == .awaitingOrigin else { return }
            entry.projection.dispatch = .notApplied
        case .expired, .withdrawn:
            return
        }
        entry.withdrawnAt = timestamp
        entry.projection.stateVersion += 1
        appendAgent(.requestResolved, resourceID: entry.spec.requestID, version: entry.projection.stateVersion,
                    projection: entry.record.json, accountID: entry.accountID, originID: entry.spec.originID)
    }

    /// `POST /v1/agent/inputs/{id}/consume`: claim the winning response once
    /// for the exact live wait. The same mutation returns the same permit; it
    /// never mints a fresh deadline (spec.agent-relay.md 15.3).
    public func consumeInput(principal: Principal, requestID: ControlID, request: InputConsumeRequest) throws -> InputConsumePermit {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins consume inputs")
        }
        sweepExpired()
        guard var entry = agent.inputs[requestID], entry.spec.originID == originID else {
            throw ControlError(code: .notFound, message: "no such input")
        }
        if let permit = entry.permit {
            guard permit.mutationID == request.mutationID else {
                throw ControlError(code: .alreadyClaimed, message: "the response was already claimed", currentProjection: entry.record.json)
            }
            return permit
        }
        guard entry.projection.resolution == .answered || entry.projection.resolution == .declined,
              let response = entry.response, let responseHash = entry.responseHash,
              let commandID = entry.projection.commandID, let jws = entry.commandJWS else {
            throw ControlError(code: .requestResolved, message: "input has no recorded response", currentProjection: entry.record.json)
        }
        guard entry.spec.runID == request.runID, entry.spec.source.nativeWaitID == request.nativeWaitID,
              ContentDigest.matches(entry.requestHash, request.requestHash),
              commandID == request.commandID, ContentDigest.matches(responseHash, request.responseHash) else {
            throw ControlError(code: .hashMismatch, message: "consume describes another wait, request, or response")
        }
        guard entry.withdrawnAt == nil, entry.projection.dispatch == .awaitingOrigin else {
            throw ControlError(code: .requestResolved, message: "response is no longer available", currentProjection: entry.record.json)
        }
        guard let run = runs[entry.spec.runID], run.cancellationRequestedAt == nil else {
            throw ControlError(code: .requestResolved, message: "job cancellation was requested")
        }
        if let deciding = entry.projection.respondedByDeviceID, devices[deciding]?.isRevoked ?? true {
            throw ControlError(code: .deviceRevoked, message: "the responding device was revoked")
        }
        let now = timestamp
        // Consume never extends authorization past the request, its native
        // deadline, or the original signed command deadline (spec 8.2).
        var applyBefore = min(now.adding(ApprovalPolicy.permitLifetime), entry.spec.expiresAt)
        if let notAfter = entry.commandNotAfter { applyBefore = min(applyBefore, notAfter) }
        guard now < applyBefore else {
            throw ControlError(code: .requestExpired, message: "the response deadline passed", currentProjection: entry.record.json)
        }
        let backup = stateBackup()
        let permit = InputConsumePermit(
            permitID: .random(), mutationID: request.mutationID, originID: originID, runID: entry.spec.runID,
            nativeWaitID: entry.spec.source.nativeWaitID, requestID: requestID, requestHash: entry.requestHash,
            commandID: commandID, responseHash: responseHash, response: response, commandJWS: jws,
            issuedAt: now, applyBefore: applyBefore
        )
        entry.permit = permit
        entry.projection.dispatch = .claimed
        entry.projection.stateVersion += 1
        agent.inputs[requestID] = entry
        agent.mutations[AgentMutationRecord.key(.inputConsume, originID: originID, mutationID: request.mutationID)] = AgentMutationRecord(
            kind: .inputConsume, originID: originID, mutationID: request.mutationID,
            bodyHash: try ContentDigest.digest(ofCanonical: request.json), result: permit.json, recordedAt: now
        )
        appendAgent(.deliveryUpdated, resourceID: requestID, version: entry.projection.stateVersion,
                    projection: entry.record.json, accountID: entry.accountID, originID: originID)
        try commit(restoring: backup)
        return permit
    }

    // MARK: Receipts

    /// `POST /v1/agent/receipts`: correlated, idempotent delivery evidence.
    /// Transitions are forward-only; the legacy approval dispatch is derived
    /// conservatively (spec.agent-relay.md 9.2).
    public func recordAgentReceipt(principal: Principal, receipt: AgentDeliveryReceipt) throws {
        guard let originID = principal.originID else {
            throw ControlError(code: .notAuthorized, message: "only origins report receipts")
        }
        guard receipts[receipt.receiptID] == nil else { return }
        guard let run = runs[receipt.runID], run.originID == originID else {
            throw ControlError(code: .notFound, message: "no such run")
        }
        _ = run
        let backup = stateBackup()
        switch receipt.requestKind {
        case .input:
            try applyInputReceipt(receipt, originID: originID)
        case .approval:
            try applyApprovalReceipt(receipt, originID: originID)
        case .sessionCommand:
            try applySessionCommandReceipt(receipt, originID: originID)
        }
        receipts[receipt.receiptID] = timestamp
        try commit(restoring: backup)
    }

    private func applyInputReceipt(_ receipt: AgentDeliveryReceipt, originID: ControlID) throws {
        guard var entry = agent.inputs[receipt.requestID], entry.spec.originID == originID else {
            throw ControlError(code: .notFound, message: "no such input")
        }
        guard entry.spec.runID == receipt.runID, entry.spec.source.nativeWaitID == receipt.nativeWaitID,
              ContentDigest.matches(entry.requestHash, receipt.requestHash) else {
            throw ControlError(code: .hashMismatch, message: "receipt describes another wait or request")
        }
        guard let permit = entry.permit, receipt.permitID == permit.permitID, receipt.commandID == permit.commandID else {
            throw ControlError(code: .notAuthorized, message: "receipt does not match the recorded claim")
        }
        guard entry.projection.dispatch.canTransition(to: receipt.dispatch) else {
            throw ControlError(
                code: .alreadyResolved,
                message: "dispatch cannot move from \(entry.projection.dispatch.rawValue) to \(receipt.dispatch.rawValue)",
                currentProjection: entry.record.json
            )
        }
        entry.projection.dispatch = receipt.dispatch
        if let operation = receipt.operation { entry.projection.operation = operation }
        entry.projection.stateVersion += 1
        agent.inputs[receipt.requestID] = entry
        appendAgent(.deliveryUpdated, resourceID: receipt.requestID, version: entry.projection.stateVersion,
                    projection: entry.record.json, accountID: entry.accountID, originID: originID)
    }

    private func applyApprovalReceipt(_ receipt: AgentDeliveryReceipt, originID: ControlID) throws {
        guard var agentEntry = agent.approvals[receipt.requestID], agentEntry.originID == originID,
              var approval = approvals[receipt.requestID] else {
            throw ControlError(code: .notFound, message: "no such agent approval")
        }
        guard agentEntry.runID == receipt.runID, agentEntry.nativeWaitID == receipt.nativeWaitID,
              ContentDigest.matches(approval.requestHash, receipt.requestHash),
              receipt.decisionID == nil || receipt.decisionID == approval.projection.decisionID else {
            throw ControlError(code: .hashMismatch, message: "receipt describes another wait or request")
        }
        switch approval.projection.resolution {
        case .approved:
            guard let consumeID = receipt.consumeID, approval.consumedBy == consumeID else {
                throw ControlError(code: .notAuthorized, message: "receipt does not match the recorded claim")
            }
        case .rejected:
            guard receipt.consumeID == nil else {
                throw ControlError(code: .invalidPayload, message: "a rejection receipt carries no consume id")
            }
        case .pending, .cancelled, .expired:
            // A system outcome (the adapter answered on its own at a
            // deadline) may be reported for a request nobody decided.
            guard receipt.systemOutcome else {
                throw ControlError(code: .alreadyResolved, message: "no recorded decision to deliver")
            }
        }
        var reference = agentEntry.reference
        // The first receipt for a request that was claimed starts from the
        // claim; one for a rejection or system outcome from awaiting_origin.
        if reference.dispatch == .none {
            reference.dispatch = approval.consumedBy != nil ? .claimed : .awaitingOrigin
        }
        guard reference.dispatch.canTransition(to: receipt.dispatch) else {
            throw ControlError(code: .alreadyResolved,
                               message: "dispatch cannot move from \(reference.dispatch.rawValue) to \(receipt.dispatch.rawValue)")
        }
        reference.dispatch = receipt.dispatch
        reference.evidence = receipt.evidence
        reference.systemOutcome = receipt.systemOutcome
        if let operation = receipt.operation { reference.operation = operation }
        reference.version += 1
        agentEntry.reference = reference
        agent.approvals[receipt.requestID] = agentEntry
        appendAgent(.deliveryUpdated, resourceID: receipt.requestID, version: reference.version,
                    projection: reference.json, accountID: agentEntry.accountID, originID: originID)

        // The legacy dispatch follows only when the evidence justifies it.
        if approval.projection.resolution == .approved || approval.projection.resolution == .rejected,
           let legacy = receipt.dispatch.legacyReceiptResult {
            let next: Dispatch
            switch legacy {
            case .applied: next = .applied
            case .notApplied: next = .notApplied
            case .unknown: next = .unknown
            }
            if approval.projection.dispatch.canTransition(to: next) {
                approval.projection.dispatch = next
                approval.projection.stateVersion += 1
                approval.receiptID = receipt.receiptID
                approvals[receipt.requestID] = approval
                append(.approvalDispatchUpdated, resourceID: receipt.requestID, version: approval.projection.stateVersion,
                       projection: approval.record.json, accountID: approval.accountID, originID: originID)
            }
        }
    }

    // MARK: Events

    /// `POST /v1/agent/events`: informational, idempotent by event ID. A
    /// session end or turn end withdraws that session's pending requests; no
    /// event can resolve a request as answered (spec.agent-relay.md 12.1).
    public func recordAgentEvent(principal: Principal, event: AgentEvent) throws {
        guard let originID = principal.originID, event.originID == originID else {
            throw ControlError(code: .notAuthorized, message: "origins report only their own events")
        }
        guard event.type.isOriginReportable else {
            throw ControlError(code: .unsupportedCommand, message: "\(event.type.rawValue) is not reported by origins")
        }
        let key = AgentMutationRecord.key(.event, originID: originID, mutationID: event.eventID)
        let bodyHash = try event.bodyHash()
        if let existing = agent.mutations[key] {
            guard ContentDigest.matches(existing.bodyHash, bodyHash) else {
                throw ControlError(code: .idempotencyConflict, message: "event id reused with a different body")
            }
            return
        }
        guard var session = agent.sessions[event.agentSessionID], session.originID == originID else {
            throw ControlError(code: .notFound, message: "no such agent session")
        }
        let backup = stateBackup()
        sweepExpired()
        switch event.type {
        case .sessionEnded:
            if session.projection.state == .active {
                session.projection.state = .ended
                session.projection.endedAt = timestamp
                session.projection.sessionVersion += 1
                agent.sessions[event.agentSessionID] = session
                withdrawPending(sessionID: event.agentSessionID, runID: nil)
            }
        case .statusChanged:
            session.projection.status = event.summary
            session.projection.sessionVersion += 1
            agent.sessions[event.agentSessionID] = session
        case .turnStarted:
            // Only the provider's own turn event makes steering possible.
            guard session.projection.registration.profile == .managed, let turnID = event.providerTurnID else {
                throw ControlError(code: .invalidPayload, message: "turn events need a managed session and a turn id")
            }
            session.projection.turnState = .active
            session.projection.activeTurnID = turnID
            session.projection.sessionVersion += 1
            agent.sessions[event.agentSessionID] = session
        case .turnCompleted, .turnFailed:
            // The turn ended: nothing pending in it can still be answered.
            withdrawPending(sessionID: event.agentSessionID, runID: event.runID)
            if session.projection.registration.profile == .managed,
               event.providerTurnID == nil || event.providerTurnID == session.projection.activeTurnID {
                session.projection.turnState = .idle
                session.projection.activeTurnID = nil
                session.projection.sessionVersion += 1
                agent.sessions[event.agentSessionID] = session
            }
            if let requestID = event.requestID {
                markOperation(requestID, originID: originID, state: event.type == .turnCompleted ? .completed : .failed)
            }
        default:
            break
        }
        agent.mutations[key] = AgentMutationRecord(
            kind: .event, originID: originID, mutationID: event.eventID,
            bodyHash: bodyHash, result: .object([:]), recordedAt: timestamp
        )
        appendAgent(event.type, resourceID: event.agentSessionID, version: session.projection.sessionVersion,
                    projection: event.json, accountID: principal.accountID, originID: originID)
        try commit(restoring: backup)
    }

    /// Withdraws a session's pending inputs and cancels its pending agent
    /// approvals; an unclaimed approved grant is marked not applied.
    func withdrawPending(sessionID: ControlID, runID: ControlID?) {
        for (id, var entry) in agent.sessionCommands where entry.record.action.agentSessionID == sessionID
            && entry.record.dispatch == .awaitingOrigin && (runID == nil || entry.record.action.runID == runID) {
            entry.record.dispatch = .notApplied
            entry.record.evidence = "session_state_changed"
            entry.record.version += 1
            agent.sessionCommands[id] = entry
            appendAgent(.deliveryUpdated, resourceID: id, version: entry.record.version, projection: entry.record.json,
                        accountID: entry.accountID, originID: entry.originID)
        }
        for (id, var entry) in agent.inputs where entry.spec.source.agentSessionID == sessionID {
            if let runID, entry.spec.runID != runID { continue }
            withdraw(&entry)
            agent.inputs[id] = entry
        }
        for (id, agentEntry) in agent.approvals where agentEntry.reference.agentSessionID == sessionID {
            if let runID, agentEntry.runID != runID { continue }
            guard var approval = approvals[id] else { continue }
            if approval.projection.resolution == .pending {
                approval.projection.resolution = .cancelled
                approval.projection.dispatch = .notApplied
            } else if approval.projection.resolution == .approved, approval.consumedBy == nil,
                      approval.projection.dispatch == .awaitingOrigin {
                approval.projection.dispatch = .notApplied
            } else {
                continue
            }
            approval.withdrawnAt = timestamp
            approval.projection.stateVersion += 1
            approvals[id] = approval
            append(.approvalResolved, resourceID: id, version: approval.projection.stateVersion,
                   projection: approval.record.json, accountID: approval.accountID, originID: approval.spec.originID)
        }
    }

    private func markOperation(_ requestID: ControlID, originID: ControlID, state: AgentOperationState) {
        if var entry = agent.inputs[requestID], entry.spec.originID == originID {
            entry.projection.operation = state
            entry.projection.stateVersion += 1
            agent.inputs[requestID] = entry
            appendAgent(.deliveryUpdated, resourceID: requestID, version: entry.projection.stateVersion,
                        projection: entry.record.json, accountID: entry.accountID, originID: originID)
        } else if var entry = agent.approvals[requestID], entry.originID == originID {
            entry.reference.operation = state
            entry.reference.version += 1
            agent.approvals[requestID] = entry
            appendAgent(.deliveryUpdated, resourceID: requestID, version: entry.reference.version,
                        projection: entry.reference.json, accountID: entry.accountID, originID: originID)
        }
    }

    // MARK: Expiry

    /// Deadline transitions for inputs, applied before every read and write.
    func sweepExpiredInputs() {
        let now = timestamp
        for (id, var entry) in agent.inputs {
            var changed = false
            if entry.projection.resolution == .pending, entry.spec.isExpired(at: now) {
                entry.projection.resolution = .expired
                entry.projection.dispatch = .notApplied
                changed = true
            } else if entry.projection.dispatch == .awaitingOrigin, entry.spec.isExpired(at: now) {
                // An unclaimed response that expires was not applied.
                entry.projection.dispatch = .notApplied
                changed = true
            }
            guard changed else { continue }
            entry.projection.stateVersion += 1
            agent.inputs[id] = entry
            appendAgent(.requestResolved, resourceID: id, version: entry.projection.stateVersion,
                        projection: entry.record.json, accountID: entry.accountID, originID: entry.spec.originID)
        }
        agent.challenges = agent.challenges.filter { $0.value.expiresAt > now }
        // An unclaimed session command past its signed deadline never runs.
        for (id, var entry) in agent.sessionCommands where entry.record.dispatch == .awaitingOrigin && entry.record.notAfter <= now {
            entry.record.dispatch = .notApplied
            entry.record.evidence = "deadline_passed"
            entry.record.version += 1
            agent.sessionCommands[id] = entry
            appendAgent(.deliveryUpdated, resourceID: id, version: entry.record.version, projection: entry.record.json,
                        accountID: entry.accountID, originID: entry.originID)
        }
    }

    // MARK: Push

    /// A generic attention hint for a new input: opaque IDs only; opening it
    /// fetches current state (spec.agent-relay.md 12.3).
    private func enqueueInputRelayPushes(accountID: ControlID, spec: InputSpec) {
        for device in devices.values where device.accountID == accountID && !device.isRevoked && !device.alertsSuppressed {
            guard let capability = device.pushCapability,
                  device.grants.contains(.agentInputsRead) || device.grants.contains(.agentInputsReadViaGateway) else { continue }
            relayOutbox.append(RelayPushEntry(
                capability: capability,
                event: "input.created",
                requestID: spec.requestID,
                originID: spec.originID,
                collapseID: "input.\(spec.requestID.rawValue)",
                presentationClass: "input"
            ))
        }
    }

    // MARK: Administration

    /// Adds or removes the agent grants of one enrolled device. Grants are
    /// separately revocable and never part of a pairing default
    /// (spec.agent-relay.md 17.1).
    public func setAgentGrants(deviceID: ControlID, enabled: Bool, messages: Bool = false, cancel: Bool = false, principal: Principal) throws -> Set<DeviceGrant> {
        guard case .admin(let accountID) = principal else {
            throw ControlError(code: .notAuthorized, message: "grant changes require account administration")
        }
        guard var device = devices[deviceID], device.accountID == accountID, !device.isRevoked else {
            throw ControlError(code: .notFound, message: "no such device")
        }
        if enabled {
            device.grants.formUnion(device.isWatchReviewer ? DeviceGrant.agentWatchReviewer : DeviceGrant.agentPhone)
            // Session commands are separate opt-ins, for full-review clients.
            device.grants.subtract([.agentMessagesSend, .agentTurnsCancel])
            if messages, device.isFullReviewClient { device.grants.insert(.agentMessagesSend) }
            if cancel, device.isFullReviewClient { device.grants.insert(.agentTurnsCancel) }
        } else {
            device.grants.subtract(DeviceGrant.agent)
        }
        devices[deviceID] = device
        try commit()
        return device.grants
    }
}
