import XCTest
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlBroker

/// Regressions for defects found in review of the first implementation.
final class RegressionTests: XCTestCase {
    // MARK: Request parsing

    func testDegenerateQueryAndFormPairsDoNotTrap() {
        // "?=" and a body of "=" split into no parts at all; indexing them
        // would take the whole broker process down from an unauthenticated
        // request.
        XCTAssertEqual(HTTPServer.parseTarget("/v1/capabilities?=").query, [:])
        XCTAssertEqual(HTTPServer.parseTarget("/v1/capabilities?=&&a=1").query, ["a": "1"])
        XCTAssertEqual(HTTPServer.parseTarget("/v1/capabilities").path, "/v1/capabilities")
        XCTAssertEqual(BrokerService.parseFormBody(Data("=".utf8)), [:])
        XCTAssertEqual(BrokerService.parseFormBody(Data("=&grant_type=refresh_token".utf8)), ["grant_type": "refresh_token"])
    }

    // MARK: Push registration

    func testPushRegistrationFailsClosedWithNoConfiguredTopics() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        // With no configured app IDs there is no topic a device may claim.
        await assertControlError(.notAuthorized) {
            try await harness.store.registerPush(
                principal: device.principal,
                registration: try PushRegistration(
                    token: String(repeating: "ab", count: 32),
                    platform: .watchOS,
                    environment: .production,
                    topic: "dev.chr33s.shell.watchkitapp"
                ),
                allowedTopics: []
            )
        }
    }

    // MARK: Sessions across a restart

    func testRestoreKeepsSessionsEnrollmentsAndSequenceNumbers() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-control-regression-\(UUID().uuidString)")
            .appendingPathComponent("broker.json")
        let persistence = try FileBrokerPersistence(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let harness = BrokerHarness(persistence: persistence)
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        let stored = await harness.store.device(device.id)
        let record = try XCTUnwrap(stored)
        let session = try await harness.store.issueSession(for: record)
        try await harness.store.commit()
        let runID = ControlID.random()
        let jobID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        _ = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let sequenceBefore = await harness.store.nextSequence

        let clock = harness.clock
        let restored = BrokerStore(
            serviceIdentity: "test-broker",
            cursorSecret: Data(repeating: 7, count: 32),
            persistence: persistence,
            now: { clock.now }
        )
        try await restored.restore()

        // A restart must not 401 every enrolled device.
        let principal = try await restored.authenticate(bearer: session.accessToken)
        XCTAssertEqual(principal.deviceID, device.id)
        // The rotating refresh token survives too.
        let refreshed = try await restored.refreshSession(refreshToken: session.refreshToken)
        XCTAssertEqual(refreshed.deviceID, device.id)
        // Sequence numbers continue rather than restarting under live cursors.
        let sequenceAfter = await restored.nextSequence
        XCTAssertEqual(sequenceAfter, sequenceBefore)
    }

    // MARK: Snapshot pagination

    func testAnItemCreatedDuringPaginationDoesNotDisplaceOne() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await harness.enrollDevice()
        let runID = ControlID.random()
        let jobID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        for _ in 0..<2 {
            _ = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        }
        for index in 0..<2 {
            _ = try await harness.store.createNotification(
                principal: harness.originPrincipal,
                event: try InformationalEvent(
                    eventID: .random(),
                    originID: harness.originID,
                    kind: .jobCompleted,
                    title: "event \(index)",
                    body: "",
                    occurredAt: harness.timestamp
                )
            )
        }

        let first = try await harness.store.snapshot(principal: device.principal, limit: 2)
        XCTAssertEqual(first.approvals.count, 2)
        // A new approval lands between the two page fetches.
        _ = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let second = try await harness.store.snapshot(
            principal: device.principal,
            pageToken: try XCTUnwrap(first.nextPageToken),
            limit: 2
        )
        // Paging is anchored, so the mid-pagination approval is not in the
        // snapshot and neither notification is skipped.
        XCTAssertTrue(second.approvals.isEmpty)
        XCTAssertEqual(second.notifications.count, 2)
        XCTAssertTrue(second.isComplete)
        // The one that arrived mid-pagination is delivered as a delta instead.
        let changes = try await harness.store.changes(principal: device.principal, cursor: second.cursor)
        XCTAssertTrue(changes.events.contains { $0.type == .approvalCreated })
    }

    // MARK: The confirmation surface

    private func makeService(_ harness: BrokerHarness) -> BrokerService {
        BrokerService(
            store: harness.store,
            configuration: BrokerService.Configuration(
                verificationURI: "http://localhost:8443/v1/oauth/confirm",
                allowedAPNsTopics: ["dev.chr33s.shell.watchkitapp"],
                adminSecret: "admin-secret",
                adminAccountID: harness.accountID
            )
        )
    }

    private func pendingUserCode(_ harness: BrokerHarness) async throws -> (code: String, fingerprint: String) {
        let key = InMemoryDeviceKey()
        let enrollment = try await harness.store.createEnrollment(publicJWK: key.publicJWK, platform: .watchOS, label: "Probe <Watch>")
        let authorization = try await harness.store.startDeviceAuthorization(
            scope: "control.enroll:\(enrollment.enrollmentID.rawValue)",
            verificationURI: "http://localhost:8443/v1/oauth/confirm"
        )
        return (try XCTUnwrap(authorization["user_code"]?.stringValue), try key.publicJWK.displayFingerprint())
    }

    /// A browser sent to the verification URI gets a page it can act on, and
    /// learns nothing about the pending enrollment until it authenticates.
    func testUnauthenticatedBrowserGetsAFormAndNoDetails() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let pending = try await pendingUserCode(harness)
        let response = await makeService(harness).handle(HTTPServer.Request(
            method: "GET",
            path: "/v1/oauth/confirm",
            query: ["user_code": pending.code],
            headers: ["accept": "text/html"],
            body: Data()
        ))
        XCTAssertEqual(response.status, 401)
        let page = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(page.contains("Administration secret"))
        XCTAssertFalse(page.contains(pending.fingerprint))
        XCTAssertFalse(page.contains("Probe"))
        XCTAssertEqual(response.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertEqual(response.headers["Cache-Control"], "no-store")
    }

    /// An API client without the credential still gets the JSON error envelope,
    /// not a page.
    func testUnauthenticatedAPICallStillGetsJSON() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let pending = try await pendingUserCode(harness)
        let response = await makeService(harness).handle(HTTPServer.Request(
            method: "GET",
            path: "/v1/oauth/confirm",
            query: ["user_code": pending.code],
            headers: [:],
            body: Data()
        ))
        XCTAssertEqual(response.status, ControlErrorCode.notAuthorized.httpStatus)
        let error = try ControlError(json: try JSONValue.parse(response.body))
        XCTAssertEqual(error.code, .notAuthorized)
    }

    func testAuthenticatedPageShowsWhatIsBeingGrantedWithEscaping() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let pending = try await pendingUserCode(harness)
        let response = await makeService(harness).handle(HTTPServer.Request(
            method: "GET",
            path: "/v1/oauth/confirm",
            query: ["user_code": pending.code],
            headers: ["accept": "text/html", "authorization": "Admin admin-secret"],
            body: Data()
        ))
        XCTAssertEqual(response.status, 200)
        let page = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(page.contains(pending.fingerprint))
        XCTAssertTrue(page.contains("approvals.decide"))
        // A device-supplied label is escaped, never rendered as markup.
        XCTAssertTrue(page.contains("Probe &lt;Watch&gt;"))
        XCTAssertFalse(page.contains("Probe <Watch>"))
    }

    func testBrowserFormConfirmationApprovesAndAWrongSecretDoesNot() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let service = makeService(harness)
        let pending = try await pendingUserCode(harness)

        let refused = await service.handle(HTTPServer.Request(
            method: "POST",
            path: "/v1/oauth/confirm",
            query: [:],
            headers: ["content-type": "application/x-www-form-urlencoded", "accept": "text/html"],
            body: Data("user_code=\(pending.code)&admin_secret=wrong&approve=true".utf8)
        ))
        XCTAssertEqual(refused.status, ControlErrorCode.notAuthorized.httpStatus)

        let approved = await service.handle(HTTPServer.Request(
            method: "POST",
            path: "/v1/oauth/confirm",
            query: [:],
            headers: ["content-type": "application/x-www-form-urlencoded", "accept": "text/html"],
            body: Data("user_code=\(pending.code)&admin_secret=admin-secret&approve=true".utf8)
        ))
        XCTAssertEqual(approved.status, 200)
        XCTAssertTrue(String(decoding: approved.body, as: UTF8.self).contains("Device approved"))
        // The approval is real: the enrollment can now be completed.
        let described = try await harness.store.describeUserCode(pending.code)
        XCTAssertEqual(described["user_code"]?.stringValue, pending.code)
    }

    // MARK: Grants

    func testChangeStreamRequiresTheReadGrant() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await harness.enrollDevice(grants: [.notificationsRead, .notificationsAck])
        let service = BrokerService(
            store: harness.store,
            configuration: BrokerService.Configuration(
                verificationURI: "https://example.test/activate",
                allowedAPNsTopics: ["dev.chr33s.shell.watchkitapp"],
                adminSecret: "admin",
                adminAccountID: harness.accountID
            )
        )
        let stored = await harness.store.device(device.id)
        let record = try XCTUnwrap(stored)
        let session = try await harness.store.issueSession(for: record)
        let response = await service.handle(HTTPServer.Request(
            method: "GET",
            path: "/v1/changes",
            query: ["cursor": "c1.0.deadbeef"],
            headers: ["authorization": "Bearer \(session.accessToken)"],
            body: Data()
        ))
        // Reduced grants must not keep reading request content through deltas.
        XCTAssertEqual(response.status, ControlErrorCode.notAuthorized.httpStatus)
    }
}
