import Foundation
import ShellControlProtocol
import ShellControlClient
import ShellControlHostSupport

/// `shell-agent/1` IPC: agent session registration, typed inputs with
/// one-time consume, detailed delivery receipts, and informational events
/// (docs/specs/agent-relay.md sections 4.2, 8, and 14.4).
///
/// The adapter owns provider parsing and the native response; the daemon
/// owns authenticated registration, publication, waiting, and consume
/// mediation.
extension DaemonCore {
    // MARK: Registration

    /// `agent.register`: binds this run to one provider session instance. The
    /// same provider session in the same owning process keeps its agent
    /// session ID across hook invocations; anything else is a new session.
    func handleAgentRegister(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let provider = try reader.string("provider", maxLength: 64)
        let providerBuild = try reader.string("provider_build", maxLength: 64)
        let adapterBuild = try reader.string("adapter_build", maxLength: 64)
        let profileText = try reader.string("profile", maxLength: 32)
        guard let profile = AgentIntegrationProfile(rawValue: profileText) else {
            throw ControlError(code: .invalidPayload, message: "unknown integration profile")
        }
        let evidenceText = try reader.string("evidence", maxLength: 32)
        guard let evidence = AgentCompatibilityEvidence(rawValue: evidenceText) else {
            throw ControlError(code: .invalidPayload, message: "unknown compatibility evidence")
        }
        let operations = try reader.stringArray("operations", maxCount: 16, maxLength: 64)
        let providerSessionID = try reader.optionalString("provider_session_id", maxLength: 256)
        let policyFingerprint = try reader.optionalString("policy_fingerprint", maxLength: 64)
        let location = try reader.optionalValue("terminal_location").map(TerminalLocation.init(json:))
        let ownerPID = try reader.optionalInteger("owner_pid")
        try reader.rejectUnknownMembers()

        // The owning process is identified by PID and start time, read here
        // rather than trusted from the adapter.
        let owner = ownerPID.flatMap { Int32(exactly: $0) }.flatMap(ProcessIdentity.of(pid:))
        if ownerPID != nil, owner == nil {
            throw ControlError(code: .nativeWaitGone, message: "the owning provider process is not running")
        }
        let key = [provider, providerBuild, adapterBuild, profileText, evidenceText, operations.joined(separator: ","),
                   providerSessionID ?? "-", policyFingerprint ?? "-",
                   owner.map { "\($0.pid)@\($0.startTime)" } ?? "run:\(binding.runID.rawValue)"].joined(separator: "|")
        let sessionID = agentSessions[key].flatMap { existing in
            existing.owner.map(\.isAlive) ?? false ? existing.agentSessionID : nil
        } ?? .random()
        let registration = try AgentSessionRegistration(
            agentSessionID: sessionID, runID: binding.runID, provider: provider, providerBuild: providerBuild,
            adapterBuild: adapterBuild, profile: profile, evidence: evidence, operations: operations,
            providerSessionID: providerSessionID, policyFingerprint: policyFingerprint,
            terminalLocation: location, startedAt: timestamp
        )
        let projection = try await client.registerAgentSession(registration)
        agentSessions[key] = AgentSessionBinding(agentSessionID: sessionID, registration: projection.registration, owner: owner)
        pruneAgentSessions()
        runs[binding.capability]?.agentSessionID = sessionID
        runs[binding.capability]?.owner = owner
        return .object([
            "agent_session_id": JSONValue(sessionID),
            "profile": .string(profile.rawValue),
            "evidence": .string(evidence.rawValue)
        ])
    }

    /// Keeps the session map bounded without dropping a session a live run
    /// still uses. A session whose owner died is ended by the heartbeat
    /// (`endDeadAgentSessions`), not silently forgotten here.
    private func pruneAgentSessions() {
        let bound = Set(runs.values.compactMap(\.agentSessionID))
        // An ownerless session lives only as long as a run is bound to it.
        agentSessions = agentSessions.filter { $0.value.owner != nil || bound.contains($0.value.agentSessionID) }
        guard agentSessions.count > Self.maximumRunBindings else { return }
        let evictable = agentSessions.filter { !bound.contains($0.value.agentSessionID) && !($0.value.owner?.isAlive ?? false) }
        for key in evictable.keys.prefix(agentSessions.count - Self.maximumRunBindings) {
            agentSessions.removeValue(forKey: key)
        }
    }

