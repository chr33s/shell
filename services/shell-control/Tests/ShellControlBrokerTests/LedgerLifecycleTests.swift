import Foundation
import XCTest
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlBroker

/// Counts durable commits, so a test can tell a no-op from a write.
final class CountingPersistence: BrokerPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: JSONValue?
    private var writes = 0

    var persistCount: Int { lock.withLock { writes } }

    func persist(snapshot: JSONValue) throws {
        lock.withLock {
            stored = snapshot
            writes += 1
        }
    }

    func load() throws -> JSONValue? { lock.withLock { stored } }
}

/// Review-driven regressions: full-review clients, refresh replay, origin
/// clock validation, heartbeat churn, retention, and the snapshot high-water
/// mark.
final class LedgerLifecycleTests: XCTestCase {
    private func makeHarness(persistence: (any BrokerPersistence)? = nil) async throws -> (BrokerHarness, ControlID, ControlID) {
        let harness = BrokerHarness(persistence: persistence)
        try await harness.bootstrap()
        let runID = ControlID.random()
        let jobID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        return (harness, runID, jobID)
    }

    private func enrollPhone(_ harness: BrokerHarness) async throws -> BrokerHarness.Device {
        let key = InMemoryDeviceKey()
        let id = try await harness.store.enrollDevice(
            accountID: harness.accountID,
            publicJWK: key.publicJWK,
            platform: .iOS,
            label: "iPhone",
            grants: DeviceGrant.watchDefault
        )
        return BrokerHarness.Device(id: id, key: key, principal: try await harness.store.authenticateDevice(id))
    }

    // MARK: Full review

