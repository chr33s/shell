import Foundation
import ShellControlProtocol
import ShellControlClient
import ShellControlHostSupport

/// The host service: it authenticates local adapters, registers jobs, persists
/// pending requests, polls the broker, validates decisions against the
/// still-blocked operation, consumes authorization, and hands the answer back
/// through the program's native permission mechanism
/// (spec.watch.md section 3).
public actor DaemonCore {
    public struct Configuration: Sendable {
        public var brokerURL: URL
        public var originID: ControlID
        public var originSecret: String
        public var socketPath: String
        public var healthSocketPath: String
        public var journalURL: URL
        public var heartbeatInterval: TimeInterval

        public init(
            brokerURL: URL,
            originID: ControlID,
            originSecret: String,
            socketPath: String,
            journalURL: URL,
            healthSocketPath: String? = nil,
            heartbeatInterval: TimeInterval = ApprovalPolicy.heartbeatInterval
        ) {
            self.brokerURL = brokerURL
            self.originID = originID
            self.originSecret = originSecret
            self.socketPath = socketPath
            self.journalURL = journalURL
            let directory = (socketPath as NSString).deletingLastPathComponent
            self.healthSocketPath = healthSocketPath ?? "\(directory)/health.sock"
            self.heartbeatInterval = heartbeatInterval
        }
    }

    struct RunBinding: Sendable {
        let runID: ControlID
        let jobID: ControlID
        /// A per-run unguessable local capability. Possession of the socket is
        /// not by itself possession of a run.
        let capability: String
        let adapter: String
        let operationSchemas: Set<String>
        /// Requests this run is blocked on, each until its expiry: past that
        /// the broker can no longer approve it, so its presence is moot.
        var waiting: [ControlID: Date] = [:]
        /// Consume IDs journaled for this run's approved requests, reused by
        /// every retry so the broker's idempotent consume can return the
        /// permit it already granted.
        var consumeIntents: [ControlID: ControlID] = [:]
        var lastActivity: Date
    }

    let configuration: Configuration
    let client: ControlAPIClient
    let journal: DispatchJournal
    /// Every CLI invocation says `hello`, so bindings are bounded: a binding
    /// with no live wait is dropped once idle, and only runs blocked on a
    /// request are sent in the presence heartbeat.
    private var runs: [String: RunBinding] = [:]
    /// Runs whose last wait just ended: one more heartbeat clears the broker's
    /// waiting flag, then they leave the presence set.
    private var drainedRuns: Set<ControlID> = []
    /// Long enough for an adapter to post its receipt after a long command.
    static let runBindingIdleLifetime: TimeInterval = 24 * 60 * 60
    static let maximumRunBindings = 4096
    /// The broker's per-heartbeat limits.
    static let heartbeatMaximumRuns = 256
    static let heartbeatMaximumWaiting = 1024
    /// Recorded results for message IDs already handled, so a retransmission
    /// replays rather than mints a second request, event, or receipt.
    ///
    /// Bounded: the daemon is long-lived and every shell command that touches
    /// the integration adds an entry, so without a retention window this grows
    /// for the life of the process — and each entry can hold a decision JWS.
    private var handled: [ControlID: (bodyHash: String, response: IPCResponse, at: Date)] = [:]
    /// Messages whose handler has not finished. A retransmission that arrives
    /// meanwhile waits for the first attempt instead of running it again.
    private var handling: [ControlID: (bodyHash: String?, response: Task<IPCResponse, Never>)] = [:]
    /// Long enough to cover any client's retransmission, far shorter than the
    /// daemon's lifetime.
    static let retransmissionWindow: TimeInterval = 24 * 60 * 60
    static let maximumHandledMessages = 4096
    private let now: @Sendable () -> Date
    private var acceptingWork = true
    private var lastOriginAuthentication: ContinuousClock.Instant?
    private var recoveryPendingCount = 0
    private var startupCandidates: [ControlID: String]?
    private var recoveryPassRunning = false
    private var inFlight = 0
    private var startupConsumes: [ControlID: DispatchJournal.ConsumeRecord] = [:]
    /// What startup had to repair in the journal, surfaced through health.
    private(set) var journalRepair: DispatchJournal.Repair?

    public init(
        configuration: Configuration,
        client: ControlAPIClient? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.configuration = configuration
        self.client = client ?? ControlAPIClient(
            baseURL: configuration.brokerURL,
            credential: .origin(originID: configuration.originID, secret: configuration.originSecret)
        )
        self.journal = try DispatchJournal(url: configuration.journalURL)
        self.now = now
    }

    var timestamp: ControlTimestamp { ControlTimestamp(now()) }

    /// Captures the immutable process-start journal frontier and persists its
    /// candidates before the executable opens either IPC listener.
    public func discoverInterruptedWorkAtStartup() throws {
        guard startupCandidates == nil else { return }
        if journalRepair == nil {
            let repair = try journal.repairAtStartup(at: now())
            journalRepair = repair
            Self.report(repair, journal: journal.url)
        }
        let frontier = try journal.startupFrontier()
        let recovered = try journal.recover(at: frontier)
        startupConsumes = recovered.consumes
        var candidates = try journal.pendingStartupCandidates()
        for requestID in recovered.unresolved where candidates[requestID] == nil {
            let classification = recovered.uncertain.contains(requestID) ? "uncertain" : "unresolved"
            try journal.append(.recoveryCandidate(requestID: requestID, classification: classification))
            candidates[requestID] = classification
        }
        // An uncertain request is also unresolved; uncertainty takes priority.
        for requestID in recovered.uncertain where candidates[requestID] != "uncertain" {
            try journal.append(.recoveryCandidate(requestID: requestID, classification: "uncertain"))
            candidates[requestID] = "uncertain"
        }
        startupCandidates = candidates
        recoveryPendingCount = candidates.count + (try journal.pendingRecoveries().count)
    }

    public func reconcileAfterRestart() async throws {
        try discoverInterruptedWorkAtStartup()
        try await runRecoveryPass()
        await heartbeatOnce()
    }

    /// Single-flight despite actor reentrancy across broker awaits.
    private func runRecoveryPass() async throws {
        guard !recoveryPassRunning else { return }
        recoveryPassRunning = true
        defer { recoveryPassRunning = false }
        try await retryUnresolvedStartupCandidates()
        await retryPersistedRecoveryMutations()
        recoveryPendingCount = (startupCandidates?.count ?? 0) + ((try? journal.pendingRecoveries().count) ?? 0)
    }

    /// Resolve only the boot-scoped candidate set. Entries appended by live
    /// runs in this process can never enter this dictionary.
    private func retryUnresolvedStartupCandidates() async throws {
        guard let snapshot = startupCandidates, !snapshot.isEmpty else { return }
        var queued = try journal.pendingRecoveries()
        var queuedRequests = Set(queued.map(\.requestID))
        for (requestID, classification) in snapshot {
            if queuedRequests.contains(requestID) {
                try retireStartupCandidate(requestID)
                continue
            }
            let record: ApprovalRecord
            do { record = try await client.approval(requestID) } catch { continue } // no authenticated state: retain the candidate

            if classification == "uncertain" {
                let consume = startupConsumes[requestID]
                var result = ReceiptResult.unknown
                var reason = "daemon_restarted_after_claim"
                if let consume, !consume.claimRecorded {
                    // A consume intent without a recorded claim: the broker may
                    // hold the claim with its reply lost. No permit left this
                    // daemon, so whatever the claim, nothing was applied.
                    switch await reclaim(requestID, record: record, consumeID: consume.consumeID) {
                    case .claimed:
                        startupConsumes[requestID]?.claimRecorded = true
                        result = .notApplied
                        reason = "daemon_restarted_before_dispatch"
                    case .noClaim:
                        // Nothing to report under our ID; an unconsumed
                        // approval expires as not applied on the broker.
                        try journal.append(.withdrawn(requestID: requestID))
                        queuedRequests.insert(requestID)
                        try retireStartupCandidate(requestID)
                        continue
                    case .retryLater:
                        continue
                    }
                }
                // The broker accepts an approved request's receipt only under
                // the consume ID that holds its claim.
                let receipt = Receipt(
                    receiptID: .random(), decisionID: record.projection.decisionID, consumeID: consume?.consumeID,
                    requestHash: record.requestHash, runID: record.spec.runID, result: result,
                    reasonCode: reason, occurredAt: timestamp
                )
                let payload = String(decoding: try JSONCanonicalization.canonicalize(receipt.json), as: UTF8.self)
                let mutationID = ControlID.random()
                try journal.append(.recoveryQueued(mutationID: mutationID, kind: "unknown_receipt", requestID: requestID, payload: payload))
                queued.append(.init(mutationID: mutationID, kind: "unknown_receipt", requestID: requestID, payload: payload))
            } else if record.projection.resolution == .pending {
                let mutationID = ControlID.random()
                let payloadValue = JSONValue.object([
                    "mutation_id": JSONValue(mutationID), "run_id": JSONValue(record.spec.runID),
                    "request_hash": .string(record.requestHash)
                ])
                let payload = String(decoding: try JSONCanonicalization.canonicalize(payloadValue), as: UTF8.self)
                try journal.append(.recoveryQueued(mutationID: mutationID, kind: "withdraw", requestID: requestID, payload: payload))
                queued.append(.init(mutationID: mutationID, kind: "withdraw", requestID: requestID, payload: payload))
            } else {
                // Authenticated terminal state proves no recovery mutation remains.
                try journal.append(.withdrawn(requestID: requestID))
            }
            queuedRequests.insert(requestID)
            try retireStartupCandidate(requestID)
        }
    }

    private static func report(_ repair: DispatchJournal.Repair, journal: URL) {
        guard !repair.isEmpty else { return }
        var message = "shell-controld: repaired journal \(journal.path):"
        if repair.discardedTornTail { message += " dropped a final record torn by a crash;" }
        if repair.terminatedFinalRecord { message += " terminated a final record missing its newline;" }
        if let quarantine = repair.quarantinedTo {
            let lines = repair.discardedLines.map(String.init).joined(separator: ", ")
            message += " corrupt record(s) at line(s) \(lines) were set aside; the original is kept at \(quarantine.path);"
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private enum Reclaim { case claimed, noClaim, retryLater }

    /// Re-runs the consume under the journaled ID. The broker returns the
    /// permit it already granted to that ID, so a claim whose reply was lost
    /// is found instead of stranded (spec.watch.md section 12).
    private func reclaim(_ requestID: ControlID, record: ApprovalRecord, consumeID: ControlID) async -> Reclaim {
        // Our consume never committed if the request is not approved: a claim
        // would have left it approved.
        guard record.projection.resolution == .approved, let decisionID = record.projection.decisionID else {
            return .noClaim
        }
        do {
            let permit = try await client.consumeApproval(requestID, request: ConsumeRequest(
                consumeID: consumeID,
                decisionID: decisionID,
                requestHash: record.requestHash,
                runID: record.spec.runID
            ))
            guard permit.consumeID == consumeID,
                  permit.decisionID == decisionID,
                  permit.originID == configuration.originID,
                  permit.runID == record.spec.runID,
                  ContentDigest.matches(permit.requestHash, record.requestHash) else {
                return .retryLater
            }
            try journal.append(.claimed(requestID: requestID, consumeID: consumeID, applyBefore: permit.applyBefore))
            return .claimed
        } catch let error as ControlError where Self.provesNoClaim(error.code) {
            return .noClaim
        } catch {
            return .retryLater
        }
    }

    /// Broker answers that establish our consume ID holds no claim: a retry
    /// under the ID that holds it would have returned its permit instead.
    private static func provesNoClaim(_ code: ControlErrorCode) -> Bool {
        switch code {
        case .alreadyClaimed, .alreadyResolved, .requestExpired, .notFound, .hashMismatch, .deviceRevoked: return true
        default: return false
        }
    }

    private func retireStartupCandidate(_ requestID: ControlID) throws {
        try journal.append(.recoveryCandidateRetired(requestID: requestID))
        startupCandidates?[requestID] = nil
    }

    private func retryPersistedRecoveryMutations() async {
        guard let pending = try? journal.pendingRecoveries() else { return }
        for item in pending {
            do {
                do {
                    try await performRecovery(item)
                } catch let error as ControlError where item.kind == "unknown_receipt" && error.code == .alreadyResolved {
                    // The dispatch is already terminal, or was never claimed:
                    // an authenticated answer that no receipt remains owed.
                }
                if item.kind == "unknown_receipt" {
                    let receipt = try Receipt(json: try JSONValue.parse(Data(item.payload.utf8)))
                    try journal.append(.dispatchResult(requestID: item.requestID, receiptID: receipt.receiptID, result: receipt.result))
                } else {
                    try journal.append(.withdrawn(requestID: item.requestID))
                }
                try journal.append(.recoveryAcknowledged(mutationID: item.mutationID))
            } catch {
                // The immutable obligation and identifiers remain pending.
            }
        }
    }

    private func performRecovery(_ item: DispatchJournal.QueuedRecovery) async throws {
        if item.kind == "unknown_receipt" {
            let receipt = try Receipt(json: try JSONValue.parse(Data(item.payload.utf8)))
            try await client.postReceipt(receipt)
            return
        }
        var reader = try JSONReader(try JSONValue.parse(Data(item.payload.utf8)))
        let mutationID = try reader.id("mutation_id")
        guard mutationID == item.mutationID else { throw ControlError(code: .hashMismatch, message: "recovery mutation identity mismatch") }
        let runID = try reader.id("run_id")
        let requestHash = try reader.string("request_hash", maxLength: 80)
        try reader.rejectUnknownMembers()
        _ = try await client.withdrawApproval(item.requestID, mutationID: item.mutationID,
                                               runID: runID, requestHash: requestHash)
    }

    public func health() -> JSONValue {
        let state: String
        if !acceptingWork {
            state = "not_ready"
        } else if recoveryPendingCount > 0 {
            state = "recovering"
        } else if originAuthenticationIsFresh {
            state = "ready"
        } else {
            state = "not_ready"
        }
        return JSONWriter.object([
            "state": .string(state),
            "store_loaded": .bool(true),
            "ipc_responsive": .bool(true),
            "origin_authenticated": .bool(originAuthenticationIsFresh),
            "recovery_pending": .number(.int(Int64(recoveryPendingCount))),
            "journal_quarantined": journalRepair?.quarantinedTo.map { .string($0.path) }
        ])
    }

    public func shutdown() {
        acceptingWork = false
    }

    public func waitUntilIdle(timeout: TimeInterval) async {
        let deadline = now().addingTimeInterval(timeout)
        while inFlight > 0 && now() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: IPC handlers

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        if !acceptingWork {
            return IPCResponse(
                messageID: request.messageID,
                ok: false,
                errorCode: ControlErrorCode.temporarilyUnavailable.rawValue,
                errorMessage: "daemon is shutting down"
            )
        }
        inFlight += 1
        defer { inFlight = max(0, inFlight - 1) }
        // Retransmission uses the same message ID and body hash; a reused ID
        // with a different body is a conflict (spec.watch.md section 17).
        if let previous = handled[request.messageID] {
            guard let hash = try? request.bodyHash(), hash == previous.bodyHash else {
                return Self.reusedMessageID(request)
            }
            // The recorded result: re-running the handler would create a second
            // request, event, or receipt for one logical message.
            return previous.response
        }
        // The handlers await the broker, so a retransmission can arrive before
        // the first attempt is recorded in `handled`.
        if let running = handling[request.messageID] {
            guard let hash = try? request.bodyHash(), hash == running.bodyHash else {
                return Self.reusedMessageID(request)
            }
            return await running.response.value
        }
        pruneHandled()
        let work = Task { await perform(request) }
        handling[request.messageID] = (try? request.bodyHash(), work)
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private static func reusedMessageID(_ request: IPCRequest) -> IPCResponse {
        IPCResponse(
            messageID: request.messageID,
            ok: false,
            errorCode: ControlErrorCode.idempotencyConflict.rawValue,
            errorMessage: "message id reused with a different body"
        )
    }

    private func perform(_ request: IPCRequest) async -> IPCResponse {
        defer { handling[request.messageID] = nil }
        do {
            let body: JSONValue
            switch request.type {
            case .hello:
                body = try await handleHello(request)
            case .notify:
                body = try await handleNotify(request)
            case .approvalRequest:
                body = try await handleApprovalRequest(request)
            case .approvalWait:
                body = try await handleApprovalWait(request)
            case .approvalWithdraw:
                body = try await handleWithdraw(request)
            case .receipt:
                body = try await handleReceipt(request)
            }
            let response = IPCResponse(messageID: request.messageID, ok: true, body: body)
            handled[request.messageID] = (try request.bodyHash(), response, now())
            return response
        } catch let error as ControlError {
            return IPCResponse(
                messageID: request.messageID,
                ok: false,
                errorCode: error.code.rawValue,
                errorMessage: error.message
            )
        } catch {
            return IPCResponse(
                messageID: request.messageID,
                ok: false,
                errorCode: ControlErrorCode.invalidPayload.rawValue,
                errorMessage: String(describing: error)
            )
        }
    }

    private func pruneHandled() {
        let cutoff = now().addingTimeInterval(-Self.retransmissionWindow)
        handled = handled.filter { $0.value.at > cutoff }
        guard handled.count > Self.maximumHandledMessages else { return }
        let newest = handled.sorted { $0.value.at > $1.value.at }.prefix(Self.maximumHandledMessages)
        handled = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    /// `hello` negotiates protocol, adapter schemas, and capabilities, and
    /// returns the local run binding.
    private func handleHello(_ request: IPCRequest) async throws -> JSONValue {
        var reader = try JSONReader(request.body)
        let protocolName = try reader.string("protocol", maxLength: 32)
        guard protocolName == ServiceCapabilities.protocolName else {
            throw ControlError(code: .unsupportedCommand, message: "unsupported protocol \(protocolName)")
        }
        let adapter = try reader.string("adapter", maxLength: 64)
        let jobLabel = try reader.string("job_label", maxLength: 120)
        let jobID = try reader.optionalID("job_id") ?? .random()
        let capabilities = try reader.stringArray("capabilities", maxCount: 32, maxLength: 64)
        let schemas = try reader.stringArray("operation_schemas", maxCount: 32, maxLength: 64)
        try reader.rejectUnknownMembers()
        guard schemas.allSatisfy({ $0 == ExecOperation.schema }) else {
            // A tool without a negotiated schema gets notifications and a link
            // to review elsewhere, not a synthetic approval implementation.
            throw ControlError(code: .unsupportedOperation, message: "no negotiated renderer for those schemas")
        }
        // A process restart creates a new run; a transport reconnect does not.
        let runID = ControlID.random()
        let capability = DaemonCore.randomCapability()
        let registration = try RunRegistration(
            runID: runID,
            jobID: jobID,
            jobLabel: jobLabel,
            adapter: adapter,
            capabilities: capabilities,
            startedAt: timestamp
        )
        try await client.registerRun(registration)
        pruneRuns()
        runs[capability] = RunBinding(runID: runID, jobID: jobID, capability: capability,
                                      adapter: adapter, operationSchemas: Set(schemas), lastActivity: now())
        try journal.append(.runStarted(runID: runID, jobID: jobID))
        return .object([
            "protocol": .string(ServiceCapabilities.protocolName),
            "run_id": JSONValue(runID),
            "job_id": JSONValue(jobID),
            "run_capability": .string(capability),
            "operation_schemas": JSONValue(strings: [ExecOperation.schema])
        ])
    }

    private func binding(for request: IPCRequest) throws -> RunBinding {
        guard let capability = request.runCapability, var binding = runs[capability] else {
            throw ControlError(code: .notAuthorized, message: "unknown run capability")
        }
        binding.lastActivity = now()
        runs[capability] = binding
        return binding
    }

    private func handleNotify(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let kindText = try reader.optionalString("kind", maxLength: 32) ?? NotificationKind.attention.rawValue
        guard let kind = NotificationKind(rawValue: kindText) else {
            throw ControlError(code: .invalidPayload, message: "unknown notification kind")
        }
        let eventID = try reader.optionalID("event_id") ?? .random()
        let title = try reader.string("title", maxLength: 120)
        let body = try reader.optionalString("body", maxLength: 1000) ?? ""
        try reader.rejectUnknownMembers()
        let event = try InformationalEvent(eventID: eventID, originID: configuration.originID,
                                           jobID: binding.jobID, runID: binding.runID, kind: kind,
                                           title: title, body: body, occurredAt: timestamp)
        try await client.createNotification(event)
        return .object(["event_id": JSONValue(event.eventID)])
    }

    /// Persists the immutable question before publishing it.
    private func handleApprovalRequest(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let summary = try reader.string("summary", maxLength: 200)
        let operation = try ControlOperation.decode(try reader.value("operation"))
        guard binding.operationSchemas.contains(operation.schema) else {
            throw ControlError(code: .unsupportedOperation, message: "operation schema was not negotiated for this run")
        }
        let lifetime = TimeInterval(try reader.optionalInteger("lifetime_seconds") ?? Int64(ApprovalPolicy.defaultLifetime))
        let minimumReviewText = try reader.optionalString("minimum_review", maxLength: 16) ?? MinimumReview.watch.rawValue
        guard let minimumReview = MinimumReview(rawValue: minimumReviewText) else {
            throw ControlError(code: .invalidPayload, message: "unknown minimum_review")
        }
        let requestID = try reader.optionalID("request_id") ?? .random()
        try reader.rejectUnknownMembers()
        let created = timestamp
        let spec = try ApprovalSpec(
            requestID: requestID,
            originID: configuration.originID,
            jobID: binding.jobID,
            runID: binding.runID,
            createdAt: created,
            expiresAt: created.adding(min(lifetime, ApprovalPolicy.maximumLifetime)),
            summary: summary,
            operation: operation,
            minimumReview: minimumReview,
            requiredFeatures: [operation.schema, ControlFeature.consume]
        )
        let hash = try spec.requestHash()
        try journal.append(.requestPersisted(requestID: spec.requestID, requestHash: hash, runID: binding.runID))
        _ = try await client.createApproval(spec)
        try journal.append(.requestPublished(requestID: spec.requestID))
        // Re-read after the awaits above: a concurrent wait on the same
        // capability may have updated the binding, and writing back a stale
        // copy would drop its request from the presence heartbeat.
        markWaiting(spec.requestID, capability: binding.capability, isWaiting: true, until: spec.expiresAt.date)
        let waiting = runs[binding.capability].map { Array($0.waiting.keys) } ?? [spec.requestID]
        try await client.heartbeat(runIDs: [binding.runID], waitingRequestIDs: waiting)
        return .object(["request_id": JSONValue(spec.requestID), "request_hash": .string(hash)])
    }

    /// `approval.wait` names the exact persisted request and returns its
    /// resolution and permit, or a terminal failure
    /// (spec.watch.md section 17).
    private func handleApprovalWait(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let requestID = try reader.id("request_id")
        let requestHash = try reader.string("request_hash", maxLength: 80)
        let timeout = try reader.optionalInteger("timeout_seconds") ?? 600
        guard timeout > 0 && timeout <= 86_400 else { throw ControlError(code: .invalidPayload, message: "invalid wait timeout") }
        try reader.rejectUnknownMembers()
        let deadline = now().addingTimeInterval(TimeInterval(timeout))

        markWaiting(requestID, capability: binding.capability, isWaiting: true)

        while now() < deadline {
            if !acceptingWork {
                return ApprovalWaitOutcome.unavailable(reason: "daemon is shutting down").json
            }
            let waiting = runs[binding.capability].map { Array($0.waiting.keys) } ?? [requestID]
            try await client.heartbeat(runIDs: [binding.runID], waitingRequestIDs: waiting)
            let record = try await client.approval(requestID)
            guard ContentDigest.matches(record.requestHash, requestHash), record.spec.runID == binding.runID else {
                throw ControlError(code: .hashMismatch, message: "the waiting request is not the one recorded")
            }
            switch record.projection.resolution {
            case .pending:
                markWaiting(requestID, capability: binding.capability, isWaiting: true, until: record.spec.expiresAt.date)
                try await Task.sleep(nanoseconds: UInt64(ApprovalPolicy.minimumPollInterval * 1_000_000_000))
                continue
            case .rejected:
                markWaiting(requestID, capability: binding.capability, isWaiting: false)
                guard let decisionID = record.projection.decisionID else {
                    return ApprovalWaitOutcome.unavailable(reason: "no decision recorded").json
                }
                try journal.append(.decisionObserved(requestID: requestID, decisionID: decisionID, resolution: .rejected))
                return ApprovalWaitOutcome.rejected(decisionID: decisionID).json
            case .expired:
                markWaiting(requestID, capability: binding.capability, isWaiting: false)
                return ApprovalWaitOutcome.expired.json
            case .cancelled:
                markWaiting(requestID, capability: binding.capability, isWaiting: false)
                return ApprovalWaitOutcome.cancelled.json
            case .approved:
                guard let decisionID = record.projection.decisionID else {
                    return ApprovalWaitOutcome.unavailable(reason: "no decision id").json
                }
                try journal.append(.decisionObserved(requestID: requestID, decisionID: decisionID, resolution: .approved))
                // The origin validates the waiting run, request hash, and local
                // context before claiming (spec.watch.md section 12). The
                // consume ID is journaled first, so a lost reply is retried
                // under the same ID, here or by restart recovery.
                let consumeID = try journaledConsumeID(for: requestID, decisionID: decisionID, capability: binding.capability)
                let permit = try await consume(
                    requestID,
                    request: ConsumeRequest(
                        consumeID: consumeID,
                        decisionID: decisionID,
                        requestHash: record.requestHash,
                        runID: binding.runID
                    ),
                    deadline: deadline
                )
                guard permit.consumeID == consumeID,
                      permit.decisionID == decisionID,
                      permit.originID == configuration.originID,
                      permit.runID == binding.runID,
                      ContentDigest.matches(permit.requestHash, requestHash),
                      permit.decision == .approve else {
                    throw ControlError(code: .hashMismatch, message: "consume permit does not match the blocked run and request")
                }
                try journal.append(.claimed(requestID: requestID, consumeID: consumeID, applyBefore: permit.applyBefore))
                markWaiting(requestID, capability: binding.capability, isWaiting: false)
                guard permit.isApplicable(at: timestamp) else {
                    // Failure to apply before expiry means no authorization.
                    return ApprovalWaitOutcome.unavailable(reason: "permit deadline passed before dispatch").json
                }
                try journal.append(.dispatchIntent(requestID: requestID, consumeID: consumeID))
                return ApprovalWaitOutcome.approved(permit).json
            }
        }
        return ApprovalWaitOutcome.unavailable(reason: "wait timed out").json
    }

    private func handleWithdraw(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let requestID = try reader.id("request_id")
        let requestHash = try reader.string("request_hash", maxLength: 80)
        let mutationID = try reader.optionalID("mutation_id") ?? .random()
        try reader.rejectUnknownMembers()
        let projection = try await client.withdrawApproval(
            requestID,
            mutationID: mutationID,
            runID: binding.runID,
            requestHash: requestHash
        )
        try journal.append(.withdrawn(requestID: requestID))
        markWaiting(requestID, capability: binding.capability, isWaiting: false)
        runs[binding.capability]?.consumeIntents[requestID] = nil
        return projection.json
    }

    /// `receipt` reports what the adapter actually applied.
    private func handleReceipt(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let resultText = try reader.string("result", maxLength: 24)
        guard let result = ReceiptResult(rawValue: resultText) else {
            throw ControlError(code: .invalidPayload, message: "unknown receipt result")
        }
        let receiptID = try reader.optionalID("receipt_id") ?? .random()
        let decisionID = try reader.optionalID("decision_id")
        let consumeID = try reader.optionalID("consume_id")
        let commandID = try reader.optionalID("command_id")
        let requestHash = try reader.optionalString("request_hash", maxLength: 80)
        let jobID = try reader.optionalID("job_id")
        let reasonCode = try reader.optionalString("reason_code", maxLength: 64) ?? "adapter_reported"
        let jobState = try reader.optionalString("job_state", maxLength: 32)
        let requestID = try reader.optionalID("request_id")
        try reader.rejectUnknownMembers()
        let receipt = Receipt(receiptID: receiptID, decisionID: decisionID, consumeID: consumeID,
                              commandID: commandID, requestHash: requestHash, jobID: jobID,
                              runID: binding.runID, result: result, reasonCode: reasonCode,
                              occurredAt: timestamp, jobState: jobState)
        try await client.postReceipt(receipt)
        if let requestID {
            try journal.append(.dispatchResult(requestID: requestID, receiptID: receipt.receiptID, result: result))
            runs[binding.capability]?.consumeIntents[requestID] = nil
        }
        return .object(["receipt_id": JSONValue(receipt.receiptID)])
    }

    /// Refreshes presence for the runs blocked on a request, batched.
    ///
    /// Presence only matters while a request can still be approved, so a run
    /// with nothing waiting is not sent: without that, every `hello` since
    /// launch would cost the broker a presence write every interval.
    public func heartbeatOnce() async {
        pruneRuns()
        let live = runs.values.filter { !$0.waiting.isEmpty }.sorted { $0.runID.rawValue < $1.runID.rawValue }
        let liveIDs = Set(live.map(\.runID))
        let drained = drainedRuns.subtracting(liveIDs)
        drainedRuns.removeAll()

        var batches: [(runIDs: [ControlID], waiting: [ControlID])] = []
        var batch: (runIDs: [ControlID], waiting: [ControlID]) = ([], [])
        func add(_ runID: ControlID, _ waiting: [ControlID]) {
            let waiting = Array(waiting.prefix(Self.heartbeatMaximumWaiting))
            if !batch.runIDs.isEmpty,
               batch.runIDs.count >= Self.heartbeatMaximumRuns
                || batch.waiting.count + waiting.count > Self.heartbeatMaximumWaiting {
                batches.append(batch)
                batch = ([], [])
            }
            batch.runIDs.append(runID)
            batch.waiting.append(contentsOf: waiting)
        }
        for binding in live { add(binding.runID, Array(binding.waiting.keys)) }
        // A drained run is sent once with nothing waiting, clearing the flag.
        for runID in drained.sorted(by: { $0.rawValue < $1.rawValue }) { add(runID, []) }
        // A heartbeat with no runs still proves origin authentication.
        if !batch.runIDs.isEmpty || batches.isEmpty { batches.append(batch) }

        var authenticated = false
        for batch in batches {
            do {
                try await client.heartbeat(runIDs: batch.runIDs, waitingRequestIDs: batch.waiting)
                authenticated = true
            } catch {
                drainedRuns.formUnion(drained.intersection(batch.runIDs))
            }
        }
        lastOriginAuthentication = authenticated ? .now : nil
    }

    /// Drops expired waits, then idle bindings. A binding with a request that
    /// can still be approved is never dropped.
    private func pruneRuns() {
        let current = now()
        for (capability, var binding) in runs where !binding.waiting.isEmpty {
            binding.waiting = binding.waiting.filter { $0.value > current }
            if binding.waiting.isEmpty { drainedRuns.insert(binding.runID) }
            runs[capability] = binding
        }
        let cutoff = current.addingTimeInterval(-Self.runBindingIdleLifetime)
        runs = runs.filter { !$0.value.waiting.isEmpty || $0.value.lastActivity > cutoff }
        if runs.count > Self.maximumRunBindings {
            let idle = runs.filter { $0.value.waiting.isEmpty }.sorted { $0.value.lastActivity < $1.value.lastActivity }
            for (capability, _) in idle.prefix(runs.count - Self.maximumRunBindings) {
                runs[capability] = nil
            }
        }
        let known = Set(runs.values.map(\.runID))
        drainedRuns.formIntersection(known)
    }

    /// The run IDs the next heartbeat would carry, for tests.
    func presenceRunIDs() -> Set<ControlID> {
        Set(runs.values.filter { !$0.waiting.isEmpty }.map(\.runID)).union(drainedRuns)
    }

    var runBindingCount: Int { runs.count }

    private var originAuthenticationIsFresh: Bool {
        guard let lastOriginAuthentication else { return false }
        return lastOriginAuthentication.duration(to: .now) <= .seconds(max(30, configuration.heartbeatInterval * 2))
    }

    public func runHeartbeats() async {
        while !Task.isCancelled {
            // Retry boot-scoped candidates and already-persisted mutations;
            // never rediscover all unfinished entries from live runs.
            try? await runRecoveryPass()
            await heartbeatOnce()
            try? await Task.sleep(nanoseconds: UInt64(configuration.heartbeatInterval * 1_000_000_000))
        }
    }

    /// Read-modify-write on the live binding, never on a copy captured before
    /// an `await`.
    private func markWaiting(_ requestID: ControlID, capability: String, isWaiting: Bool, until expiry: Date? = nil) {
        guard var binding = runs[capability] else { return }
        if isWaiting {
            binding.waiting[requestID] = expiry
                ?? binding.waiting[requestID]
                ?? now().addingTimeInterval(ApprovalPolicy.maximumLifetime)
        } else if binding.waiting.removeValue(forKey: requestID) != nil, binding.waiting.isEmpty {
            drainedRuns.insert(binding.runID)
        }
        runs[capability] = binding
    }

    /// The consume ID for this request, journaled before first use and reused
    /// by every retry.
    private func journaledConsumeID(for requestID: ControlID, decisionID: ControlID, capability: String) throws -> ControlID {
        if let existing = runs[capability]?.consumeIntents[requestID] { return existing }
        let consumeID = ControlID.random()
        try journal.append(.consumeIntent(requestID: requestID, consumeID: consumeID, decisionID: decisionID))
        runs[capability]?.consumeIntents[requestID] = consumeID
        return consumeID
    }

    /// Retries a lost consume reply under the same consume ID until the wait's
    /// deadline. A definitive broker refusal is not retried.
    private func consume(_ requestID: ControlID, request: ConsumeRequest, deadline: Date) async throws -> ConsumePermit {
        var delay: TimeInterval = 0.25
        while true {
            do {
                return try await client.consumeApproval(requestID, request: request)
            } catch let error as ControlError where !error.code.isRetryable {
                throw error
            } catch {
                guard acceptingWork, now() < deadline, !Task.isCancelled else { throw error }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, ApprovalPolicy.minimumPollInterval)
            }
        }
    }

    static func randomCapability() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).map { String(format: "%02x", $0) }.joined()
    }
}