    /// Reports the end of every session whose owning provider process has
    /// exited — a killed agent never runs its SessionEnd hook — so the broker
    /// withdraws what was pending and the session does not stay "active"
    /// forever. The binding is dropped only once the broker recorded it.
    func endDeadAgentSessions() async {
        for (key, session) in agentSessions {
            guard let owner = session.owner, !owner.isAlive else { continue }
            do {
                try await client.postAgentEvent(try AgentEvent(
                    type: .sessionEnded, originID: configuration.originID, agentSessionID: session.agentSessionID,
                    occurredAt: timestamp, observedAt: timestamp, summary: "The agent process exited"
                ))
                agentSessions.removeValue(forKey: key)
            } catch let error as ControlError where error.code == .notFound {
                agentSessions.removeValue(forKey: key)
            } catch {
                // Retried on the next heartbeat.
            }
        }
    }

    func sessionBinding(_ binding: RunBinding) throws -> AgentSessionBinding {
        guard let sessionID = binding.agentSessionID,
              let session = agentSessions.values.first(where: { $0.agentSessionID == sessionID }) else {
            throw ControlError(code: .invalidPayload, message: "register the agent session first")
        }
        return session
    }

    // MARK: Events

    /// `agent.event`: informational status. It carries no authority.
    func handleAgentEvent(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        let session = try sessionBinding(binding)
        var reader = try JSONReader(request.body)
        let type = AgentEventType(rawValue: try reader.string("type", maxLength: 64))
        let eventID = try reader.optionalID("event_id") ?? .random()
        let summary = try reader.optionalString("summary", maxLength: AgentPolicy.maximumSummaryScalars)
        let requestID = try reader.optionalID("request_id")
        let turnID = try reader.optionalString("provider_turn_id", maxLength: 256)
        try reader.rejectUnknownMembers()
        let event = try AgentEvent(
            eventID: eventID, type: type, originID: configuration.originID, agentSessionID: session.agentSessionID,
            runID: binding.runID, requestID: requestID, providerTurnID: turnID,
            occurredAt: timestamp, observedAt: timestamp, summary: summary
        )
        try await client.postAgentEvent(event)
        return .object(["event_id": JSONValue(eventID)])
    }

    // MARK: Inputs

