import Foundation
import XCTest
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient
@testable import ShellControlBroker

/// Routes client requests straight into `BrokerService.handle`, so the phone's
/// real HTTP client, the gateway router, and the Watch client are exercised
/// against the real broker without sockets.
struct InProcessTransport: ControlHTTPTransport {
    let service: BrokerService
    var extraHeaders: [String: String] = [:]

    func send(_ request: ControlHTTPRequest, baseURL: URL) async throws -> ControlHTTPResponse {
        var headers: [String: String] = ["host": baseURL.host.map { host in baseURL.port.map { "\(host):\($0)" } ?? host } ?? ""]
        for (name, value) in request.headers { headers[name.lowercased()] = value }
        for (name, value) in extraHeaders { headers[name.lowercased()] = value }
        let response = await service.handle(HTTPServer.Request(
            method: request.method,
            path: request.path,
            query: Dictionary(request.query, uniquingKeysWith: { _, last in last }),
            headers: headers,
            body: request.body ?? Data()
        ))
        return ControlHTTPResponse(status: response.status, headers: response.headers, body: response.body)
    }
}

/// A WatchConnectivity stand-in: it hands the request bytes to the phone's
/// router and returns the reply bytes, and can be made unreachable.
final class DirectWatchLink: WatchGatewayLink, @unchecked Sendable {
    let router: WatchGatewayRouter
    private let lock = NSLock()
    private var reachable = true
    private(set) var sent = 0

    init(router: WatchGatewayRouter) { self.router = router }

    func setReachable(_ value: Bool) { lock.withLock { reachable = value } }

    func isReachable() async -> Bool { lock.withLock { reachable } }

    func send(_ data: Data) async throws -> Data {
        lock.withLock { sent += 1 }
        return await router.handle(data)
    }
}

final class GatewayFixture {
    let harness: BrokerHarness
    let service: BrokerService
    let originKey: OriginSigningKey
    let adminSecret = "admin-secret-for-tests-0123456789"
    let route: OriginRoute

    init(persistence: (any BrokerPersistence)? = nil) {
        do {
            route = try OriginRoute("http://127.0.0.1:8443")
        } catch {
            preconditionFailure("the loopback test route is valid: \(error)")
        }
        let originKey = OriginSigningKey()
        self.originKey = originKey
        harness = BrokerHarness(persistence: persistence, originKey: originKey)
        service = BrokerService(store: harness.store, configuration: .init(
            verificationURI: "http://127.0.0.1:8443/v1/oauth/confirm",
            allowedAPNsTopics: [],
            adminSecret: adminSecret,
            adminAccountID: harness.accountID
        ))
    }

    var origin: OriginIdentity { OriginIdentity(originID: harness.originID, publicJWK: originKey.publicJWK) }
    var transport: InProcessTransport { InProcessTransport(service: service) }

    func admin(_ method: String, _ path: String, query: [(String, String)] = [], body: JSONValue? = nil, extraHeaders: [String: String] = [:]) async throws -> JSONValue {
        let response = try await InProcessTransport(service: service, extraHeaders: extraHeaders).send(ControlHTTPRequest(
            method: method, path: path, query: query,
            headers: ["Authorization": "Admin \(adminSecret)", "Content-Type": "application/json"],
            body: try body.map(JSONCanonicalization.canonicalize)
        ), baseURL: route.url)
        let value = try JSONValue.parse(response.body)
        guard response.isSuccess else { throw try ControlError(json: value) }
        return value
    }

    func invitation() async throws -> PairingInvitation {
        var reader = try JSONReader(try await admin("POST", "/v1/admin/pairings"))
        return try PairingInvitation(
            origin: origin,
            route: route,
            pairingID: try reader.id("pairing_id"),
            pairingSecret: try reader.string("pairing_secret"),
            expiresAt: try reader.timestamp("expires_at")
        )
    }

    func confirm(_ userCode: String) async throws {
        _ = try await admin("POST", "/v1/oauth/confirm", body: .object(["user_code": .string(userCode)]))
    }

    struct Phone: Sendable {
        let client: ControlAPIClient
        let key: InMemoryDeviceKey
        let session: DeviceSession
    }

