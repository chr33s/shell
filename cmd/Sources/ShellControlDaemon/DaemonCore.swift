import Foundation
import ShellControlProtocol
import ShellControlClient

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
        public var journalURL: URL
        public var heartbeatInterval: TimeInterval

        public init(
            brokerURL: URL,
            originID: ControlID,
            originSecret: String,
            socketPath: String,
            journalURL: URL,
            heartbeatInterval: TimeInterval = ApprovalPolicy.heartbeatInterval
        ) {
            self.brokerURL = brokerURL
            self.originID = originID
            self.originSecret = originSecret
            self.socketPath = socketPath
            self.journalURL = journalURL
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
        var waiting: Set<ControlID> = []
    }

    let configuration: Configuration
    let client: ControlAPIClient
    let journal: DispatchJournal
    private var runs: [String: RunBinding] = [:]
    /// Recorded results for message IDs already handled, so a retransmission
    /// replays rather than mints a second request, event, or receipt.
    private var handled: [ControlID: (bodyHash: String, response: IPCResponse)] = [:]
    private let now: @Sendable () -> Date

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

    /// On restart, reconcile the journal, broker state, and live run identity.
    /// When safe continuation cannot be proven, the daemon does not apply and a
    /// new request is required (spec.watch.md section 17).
    public func reconcileAfterRestart() async throws {
        let recovery = try journal.recover()
        for requestID in recovery.uncertain {
            // Uncertain external effects are reported unknown, never replayed.
            guard let record = try? await client.approval(requestID) else { continue }
            let receipt = Receipt(
                receiptID: .random(),
                decisionID: record.projection.decisionID,
                consumeID: nil,
                requestHash: record.requestHash,
                runID: record.spec.runID,
                result: .unknown,
                reasonCode: "daemon_restarted_after_claim",
                occurredAt: timestamp
            )
            try? await client.postReceipt(receipt)
            try journal.append(.dispatchResult(requestID: requestID, receiptID: receipt.receiptID, result: .unknown))
        }
        for requestID in recovery.unresolved {
            guard let record = try? await client.approval(requestID) else { continue }
            guard record.projection.resolution == .pending else { continue }
            // The waiter did not survive the restart, so the question is
            // withdrawn rather than answered into a process that no longer
            // exists.
            _ = try? await client.withdrawApproval(
                requestID,
                mutationID: .random(),
                runID: record.spec.runID,
                requestHash: record.requestHash
            )
            try journal.append(.withdrawn(requestID: requestID))
        }
    }

    // MARK: IPC handlers

    public func handle(_ request: IPCRequest) async -> IPCResponse {
        // Retransmission uses the same message ID and body hash; a reused ID
        // with a different body is a conflict (spec.watch.md section 17).
        if let previous = handled[request.messageID] {
            guard let hash = try? request.bodyHash(), hash == previous.bodyHash else {
                return IPCResponse(
                    messageID: request.messageID,
                    ok: false,
                    errorCode: ControlErrorCode.idempotencyConflict.rawValue,
                    errorMessage: "message id reused with a different body"
                )
            }
            // The recorded result: re-running the handler would create a second
            // request, event, or receipt for one logical message.
            return previous.response
        }
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
            handled[request.messageID] = (try request.bodyHash(), response)
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
        runs[capability] = RunBinding(runID: runID, jobID: jobID, capability: capability, adapter: adapter)
        try journal.append(.runStarted(runID: runID, jobID: jobID))
        return .object([
            "protocol": .string(ServiceCapabilities.protocolName),
            "run_id": JSONValue(runID),
            "job_id": JSONValue(jobID),
            "run_capability": .string(capability),
            "operation_schemas": JSONValue(strings: [ExecOperation.schema]),
        ])
    }

    private func binding(for request: IPCRequest) throws -> RunBinding {
        guard let capability = request.runCapability, let binding = runs[capability] else {
            throw ControlError(code: .notAuthorized, message: "unknown run capability")
        }
        return binding
    }

    private func handleNotify(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let kindText = try reader.optionalString("kind", maxLength: 32) ?? NotificationKind.attention.rawValue
        guard let kind = NotificationKind(rawValue: kindText) else {
            throw ControlError(code: .invalidPayload, message: "unknown notification kind")
        }
        let event = try InformationalEvent(
            eventID: try reader.optionalID("event_id") ?? .random(),
            originID: configuration.originID,
            jobID: binding.jobID,
            runID: binding.runID,
            kind: kind,
            title: try reader.string("title", maxLength: 120),
            body: try reader.optionalString("body", maxLength: 1000) ?? "",
            occurredAt: timestamp
        )
        try await client.createNotification(event)
        return .object(["event_id": JSONValue(event.eventID)])
    }

    /// Persists the immutable question before publishing it.
    private func handleApprovalRequest(_ request: IPCRequest) async throws -> JSONValue {
        let binding = try binding(for: request)
        var reader = try JSONReader(request.body)
        let summary = try reader.string("summary", maxLength: 200)
        let operation = try ControlOperation.decode(try reader.value("operation"))
        let lifetime = TimeInterval(try reader.optionalInteger("lifetime_seconds") ?? Int64(ApprovalPolicy.defaultLifetime))
        let minimumReviewText = try reader.optionalString("minimum_review", maxLength: 16) ?? MinimumReview.watch.rawValue
        guard let minimumReview = MinimumReview(rawValue: minimumReviewText) else {
            throw ControlError(code: .invalidPayload, message: "unknown minimum_review")
        }
        let created = timestamp
        let spec = try ApprovalSpec(
            requestID: try reader.optionalID("request_id") ?? .random(),
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
        markWaiting(spec.requestID, capability: binding.capability, isWaiting: true)
        let waiting = runs[binding.capability]?.waiting ?? [spec.requestID]
        try await client.heartbeat(runIDs: [binding.runID], waitingRequestIDs: Array(waiting))
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
        let deadline = now().addingTimeInterval(TimeInterval(try reader.optionalInteger("timeout_seconds") ?? 600))

        markWaiting(requestID, capability: binding.capability, isWaiting: true)

        while now() < deadline {
            let waiting = runs[binding.capability]?.waiting ?? [requestID]
            try await client.heartbeat(runIDs: [binding.runID], waitingRequestIDs: Array(waiting))
            let record = try await client.approval(requestID)
            guard ContentDigest.matches(record.requestHash, requestHash), record.spec.runID == binding.runID else {
                throw ControlError(code: .hashMismatch, message: "the waiting request is not the one recorded")
            }
            switch record.projection.resolution {
            case .pending:
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
                // context before claiming (spec.watch.md section 12).
                let consumeID = ControlID.random()
                let permit = try await client.consumeApproval(
                    requestID,
                    request: ConsumeRequest(
                        consumeID: consumeID,
                        decisionID: decisionID,
                        requestHash: record.requestHash,
                        runID: binding.runID
                    )
                )
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
        let projection = try await client.withdrawApproval(
            requestID,
            mutationID: try reader.optionalID("mutation_id") ?? .random(),
            runID: binding.runID,
            requestHash: requestHash
        )
        try journal.append(.withdrawn(requestID: requestID))
        markWaiting(requestID, capability: binding.capability, isWaiting: false)
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
        let receipt = Receipt(
            receiptID: try reader.optionalID("receipt_id") ?? .random(),
            decisionID: try reader.optionalID("decision_id"),
            consumeID: try reader.optionalID("consume_id"),
            commandID: try reader.optionalID("command_id"),
            requestHash: try reader.optionalString("request_hash", maxLength: 80),
            jobID: try reader.optionalID("job_id"),
            runID: binding.runID,
            result: result,
            reasonCode: try reader.optionalString("reason_code", maxLength: 64) ?? "adapter_reported",
            occurredAt: timestamp,
            jobState: try reader.optionalString("job_state", maxLength: 32)
        )
        try await client.postReceipt(receipt)
        if let requestID = try reader.optionalID("request_id") {
            try journal.append(.dispatchResult(requestID: requestID, receiptID: receipt.receiptID, result: result))
        }
        return .object(["receipt_id": JSONValue(receipt.receiptID)])
    }

    /// Refreshes presence for active runs and their waiters.
    public func heartbeatOnce() async {
        for binding in runs.values {
            try? await client.heartbeat(runIDs: [binding.runID], waitingRequestIDs: Array(binding.waiting))
        }
    }

    public func runHeartbeats() async {
        while !Task.isCancelled {
            await heartbeatOnce()
            try? await Task.sleep(nanoseconds: UInt64(configuration.heartbeatInterval * 1_000_000_000))
        }
    }

    /// Read-modify-write on the live binding, never on a copy captured before
    /// an `await`.
    private func markWaiting(_ requestID: ControlID, capability: String, isWaiting: Bool) {
        guard var binding = runs[capability] else { return }
        if isWaiting {
            binding.waiting.insert(requestID)
        } else {
            binding.waiting.remove(requestID)
        }
        runs[capability] = binding
    }

    static func randomCapability() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).map { String(format: "%02x", $0) }.joined()
    }
}