    /// `input.request`: builds the immutable input from the adapter's
    /// questions and the registered session, persists it, then publishes it.
    func handleInputRequest(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        let session = try sessionBinding(binding)
        var reader = try JSONReader(request.body)
        let summary = try reader.string("summary", maxLength: AgentPolicy.maximumSummaryScalars)
        guard let rawQuestions = try reader.value("questions").arrayValue else {
            throw ControlError(code: .unsupportedInputSchema, message: "questions must be an array")
        }
        let questions: [InputQuestion]
        do {
            questions = try rawQuestions.map { try InputQuestion(json: $0) }
        } catch {
            throw ControlError(code: .unsupportedInputSchema, message: "\(error)")
        }
        let responses = try reader.optionalValue("allowed_responses").map { _ in
            try reader.stringArray("allowed_responses", maxCount: 4, maxLength: 16).map { text -> InputAllowedResponse in
                guard let response = InputAllowedResponse(rawValue: text) else {
                    throw ControlError(code: .unsupportedInputSchema, message: "unknown response \(text)")
                }
                return response
            }
        } ?? [.answer]
        let reviewText = try reader.optionalString("minimum_review", maxLength: 16) ?? MinimumReview.full.rawValue
        guard let minimumReview = MinimumReview(rawValue: reviewText) else {
            throw ControlError(code: .invalidPayload, message: "unknown minimum_review")
        }
        let lifetime = TimeInterval(try reader.optionalInteger("lifetime_seconds") ?? Int64(AgentPolicy.defaultLifetime))
        let requestID = try reader.optionalID("request_id") ?? .random()
        let source = try InputSource(
            provider: session.registration.provider,
            providerBuild: session.registration.providerBuild,
            adapterBuild: session.registration.adapterBuild,
            nativeRequestSHA256: try reader.string("native_request_sha256", maxLength: 64),
            contextSHA256: try reader.string("context_sha256", maxLength: 64),
            answerMappingSHA256: try reader.string("answer_mapping_sha256", maxLength: 64),
            agentSessionID: session.agentSessionID,
            nativeWaitID: try reader.id("native_wait_id"),
            connectionEpoch: try reader.optionalID("connection_epoch"),
            providerSessionID: session.registration.providerSessionID,
            providerTurnID: try reader.optionalString("provider_turn_id", maxLength: 256),
            providerRequestID: try reader.optionalValue("provider_request_id").map(NativeIdentifier.init(json:))
        )
        try reader.rejectUnknownMembers()
        guard lifetime > 0 else { throw ControlError(code: .invalidPayload, message: "lifetime must be positive") }
        let created = timestamp
        let spec = try InputSpec(
            requestID: requestID, originID: configuration.originID, jobID: binding.jobID, runID: binding.runID,
            createdAt: created, expiresAt: created.adding(min(lifetime, AgentPolicy.maximumLifetime)),
            summary: summary, source: source, questions: questions, allowedResponses: responses,
            minimumReview: minimumReview
        )
        let hash = try spec.requestHash()
        try journal.append(.inputPersisted(requestID: requestID, requestHash: hash, runID: binding.runID))
        _ = try await client.createInput(spec)
        markWaiting(requestID, capability: binding.capability, isWaiting: true, until: spec.expiresAt.date)
        let waiting = runs[binding.capability].map { Array($0.waiting.keys) } ?? [requestID]
        try await client.heartbeat(runIDs: [binding.runID], waitingRequestIDs: waiting)
        return .object(["request_id": JSONValue(requestID), "request_hash": .string(hash)])
    }

    /// `input.wait`: waits on the exact published input, and for a recorded
    /// response claims it once for this run's native wait and returns the
    /// validated permit. Losing the adapter withdraws the input.
    func handleInputWait(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let requestID = try reader.id("request_id")
        let requestHash = try reader.string("request_hash", maxLength: 80)
        let timeout = try reader.optionalInteger("timeout_seconds") ?? Int64(AgentPolicy.defaultLifetime)
        guard timeout > 0 && timeout <= Int64(AgentPolicy.maximumLifetime) else {
            throw ControlError(code: .invalidPayload, message: "invalid wait timeout")
        }
        try reader.rejectUnknownMembers()
        let deadline = now().addingTimeInterval(TimeInterval(timeout))
        markWaiting(requestID, capability: binding.capability, isWaiting: true)
        do {
            return try await waitForInput(requestID, requestHash: requestHash, binding: binding, deadline: deadline)
        } catch where Task.isCancelled {
            markWaiting(requestID, capability: binding.capability, isWaiting: false)
            await withdrawInputOutsideCancellation(requestID, runID: binding.runID, requestHash: requestHash)
            throw ControlError(code: .nativeWaitGone, message: "the waiting adapter disconnected")
        }
    }

