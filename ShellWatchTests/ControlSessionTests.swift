import XCTest
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@testable import ShellWatch

/// The Watch session behind the iPhone gateway: enrollment through the
/// iPhone, live-only decisions, stale cache, and command reconciliation
/// (spec.iphone-gateway.md sections 10, 11, 14, 15, and 18).
@MainActor
final class ControlSessionTests: XCTestCase {
    private let now = ControlTimestamp(Date(timeIntervalSince1970: 1_788_000_000))

    private struct Rig {
        let session: ControlSession
        let gateway: StubGateway
        let keys: InMemoryCredentialStore
        let reviewers: InMemoryWatchReviewerStore
        let cache: InMemoryInboxCache
        let journal: InMemoryCommandJournal
    }

    private func rig(enrolled: Bool = true, cache: InMemoryInboxCache = InMemoryInboxCache()) async throws -> Rig {
        let gateway = StubGateway(now: now)
        let keys = InMemoryCredentialStore()
        let reviewers = InMemoryWatchReviewerStore()
        if enrolled {
            let key = InMemoryDeviceKey()
            try keys.storeSigningKey(key)
            let reviewer = WatchTestFixtures.activeReviewer(accountID: gateway.accountID, key: key)
            try reviewers.store(reviewer)
            await gateway.setReviewer(reviewer)
        }
        let journal = InMemoryCommandJournal()
        let session = try ControlSession(
            link: gateway, keys: keys, reviewerStore: reviewers, cache: cache,
            journalStore: journal, now: { [now] in now.date }
        )
        return Rig(session: session, gateway: gateway, keys: keys, reviewers: reviewers, cache: cache, journal: journal)
    }

    // MARK: Enrollment through the iPhone

    func testWithoutAReviewerIdentityTheWatchAsksForSetup() async throws {
        let rig = try await rig(enrolled: false)
        await rig.session.start()
        XCTAssertEqual(rig.session.phase, .needsEnrollment)
        let sent = await rig.gateway.requestTypes()
        XCTAssertTrue(sent.isEmpty, "nothing is fetched without an identity")
    }

    /// The Watch makes its own key; only the public half and a signature
    /// travel. The Mac's confirmation is what makes it active.
    func testEnrollmentGoesThroughTheIPhoneAndWaitsForTheMac() async throws {
        let rig = try await rig(enrolled: false)
        await rig.session.start()
        await rig.session.enroll(label: "Apple Watch")
        guard case .awaitingConfirmation(let pending) = rig.session.phase else {
            return XCTFail("expected awaiting confirmation, got \(rig.session.phase)")
        }
        XCTAssertEqual(pending.userCode, "BCDF-GHJK")
        let key = try XCTUnwrap(try rig.keys.loadSigningKey())
        XCTAssertEqual(pending.fingerprint, try key.publicJWK.displayFingerprint())
        let requests = await rig.gateway.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.body["private_key"], "no private material leaves the Watch")