    /// The whole iPhone pairing: proof, claim, Mac confirmation, completion.
    func pairPhone() async throws -> Phone {
        let invitation = try await invitation()
        let unauthenticated = ControlAPIClient(baseURL: invitation.route.url, transport: transport)
        try await unauthenticated.verifyOrigin(invitation.origin)
        let key = InMemoryDeviceKey()
        let claim = try await unauthenticated.claimPairing(invitation, key: key, platform: .iOS, label: "iPhone", now: harness.timestamp)
        try await confirm(claim.authorization.userCode)
        let enrollment = EnrollmentCoordinator(baseURL: invitation.route.url, transport: transport, now: { [clock = harness.clock] in clock.now })
        let token = try await enrollment.poll(deviceCode: claim.authorization.deviceCode)
        let session = try await enrollment.complete(enrollmentID: claim.enrollmentID, enrollmentToken: token, challenge: claim.challenge, key: key)
        return Phone(
            client: ControlAPIClient(baseURL: invitation.route.url, transport: transport, credential: .device(session.accessToken)),
            key: key,
            session: session
        )
    }

    struct Watch {
        let key: InMemoryDeviceKey
        let client: WatchGatewayClient
        let link: DirectWatchLink
        let router: WatchGatewayRouter
        let status: WatchReviewerStatus
    }

    func enrollWatch(behind phone: Phone, key: InMemoryDeviceKey = InMemoryDeviceKey()) async throws -> Watch {
        let router = WatchGatewayRouter(client: { phone.client }, binding: InMemoryWatchBindingStore(), now: { [clock = harness.clock] in clock.now })
        let link = DirectWatchLink(router: router)
        let client = WatchGatewayClient(link: link)
        let pending = try await client.requestEnrollment(try WatchEnrollmentRequest.make(key: key, label: "Apple Watch"))
        XCTAssertEqual(pending.state, .pending)
        try await confirm(try XCTUnwrap(pending.userCode))
        let active = try await client.enrollmentStatus()
        XCTAssertEqual(active.state, .active)
        return Watch(key: key, client: client, link: link, router: router, status: active)
    }

    func publishApproval() async throws -> ApprovalRecord {
        let runID = ControlID.random()
        let jobID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        return try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
    }
}

final class GatewayTests: XCTestCase {
    // MARK: Origin identity and pairing

    func testOriginProofAnswersTheNonceUnderTheOriginKey() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let client = ControlAPIClient(baseURL: fixture.route.url, transport: fixture.transport)
        try await client.verifyOrigin(fixture.origin)