    private func waitForInput(_ requestID: ControlID, requestHash: String, binding: RunBinding, deadline: Date) async throws -> JSONValue {
        while now() < deadline {
            try Task.checkCancellation()
            if !acceptingWork { return Self.inputOutcome("unavailable", reason: "daemon is shutting down") }
            if let owner = runs[binding.capability]?.owner, !owner.isAlive {
                markWaiting(requestID, capability: binding.capability, isWaiting: false)
                await withdrawInputOutsideCancellation(requestID, runID: binding.runID, requestHash: requestHash)
                return Self.inputOutcome("unavailable", reason: "native_wait_gone")
            }
            let waiting = runs[binding.capability].map { Array($0.waiting.keys) } ?? [requestID]
            try await client.heartbeat(runIDs: [binding.runID], waitingRequestIDs: waiting)
            let record = try await client.input(requestID)
            guard ContentDigest.matches(record.requestHash, requestHash), record.spec.runID == binding.runID else {
                throw ControlError(code: .hashMismatch, message: "the waiting input is not the one recorded")
            }
            switch record.projection.resolution {
            case .pending:
                markWaiting(requestID, capability: binding.capability, isWaiting: true, until: record.spec.expiresAt.date)
                try await Task.sleep(nanoseconds: UInt64(configuration.pollInterval * 1_000_000_000))
                continue
            case .expired, .withdrawn:
                markWaiting(requestID, capability: binding.capability, isWaiting: false)
                try journal.append(.inputResolved(requestID: requestID, resolution: record.projection.resolution.rawValue))
                return Self.inputOutcome(record.projection.resolution.rawValue)
            case .answered, .declined:
                try journal.append(.inputResolved(requestID: requestID, resolution: record.projection.resolution.rawValue))
                guard let commandID = record.projection.commandID, let response = record.response else {
                    return Self.inputOutcome("unavailable", reason: "no response recorded")
                }
                // Recheck the committed response before claiming it.
                do { try response.validate(against: record.spec) } catch {
                    throw ControlError(code: .responseInvalid, message: "\(error)")
                }
                let mutationID = try journaledInputConsume(requestID, commandID: commandID, capability: binding.capability)
                let consume = InputConsumeRequest(
                    mutationID: mutationID, runID: binding.runID, nativeWaitID: record.spec.source.nativeWaitID,
                    requestHash: record.requestHash, commandID: commandID, responseHash: response.responseHash
                )
                let permit = try await consumeInput(requestID, request: consume, deadline: deadline)
                try permit.validate(request: consume, originID: configuration.originID, requestID: requestID)
                try journal.append(.inputClaimed(requestID: requestID, permitID: permit.permitID, applyBefore: permit.applyBefore))
                markWaiting(requestID, capability: binding.capability, isWaiting: false)
                guard permit.isApplicable(at: timestamp) else {
                    return Self.inputOutcome("unavailable", reason: "permit deadline passed before dispatch")
                }
                return .object([
                    "outcome": .string(record.projection.resolution.rawValue),
                    "permit": permit.json,
                    "spec": record.spec.json
                ])
            }
        }
        return Self.inputOutcome("unavailable", reason: "wait timed out")
    }

    static func inputOutcome(_ outcome: String, reason: String? = nil) -> JSONValue {
        JSONWriter.object(["outcome": .string(outcome), "reason": reason.map { .string($0) }])
    }

    private func journaledInputConsume(_ requestID: ControlID, commandID: ControlID, capability: String) throws -> ControlID {
        if let existing = runs[capability]?.inputConsumes[requestID] { return existing }
        let mutationID = ControlID.random()
        try journal.append(.inputConsumeIntent(requestID: requestID, mutationID: mutationID, commandID: commandID))
        runs[capability]?.inputConsumes[requestID] = mutationID
        return mutationID
    }

