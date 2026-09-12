import XCTest
import ShellControlProtocol
import ShellControlClient
@testable import ShellControlDaemon

/// A scripted broker: enough of the origin-facing surface to drive the daemon
/// end to end without a network (spec.watch.md section 20).
actor FakeBroker: ControlHTTPTransport {
    var approvals: [ControlID: ApprovalRecord] = [:]
    var receipts: [Receipt] = []
    var permits: [ControlID: ConsumePermit] = [:]
    var heartbeats = 0
    var notifications: [InformationalEvent] = []
    var consumeCount = 0
    var failReceipts = false
    var receiptAttempts = 0
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
            record.projection.dispatch = .claimed
            approvals[requestID] = record
            return try ok(permit.json)
        }
        if request.method == "POST", request.path.hasSuffix("/withdraw") {
            return try ok(.object(["projection": ApprovalProjection(resolution: .cancelled, dispatch: .notApplied).json]))
        }
        return ControlHTTPResponse(status: 404, body: Data("{}".utf8))
    }
}

final class DaemonTests: XCTestCase {
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
                "operation_schemas": .array([.string(ExecOperation.schema)]),
            ])
        ))
        XCTAssertTrue(hello.ok)
        var helloReader = try JSONReader(hello.body)
        let capability = try helloReader.string("run_capability", maxLength: 128)
        XCTAssertFalse(capability.isEmpty)

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
                    "context_sha256": .string(String(repeating: "0", count: 64)),
                ]),
            ])
        ))
        XCTAssertTrue(created.ok)
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
                "timeout_seconds": 30,
            ])
        ))
        XCTAssertTrue(waited.ok)
        let outcome = try ApprovalWaitOutcome(json: waited.body)
        guard case .approved(let permit) = outcome else { return XCTFail("expected an approved permit") }
        XCTAssertEqual(permit.decisionID, decisionID)
        XCTAssertEqual(outcome.exitCode, .approved)

        let receipt = await core.handle(IPCRequest(
            messageID: .random(),
            type: .receipt,
            runCapability: capability,
            body: .object([
                "result": "applied",
                "request_id": JSONValue(requestID),
                "decision_id": JSONValue(decisionID),
                "consume_id": JSONValue(permit.consumeID),
                "request_hash": .string(requestHash),
            ])
        ))
        XCTAssertTrue(receipt.ok)
        let recorded = await broker.receipts
        XCTAssertEqual(recorded.first?.result, .applied)
        clock = clock.addingTimeInterval(1)
    }

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
                "operation_schemas": .array([.string(ExecOperation.schema)]),
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
                    "context_sha256": .string(String(repeating: "0", count: 64)),
                ]),
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
                "timeout_seconds": 30,
            ])
        ))
        let outcome = try ApprovalWaitOutcome(json: waited.body)
        XCTAssertEqual(outcome.exitCode, .rejected)
        let consumes = await broker.consumeCount
        XCTAssertEqual(consumes, 0)
    }

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
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.errorCode, ControlErrorCode.notAuthorized.rawValue)
    }

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
                "operation_schemas": .array([.string(ExecOperation.schema)]),
            ])
        )
        let first = await core.handle(hello)
        XCTAssertTrue(first.ok)
        let changed = IPCRequest(
            messageID: messageID,
            type: .hello,
            runCapability: nil,
            body: .object([
                "protocol": .string(ServiceCapabilities.protocolName),
                "adapter": "other-adapter",
                "job_label": "build",
                "capabilities": .array([]),
                "operation_schemas": .array([.string(ExecOperation.schema)]),
            ])
        )
        let response = await core.handle(changed)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.errorCode, ControlErrorCode.idempotencyConflict.rawValue)
    }

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
                "operation_schemas": .array(["k8s.apply.v1"]),
            ])
        ))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.errorCode, ControlErrorCode.unsupportedOperation.rawValue)
    }

    /// A retransmission with the same message id and body must replay the
    /// recorded result, not mint a second request on the broker.
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
                "operation_schemas": .array([.string(ExecOperation.schema)]),
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
                    "context_sha256": .string(String(repeating: "0", count: 64)),
                ]),
            ])
        )
        let first = await core.handle(request)
        let replay = await core.handle(request)
        XCTAssertTrue(first.ok)
        XCTAssertTrue(replay.ok)
        XCTAssertEqual(first.body, replay.body)
        let published = await broker.approvals.count
        XCTAssertEqual(published, 1)
    }

    /// Two waits on one run capability must not lose each other's presence.
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
                "operation_schemas": .array([.string(ExecOperation.schema)]),
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
                        "context_sha256": .string(String(repeating: "0", count: 64)),
                    ]),
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
                "timeout_seconds": 5,
            ])
        ))
        async let secondWait = core.handle(IPCRequest(
            messageID: .random(),
            type: .approvalWait,
            runCapability: capability,
            body: .object([
                "request_id": JSONValue(secondID),
                "request_hash": .string(secondHash),
                "timeout_seconds": 5,
            ])
        ))
        _ = await firstWait
        // The first wait resolving must not drop the second from the lease.
        try await broker.resolve(secondID, as: .rejected, decisionID: .random())
        let outcome = try ApprovalWaitOutcome(json: (await secondWait).body)
        XCTAssertEqual(outcome.exitCode, .rejected)
    }

    // MARK: Journal

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
        XCTAssertTrue(recovery.uncertain.contains(requestID))

        try journal.append(.dispatchResult(requestID: requestID, receiptID: .random(), result: .unknown))
        recovery = try journal.recover()
        XCTAssertFalse(recovery.uncertain.contains(requestID))
        XCTAssertFalse(recovery.unresolved.contains(requestID))
    }

    func testJournalTracksUnresolvedRequests() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-controld-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try DispatchJournal(url: directory.appendingPathComponent("journal.ndjson"))
        let requestID = ControlID.random()
        try journal.append(.requestPersisted(requestID: requestID, requestHash: "sha256:" + String(repeating: "0", count: 64), runID: .random()))
        XCTAssertTrue(try journal.recover().unresolved.contains(requestID))
        try journal.append(.withdrawn(requestID: requestID))
        XCTAssertFalse(try journal.recover().unresolved.contains(requestID))
    }

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
        XCTAssertEqual(try journal.pendingRecoveries().count, 1)
        let posted = await broker.receipts
        XCTAssertTrue(posted.isEmpty)
        let attempts = await broker.receiptAttempts
        XCTAssertGreaterThanOrEqual(attempts, 1)
    }

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
        XCTAssertTrue(try journal.pendingRecoveries().isEmpty)
        let postedReceiptIDs = await broker.receipts.map(\.receiptID)
        XCTAssertEqual(postedReceiptIDs, [receipt.receiptID])
    }

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
        XCTAssertEqual(try journal.pendingRecoveries().count, 1)
        await broker.setFailReceipts(false)
        try await core.reconcileAfterRestart()
        XCTAssertEqual(try journal.pendingRecoveries().count, 0)
        let posted = await broker.receipts
        XCTAssertEqual(posted.map(\.receiptID), [receiptID])
        let consumes = await broker.consumeCount
        XCTAssertEqual(consumes, 0)
    }
}

extension FakeBroker {
    func setFailReceipts(_ flag: Bool) {
        failReceipts = flag
    }
}
