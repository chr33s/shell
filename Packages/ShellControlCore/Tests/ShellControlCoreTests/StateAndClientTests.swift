import XCTest
@testable import ShellControlProtocol
@testable import ShellControlClient

final class StateAndClientTests: XCTestCase {
    func testResolutionIsImmutableOnceTerminal() {
        XCTAssertTrue(Resolution.pending.canTransition(to: .approved))
        XCTAssertFalse(Resolution.approved.canTransition(to: .rejected))
        XCTAssertFalse(Resolution.rejected.canTransition(to: .pending))
    }

    func testDispatchTransitions() {
        XCTAssertTrue(Dispatch.none.canTransition(to: .awaitingOrigin))
        XCTAssertTrue(Dispatch.awaitingOrigin.canTransition(to: .claimed))
        XCTAssertTrue(Dispatch.awaitingOrigin.canTransition(to: .applied))
        XCTAssertTrue(Dispatch.claimed.canTransition(to: .unknown))
        // Unknown reconciles only with positive evidence, and never to pending.
        XCTAssertTrue(Dispatch.unknown.canTransition(to: .applied))
        XCTAssertFalse(Dispatch.applied.canTransition(to: .claimed))
        XCTAssertFalse(Dispatch.unknown.canTransition(to: .awaitingOrigin))
    }

    func testPresenceGoesStaleAfterFortyFiveSeconds() throws {
        let seen = try XCTUnwrap(ControlTimestamp(rfc3339: "2026-09-07T09:00:00Z"))
        let presence = SourcePresence(lastSeenAt: seen, isWaiting: true)
        XCTAssertTrue(presence.isFresh(at: seen.adding(44)))
        XCTAssertFalse(presence.isFresh(at: seen.adding(46)))
        XCTAssertFalse(SourcePresence(lastSeenAt: seen, isWaiting: false).isFresh(at: seen))
    }

    func testErrorCodeMapping() {
        XCTAssertEqual(ControlErrorCode.alreadyClaimed.httpStatus, 409)
        XCTAssertEqual(ControlErrorCode.originUnavailable.httpStatus, 423)
        XCTAssertEqual(ControlErrorCode.hashMismatch.clientAction, .requireFreshReview)
        XCTAssertEqual(ControlErrorCode.unsupportedOperation.clientAction, .handoff)
        XCTAssertFalse(ControlErrorCode.alreadyResolved.isRetryable)
        XCTAssertTrue(ControlErrorCode.temporarilyUnavailable.isRetryable)
    }

    func testSanitizerEscapesBidiAndControlCharacters() {
        let result = DisplaySanitizer.sanitize("rm\u{202E}txt.exe\u{07}")
        XCTAssertTrue(result.didEscape)
        XCTAssertTrue(result.text.contains("<U+202E>"))
        XCTAssertFalse(result.isTruncated)
        let long = DisplaySanitizer.sanitize(String(repeating: "a", count: 600), maxScalars: 100)
        XCTAssertTrue(long.isTruncated)
    }

    func testIPCFramingRoundTrip() throws {
        var buffer = try IPCFraming.frame(JSONValue.object(["a": 1]))
        buffer.append(try IPCFraming.frame(JSONValue.object(["b": 2])))
        XCTAssertEqual(try IPCFraming.decodeFrame(from: &buffer), .object(["a": 1]))
        XCTAssertEqual(try IPCFraming.decodeFrame(from: &buffer), .object(["b": 2]))
        XCTAssertNil(try IPCFraming.decodeFrame(from: &buffer))
    }

    func testPartialFrameYieldsNilRatherThanGarbage() throws {
        var buffer = try IPCFraming.frame(JSONValue.object(["a": 1]))
        buffer.removeLast()
        XCTAssertNil(try IPCFraming.decodeFrame(from: &buffer))
    }

    func testExitCodeConvention() {
        XCTAssertEqual(ApprovalWaitOutcome.rejected(decisionID: .random()).exitCode.rawValue, 10)
        XCTAssertEqual(ApprovalWaitOutcome.expired.exitCode.rawValue, 11)
        XCTAssertEqual(ApprovalWaitOutcome.cancelled.exitCode.rawValue, 12)
        XCTAssertEqual(ApprovalWaitOutcome.unavailable(reason: "x").exitCode.rawValue, 13)
    }

    func testPushPayloadStaysUnderTheAPNsLimit() throws {
        let payload = ApprovalPushPayload(eventID: .random(), requestID: .random())
        let encoded = try payload.encoded()
        XCTAssertLessThan(encoded.count, 4096)
        // The payload carries identifiers only: no credential, key, or command.
        let value = try JSONValue.parse(encoded)
        XCTAssertNil(value["token"])
        XCTAssertNil(value["command"])
        XCTAssertEqual(value["aps"]?["category"]?.stringValue, "SHELL_APPROVAL_V1")
        XCTAssertEqual(payload.collapseID, "approval.\(payload.requestID.rawValue)")
    }

