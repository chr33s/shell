import Foundation
import Testing
import ShellControlProtocol
import ShellControlClient
@testable import ShellControlDaemon

/// A scripted broker: enough of the origin-facing surface to drive the daemon
/// end to end without a network (docs/specs/control-protocol.md section 19.5).
actor FakeBroker: ControlHTTPTransport {
    var approvals: [ControlID: ApprovalRecord] = [:]
    var receipts: [Receipt] = []
    var permits: [ControlID: ConsumePermit] = [:]
    var heartbeats = 0
    var notifications: [InformationalEvent] = []
    var consumeCount = 0
    var failReceipts = false
    var receiptAttempts = 0
    var withdrawals = 0
    /// The `run_ids` of every heartbeat, in order.
    var heartbeatRuns: [[String]] = []
    /// Which consume ID holds each request's claim, as the real broker keeps.
    var consumedBy: [ControlID: ControlID] = [:]
    /// Every consume ID presented, in order.
    var consumeIDs: [ControlID] = []
    /// Commit the next consume, then lose its reply.
    var dropNextConsumeReply = false
    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date) { self.now = now }

    func resolve(_ requestID: ControlID, as resolution: Resolution, decisionID: ControlID) throws {
        guard var record = approvals[requestID] else { return }
        record.projection.resolution = resolution
        record.projection.dispatch = .awaitingOrigin
        record.projection.decisionID = decisionID
        record.projection.stateVersion += 1
        approvals[requestID] = record
    }

    func send(_ request: ControlHTTPRequest, baseURL: URL) async throws -> ControlHTTPResponse {
        func ok(_ value: JSONValue) throws -> ControlHTTPResponse {
            ControlHTTPResponse(status: 200, body: try JSONCanonicalization.canonicalize(value))
        }
        let stamp = ControlTimestamp(now())
        switch (request.method, request.path) {
        case ("PUT", let path) where path.hasPrefix("/v1/origins/me/runs/"):
            return try ok(.object(["ok": true]))
        case ("POST", "/v1/origins/me/heartbeat"):
            heartbeats += 1
            let body = try JSONValue.parse(request.body ?? Data())
            heartbeatRuns.append(body["run_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            return try ok(.object(["ok": true]))
        case ("POST", "/v1/notifications"):
            let event = try InformationalEvent(json: try JSONValue.parse(request.body ?? Data()))
            notifications.append(event)
            return try ok(event.json)
        case ("POST", "/v1/approvals"):
            let spec = try ApprovalSpec(json: try JSONValue.parse(request.body ?? Data()))
            let record = try ApprovalRecord(
                spec: spec,
                projection: ApprovalProjection(presence: SourcePresence(lastSeenAt: stamp, isWaiting: true))
            )
            approvals[spec.requestID] = record
            return try ok(record.json)
        case ("POST", "/v1/receipts"):
            receiptAttempts += 1
            if failReceipts {
                throw TransportError.offline
            }
            receipts.append(try Receipt(json: try JSONValue.parse(request.body ?? Data())))
            return try ok(.object(["ok": true]))
        default:
            break
        }
        if request.method == "GET", request.path.hasPrefix("/v1/approvals/") {
            let id = ControlID(String(request.path.dropFirst("/v1/approvals/".count)))
            guard let id, let record = approvals[id] else {
                return ControlHTTPResponse(status: 404, body: try JSONCanonicalization.canonicalize(
                    ControlError(code: .notFound, message: "no such request").json
                ))
            }
            return try ok(record.json)
        }
        if request.method == "POST", request.path.hasSuffix("/consume") {
            consumeCount += 1
            let consume = try ConsumeRequest(json: try JSONValue.parse(request.body ?? Data()))
            let idText = String(request.path.dropFirst("/v1/approvals/".count).dropLast("/consume".count))
            guard let requestID = ControlID(idText), var record = approvals[requestID] else {
                return ControlHTTPResponse(status: 404, body: Data("{}".utf8))
            }
            consumeIDs.append(consume.consumeID)
            // Same-ID retries return the recorded permit; another ID is refused.
            if let holder = consumedBy[requestID] {
                if holder == consume.consumeID, let permit = permits[holder] { return try ok(permit.json) }
                return ControlHTTPResponse(status: 409, body: try JSONCanonicalization.canonicalize(
                    ControlError(code: .alreadyClaimed, message: "approval was already claimed").json
                ))
            }
            let permit = ConsumePermit(
                consumeID: consume.consumeID,
                decisionID: consume.decisionID,
                originID: record.spec.originID,
                runID: consume.runID,
                requestHash: record.requestHash,
                applyBefore: stamp.adding(ApprovalPolicy.permitLifetime),
                decision: .approve,
                decisionJWS: "header.payload.signature"
            )
            permits[consume.consumeID] = permit
            consumedBy[requestID] = consume.consumeID
            record.projection.dispatch = .claimed
            approvals[requestID] = record
            if dropNextConsumeReply {
                dropNextConsumeReply = false
                throw TransportError.offline
            }
            return try ok(permit.json)
        }
        if request.method == "POST", request.path.hasSuffix("/withdraw") {
            withdrawals += 1
            return try ok(.object(["projection": ApprovalProjection(resolution: .cancelled, dispatch: .notApplied).json]))
        }
        return ControlHTTPResponse(status: 404, body: Data("{}".utf8))
    }
}

@Suite
final class DaemonTests {
    private func makeCore(
        _ broker: FakeBroker,
        now: @escaping @Sendable () -> Date,
        heartbeatInterval: TimeInterval = ApprovalPolicy.heartbeatInterval
    ) throws -> (DaemonCore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-controld-tests-\(UUID().uuidString)")
        let originID = ControlID.random()
        let configuration = DaemonCore.Configuration(
            brokerURL: URL(string: "https://broker.test")!,
            originID: originID,
            originSecret: "secret",
            socketPath: directory.appendingPathComponent("control.sock").path,
            journalURL: directory.appendingPathComponent("journal.ndjson"),
            heartbeatInterval: heartbeatInterval
        )
        let client = ControlAPIClient(
            baseURL: configuration.brokerURL,
            transport: broker,
            credential: .origin(originID: originID, secret: "secret")
        )
        return (try DaemonCore(configuration: configuration, client: client, now: now), directory)
    }

    @Test
    func testHelloRequestApproveWaitAndReceipt() async throws {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }

        let hello = await core.handle(IPCRequest(
            messageID: .random(),
            type: .hello,
            runCapability: nil,
            body: .object([
                "protocol": .string(ServiceCapabilities.protocolName),
                "adapter": "test-adapter",
                "job_label": "build",
                "capabilities": .array(["consume.v1"]),
                "operation_schemas": .array([.string(ExecOperation.schema)])
            ])
        ))
        #expect(hello.ok)
        var helloReader = try JSONReader(hello.body)
        let capability = try helloReader.string("run_capability", maxLength: 128)
        #expect(!(capability.isEmpty))

        let created = await core.handle(IPCRequest(
            messageID: .random(),
            type: .approvalRequest,
            runCapability: capability,
            body: .object([
                "summary": "Push feature branch",
                "operation": .object([
                    "schema": .string(ExecOperation.schema),
                    "argv": .array(["/usr/bin/git", "push"]),
                    "cwd": "/srv/work/shell",
                    "context_sha256": .string(String(repeating: "0", count: 64))
                ])
            ])
        ))
        #expect(created.ok)
        var createdReader = try JSONReader(created.body)
        let requestID = try createdReader.id("request_id")
        let requestHash = try createdReader.string("request_hash", maxLength: 80)

        // The Watch approves out of band.
        let decisionID = ControlID.random()
        try await broker.resolve(requestID, as: .approved, decisionID: decisionID)

        let waited = await core.handle(IPCRequest(
            messageID: .random(),
            type: .approvalWait,
            runCapability: capability,
            body: .object([
                "request_id": JSONValue(requestID),
                "request_hash": .string(requestHash),
                "timeout_seconds": 30
            ])
        ))
        #expect(waited.ok)
        let outcome = try ApprovalWaitOutcome(json: waited.body)
        guard case .approved(let permit) = outcome else { Issue.record("expected an approved permit")
return }
        #expect(permit.decisionID == decisionID)
        #expect(outcome.exitCode == .approved)

        let receipt = await core.handle(IPCRequest(
            messageID: .random(),
            type: .receipt,
            runCapability: capability,
            body: .object([
                "result": "applied",
                "request_id": JSONValue(requestID),
                "decision_id": JSONValue(decisionID),
                "consume_id": JSONValue(permit.consumeID),
                "request_hash": .string(requestHash)
            ])
        ))
        #expect(receipt.ok)
        let recorded = await broker.receipts
        #expect(recorded.first?.result == .applied)
        clock = clock.addingTimeInterval(1)
    }

    @Test
    func testRejectionReturnsExitCodeTenAndClaimsNothing() async throws {
        nonisolated(unsafe) let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        let hello = await core.handle(IPCRequest(
            messageID: .random(),
            type: .hello,
            runCapability: nil,
            body: .object([
                "protocol": .string(ServiceCapabilities.protocolName),
                "adapter": "test-adapter",
                "job_label": "build",
                "capabilities": .array([]),
                "operation_schemas": .array([.string(ExecOperation.schema)])
            ])
        ))
        var helloReader = try JSONReader(hello.body)
        let capability = try helloReader.string("run_capability", maxLength: 128)
        let created = await core.handle(IPCRequest(
            messageID: .random(),
            type: .approvalRequest,
            runCapability: capability,
            body: .object([
                "summary": "Push feature branch",
                "operation": .object([
                    "schema": .string(ExecOperation.schema),
                    "argv": .array(["/usr/bin/git", "push"]),
                    "cwd": "/srv/work/shell",
                    "context_sha256": .string(String(repeating: "0", count: 64))
                ])
            ])
        ))
        var createdReader = try JSONReader(created.body)
        let requestID = try createdReader.id("request_id")
        let requestHash = try createdReader.string("request_hash", maxLength: 80)
        try await broker.resolve(requestID, as: .rejected, decisionID: .random())
        let waited = await core.handle(IPCRequest(
            messageID: .random(),
            type: .approvalWait,
            runCapability: capability,
            body: .object([
                "request_id": JSONValue(requestID),
                "request_hash": .string(requestHash),
                "timeout_seconds": 30
            ])
        ))
        let outcome = try ApprovalWaitOutcome(json: waited.body)
        #expect(outcome.exitCode == .rejected)
        let consumes = await broker.consumeCount
        #expect(consumes == 0)
    }

    @Test
    func testUnknownRunCapabilityIsRefused() async throws {
        nonisolated(unsafe) let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = await core.handle(IPCRequest(
            messageID: .random(),
            type: .notify,
            runCapability: "not-a-real-capability",
            body: .object(["title": "hi"])
        ))
        #expect(!(response.ok))
        #expect(response.errorCode == ControlErrorCode.notAuthorized.rawValue)
    }

    @Test
    func testRetransmissionWithADifferentBodyConflicts() async throws {
        nonisolated(unsafe) let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        let messageID = ControlID.random()
        let hello = IPCRequest(
            messageID: messageID,
            type: .hello,
            runCapability: nil,
            body: .object([
                "protocol": .string(ServiceCapabilities.protocolName),
                "adapter": "test-adapter",
                "job_label": "build",
                "capabilities": .array([]),
                "operation_schemas": .array([.string(ExecOperation.schema)])
            ])
        )
        let first = await core.handle(hello)
        #expect(first.ok)
        let changed = IPCRequest(
            messageID: messageID,
            type: .hello,
            runCapability: nil,
            body: .object([
                "protocol": .string(ServiceCapabilities.protocolName),
                "adapter": "other-adapter",
                "job_label": "build",
                "capabilities": .array([]),
                "operation_schemas": .array([.string(ExecOperation.schema)])
            ])
        )
        let response = await core.handle(changed)
        #expect(!(response.ok))
        #expect(response.errorCode == ControlErrorCode.idempotencyConflict.rawValue)
    }

    @Test
    func testUnnegotiatedOperationSchemaGetsNoApprovalPath() async throws {
        nonisolated(unsafe) let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = await core.handle(IPCRequest(
            messageID: .random(),
            type: .hello,
            runCapability: nil,
            body: .object([
                "protocol": .string(ServiceCapabilities.protocolName),
                "adapter": "kubectl",
                "job_label": "deploy",
                "capabilities": .array([]),
                "operation_schemas": .array(["k8s.apply.v1"])
            ])
        ))
        #expect(!(response.ok))
        #expect(response.errorCode == ControlErrorCode.unsupportedOperation.rawValue)
    }

    /// A retransmission with the same message id and body must replay the
    /// recorded result, not mint a second request on the broker.
    @Test
    func testRetransmissionReplaysInsteadOfCreatingASecondRequest() async throws {
        nonisolated(unsafe) let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        let hello = await core.handle(IPCRequest(
            messageID: .random(),
            type: .hello,
            runCapability: nil,
            body: .object([
                "protocol": .string(ServiceCapabilities.protocolName),
                "adapter": "test-adapter",
                "job_label": "build",
                "capabilities": .array([]),
                "operation_schemas": .array([.string(ExecOperation.schema)])
            ])
        ))
        var helloReader = try JSONReader(hello.body)
        let capability = try helloReader.string("run_capability", maxLength: 128)
        let request = IPCRequest(
            messageID: .random(),
            type: .approvalRequest,
            runCapability: capability,
            body: .object([
                "summary": "Push feature branch",
                "operation": .object([
                    "schema": .string(ExecOperation.schema),
                    "argv": .array(["/usr/bin/git", "push"]),
                    "cwd": "/srv/work/shell",
                    "context_sha256": .string(String(repeating: "0", count: 64))
                ])
            ])
        )
        let first = await core.handle(request)
        let replay = await core.handle(request)
        #expect(first.ok)
        #expect(replay.ok)
        #expect(first.body == replay.body)
        let published = await broker.approvals.count
        #expect(published == 1)
    }

    /// Two waits on one run capability must not lose each other's presence.
    @Test
    func testConcurrentWaitsKeepBothRequestsInThePresenceLease() async throws {
        nonisolated(unsafe) let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        let hello = await core.handle(IPCRequest(
            messageID: .random(),
            type: .hello,
            runCapability: nil,
            body: .object([
                "protocol": .string(ServiceCapabilities.protocolName),
                "adapter": "test-adapter",
                "job_label": "build",
                "capabilities": .array([]),
                "operation_schemas": .array([.string(ExecOperation.schema)])
            ])
        ))
        var helloReader = try JSONReader(hello.body)
        let capability = try helloReader.string("run_capability", maxLength: 128)

        func create() async throws -> (ControlID, String) {
            let created = await core.handle(IPCRequest(
                messageID: .random(),
                type: .approvalRequest,
                runCapability: capability,
                body: .object([
                    "summary": "Push feature branch",
                    "operation": .object([
                        "schema": .string(ExecOperation.schema),
                        "argv": .array(["/usr/bin/git", "push"]),
                        "cwd": "/srv/work/shell",
                        "context_sha256": .string(String(repeating: "0", count: 64))
                    ])
                ])
            ))
            var reader = try JSONReader(created.body)
            return (try reader.id("request_id"), try reader.string("request_hash", maxLength: 80))
        }

        let (firstID, firstHash) = try await create()
        let (secondID, secondHash) = try await create()
        try await broker.resolve(firstID, as: .rejected, decisionID: .random())

        async let firstWait = core.handle(IPCRequest(
            messageID: .random(),
            type: .approvalWait,
            runCapability: capability,
            body: .object([
                "request_id": JSONValue(firstID),
                "request_hash": .string(firstHash),
                "timeout_seconds": 5
            ])
        ))
        async let secondWait = core.handle(IPCRequest(
            messageID: .random(),
            type: .approvalWait,
            runCapability: capability,
            body: .object([
                "request_id": JSONValue(secondID),
                "request_hash": .string(secondHash),
                "timeout_seconds": 5
            ])
        ))
        _ = await firstWait
        // The first wait resolving must not drop the second from the lease.
        try await broker.resolve(secondID, as: .rejected, decisionID: .random())
        let outcome = try ApprovalWaitOutcome(json: (await secondWait).body)
        #expect(outcome.exitCode == .rejected)
    }

    // MARK: Journal

    @Test
    func testJournalRecoveryReportsUncertainDispatch() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-controld-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson"))
        let requestID = ControlID.random()
        let consumeID = ControlID.random()
        let stamp = ControlTimestamp(Date(timeIntervalSince1970: 1_788_000_000))
        try journal.append(.requestPersisted(requestID: requestID, requestHash: "sha256:" + String(repeating: "0", count: 64), runID: .random()))
        try journal.append(.requestPublished(requestID: requestID))
        try journal.append(.decisionObserved(requestID: requestID, decisionID: .random(), resolution: .approved))
        try journal.append(.claimed(requestID: requestID, consumeID: consumeID, applyBefore: stamp.adding(10)))
        try journal.append(.dispatchIntent(requestID: requestID, consumeID: consumeID))

        // Crashed between dispatch and receipt: the effect is uncertain.
        var recovery = try journal.recover()
        #expect(recovery.uncertain.contains(requestID))

        try journal.append(.dispatchResult(requestID: requestID, receiptID: .random(), result: .unknown))
        recovery = try journal.recover()
        #expect(!(recovery.uncertain.contains(requestID)))
        #expect(!(recovery.unresolved.contains(requestID)))
    }

    @Test
    func testJournalTracksUnresolvedRequests() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-controld-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson"))
        let requestID = ControlID.random()
        try journal.append(.requestPersisted(requestID: requestID, requestHash: "sha256:" + String(repeating: "0", count: 64), runID: .random()))
        #expect(try journal.recover().unresolved.contains(requestID))
        try journal.append(.withdrawn(requestID: requestID))
        #expect(!(try journal.recover().unresolved.contains(requestID)))
    }

    @Test
    func testFailedRecoveryWriteDoesNotCompleteTheObligation() async throws {
        nonisolated(unsafe) let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        await broker.setFailReceipts(true)
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson"))
        let requestID = ControlID.random()
        let mutationID = ControlID.random()
        let receipt = Receipt(
            receiptID: .random(),
            decisionID: .random(),
            consumeID: nil,
            requestHash: "sha256:" + String(repeating: "0", count: 64),
            runID: .random(),
            result: .unknown,
            reasonCode: "daemon_restarted_after_claim",
            occurredAt: ControlTimestamp(clock)
        )
        let payload = String(decoding: try JSONCanonicalization.canonicalize(receipt.json), as: UTF8.self)
        try journal.append(.recoveryQueued(
            mutationID: mutationID,
            kind: "unknown_receipt",
            requestID: requestID,
            payload: payload
        ))
        try await core.reconcileAfterRestart()
        #expect((try journal.pendingRecoveries().count) == 1)
        let posted = await broker.receipts
        #expect(posted.isEmpty)
        let attempts = await broker.receiptAttempts
        #expect(attempts >= 1)
    }

    @Test
    func testHeartbeatRetriesRecoveryWithoutAnotherRestart() async throws {
        nonisolated(unsafe) let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        await broker.setFailReceipts(true)
        let (core, directory) = try makeCore(broker, now: { clock }, heartbeatInterval: 0.01)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson"))
        let requestID = ControlID.random()
        let receipt = Receipt(
            receiptID: .random(),
            decisionID: .random(),
            consumeID: nil,
            requestHash: "sha256:" + String(repeating: "0", count: 64),
            runID: .random(),
            result: .unknown,
            reasonCode: "daemon_restarted_after_claim",
            occurredAt: ControlTimestamp(clock)
        )
        let payload = String(decoding: try JSONCanonicalization.canonicalize(receipt.json), as: UTF8.self)
        try journal.append(.recoveryQueued(
            mutationID: .random(),
            kind: "unknown_receipt",
            requestID: requestID,
            payload: payload
        ))
        try await core.reconcileAfterRestart()
        await broker.setFailReceipts(false)
        let heartbeats = Task { await core.runHeartbeats() }
        defer { heartbeats.cancel() }
        for _ in 0..<50 {
            if try journal.pendingRecoveries().isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(try journal.pendingRecoveries().isEmpty)
        let postedReceiptIDs = await broker.receipts.map(\.receiptID)
        #expect(postedReceiptIDs == [receipt.receiptID])
    }

    @Test
    func testLiveRequestIsNeverRediscoveredByRecurringRecovery() async throws {
        let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock }, heartbeatInterval: 0.005)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await core.reconcileAfterRestart() // captures an empty startup frontier
        _ = try await createPending(on: core)

        let task = Task { await core.runHeartbeats() }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        let withdrawals = await broker.withdrawals
        let receipts = await broker.receipts
        #expect(withdrawals == 0)
        #expect(receipts.isEmpty)
    }

    @Test
    func testLiveClaimAwaitingAdapterReceiptGetsNoRestartReceipt() async throws {
        let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock }, heartbeatInterval: 0.005)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await core.reconcileAfterRestart()
        let created = try await createPending(on: core)
        try await broker.resolve(created.id, as: .approved, decisionID: .random())
        _ = await core.handle(IPCRequest(messageID: .random(), type: .approvalWait,
            runCapability: created.capability, body: .object([
                "request_id": JSONValue(created.id), "request_hash": .string(created.hash), "timeout_seconds": 2
            ])))
        let task = Task { await core.runHeartbeats() }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        let receipts = await broker.receipts
        #expect(receipts.isEmpty)
    }

    @Test
    func testRealRestartDiscoversPriorPendingRequest() async throws {
        let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        try await core.reconcileAfterRestart()
        _ = try await createPending(on: core)
        let configuration = await core.configuration
        let client = ControlAPIClient(baseURL: configuration.brokerURL, transport: broker,
                                      credential: .origin(originID: configuration.originID, secret: configuration.originSecret))
        let restarted = try DaemonCore(configuration: configuration, client: client, now: { clock })
        try await restarted.reconcileAfterRestart()
        let withdrawals = await broker.withdrawals
        #expect(withdrawals == 1)
    }

    @Test
    func testCorruptAuthorityJournalFailsClosed() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-corrupt-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson"))
        // A damaged record in the middle is corruption, not a torn append.
        try Data("{truncated\n".utf8).write(to: journal.url)
        try journal.append(.withdrawn(requestID: .random()))
        #expect(throws: (any Error).self){ try journal.startupFrontier() }
    }

    @Test
    func testTornFinalRecordIsDroppedAndTheJournalStaysAppendable() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-torn-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson"))
        let requestID = ControlID.random()
        try journal.append(.requestPersisted(requestID: requestID, requestHash: "sha256:" + String(repeating: "0", count: 64), runID: .random()))
        try journal.append(.requestPublished(requestID: requestID))
        // A crash part-way through `append`: no newline, not a whole record.
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"kind":"withdrawn","request_id":"#.utf8))
        try handle.close()

        #expect((try journal.load().count) == 2)
        let repair = try journal.repairAtStartup()
        #expect(repair.discardedTornTail)
        #expect((repair.quarantinedTo) == nil)
        #expect((try Data(contentsOf: journal.url).last) == 0x0A)

        // The next record lands on its own line rather than on the torn bytes.
        try journal.append(.withdrawn(requestID: requestID))
        #expect((try journal.load().count) == 3)
        #expect(!(try journal.recover().unresolved.contains(requestID)))
    }

    @Test
    func testMidFileCorruptionIsQuarantinedAndStartupStillSucceeds() async throws {
        let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson"))
        let kept = ControlID.random()
        try journal.append(.runStarted(runID: .random(), jobID: .random()))
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        try journal.append(.requestPersisted(requestID: kept, requestHash: "sha256:" + String(repeating: "0", count: 64), runID: .random()))
        let original = try Data(contentsOf: journal.url)
        #expect(throws: (any Error).self){ try journal.load() }

        // Startup neither throws nor crash-loops; the damage is surfaced.
        try await core.reconcileAfterRestart()
        let health = await core.health()
        let quarantinedPath = try #require(health["journal_quarantined"]?.stringValue)
        #expect((try Data(contentsOf: URL(fileURLWithPath: quarantinedPath))) == original)
        // Every readable record is kept; the recovery candidate follows them.
        let salvaged = try journal.load()
        #expect(salvaged.count == 3)
        #expect(salvaged.contains { entry in
            if case .requestPersisted(let requestID, _, _) = entry { return requestID == kept }
            return false
        })
    }

    private func createPending(on core: DaemonCore) async throws -> (id: ControlID, hash: String, capability: String) {
        let hello = await core.handle(IPCRequest(messageID: .random(), type: .hello, runCapability: nil, body: .object([
            "protocol": .string(ServiceCapabilities.protocolName), "adapter": "test", "job_label": "live",
            "capabilities": .array([]), "operation_schemas": .array([.string(ExecOperation.schema)])
        ])))
        var helloReader = try JSONReader(hello.body)
        let capability = try helloReader.string("run_capability", maxLength: 128)
        let created = await core.handle(IPCRequest(messageID: .random(), type: .approvalRequest,
            runCapability: capability, body: .object([
                "summary": "Live request", "operation": .object([
                    "schema": .string(ExecOperation.schema), "argv": .array(["/usr/bin/true"]),
                    "cwd": "/tmp", "context_sha256": .string(String(repeating: "0", count: 64))
                ])
            ])))
        var reader = try JSONReader(created.body)
        return (try reader.id("request_id"), try reader.string("request_hash", maxLength: 80), capability)
    }

    // MARK: Run bindings and presence

    private func hello(on core: DaemonCore) async throws -> String {
        let hello = await core.handle(IPCRequest(messageID: .random(), type: .hello, runCapability: nil, body: .object([
            "protocol": .string(ServiceCapabilities.protocolName), "adapter": "test", "job_label": "notify",
            "capabilities": .array([]), "operation_schemas": .array([.string(ExecOperation.schema)])
        ])))
        var reader = try JSONReader(hello.body)
        return try reader.string("run_capability", maxLength: 128)
    }

    private func runID(of requestID: ControlID, on broker: FakeBroker) async -> String? {
        await broker.approvals[requestID]?.spec.runID.rawValue
    }

    @Test
    func testHeartbeatCarriesOnlyWaitingRunsInOneBatch() async throws {
        let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }

        // Many one-shot commands: each says hello and is done.
        for _ in 0..<20 { _ = try await hello(on: core) }
        await core.heartbeatOnce()
        var sent = await broker.heartbeatRuns
        #expect(sent.count == 1, "one heartbeat per interval, not one per hello")
        #expect(sent.last == [], "runs with nothing waiting need no presence")

        let first = try await createPending(on: core)
        let second = try await createPending(on: core)
        let before = await broker.heartbeatRuns.count
        await core.heartbeatOnce()
        sent = await broker.heartbeatRuns
        #expect(sent.count == before + 1, "live runs are batched into one heartbeat")
        let firstRunID = await runID(of: first.id, on: broker)
        let secondRunID = await runID(of: second.id, on: broker)
        let firstRun = try #require(firstRunID)
        let secondRun = try #require(secondRunID)
        #expect(Set(sent.last ?? []) == [firstRun, secondRun])

        // The first request resolves: its run is sent once more to clear the
        // waiting flag, then drops out of presence.
        try await broker.resolve(first.id, as: .rejected, decisionID: .random())
        _ = await core.handle(IPCRequest(messageID: .random(), type: .approvalWait, runCapability: first.capability, body: .object([
            "request_id": JSONValue(first.id), "request_hash": .string(first.hash), "timeout_seconds": 5
        ])))
        await core.heartbeatOnce()
        let drained = await broker.heartbeatRuns.last
        #expect(Set(drained ?? []) == [firstRun, secondRun])
        await core.heartbeatOnce()
        let settled = await broker.heartbeatRuns.last
        #expect(settled == [secondRun])
    }

    @Test
    func testIdleBindingsExpireWhilePendingRequestsKeepTheirs() async throws {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }

        let idle = try await hello(on: core)
        let pending = try await createPending(on: core)
        let pendingRunID = await runID(of: pending.id, on: broker)
        let pendingRun = try #require(pendingRunID)

        // Still approvable: the pending request's run keeps its binding and
        // its presence.
        clock = clock.addingTimeInterval(4 * 60)
        await core.heartbeatOnce()
        let present = await core.presenceRunIDs()
        let bindings = await core.runBindingCount
        #expect(present.map(\.rawValue) == [pendingRun])
        #expect(bindings == 2)

        // Past the request's expiry and the idle lifetime, both are released.
        clock = clock.addingTimeInterval(DaemonCore.runBindingIdleLifetime + 60)
        await core.heartbeatOnce()
        await core.heartbeatOnce()
        let remaining = await core.runBindingCount
        let stillPresent = await core.presenceRunIDs()
        let lastSent = await broker.heartbeatRuns.last
        #expect(remaining == 0)
        #expect(stillPresent.isEmpty)
        #expect(lastSent == [])
        let refused = await core.handle(IPCRequest(messageID: .random(), type: .notify, runCapability: idle,
                                                   body: .object(["title": "late"])))
        #expect(refused.errorCode == ControlErrorCode.notAuthorized.rawValue)
    }

    // MARK: Consume identity

    @Test
    func testLostConsumeReplyIsRetriedWithTheJournaledConsumeID() async throws {
        let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        try await core.reconcileAfterRestart()
        let created = try await createPending(on: core)
        try await broker.resolve(created.id, as: .approved, decisionID: .random())
        // The broker commits the claim, and the reply is lost.
        await broker.setDropNextConsumeReply(true)

        let waited = await core.handle(IPCRequest(messageID: .random(), type: .approvalWait,
            runCapability: created.capability, body: .object([
                "request_id": JSONValue(created.id), "request_hash": .string(created.hash), "timeout_seconds": 30
            ])))
        #expect(waited.ok, "\(waited.errorMessage ?? "")")
        guard case .approved(let permit) = try ApprovalWaitOutcome(json: waited.body) else {
            Issue.record("the retry must recover the permit the broker already granted")
return
        }
        let presented = await broker.consumeIDs
        #expect(presented == [permit.consumeID, permit.consumeID])

        // The consume ID was journaled before the broker saw it.
        let entries = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson")).load()
        let intent = entries.firstIndex { entry in
            if case .consumeIntent(created.id, permit.consumeID, _) = entry { return true }
            return false
        }
        let claim = entries.firstIndex { entry in
            if case .claimed(created.id, permit.consumeID, _) = entry { return true }
            return false
        }
        let intentIndex = try #require(intent)
        let claimIndex = try #require(claim)
        #expect(intentIndex < claimIndex)
    }

    @Test
    func testRestartRecoveryReclaimsAnIntentWithoutResultUnderTheSameID() async throws {
        let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        try await core.reconcileAfterRestart()
        let created = try await createPending(on: core)
        let decisionID = ControlID.random()
        try await broker.resolve(created.id, as: .approved, decisionID: decisionID)

        // The daemon journaled its intent and the broker committed the claim,
        // then the process died before the reply was recorded.
        let journal = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson"))
        let consumeID = ControlID.random()
        try journal.append(.decisionObserved(requestID: created.id, decisionID: decisionID, resolution: .approved))
        try journal.append(.consumeIntent(requestID: created.id, consumeID: consumeID, decisionID: decisionID))
        try await broker.commitClaim(created.id, consumeID: consumeID)

        let frontier = try journal.recover()
        #expect(frontier.uncertain.contains(created.id), "an intent without a result is uncertain")
        #expect(frontier.consumes[created.id] == .init(consumeID: consumeID, claimRecorded: false))

        let configuration = await core.configuration
        let client = ControlAPIClient(baseURL: configuration.brokerURL, transport: broker,
                                      credential: .origin(originID: configuration.originID, secret: configuration.originSecret))
        let restarted = try DaemonCore(configuration: configuration, client: client, now: { clock })
        try await restarted.reconcileAfterRestart()

        // The same ID recovers the claim instead of hitting `already_claimed`,
        // and the permit that never left the daemon is reported not applied.
        let presented = await broker.consumeIDs
        #expect(presented == [consumeID])
        let receipts = await broker.receipts
        #expect(receipts.count == 1)
        #expect(receipts.first?.consumeID == consumeID)
        #expect(receipts.first?.result == .notApplied)
        let after = try journal.recover()
        #expect(!(after.uncertain.contains(created.id)))
        #expect(!(after.unresolved.contains(created.id)))
        #expect(try journal.pendingRecoveries().isEmpty)
        let health = await restarted.health()
        #expect(health["recovery_pending"] == .number(.int(0)))
    }

    @Test
    func testRestartReceiptForARecordedClaimCarriesItsConsumeID() async throws {
        let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        try await core.reconcileAfterRestart()
        let created = try await createPending(on: core)
        try await broker.resolve(created.id, as: .approved, decisionID: .random())
        _ = await core.handle(IPCRequest(messageID: .random(), type: .approvalWait,
            runCapability: created.capability, body: .object([
                "request_id": JSONValue(created.id), "request_hash": .string(created.hash), "timeout_seconds": 5
            ])))
        let holder = await broker.consumedBy[created.id]
        let claimedBy = try #require(holder)

        let configuration = await core.configuration
        let client = ControlAPIClient(baseURL: configuration.brokerURL, transport: broker,
                                      credential: .origin(originID: configuration.originID, secret: configuration.originSecret))
        let restarted = try DaemonCore(configuration: configuration, client: client, now: { clock })
        try await restarted.reconcileAfterRestart()
        let receipts = await broker.receipts
        #expect(receipts.map(\.result) == [.unknown])
        #expect(receipts.first?.consumeID == claimedBy, "the broker accepts an approved receipt only under its claim")
        let presented = await broker.consumeIDs
        #expect(presented == [claimedBy], "a recorded claim is not consumed again")
    }

    @Test
    func testRecoveryRetriesReuseTheSameReceiptID() async throws {
        nonisolated(unsafe) let clock = Date(timeIntervalSince1970: 1_788_000_000)
        let broker = FakeBroker(now: { clock })
        await broker.setFailReceipts(true)
        let (core, directory) = try makeCore(broker, now: { clock })
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson"))
        let requestID = ControlID.random()
        let mutationID = ControlID.random()
        let receiptID = ControlID.random()
        let receipt = Receipt(
            receiptID: receiptID,
            decisionID: .random(),
            consumeID: nil,
            requestHash: "sha256:" + String(repeating: "0", count: 64),
            runID: .random(),
            result: .unknown,
            reasonCode: "daemon_restarted_after_claim",
            occurredAt: ControlTimestamp(clock)
        )
        let payload = String(decoding: try JSONCanonicalization.canonicalize(receipt.json), as: UTF8.self)
        try journal.append(.recoveryQueued(
            mutationID: mutationID,
            kind: "unknown_receipt",
            requestID: requestID,
            payload: payload
        ))
        try await core.reconcileAfterRestart()
        #expect((try journal.pendingRecoveries().count) == 1)
        await broker.setFailReceipts(false)
        try await core.reconcileAfterRestart()
        #expect((try journal.pendingRecoveries().count) == 0)
        let posted = await broker.receipts
        #expect(posted.map(\.receiptID) == [receiptID])
        let consumes = await broker.consumeCount
        #expect(consumes == 0)
    }
}

extension FakeBroker {
    func setFailReceipts(_ flag: Bool) {
        failReceipts = flag
    }

    func setDropNextConsumeReply(_ flag: Bool) {
        dropNextConsumeReply = flag
    }

    /// The broker committed a claim whose reply never reached the origin.
    func commitClaim(_ requestID: ControlID, consumeID: ControlID) throws {
        guard var record = approvals[requestID], let decisionID = record.projection.decisionID else { return }
        permits[consumeID] = ConsumePermit(
            consumeID: consumeID,
            decisionID: decisionID,
            originID: record.spec.originID,
            runID: record.spec.runID,
            requestHash: record.requestHash,
            applyBefore: ControlTimestamp(now()).adding(ApprovalPolicy.permitLifetime),
            decision: .approve,
            decisionJWS: "header.payload.signature"
        )
        consumedBy[requestID] = consumeID
        record.projection.dispatch = .claimed
        approvals[requestID] = record
    }
}