    /// Retries a lost consume reply under the same mutation ID; a definitive
    /// refusal is not retried.
    private func consumeInput(_ requestID: ControlID, request: InputConsumeRequest, deadline: Date) async throws -> InputConsumePermit {
        var delay: TimeInterval = 0.25
        while true {
            do {
                return try await client.consumeInput(requestID, request: request)
            } catch let error as ControlError where !error.code.isRetryable {
                throw error
            } catch {
                guard acceptingWork, now() < deadline, !Task.isCancelled else { throw error }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, ApprovalPolicy.minimumPollInterval)
            }
        }
    }

    func handleInputWithdraw(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let requestID = try reader.id("request_id")
        let requestHash = try reader.string("request_hash", maxLength: 80)
        let mutationID = try reader.optionalID("mutation_id") ?? .random()
        try reader.rejectUnknownMembers()
        let record = try await client.withdrawInput(requestID, mutationID: mutationID, runID: binding.runID, requestHash: requestHash)
        try journal.append(.withdrawn(requestID: requestID))
        markWaiting(requestID, capability: binding.capability, isWaiting: false)
        return record.json
    }

    // MARK: Session commands

    /// `session.command.wait`: the managed adapter's long wait for its
    /// session's next signed command. The command is claimed for the named
    /// connection before it is returned, and the permit is checked against
    /// that connection and session (docs/specs/agent-relay.md section 15).
    func handleSessionCommandWait(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        let session = try sessionBinding(binding)
        guard session.registration.profile == .managed else {
            throw ControlError(code: .unsupportedOperation, message: "only a managed session receives commands")
        }
        var reader = try JSONReader(request.body)
        let epoch = try reader.id("connection_epoch")
        let timeout = try reader.optionalInteger("timeout_seconds") ?? 30
        guard timeout > 0 && timeout <= 300 else { throw ControlError(code: .invalidPayload, message: "invalid wait timeout") }
        try reader.rejectUnknownMembers()
        let deadline = now().addingTimeInterval(TimeInterval(timeout))
        while now() < deadline, acceptingWork {
            try Task.checkCancellation()
            try await client.heartbeat(runIDs: [binding.runID], waitingRequestIDs: [])
            if let next = try await client.pendingSessionCommands(session.agentSessionID).first {
                let claim = AgentSessionClaimRequest(mutationID: .random(), commandID: next.commandID,
                                                     actionDigest: next.actionDigest, connectionEpoch: epoch)
                let permit: AgentSessionPermit
                do {
                    permit = try await client.claimSessionCommand(session.agentSessionID, request: claim)
                } catch let error as ControlError where [.alreadyClaimed, .requestResolved, .requestExpired].contains(error.code) {
                    continue
                }
                try permit.validate(connectionEpoch: epoch, agentSessionID: session.agentSessionID)
                guard permit.action.runID == binding.runID else {
                    throw ControlError(code: .nativeContextChanged, message: "the command targets another run")
                }
                return .object(["outcome": "command", "permit": permit.json])
            }
            try await Task.sleep(nanoseconds: UInt64(configuration.pollInterval * 1_000_000_000))
        }
        return .object(["outcome": "none"])
    }

    // MARK: Receipts

    /// `agent.receipt`: forwards correlated delivery evidence. The adapter
    /// reports `dispatch_started` before its first write to the provider and
    /// the strongest justified state after it (docs/specs/agent-relay.md 8.1).
    func handleAgentReceipt(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let kindText = try reader.string("request_kind", maxLength: 16)
        guard let kind = AgentRequestKind(rawValue: kindText) else { throw ControlError(code: .invalidPayload, message: "unknown request kind") }
        let dispatchText = try reader.string("dispatch", maxLength: 32)
        guard let dispatch = AgentDispatch(rawValue: dispatchText) else { throw ControlError(code: .invalidPayload, message: "unknown dispatch") }
        let operation = try reader.optionalString("operation", maxLength: 32).map { text -> AgentOperationState in
            guard let state = AgentOperationState(rawValue: text) else { throw ControlError(code: .invalidPayload, message: "unknown operation") }
            return state
        }
        let receipt = try AgentDeliveryReceipt(
            receiptID: try reader.optionalID("receipt_id") ?? .random(),
            requestKind: kind,
            requestID: try reader.id("request_id"),
            requestHash: try reader.string("request_hash", maxLength: 80),
            runID: binding.runID,
            nativeWaitID: try reader.id("native_wait_id"),
            decisionID: try reader.optionalID("decision_id"),
            consumeID: try reader.optionalID("consume_id"),
            commandID: try reader.optionalID("command_id"),
            permitID: try reader.optionalID("permit_id"),
            dispatch: dispatch,
            evidence: try reader.string("evidence", maxLength: 64),
            systemOutcome: try reader.optionalBool("system_outcome") ?? false,
            operation: operation,
            occurredAt: timestamp
        )
        try reader.rejectUnknownMembers()
        // Posted first. A transient failure is queued durably and retried
        // by the recovery loop, so the broker still learns the outcome; a
        // definitive refusal is returned to the adapter. The delivery is
        // journaled only once it is recorded or queued.
        var queued = false
        do {
            try await client.postAgentReceipt(receipt)
        } catch let error as ControlError where !error.code.isRetryable {
            throw error
        } catch {
            let payload = String(decoding: try JSONCanonicalization.canonicalize(receipt.json), as: UTF8.self)
            try journal.append(.recoveryQueued(mutationID: receipt.receiptID, kind: "agent_receipt", requestID: receipt.requestID, payload: payload))
            queued = true
        }
        try journalDelivery(receipt)
        if dispatch.isTerminal || dispatch == .nativeResponseWritten {
            runs[binding.capability]?.inputConsumes[receipt.requestID] = nil
            runs[binding.capability]?.consumeIntents[receipt.requestID] = nil
        }
        return .object(["receipt_id": JSONValue(receipt.receiptID), "queued": .bool(queued)])
    }

    private func journalDelivery(_ receipt: AgentDeliveryReceipt) throws {
        switch receipt.requestKind {
        case .input:
            try journal.append(.inputDelivery(requestID: receipt.requestID, receiptID: receipt.receiptID, dispatch: receipt.dispatch.rawValue))
        case .approval:
            if let legacy = receipt.dispatch.legacyReceiptResult {
                try journal.append(.dispatchResult(requestID: receipt.requestID, receiptID: receipt.receiptID, result: legacy))
            }
        case .sessionCommand:
            // Never replayed on recovery; the managed adapter reports its own
            // outcome or the claim ages out.
            break
        }
    }

    // MARK: Cleanup outside a cancelled task

    /// A cancelled task's own network calls are cancelled too, so cleanup for
    /// a vanished adapter runs in a fresh task.
    func withdrawOutsideCancellation(_ requestID: ControlID, runID: ControlID, requestHash: String) async {
        let client = self.client
        let withdrew = await Task { () -> Bool in
            (try? await client.withdrawApproval(requestID, mutationID: .random(), runID: runID, requestHash: requestHash)) != nil
        }.value
        if withdrew { try? journal.append(.withdrawn(requestID: requestID)) }
    }

    func withdrawInputOutsideCancellation(_ requestID: ControlID, runID: ControlID, requestHash: String) async {
        let client = self.client
        let withdrew = await Task { () -> Bool in
            (try? await client.withdrawInput(requestID, mutationID: .random(), runID: runID, requestHash: requestHash)) != nil
        }.value
        if withdrew { try? journal.append(.withdrawn(requestID: requestID)) }
    }

    // MARK: Restart recovery

    /// Queues the recovery an interrupted input needs: withdrawal of one
    /// whose waiting adapter died with the old process, or an `unknown`
    /// receipt for one claimed without a terminal delivery. Nothing is ever
    /// re-dispatched (docs/specs/agent-relay.md 8.3).
    func queueInputRecovery(at frontier: [DispatchJournal.Entry]) throws -> Int {
        let recovery = journal.recoverInputs(at: frontier)
        let queued = Set(try journal.pendingRecoveries().map(\.requestID))
        var count = 0
        for (requestID, item) in recovery.pending where !queued.contains(requestID) {
            let mutationID = ControlID.random()
            let payload = JSONValue.object([
                "mutation_id": JSONValue(mutationID), "run_id": JSONValue(item.runID), "request_hash": .string(item.requestHash)
            ])
            try journal.append(.recoveryQueued(mutationID: mutationID, kind: "input_withdraw", requestID: requestID,
                                               payload: String(decoding: try JSONCanonicalization.canonicalize(payload), as: UTF8.self)))
            count += 1
        }
        for (requestID, item) in recovery.stranded where !queued.contains(requestID) {
            guard let mutationID = item.consumeMutationID, let commandID = item.commandID else { continue }
            let payload = JSONValue.object([
                "run_id": JSONValue(item.runID), "request_hash": .string(item.requestHash),
                "consume_mutation_id": JSONValue(mutationID), "command_id": JSONValue(commandID)
            ])
            try journal.append(.recoveryQueued(mutationID: .random(), kind: "input_reclaim", requestID: requestID,
                                               payload: String(decoding: try JSONCanonicalization.canonicalize(payload), as: UTF8.self)))
            count += 1
        }
        for (requestID, item) in recovery.uncertain where !queued.contains(requestID) {
            let mutationID = ControlID.random()
            let payload = JSONWriter.object([
                "run_id": JSONValue(item.runID), "request_hash": .string(item.requestHash),
                "permit_id": item.permitID.map { JSONValue($0) }, "command_id": item.commandID.map { JSONValue($0) }
            ])
            try journal.append(.recoveryQueued(mutationID: mutationID, kind: "input_unknown_receipt", requestID: requestID,
                                               payload: String(decoding: try JSONCanonicalization.canonicalize(payload), as: UTF8.self)))
            count += 1
        }
        return count
    }

    /// Performs one queued input recovery. The native wait ID is read back
    /// from the broker's own record rather than guessed.
    func performInputRecovery(_ item: DispatchJournal.QueuedRecovery) async throws {
        if item.kind == "agent_receipt" {
            let receipt = try AgentDeliveryReceipt(json: try JSONValue.parse(Data(item.payload.utf8)))
            try await client.postAgentReceipt(receipt)
            return
        }
        var reader = try JSONReader(try JSONValue.parse(Data(item.payload.utf8)))
        let runID = try reader.id("run_id")
        let requestHash = try reader.string("request_hash", maxLength: 80)
        switch item.kind {
        case "input_reclaim":
            // A consume intent with no recorded claim: the broker may hold
            // the claim with its reply lost. Re-consuming under the same
            // mutation returns that permit; nothing was dispatched, so it is
            // reported not applied.
            let mutationID = try reader.id("consume_mutation_id")
            let commandID = try reader.id("command_id")
            try reader.rejectUnknownMembers()
            let record = try await client.input(item.requestID)
            guard let response = record.response else { return }
            let permit = try await client.consumeInput(item.requestID, request: InputConsumeRequest(
                mutationID: mutationID, runID: runID, nativeWaitID: record.spec.source.nativeWaitID,
                requestHash: requestHash, commandID: commandID, responseHash: response.responseHash
            ))
            let receipt = try AgentDeliveryReceipt(
                receiptID: item.mutationID, requestKind: .input, requestID: item.requestID, requestHash: requestHash,
                runID: runID, nativeWaitID: record.spec.source.nativeWaitID, commandID: commandID, permitID: permit.permitID,
                dispatch: .notApplied, evidence: "daemon_restarted_before_dispatch", occurredAt: timestamp
            )
            try await client.postAgentReceipt(receipt)
            try journal.append(.inputDelivery(requestID: item.requestID, receiptID: receipt.receiptID, dispatch: AgentDispatch.notApplied.rawValue))
        case "input_withdraw":
            let mutationID = try reader.id("mutation_id")
            guard mutationID == item.mutationID else { throw ControlError(code: .hashMismatch, message: "recovery mutation identity mismatch") }
            try reader.rejectUnknownMembers()
            _ = try await client.withdrawInput(item.requestID, mutationID: mutationID, runID: runID, requestHash: requestHash)
            try journal.append(.withdrawn(requestID: item.requestID))
        case "input_unknown_receipt":
            let permitID = try reader.optionalID("permit_id")
            let commandID = try reader.optionalID("command_id")
            try reader.rejectUnknownMembers()
            let record = try await client.input(item.requestID)
            let receipt = try AgentDeliveryReceipt(
                receiptID: item.mutationID, requestKind: .input, requestID: item.requestID, requestHash: requestHash,
                runID: runID, nativeWaitID: record.spec.source.nativeWaitID, commandID: commandID, permitID: permitID,
                dispatch: .unknown, evidence: "daemon_restarted_after_claim", occurredAt: timestamp
            )
            do {
                try await client.postAgentReceipt(receipt)
            } catch let error as ControlError where error.code == .alreadyResolved {
                // Already terminal: no receipt remains owed.
            }
            try journal.append(.inputDelivery(requestID: item.requestID, receiptID: receipt.receiptID, dispatch: AgentDispatch.unknown.rawValue))
        default:
            throw ControlError(code: .invalidPayload, message: "unknown input recovery \(item.kind)")
        }
    }
}