        // Another key is not the paired origin, whatever the route says.
        let impostor = OriginIdentity(originID: fixture.origin.originID, publicJWK: OriginSigningKey().publicJWK)
        await assertControlError(.notAuthorized) { try await client.verifyOrigin(impostor) }
    }

    func testPairingSecretIsRequiredAndSpentOnce() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let invitation = try await fixture.invitation()
        let client = ControlAPIClient(baseURL: fixture.route.url, transport: fixture.transport)

        let forged = try PairingInvitation(
            origin: invitation.origin, route: invitation.route, pairingID: invitation.pairingID,
            pairingSecret: Base64URL.encode(Data(repeating: 1, count: 32)), expiresAt: invitation.expiresAt
        )
        await assertControlError(.notAuthorized) {
            _ = try await client.claimPairing(forged, key: InMemoryDeviceKey(), platform: .iOS, label: "iPhone")
        }
        _ = try await client.claimPairing(invitation, key: InMemoryDeviceKey(), platform: .iOS, label: "iPhone")
        await assertControlError(.notFound) {
            _ = try await client.claimPairing(invitation, key: InMemoryDeviceKey(), platform: .iOS, label: "iPhone")
        }
    }

    func testPairingExpires() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let invitation = try await fixture.invitation()
        fixture.harness.clock.advance(11 * 60)
        let client = ControlAPIClient(baseURL: fixture.route.url, transport: fixture.transport)
        await assertControlError(.requestExpired) {
            _ = try await client.claimPairing(invitation, key: InMemoryDeviceKey(), platform: .iOS, label: "iPhone")
        }
    }

    func testPairedPhoneNeedsMacConfirmationBeforeItHasASession() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let invitation = try await fixture.invitation()
        let client = ControlAPIClient(baseURL: fixture.route.url, transport: fixture.transport)
        let claim = try await client.claimPairing(invitation, key: InMemoryDeviceKey(), platform: .iOS, label: "iPhone")
        let enrollment = EnrollmentCoordinator(baseURL: fixture.route.url, transport: fixture.transport)
        do {
            _ = try await enrollment.poll(deviceCode: claim.authorization.deviceCode)
            XCTFail("expected authorization_pending")
        } catch EnrollmentError.authorizationPending {}
        let pending = try await fixture.admin("GET", "/v1/admin/pending")
        XCTAssertEqual(pending["pending"]?.arrayValue?.count, 1)
    }

    /// Without the setup QR there is no way in: direct enrollment is closed in
    /// the gateway profile, for iPhones and Watches alike.
    func testDirectEnrollmentIsClosedInTheGatewayProfile() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        for platform in [PushRegistration.Platform.iOS, .watchOS] {
            let coordinator = EnrollmentCoordinator(baseURL: fixture.route.url, transport: fixture.transport)
            await assertControlError(.notAuthorized) {
                _ = try await coordinator.start(key: InMemoryDeviceKey(), platform: platform, label: "device")
            }
        }
    }

    /// Admin routes are unreachable through Tailscale Serve, whatever Host says.
    func testAdminRoutesRefuseTailscaleForwardedRequests() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        await assertControlError(.notFound) {
            _ = try await fixture.admin("POST", "/v1/admin/pairings", extraHeaders: ["Tailscale-User-Login": "someone@example.com"])
        }
        await assertControlError(.notFound) {
            _ = try await fixture.admin("GET", "/v1/admin/devices", extraHeaders: ["X-Forwarded-For": "100.64.0.2"])
        }
    }

    // MARK: Watch behind the gateway

    func testWatchDecisionThroughTheGatewayIsAttributedToTheWatchKey() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        XCTAssertEqual(watch.status.gatewayDeviceID, phone.session.deviceID)
        XCTAssertEqual(watch.status.accountID, fixture.harness.accountID)
        XCTAssertFalse(watch.status.grants.contains(.requestsRead), "a reviewer holds no standalone read grant")
        let record = try await fixture.publishApproval()

        // The inbox comes through the gateway, one bounded page at a time.
        let page = try await watch.client.snapshot()
        XCTAssertEqual(page.approvals.map(\.spec.requestID), [record.spec.requestID])

        let coordinator = DecisionCoordinator(
            service: watch.client,
            journal: try CommandJournal(),
            key: watch.key,
            signer: SignerIdentity(deviceID: watch.status.watchDeviceID, audience: try XCTUnwrap(watch.status.audience), grants: watch.status.grants),
            now: { [clock = fixture.harness.clock] in clock.now }
        )
        let state = try await coordinator.decide(.approve, reviewed: try await watch.client.approval(record.spec.requestID))
        guard case .waitingForHost(let result) = state else { return XCTFail("unexpected \(state)") }
        XCTAssertEqual(result.resolution, .approved)

        let stored = try await fixture.harness.store.approval(record.spec.requestID, principal: phone.session.principal(fixture.harness.store))
        XCTAssertEqual(stored.projection.decidedByDeviceID, watch.status.watchDeviceID)

        // The recorded result is reachable again by command id.
        let queried = try await watch.client.commandResult(result.commandID)
        XCTAssertEqual(queried.decisionID, result.decisionID)
    }

    /// The iPhone relays; it cannot forge. A JWS it signs is either not the
    /// Watch's key or not the Watch's identity.
    func testIPhoneCannotSubstituteItsOwnSignatureForTheWatch() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        let record = try await fixture.publishApproval()
        let watchID = watch.status.watchDeviceID
        let challenge = try ReviewChallenge(json: try await phone.client.gatewayReviewChallenge(
            watch: watchID,
            request: try ReviewChallengeRequest(
                target: .approval(requestID: record.spec.requestID, requestHash: record.requestHash,
                                  expectedStateVersion: record.projection.stateVersion, policyVersion: record.projection.policyVersion),
                action: .approvalDecide
            ).json
        ))

        // Claims to be the Watch, signed with the phone's key.
        let forgedWatch = try fixture.harness.signDecision(
            .approve,
            device: .init(id: watchID, key: phone.key, principal: .device(deviceID: watchID, accountID: fixture.harness.accountID, grants: [])),
            record: record,
            challengeID: challenge.challengeID
        )
        await assertControlError(.invalidPayload) {
            _ = try await phone.client.gatewaySubmit(watch: watchID, signedCommand: forgedWatch, commandID: .random())
        }
        // Honestly the phone's own decision, pushed down the Watch channel.
        let phoneOwn = try fixture.harness.signDecision(
            .approve,
            device: .init(id: phone.session.deviceID, key: phone.key, principal: .device(deviceID: phone.session.deviceID, accountID: fixture.harness.accountID, grants: [])),
            record: record,
            challengeID: challenge.challengeID
        )
        await assertControlError(.notAuthorized) {
            _ = try await phone.client.gatewaySubmit(watch: watchID, signedCommand: phoneOwn, commandID: .random())
        }
        let current = try await fixture.harness.store.approval(record.spec.requestID, principal: fixture.harness.originPrincipal)
        XCTAssertEqual(current.projection.resolution, .pending)
    }

    func testAnotherGatewayCannotReachTheWatch() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let other = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        _ = try await fixture.publishApproval()
        await assertControlError(.reviewerNotBound) {
            _ = try await other.client.gatewaySnapshot(watch: watch.status.watchDeviceID, limit: 4)
        }
        await assertControlError(.reviewerNotBound) {
            _ = try await other.client.watchReviewer(watch.status.watchDeviceID)
        }
        // An ID that exists nowhere looks exactly the same.
        await assertControlError(.reviewerNotBound) {
            _ = try await other.client.watchReviewer(.random())
        }
    }

    func testSwitchingGatewayRequiresExplicitRebinding() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        let replacement = try await fixture.pairPhone()

        // The same Watch key asking through a new iPhone is only a request.
        let router = WatchGatewayRouter(client: { replacement.client }, binding: InMemoryWatchBindingStore())
        let client = WatchGatewayClient(link: DirectWatchLink(router: router))
        let pending = try await client.requestEnrollment(try WatchEnrollmentRequest.make(key: watch.key, label: "Apple Watch"))
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.watchDeviceID, watch.status.watchDeviceID)
        // Until confirmed, the old binding stands.
        _ = try await phone.client.gatewaySnapshot(watch: watch.status.watchDeviceID, limit: 4)

        try await fixture.confirm(try XCTUnwrap(pending.userCode))
        let rebound = try await client.enrollmentStatus()
        XCTAssertEqual(rebound.state, .active)
        await assertControlError(.reviewerNotBound) {
            _ = try await phone.client.gatewaySnapshot(watch: watch.status.watchDeviceID, limit: 4)
        }
    }

    func testRevokingTheGatewayDisablesWatchTransport() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        _ = try await fixture.admin("POST", "/v1/admin/devices/\(phone.session.deviceID.rawValue)/revoke")
        do {
            _ = try await watch.client.snapshot()
            XCTFail("expected refusal")
        } catch let error as ControlError {
            XCTAssertTrue([.deviceRevoked, .invalidToken].contains(error.code))
        }
    }

    func testRevokingTheWatchLeavesTheIPhoneUsable() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        _ = try await fixture.admin("POST", "/v1/admin/devices/\(watch.status.watchDeviceID.rawValue)/revoke")
        await assertControlError(.deviceRevoked) { _ = try await watch.client.snapshot() }
        _ = try await phone.client.snapshot()
    }

    func testUnreachableIPhoneDisablesDecisionsWithoutQueueing() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        let record = try await fixture.publishApproval()
        let reviewed = try await watch.client.approval(record.spec.requestID)
        watch.link.setReachable(false)
        let sentBefore = watch.link.sent

        let journal = try CommandJournal()
        let coordinator = DecisionCoordinator(
            service: watch.client, journal: journal, key: watch.key,
            signer: SignerIdentity(deviceID: watch.status.watchDeviceID, audience: try XCTUnwrap(watch.status.audience), grants: watch.status.grants),
            now: { [clock = fixture.harness.clock] in clock.now }
        )
        do {
            _ = try await coordinator.decide(.approve, reviewed: reviewed)
            XCTFail("expected iPhone unavailable")
        } catch let error as WatchGatewayError {
            XCTAssertEqual(error, .iPhoneUnreachable)
        }
        let journalled = await journal.pending
        XCTAssertTrue(journalled.isEmpty, "nothing was signed for later delivery")
        XCTAssertEqual(watch.link.sent, sentBefore)
        watch.link.setReachable(true)
        let current = try await watch.client.approval(record.spec.requestID)
        XCTAssertEqual(current.projection.resolution, .pending)
    }

    func testSimultaneousIPhoneAndWatchDecisionsYieldOneWinner() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        let record = try await fixture.publishApproval()
        let clock = fixture.harness.clock
        let watchCoordinator = DecisionCoordinator(
            service: watch.client, journal: try CommandJournal(), key: watch.key,
            signer: SignerIdentity(deviceID: watch.status.watchDeviceID, audience: try XCTUnwrap(watch.status.audience), grants: watch.status.grants),
            now: { clock.now }
        )
        let phoneCoordinator = DecisionCoordinator(client: phone.client, journal: try CommandJournal(), key: phone.key, session: phone.session, now: { clock.now })
        async let fromWatch = try? watchCoordinator.decide(.approve, reviewed: record)
        async let fromPhone = try? phoneCoordinator.decide(.reject, reviewed: record)
        let outcomes = await [fromWatch, fromPhone]
        let recorded = outcomes.compactMap { $0 }.filter {
            if case .waitingForHost = $0 { return true }
            return false
        }
        XCTAssertEqual(recorded.count, 1)
    }

    func testDuplicateWatchCommandReturnsTheOriginalAndAChangedBodyConflicts() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        let record = try await fixture.publishApproval()
        let watchID = watch.status.watchDeviceID
        let device = BrokerHarness.Device(id: watchID, key: watch.key, principal: .device(deviceID: watchID, accountID: fixture.harness.accountID, grants: []))
        let challenge = try await watch.client.reviewChallenge(try ReviewChallengeRequest(
            target: .approval(requestID: record.spec.requestID, requestHash: record.requestHash,
                              expectedStateVersion: record.projection.stateVersion, policyVersion: record.projection.policyVersion),
            action: .approvalDecide
        ))
        let commandID = ControlID.random()
        let jws = try fixture.harness.signDecision(.reject, device: device, record: record, challengeID: challenge.challengeID, commandID: commandID)
        let first = try await watch.client.submit(signedCommand: jws, commandID: commandID)
        let again = try await watch.client.submit(signedCommand: jws, commandID: commandID)
        XCTAssertEqual(first.decisionID, again.decisionID)
        let changed = try fixture.harness.signDecision(.approve, device: device, record: record, challengeID: challenge.challengeID, commandID: commandID)
        await assertControlError(.idempotencyConflict) {
            _ = try await watch.client.submit(signedCommand: changed, commandID: commandID)
        }
    }

    /// One approval too large for a Watch message is left out of the Watch's
    /// snapshot instead of failing every sync; its review is handed off.
    func testOversizedApprovalDoesNotStallTheWatchSnapshot() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        let small = try await fixture.publishApproval()
        let runID = ControlID.random(), jobID = ControlID.random()
        try await fixture.harness.registerRun(runID: runID, jobID: jobID)
        let huge = try await fixture.harness.publish(try fixture.harness.makeSpec(
            runID: runID, jobID: jobID, argv: ["/bin/echo"] + Array(repeating: String(repeating: "x", count: 4000), count: 20)
        ))

        var page = try await watch.client.snapshot(limit: 8)
        var seen = page.approvals.map(\.spec.requestID)
        while let next = page.nextPageToken {
            page = try await watch.client.snapshot(pageToken: next, limit: 8)
            seen += page.approvals.map(\.spec.requestID)
        }
        XCTAssertTrue(seen.contains(small.spec.requestID))
        XCTAssertFalse(seen.contains(huge.spec.requestID))
        await assertControlError(.unsupportedOperation) { _ = try await watch.client.approval(huge.spec.requestID) }
    }

    // MARK: Background channel

    func testBackgroundDeliveryCarriesNoAuthority() async throws {
        let router = WatchGatewayRouter(client: { throw TransportError.offline }, binding: InMemoryWatchBindingStore())
        XCTAssertFalse(router.handleBackground(["signed_command": "a.b.c", "type": "command.submit"]))
        let decisionLike: [String: Any] = [
            WatchGatewayContext.applicationContextKey: #"{"mac_reachable":true,"pending_count":1,"protocol":"shell-watch-gateway/1","refresh_requested":false,"request_ids":[],"signed_command":"a.b.c","type":"gateway.context","v":1}"#
        ]
        XCTAssertNil(WatchGatewayContext(applicationContext: decisionLike))
        let context = WatchGatewayContext(pendingCount: 2, requestIDs: [.random()], refreshRequested: true, macReachable: true)
        XCTAssertEqual(WatchGatewayContext(applicationContext: try context.applicationContext()), context)
    }

    func testRouterRejectsMessagesForAnUnboundWatch() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)
        let stranger = WatchGatewayClient(link: watch.link, watchDeviceID: .random())
        await assertControlError(.reviewerNotBound) { _ = try await stranger.snapshot() }
    }

    /// The iPhone's own session problem is not a connectivity failure, and
    /// is not the Watch's revocation either.
    func testRouterRelaysTheIPhonesSessionProblemAsAControlError() async throws {
        struct PairingRequired: ControlErrorConvertible {
            var controlError: ControlError { ControlError(code: .notAuthorized, message: "pair again") }
        }
        let router = WatchGatewayRouter(client: { throw PairingRequired() }, binding: InMemoryWatchBindingStore())
        let client = WatchGatewayClient(link: DirectWatchLink(router: router))
        await assertControlError(.notAuthorized) {
            _ = try await client.requestEnrollment(try WatchEnrollmentRequest.make(key: InMemoryDeviceKey(), label: "Apple Watch"))
        }
    }

    /// An upstream rejection is reinterpreted against the iPhone's session
    /// before it reaches the Watch.
    func testRouterAppliesTheIPhonesErrorRecovery() async throws {
        struct PairingRequired: ControlErrorConvertible {
            var controlError: ControlError { ControlError(code: .notAuthorized, message: "pair again") }
        }
        let router = WatchGatewayRouter(
            client: { throw ControlError(code: .invalidToken, message: "token expired") },
            binding: InMemoryWatchBindingStore(),
            recover: { error in
                (error as? ControlError)?.code == .invalidToken ? PairingRequired() : error
            }
        )
        let client = WatchGatewayClient(link: DirectWatchLink(router: router))
        await assertControlError(.notAuthorized) {
            _ = try await client.requestEnrollment(try WatchEnrollmentRequest.make(key: InMemoryDeviceKey(), label: "Apple Watch"))
        }
    }

    // MARK: Push relay and durability

    func testApprovalQueuesARelayHintForARegisteredCapability() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        try await phone.client.registerPushCapability("capability.v1.test")
        let record = try await fixture.publishApproval()
        let relayed = await fixture.harness.store.drainRelayOutbox()
        XCTAssertEqual(relayed.map(\.requestID), [record.spec.requestID])
        XCTAssertEqual(relayed.first?.event, "approval.created")
        XCTAssertEqual(relayed.first?.capability, "capability.v1.test")
    }

    func testRestartPreservesPairedDevicesAndReviewerBindings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try FileBrokerPersistence(url: directory.appendingPathComponent("broker.json"))
        let fixture = GatewayFixture(persistence: persistence)
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let watch = try await fixture.enrollWatch(behind: phone)

        let clock = fixture.harness.clock
        let restored = BrokerStore(serviceIdentity: "test-broker", cursorSecret: Data(repeating: 7, count: 32), persistence: persistence, now: { clock.now })
        try await restored.restore()
        let principal = try await restored.authenticate(bearer: phone.session.accessToken)
        let status = try await restored.watchReviewer(principal: principal, watchID: watch.status.watchDeviceID)
        XCTAssertEqual(status.state, .active)
        XCTAssertEqual(status.gatewayDeviceID, phone.session.deviceID)
    }
}

extension DeviceSession {
    func principal(_ store: BrokerStore) async throws -> Principal {
        try await store.authenticateDevice(deviceID)
    }
}
