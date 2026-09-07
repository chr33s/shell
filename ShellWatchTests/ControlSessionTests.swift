import XCTest
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@testable import ShellWatch

/// The Watch's session: credential renewal, offline behaviour, and cache
/// handling (spec.watch.md sections 5, 7, and 15).
@MainActor
final class ControlSessionTests: XCTestCase {
    private let now = ControlTimestamp(Date(timeIntervalSince1970: 1_788_000_000))

    private func makeSession(
        service: StubControlService,
        credentials: InMemoryCredentialStore,
        cache: InMemoryInboxCache = InMemoryInboxCache()
    ) throws -> ControlSession {
        try ControlSession(
            brokerURL: URL(string: "https://control.test")!,
            credentials: credentials,
            cache: cache,
            journalStore: InMemoryCommandJournal(),
            transport: service,
            now: { [now] in now.date }
        )
    }

    private func makeService(deviceID: ControlID = .random(), accountID: ControlID = .random()) -> StubControlService {
        StubControlService(
            validAccessToken: "access-1",
            refreshToken: "refresh-1",
            nextAccessToken: "access-2",
            deviceID: deviceID,
            accountID: accountID,
            now: now
        )
    }

    // MARK: Credential renewal

    /// Access tokens last ten minutes. A stale one must be renewed before the
    /// request goes out, not discovered as an unrecoverable 401.
    func testAStaleAccessTokenIsRenewedBeforeAnyRequest() async throws {
        let service = makeService()
        let credentials = InMemoryCredentialStore()
        let key = InMemoryDeviceKey()
        try credentials.storeSigningKey(key)
        // Already expired, as it would be after the app was closed for an hour.
        var stored = await service.session(accessTokenExpiresAt: now.adding(-60))
        stored.accessToken = "access-1"
        try credentials.storeSession(stored)

        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        await service.setApprovals([record])
        await service.setValidToken("access-2-only")

        let session = try makeSession(service: service, credentials: credentials)
        await session.start()

        XCTAssertEqual(session.phase, .ready)
        let refreshes = await service.refreshCount
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(session.inbox.pendingApprovals.count, 1)
        // Every authorized call used the renewed token.
        let headers = await service.authorizationHeaders().compactMap { $0 }
        XCTAssertFalse(headers.contains("Bearer access-1"))
        // The rotated credentials were persisted, so a relaunch does not repeat
        // the renewal from a spent refresh token.
        let persisted = try XCTUnwrap(try credentials.loadSession())
        XCTAssertEqual(persisted.accessToken, "access-2-only")
        XCTAssertNotEqual(persisted.refreshToken, "refresh-1")
    }

    func testAFreshAccessTokenIsNotRenewed() async throws {
        let service = makeService()
        let credentials = InMemoryCredentialStore()
        try credentials.storeSigningKey(InMemoryDeviceKey())
        try credentials.storeSession(await service.session())

        let session = try makeSession(service: service, credentials: credentials)
        await session.start()

        let refreshes = await service.refreshCount
        XCTAssertEqual(refreshes, 0)
        XCTAssertFalse(session.isOffline)
    }

    /// A revoked device cannot recover by refreshing: the local credentials and
    /// cache go away and the app returns to enrollment.
    func testRevocationDuringRenewalSignsOutAndClearsLocalState() async throws {
        let service = makeService()
        await service.setRefreshFailure(ControlError(code: .deviceRevoked, message: "device revoked"))
        let credentials = InMemoryCredentialStore()
        try credentials.storeSigningKey(InMemoryDeviceKey())
        var stored = await service.session(accessTokenExpiresAt: now.adding(-60))
        stored.accessToken = "access-1"
        try credentials.storeSession(stored)
        let cache = InMemoryInboxCache()
        var seeded = InboxState()
        seeded.approvals[.random()] = try WatchTestFixtures.makeRecord(createdAt: now)
        try cache.commit(seeded)

        let session = try makeSession(service: service, credentials: credentials, cache: cache)
        await session.start()

        XCTAssertEqual(session.phase, .needsEnrollment)
        XCTAssertTrue(session.inbox.approvals.isEmpty)
        XCTAssertNil(try credentials.loadSession())
        XCTAssertNil(try cache.load())
    }

    // MARK: Offline

    /// Cached viewing is allowed offline; no new control command is queued.
    func testOfflineKeepsTheCacheAndDisablesNewCommands() async throws {
        let service = makeService()
        let credentials = InMemoryCredentialStore()
        try credentials.storeSigningKey(InMemoryDeviceKey())
        try credentials.storeSession(await service.session())
        let cache = InMemoryInboxCache()
        var seeded = InboxState()
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        seeded.approvals[record.spec.requestID] = record
        seeded.lastRefreshedAt = now.adding(-120)
        try cache.commit(seeded)
        await service.setTransportFailure(.offline)

        let session = try makeSession(service: service, credentials: credentials, cache: cache)
        await session.start()

        XCTAssertTrue(session.isOffline)
        XCTAssertEqual(session.inbox.pendingApprovals.count, 1)
        // The staleness is visible rather than presented as current.
        XCTAssertEqual(session.lastRefreshedAt, now.adding(-120))
        // A review fetch fails rather than deciding from the cache.
        do {
            _ = try await session.fetchForReview(record.spec.requestID)
            XCTFail("a review fetch must not succeed offline")
        } catch {}
        XCTAssertTrue(session.pendingCommands.isEmpty)
    }

    // MARK: Reconciliation

    /// An expired cursor forces a fresh snapshot rather than a silent gap.
    func testExpiredCursorFallsBackToAFullSnapshot() async throws {
        let service = makeService()
        let credentials = InMemoryCredentialStore()
        try credentials.storeSigningKey(InMemoryDeviceKey())
        try credentials.storeSession(await service.session())
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        await service.setApprovals([record])

        let session = try makeSession(service: service, credentials: credentials)
        await session.start()
        XCTAssertEqual(session.inbox.cursor?.rawValue, "c1.1.tag")

        await service.setExpireNextCursor(true)
        await session.refresh()

        XCTAssertEqual(session.inbox.pendingApprovals.count, 1)
        let recorded = await service.requests
        let paths = recorded.map(\.path)
        XCTAssertEqual(paths.filter { $0 == "/v1/snapshot" }.count, 2)
    }

    func testAReviewFetchAlwaysAsksTheService() async throws {
        let service = makeService()
        let credentials = InMemoryCredentialStore()
        try credentials.storeSigningKey(InMemoryDeviceKey())
        try credentials.storeSession(await service.session())
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        await service.setApprovals([record])

        let session = try makeSession(service: service, credentials: credentials)
        await session.start()
        let fetched = try await session.fetchForReview(record.spec.requestID)

        XCTAssertEqual(fetched.requestHash, record.requestHash)
        let recorded = await service.requests
        let paths = recorded.map(\.path)
        XCTAssertTrue(paths.contains("/v1/approvals/\(record.spec.requestID.rawValue)"))
    }

    func testWithoutCredentialsTheAppAsksForEnrollment() async throws {
        let service = makeService()
        let session = try makeSession(service: service, credentials: InMemoryCredentialStore())
        await session.start()
        XCTAssertEqual(session.phase, .needsEnrollment)
        let requests = await service.requests
        XCTAssertTrue(requests.isEmpty)
    }
}