        await rig.gateway.setNextReviewerState(.active)
        await rig.session.checkEnrollment()
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(rig.reviewers.load()?.state, .active)
        XCTAssertEqual(rig.reviewers.load()?.accountID, rig.gateway.accountID)
    }

    func testEnrollmentNeedsAReachableIPhone() async throws {
        let rig = try await rig(enrolled: false)
        await rig.gateway.setReachable(false)
        await rig.session.start()
        await rig.session.enroll(label: "Apple Watch")
        XCTAssertEqual(rig.session.phase, .needsEnrollment)
        XCTAssertEqual(rig.session.enrollmentMessage, "iPhone unavailable")
    }

    // MARK: Live-only decisions

    func testUnreachableIPhoneKeepsTheCacheAndQueuesNothing() async throws {
        let cache = InMemoryInboxCache()
        var seeded = InboxState()
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        seeded.approvals[record.spec.requestID] = record
        seeded.lastRefreshedAt = now
        try cache.commit(seeded)
        let rig = try await rig(cache: cache)
        await rig.gateway.setReachable(false)
        await rig.session.start()

        XCTAssertFalse(rig.session.isGatewayReachable)
        XCTAssertFalse(rig.session.isShowingLiveState, "cached material is shown as stale")
        XCTAssertEqual(rig.session.inbox.pendingApprovals.count, 1)

        await rig.session.decide(.approve, on: record)
        let submitted = await rig.gateway.submitted
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertTrue(try rig.journal.load().isEmpty, "no authorization is held for later delivery")
        XCTAssertNil(rig.session.submissions[record.spec.requestID])
        XCTAssertEqual(rig.session.inbox.pendingApprovals.count, 1)
    }

    /// A Watch decision is signed by the Watch key and carried unchanged.
    func testDecisionIsSignedByTheWatchKeyAndSentLive() async throws {
        let rig = try await rig()
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        await rig.gateway.setApprovals([record])
        await rig.session.start()
        XCTAssertEqual(rig.session.phase, .ready)

        await rig.session.decide(.approve, on: record)
        let submitted = await rig.gateway.submitted
        let jws = try XCTUnwrap(submitted.first)
        let reviewer = try XCTUnwrap(rig.reviewers.load())
        let key = try XCTUnwrap(try rig.keys.loadSigningKey())
        let verified = try ControlJWS.verify(compactSerialization: jws) { id in
            id == reviewer.watchDeviceID ? key.publicJWK : nil
        }
        XCTAssertEqual(verified.deviceID, reviewer.watchDeviceID)
        XCTAssertEqual(verified.command.envelope.audience, reviewer.audience)
        let types = await rig.gateway.requestTypes()
        // Fetch before deciding, then a fresh challenge, then the command.
        XCTAssertEqual(Array(types.suffix(4).prefix(3)), [.approvalFetch, .reviewChallenge, .commandSubmit])
    }

    /// A WatchConnectivity error before submission leaves nothing unknown:
    /// no command was signed or sent.
    func testDeliveryErrorBeforeSubmissionIsNotAnUnknownOutcome() async throws {
        let rig = try await rig()
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        await rig.gateway.setApprovals([record])
        await rig.session.start()
        await rig.gateway.setDeliveryFailure(true)
        await rig.session.decide(.approve, on: record)
        XCTAssertNil(rig.session.submissions[record.spec.requestID])
        XCTAssertTrue(try rig.journal.load().isEmpty)
        XCTAssertEqual(rig.session.gatewayProblem, "iPhone unavailable")
    }

    /// A request that changed during review says so; it is not reported as
    /// a missing iPhone.
    func testChangedRequestIsNotReportedAsIPhoneUnavailable() async throws {
        let rig = try await rig()
        let reviewed = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        let changed = try WatchTestFixtures.makeRecord(requestID: reviewed.spec.requestID, createdAt: now, presentAt: now)
        await rig.gateway.setApprovals([changed])
        await rig.session.start()
        await rig.session.decide(.approve, on: reviewed)
        XCTAssertNil(rig.session.submissions[reviewed.spec.requestID])
        XCTAssertNil(rig.session.gatewayProblem)
        XCTAssertEqual(rig.session.decisionProblems[reviewed.spec.requestID], "This request changed while you were reviewing it. Review it again.")
    }

    func testMacUnavailableBehindAReachableIPhoneFailsClosed() async throws {
        let rig = try await rig()
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        await rig.gateway.setApprovals([record])
        await rig.session.start()
        await rig.gateway.setMacUnavailable(true)
        do {
            _ = try await rig.session.fetchForReview(record.spec.requestID)
            XCTFail("a review must not be served from cache")
        } catch let error as WatchGatewayError {
            guard case .gatewayUnavailable = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertNotNil(rig.session.gatewayProblem)
    }

    /// A submission whose reply was lost is reconciled by its command ID; a
    /// replacement is never signed.
    func testAmbiguousCommandIsReconciledByItsID() async throws {
        let journalStore = InMemoryCommandJournal()
        let commandID = ControlID.random()
        try journalStore.save([PendingCommand(
            commandID: commandID, signedCommand: "a.b.c", type: .approvalDecide,
            targetID: .random(), notAfter: now.adding(60), status: .outcomeUnknown
        )])
        let gateway = StubGateway(now: now)
        await gateway.setResult(CommandResult(recorded: true, commandID: commandID, resolution: .approved, dispatch: .awaitingOrigin, serverTime: now))
        let keys = InMemoryCredentialStore()
        let key = InMemoryDeviceKey()
        try keys.storeSigningKey(key)
        let reviewers = InMemoryWatchReviewerStore(WatchTestFixtures.activeReviewer(accountID: gateway.accountID, key: key))
        let session = try ControlSession(
            link: gateway, keys: keys, reviewerStore: reviewers, cache: InMemoryInboxCache(),
            journalStore: journalStore, now: { [now] in now.date }
        )
        await session.start()
        XCTAssertTrue(session.pendingCommands.isEmpty)
        let types = await gateway.requestTypes()
        XCTAssertTrue(types.contains(.commandQuery))
        XCTAssertFalse(types.contains(.commandSubmit))
    }

    // MARK: Refresh

    func testExpiredCursorFallsBackToAFullSnapshot() async throws {
        let rig = try await rig()
        await rig.session.start()
        await rig.gateway.setExpireNextCursor(true)
        await rig.session.refresh()
        let types = await rig.gateway.requestTypes()
        XCTAssertEqual(types.filter { $0 == .snapshotFetch }.count, 2)
        XCTAssertNotNil(rig.session.inbox.cursor)
    }

    func testAReviewFetchAlwaysAsksTheGateway() async throws {
        let rig = try await rig()
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        await rig.gateway.setApprovals([record])
        await rig.session.start()
        let before = await rig.gateway.requestTypes().filter { $0 == .approvalFetch }.count
        _ = try await rig.session.fetchForReview(record.spec.requestID)
        let after = await rig.gateway.requestTypes().filter { $0 == .approvalFetch }.count
        XCTAssertEqual(after, before + 1)
    }

    func testRevocationSignsOutAndClearsLocalState() async throws {
        let rig = try await rig()
        await rig.session.start()
        await rig.gateway.setNextReviewerState(.revoked)
        await rig.session.checkEnrollment()
        XCTAssertEqual(rig.session.phase, .needsEnrollment)
        XCTAssertNil(try rig.keys.loadSigningKey())
        XCTAssertNil(rig.reviewers.load())
        XCTAssertTrue(rig.session.inbox.approvals.isEmpty)
    }

    /// A re-paired or replaced iPhone no longer carries this Watch. The Watch
    /// drops its reviewer identity but keeps its key, so setting up again is
    /// a re-binding of the same key that the Mac confirms.
    func testUnboundWatchReturnsToSetupKeepingItsKey() async throws {
        let rig = try await rig()
        await rig.session.start()
        let key = try XCTUnwrap(try rig.keys.loadSigningKey())
        await rig.gateway.setUnbound(true)
        await rig.session.refresh()
        XCTAssertEqual(rig.session.phase, .needsEnrollment)
        XCTAssertNil(rig.reviewers.load())
        XCTAssertEqual(try rig.keys.loadSigningKey()?.publicJWK, key.publicJWK)

        await rig.gateway.setUnbound(false)
        await rig.session.enroll(label: "Apple Watch")
        let requests = await rig.gateway.requests
        let enrollment = try WatchEnrollmentRequest(json: try XCTUnwrap(requests.last { $0.type == .enrollmentRequest }).body)
        XCTAssertEqual(enrollment.publicJWK, key.publicJWK)
    }

    /// Background context is display state: a refresh hint at most.
    func testBackgroundContextNeverCarriesAuthority() async throws {
        let rig = try await rig()
        await rig.session.start()
        let decisionLike: [String: Any] = [
            WatchGatewayContext.applicationContextKey: #"{"mac_reachable":true,"pending_count":1,"protocol":"shell-watch-gateway/1","refresh_requested":false,"request_ids":[],"signed_command":"a.b.c","type":"gateway.context","v":1}"#
        ]
        XCTAssertNil(WatchGatewayContext(applicationContext: decisionLike))
        rig.session.applyContext(WatchGatewayContext(pendingCount: 1, refreshRequested: false, macReachable: true))
        let submitted = await rig.gateway.submitted
        XCTAssertTrue(submitted.isEmpty)
    }

    func testBackgroundingCancelsPolling() async throws {
        let rig = try await rig()
        await rig.session.start()
        rig.session.startPolling()
        XCTAssertTrue(rig.session.isPolling)
        rig.session.noteSceneActive(false)
        XCTAssertFalse(rig.session.isPolling)
    }

    /// A loop cancelled by backgrounding exits late, after the scene came
    /// back and a new loop started. It must not clear the new loop's slot,
    /// which left the Watch polling with `isPolling` false and a second
    /// loop able to start beside it.
    func testALateExitingCancelledLoopDoesNotClobberItsReplacement() async throws {
        let rig = try await rig()
        await rig.session.start()
        rig.session.startPolling()
        rig.session.noteSceneActive(false)
        rig.session.noteSceneActive(true)
        XCTAssertTrue(rig.session.isPolling)
        // Let the cancelled loop wake from its sleep and finish.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(rig.session.isPolling, "the replacement loop is still registered")
        rig.session.stopPolling()
        XCTAssertFalse(rig.session.isPolling)
    }

    /// A reconcile keeps the in-memory inbox within the cache's bounds: the
    /// reconciler itself never drops a resolved approval.
    func testRefreshKeepsTheInboxBounded() async throws {
        let cache = InMemoryInboxCache()
        var seeded = InboxState()
        for _ in 0..<(InboxBounds.maxApprovals + 20) {
            let record = try WatchTestFixtures.makeRecord(createdAt: now, resolution: .rejected, presentAt: now)
            seeded.approvals[record.spec.requestID] = record
        }
        let pending = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        seeded.approvals[pending.spec.requestID] = pending
        seeded.cursor = ChangeCursor("c1.1.tag")
        try cache.commit(seeded)
        let rig = try await rig(cache: cache)
        await rig.session.start()
        XCTAssertLessThanOrEqual(rig.session.inbox.approvals.count, InboxBounds.maxApprovals)
        XCTAssertNotNil(rig.session.inbox.approvals[pending.spec.requestID], "pending requests are always kept")
    }
}