    func testFullReviewRequestIsApprovableFromTheIPhoneButNotTheWatch() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let watch = try await harness.enrollDevice()
        let phone = try await enrollPhone(harness)
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID, minimumReview: .full))

        let current = try await harness.store.approval(record.spec.requestID, principal: watch.principal)
        await assertControlError(.fullReviewRequired) {
            _ = try await harness.decide(.approve, device: watch, record: current)
        }

        let outcome = try await harness.decide(.approve, device: phone, record: current)
        XCTAssertEqual(outcome.result.resolution, .approved)
        let final = try await harness.store.approval(record.spec.requestID, principal: phone.principal)
        XCTAssertEqual(final.projection.decidedByDeviceID, phone.id)
    }

    func testFullReviewApprovalFromTheIPhoneStillNeedsPresence() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let phone = try await enrollPhone(harness)
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID, minimumReview: .full))
        harness.clock.advance(ApprovalPolicy.presenceStaleAfter + 5)
        let current = try await harness.store.approval(record.spec.requestID, principal: phone.principal)
        await assertControlError(.originUnavailable) {
            _ = try await harness.decide(.approve, device: phone, record: current)
        }
    }

    // MARK: Refresh replay

    func testRefreshRetryInsideTheGraceWindowReturnsTheSamePairAcrossARestart() async throws {
        let persistence = CountingPersistence()
        let harness = BrokerHarness(persistence: persistence)
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        let stored = await harness.store.device(device.id)
        let session = try await harness.store.issueSession(for: try XCTUnwrap(stored))
        try await harness.store.commit()

        let rotated = try await harness.store.refreshSession(refreshToken: session.refreshToken)
        XCTAssertNotEqual(rotated.refreshToken, session.refreshToken)

        // The response was lost; the broker restarted; the client retries.
        let clock = harness.clock
        let restored = BrokerStore(
            serviceIdentity: "test-broker",
            cursorSecret: Data(repeating: 7, count: 32),
            persistence: persistence,
            now: { clock.now }
        )
        try await restored.restore()
        clock.advance(30)
        let retried = try await restored.refreshSession(refreshToken: session.refreshToken)
        XCTAssertEqual(retried, rotated)
        _ = try await restored.authenticate(bearer: retried.accessToken)

        // Past the window, the spent token is plain reuse; the successor lives on.
        clock.advance(BrokerStore.refreshReplayGrace)
        await assertControlError(.invalidToken) {
            _ = try await restored.refreshSession(refreshToken: session.refreshToken)
        }
        _ = try await restored.refreshSession(refreshToken: rotated.refreshToken)
    }

    func testRefreshRetryAfterTheSuccessorWasUsedIsRejected() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        let stored = await harness.store.device(device.id)
        let session = try await harness.store.issueSession(for: try XCTUnwrap(stored))
        let rotated = try await harness.store.refreshSession(refreshToken: session.refreshToken)
        _ = try await harness.store.refreshSession(refreshToken: rotated.refreshToken)
        await assertControlError(.invalidToken) {
            _ = try await harness.store.refreshSession(refreshToken: session.refreshToken)
        }
    }

    func testRefreshRetryAfterLogoutIsRejected() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        let stored = await harness.store.device(device.id)
        let session = try await harness.store.issueSession(for: try XCTUnwrap(stored))
        _ = try await harness.store.refreshSession(refreshToken: session.refreshToken)
        try await harness.store.revokeSessions(deviceID: device.id)
        await assertControlError(.invalidToken) {
            _ = try await harness.store.refreshSession(refreshToken: session.refreshToken)
        }
    }

    // MARK: Origin clock

    private func spec(
        _ harness: BrokerHarness,
        runID: ControlID,
        jobID: ControlID,
        createdIn created: TimeInterval,
        expiresIn expires: TimeInterval
    ) throws -> ApprovalSpec {
        try ApprovalSpec(
            requestID: .random(),
            originID: harness.originID,
            jobID: jobID,
            runID: runID,
            createdAt: harness.timestamp.adding(created),
            expiresAt: harness.timestamp.adding(expires),
            summary: "Push feature branch",
            operation: .exec(try ExecOperation(
                argv: ["/usr/bin/git", "push"],
                cwd: "/srv/work/shell",
                contextSHA256: String(repeating: "0", count: 64)
            )),
            minimumReview: .watch,
            requiredFeatures: [ExecOperation.schema, ControlFeature.consume]
        )
    }

    func testApprovalTimesAreCheckedAgainstTheBrokerClock() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let year: TimeInterval = 365 * 24 * 60 * 60
        let origin = harness.originPrincipal
        let farFuture = try spec(harness, runID: runID, jobID: jobID, createdIn: year, expiresIn: year + 300)
        await assertControlError(.invalidPayload) {
            _ = try await harness.store.createApproval(principal: origin, spec: farFuture)
        }
        let alreadyExpired = try spec(harness, runID: runID, jobID: jobID, createdIn: -1_200, expiresIn: -60)
        await assertControlError(.requestExpired) {
            _ = try await harness.store.createApproval(principal: origin, spec: alreadyExpired)
        }
        let overCap = try spec(harness, runID: runID, jobID: jobID, createdIn: 50, expiresIn: 50 + ApprovalPolicy.maximumLifetime)
        await assertControlError(.invalidPayload) {
            _ = try await harness.store.createApproval(principal: origin, spec: overCap)
        }
        // A small skew is tolerated.
        let skewed = try spec(harness, runID: runID, jobID: jobID, createdIn: 30, expiresIn: 300)
        _ = try await harness.store.createApproval(principal: origin, spec: skewed)
    }

    // MARK: Heartbeats

    func testSteadyHeartbeatsNeitherCommitNorLogButKeepPresenceFresh() async throws {
        let persistence = CountingPersistence()
        let (harness, runID, jobID) = try await makeHarness(persistence: persistence)
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let writes = persistence.persistCount
        let sequence = await harness.store.nextSequence

        for _ in 0..<4 {
            harness.clock.advance(ApprovalPolicy.heartbeatInterval)
            try await harness.store.heartbeat(
                principal: harness.originPrincipal,
                runIDs: [runID],
                waitingRequestIDs: [record.spec.requestID]
            )
        }
        try await harness.store.heartbeat(principal: harness.originPrincipal, runIDs: [], waitingRequestIDs: [])
        XCTAssertEqual(persistence.persistCount, writes)
        let steadySequence = await harness.store.nextSequence
        XCTAssertEqual(steadySequence, sequence)
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        XCTAssertTrue(current.projection.presence.isFresh(at: harness.timestamp))

        // A change in the waiting set is material.
        try await harness.store.heartbeat(principal: harness.originPrincipal, runIDs: [runID], waitingRequestIDs: [])
        let changedSequence = await harness.store.nextSequence
        XCTAssertEqual(changedSequence, sequence + 1)
        XCTAssertEqual(persistence.persistCount, writes + 1)

        // So is returning from stale.
        harness.clock.advance(ApprovalPolicy.presenceStaleAfter + 1)
        try await harness.store.heartbeat(principal: harness.originPrincipal, runIDs: [runID], waitingRequestIDs: [])
        let returnedSequence = await harness.store.nextSequence
        XCTAssertEqual(returnedSequence, sequence + 2)
    }

    // MARK: Retention

    func testTerminalRecordsArePurgedAfterRetentionLeavingTombstones() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let commandID = ControlID.random()
        let outcome = try await harness.decide(.approve, device: device, record: current, commandID: commandID)
        let decisionID = try XCTUnwrap(outcome.result.decisionID)
        let consumeID = ControlID.random()
        _ = try await harness.store.consumeApproval(
            principal: harness.originPrincipal,
            requestID: record.spec.requestID,
            request: ConsumeRequest(consumeID: consumeID, decisionID: decisionID, requestHash: record.requestHash, runID: runID)
        )
        try await harness.store.recordReceipt(principal: harness.originPrincipal, receipt: Receipt(
            receiptID: .random(),
            decisionID: decisionID,
            consumeID: consumeID,
            requestHash: record.requestHash,
            runID: runID,
            result: .applied,
            reasonCode: "adapter_applied",
            occurredAt: harness.timestamp
        ))
        let expired = try harness.makeSpec(runID: runID, jobID: jobID)
        _ = try await harness.publish(expired)
        _ = try await harness.store.createNotification(principal: harness.originPrincipal, event: try InformationalEvent(
            eventID: .random(),
            originID: harness.originID,
            kind: .jobCompleted,
            title: "Build finished",
            body: "",
            occurredAt: harness.timestamp
        ))

        // Inside retention nothing goes.
        harness.clock.advance(ApprovalPolicy.commandRetention - 60 * 60)
        try await harness.store.commit()
        var counts = await (harness.store.approvals.count, harness.store.notifications.count, harness.store.idempotency.count, harness.store.receipts.count)
        XCTAssertEqual(counts.0, 2)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1)
        XCTAssertEqual(counts.3, 1)

        harness.clock.advance(2 * 60 * 60)
        try await harness.store.commit()
        counts = await (harness.store.approvals.count, harness.store.notifications.count, harness.store.idempotency.count, harness.store.receipts.count)
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
        XCTAssertEqual(counts.3, 0)
        let accessTokens = await harness.store.accessTokens.count
        XCTAssertEqual(accessTokens, 0)

        // Both request IDs stay spent, including the one that merely expired.
        let consumed = await harness.store.tombstones[record.spec.requestID]
        XCTAssertEqual(consumed?.consumedBy, consumeID)
        let lapsed = await harness.store.tombstones[expired.requestID]
        XCTAssertEqual(lapsed?.resolution, .expired)
        await assertControlError(.notFound) {
            _ = try await harness.store.commandResult(commandID, principal: device.principal)
        }
    }

    func testPersistRefusesALedgerTooLargeToRestore() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-control-size-\(UUID().uuidString)")
            .appendingPathComponent("broker.json")
        let persistence = try FileBrokerPersistence(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try persistence.persist(snapshot: .object(["v": 1]))
        let oversized = JSONValue.object(["blob": .string(String(repeating: "a", count: FileBrokerPersistence.maximumBytes))])
        XCTAssertThrowsError(try persistence.persist(snapshot: oversized))
        // The last good ledger is still the one on disk, and it still loads.
        XCTAssertNotNil(try persistence.load())
    }

    // MARK: High-water mark

    func testSnapshotHighWaterSurvivesAnEmptiedChangeLog() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let early = try await harness.store.snapshot(principal: device.principal)
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        _ = try await harness.decide(.reject, device: device, record: current)
        let lastSequence = await harness.store.nextSequence - 1

        // An idle week empties the log.
        harness.clock.advance(ApprovalPolicy.changeLogRetention + 60)
        try await harness.store.commit()
        let logCount = await harness.store.changeLog.count
        XCTAssertEqual(logCount, 0)

        // A new snapshot still sees the older item and anchors at the counter.
        let page = try await harness.store.snapshot(principal: device.principal)
        XCTAssertEqual(page.approvals.map(\.spec.requestID), [record.spec.requestID])
        let resumed = try await harness.store.changes(principal: device.principal, cursor: page.cursor)
        XCTAssertTrue(resumed.events.isEmpty)
        XCTAssertEqual(page.cursor, CursorCodec.encodeCursor(sequence: LogSequence(lastSequence), principal: device.principal, secret: Data(repeating: 7, count: 32)))

        // A cursor older than anything retained is expired, not silently empty.
        await assertControlError(.cursorExpired) {
            _ = try await harness.store.changes(principal: device.principal, cursor: early.cursor)
        }
    }

    // MARK: Origin mutation records

    func testANotifyMutationIDDoesNotReplayAsAWithdrawAfterRestart() async throws {
        let persistence = CountingPersistence()
        let (harness, runID, jobID) = try await makeHarness(persistence: persistence)
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let sharedID = ControlID.random()
        _ = try await harness.store.createNotification(principal: harness.originPrincipal, event: try InformationalEvent(
            eventID: sharedID,
            originID: harness.originID,
            kind: .jobCompleted,
            title: "Build finished",
            body: "",
            occurredAt: harness.timestamp
        ))
        try await harness.store.commit()

        let clock = harness.clock
        let restored = BrokerStore(
            serviceIdentity: "test-broker",
            cursorSecret: Data(repeating: 7, count: 32),
            persistence: persistence,
            now: { clock.now }
        )
        try await restored.restore()
        let withdrawn = try await restored.withdrawApproval(
            principal: harness.originPrincipal,
            requestID: record.spec.requestID,
            mutationID: sharedID,
            runID: runID,
            requestHash: record.requestHash
        )
        XCTAssertNotEqual(withdrawn.projection.resolution, .pending, "the withdraw was taken for a replay of the notify")
        let mutations = await restored.originMutations
        XCTAssertEqual(mutations.count, 2)
        XCTAssertEqual(Set(mutations.values.map(\.kind)), [.notify, .withdraw])
    }
}