    func testAPNsExpirationNeverOutlivesTheDeadline() throws {
        let deadline = try XCTUnwrap(ControlTimestamp(rfc3339: "2026-09-07T09:05:00Z"))
        let headers = APNsRequestHeaders(topic: "dev.chr33s.shell.watchkitapp", expiresAt: deadline, collapseID: "approval.x")
        XCTAssertEqual(headers.headerFields["apns-expiration"], String(Int64(deadline.date.timeIntervalSince1970)))
        XCTAssertEqual(headers.headerFields["apns-push-type"], "alert")
        XCTAssertEqual(headers.headerFields["apns-priority"], "10")
    }

    // MARK: Reconciliation

    private func makeRecord(requestID: ControlID, stateVersion: Int64, resolution: Resolution = .pending) throws -> ApprovalRecord {
        let created = try XCTUnwrap(ControlTimestamp(rfc3339: "2026-09-07T09:00:00Z"))
        let spec = try ApprovalSpec(
            requestID: requestID,
            originID: .random(),
            jobID: .random(),
            runID: .random(),
            createdAt: created,
            expiresAt: created.adding(300),
            summary: "Push feature branch",
            operation: .exec(try ExecOperation(argv: ["/usr/bin/git", "push"], cwd: "/srv", contextSHA256: String(repeating: "a", count: 64))),
            minimumReview: .watch,
            requiredFeatures: [ExecOperation.schema]
        )
        return try ApprovalRecord(spec: spec, projection: ApprovalProjection(stateVersion: stateVersion, resolution: resolution))
    }

    func testSnapshotAppliesAtomicallyAndDeltasDeduplicate() throws {
        let requestID = ControlID.random()
        let record = try makeRecord(requestID: requestID, stateVersion: 1)
        let serverTime = try XCTUnwrap(ControlTimestamp(rfc3339: "2026-09-07T09:00:10Z"))
        var accumulator = InboxReconciler.SnapshotAccumulator(firstPage: SnapshotPage(
            approvals: [record],
            notifications: [],
            snapshotToken: "s1",
            nextPageToken: nil,
            cursor: ChangeCursor("c1.5.tag"),
            serverTime: serverTime
        ))
        var reconciler = InboxReconciler()
        try reconciler.applyCompletedSnapshot(accumulator, at: serverTime)
        XCTAssertEqual(reconciler.state.pendingApprovals.count, 1)
        XCTAssertEqual(reconciler.state.lastRefreshedAt, serverTime)

        let resolved = try makeRecord(requestID: requestID, stateVersion: 2, resolution: .approved)
        let event = ChangeEvent(
            eventID: .random(),
            sequence: LogSequence(6),
            type: .approvalResolved,
            resourceID: requestID,
            resourceVersion: 2,
            serverTime: serverTime,
            projection: resolved.json
        )
        let page = ChangePage(events: [event, event], cursor: ChangeCursor("c1.6.tag"), serverTime: serverTime)
        // At-least-once delivery: the duplicate applies once.
        XCTAssertEqual(reconciler.apply(page), 1)
        XCTAssertEqual(reconciler.state.approvals[requestID]?.projection.resolution, .approved)
        XCTAssertEqual(reconciler.state.cursor?.rawValue, "c1.6.tag")

        // A stale redelivery cannot roll the record backwards.
        let stale = ChangeEvent(
            eventID: .random(),
            sequence: LogSequence(7),
            type: .approvalResolved,
            resourceID: requestID,
            resourceVersion: 1,
            serverTime: serverTime,
            projection: record.json
        )
        _ = reconciler.apply(ChangePage(events: [stale], cursor: ChangeCursor("c1.7.tag"), serverTime: serverTime))
        XCTAssertEqual(reconciler.state.approvals[requestID]?.projection.resolution, .approved)
        _ = accumulator
    }

    func testIncompleteSnapshotIsNotApplied() throws {
        let serverTime = try XCTUnwrap(ControlTimestamp(rfc3339: "2026-09-07T09:00:10Z"))
        let accumulator = InboxReconciler.SnapshotAccumulator(firstPage: SnapshotPage(
            approvals: [],
            notifications: [],
            snapshotToken: "s1",
            nextPageToken: "1@s1",
            cursor: ChangeCursor("c1.5.tag"),
            serverTime: serverTime
        ))
        var reconciler = InboxReconciler()
        XCTAssertThrowsError(try reconciler.applyCompletedSnapshot(accumulator, at: serverTime))
    }

    func testJournalKeepsAmbiguousCommandsAcrossSnapshots() async throws {
        let journal = try CommandJournal()
        let commandID = ControlID.random()
        let notAfter = try XCTUnwrap(ControlTimestamp(rfc3339: "2026-09-07T09:01:00Z"))
        try await journal.record(PendingCommand(
            commandID: commandID,
            signedCommand: "a.b.c",
            type: .approvalDecide,
            targetID: .random(),
            notAfter: notAfter
        ))
        try await journal.update(commandID, status: .outcomeUnknown)
        let pending = await journal.pending
        XCTAssertEqual(pending.first?.status, .outcomeUnknown)
        // The identical command may be retried only while its lifetime holds.
        XCTAssertTrue(pending[0].isRetryable(at: notAfter.adding(-5)))
        XCTAssertFalse(pending[0].isRetryable(at: notAfter.adding(5)))
    }
}
