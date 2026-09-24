//
//  ControlCompanionWiringTests.swift
//  ShellTests
//
//  The phone side of the control companion (spec.watch.md section 2).
//
//  The protocol itself is tested in `Packages/ShellControlCore`; these cover
//  the two integration points that live in this app: notification-response
//  routing, and the rule that terminal OSC output can only ever produce an
//  informational alert.
//

import UserNotifications
import XCTest
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@testable import Shell

final class ControlCompanionWiringTests: XCTestCase {

    // MARK: - Notification responses select an intent, never a decision

    func testReviewActionYieldsAReviewIntentCarryingOnlyTheRequestID() throws {
        let requestID = try XCTUnwrap(ControlID("10000000-0000-4000-8000-000000000001"))
        let intent = ControlNotifications.intent(
            actionIdentifier: PushCategory.Action.review.rawValue,
            userInfo: ["request_id": requestID.rawValue, "event_id": "ignored"]
        )
        XCTAssertEqual(intent, .review(requestID: requestID))
    }

    /// The Approve shortcut is an *intent*: the app still fetches and reviews
    /// the request before submitting anything.
    func testApproveActionYieldsAProposalNotAnApproval() throws {
        let requestID = try XCTUnwrap(ControlID("10000000-0000-4000-8000-000000000001"))
        let intent = ControlNotifications.intent(
            actionIdentifier: PushCategory.Action.approve.rawValue,
            userInfo: ["request_id": requestID.rawValue]
        )
        XCTAssertEqual(intent, .proposeApprove(requestID: requestID))
    }

    /// Default dismissal or an unknown action opens review, never a decision.
    func testUnknownActionFallsBackToReview() throws {
        let requestID = try XCTUnwrap(ControlID("10000000-0000-4000-8000-000000000001"))
        XCTAssertEqual(
            ControlNotifications.intent(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: ["request_id": requestID.rawValue]),
            .review(requestID: requestID)
        )
    }

    func testAPayloadWithoutARequestIDProducesNoIntent() {
        XCTAssertNil(ControlNotifications.intent(actionIdentifier: PushCategory.Action.approve.rawValue, userInfo: [:]))
        // A non-canonical identifier is not accepted either.
        XCTAssertNil(ControlNotifications.intent(
            actionIdentifier: PushCategory.Action.review.rawValue,
            userInfo: ["request_id": "surface-0x600001234"]
        ))
    }

    // MARK: - Category shape

    func testApprovalCategoryPutsForegroundReviewFirst() async throws {
        let center = UNUserNotificationCenter.current()
        ControlNotifications.registerCategories(on: center)
        let categories = await center.notificationCategories()
        let approval = try XCTUnwrap(categories.first { $0.identifier == PushCategory.approval })
        // Apple invokes the first nondestructive action for Double Tap, so
        // Review must be first and must be a foreground action.
        let first = try XCTUnwrap(approval.actions.first)
        XCTAssertEqual(first.identifier, PushCategory.Action.review.rawValue)
        XCTAssertTrue(first.options.contains(.foreground))
        for action in approval.actions {
            XCTAssertTrue(
                action.options.contains(.foreground),
                "\(action.identifier) must be foreground so review happens on the device where it was selected"
            )
        }
        XCTAssertTrue(categories.contains { $0.identifier == PushCategory.informational })
    }

    // MARK: - Terminal OSC output is informational only

    /// A local alert built from OSC 9 / OSC 777 text carries no request
    /// identity, so nothing in the app can turn it into a review or a
    /// decision.
    func testTerminalAlertsCarryNoRequestIdentity() throws {
        let source = try controlSource()
        let function = try XCTUnwrap(
            source.range(of: "static func postLocalTerminalAlert").map { String(source[$0.lowerBound...].prefix(700)) }
        )
        XCTAssertTrue(function.contains("PushCategory.informational"))
        XCTAssertFalse(
            function.contains("request_id"),
            "A terminal-sourced alert must never carry a request id, which would make it actionable"
        )
    }

    /// The tripwire pair for the two call sites that live in an app delegate
    /// and a Ghostty callback, neither of which a unit test can drive.
    func testTripwireAppDelegateRegistersCategoriesAndTerminalRoutesOSCToAlerts() throws {
        try SourceTree.requireSources()
        let source = SourceTree.allAppSource()
        XCTAssertGreaterThan(source.count, 100_000)
        XCTAssertTrue(
            source.contains("ControlNotifications.registerCategories()"),
            "AppDelegate must register the control categories before any scene is constructed"
        )
        XCTAssertTrue(
            source.contains("ControlNotifications.postLocalTerminalAlert(title: title, body: body)"),
            "The Ghostty desktop-notification callback must route to an informational alert"
        )
    }

    private func controlSource() throws -> String {
        try SourceTree.requireSources()
        return SourceTree.allAppSource()
    }

    // MARK: - iPhone gateway profile: origin identity versus route

    /// The phone carries no broker URL: it pairs with its Mac from the setup
    /// QR. The relay is optional and the placeholder means "none".
    func testThePhoneCarriesNoBrokerURLAndTheRelayIsOptional() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SHELLControlBrokerURL"))
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "SHELLControlPushRelayURL"))
        #if DEBUG
        XCTAssertNil(ControlPushCapability.relayURL, "the placeholder relay must read as not configured")
        #endif
    }

    /// The relay is told the environment the signing profile grants, which a
    /// Release build signed for development does not share with its config.
    func testPushEnvironmentFollowsTheProvisioningProfile() {
        func profile(_ aps: String) -> Data {
            var data = Data([0x30, 0x80, 0x06, 0x09])
            data.append(Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Entitlements</key><dict><key>aps-environment</key><string>\#(aps)</string></dict></dict></plist>"#.utf8))
            data.append(Data([0x00, 0xA0, 0x82]))
            return data
        }
        XCTAssertEqual(ControlPushCapability.profileEnvironment(profile("development")), .development)
        XCTAssertEqual(ControlPushCapability.profileEnvironment(profile("production")), .production)
        XCTAssertNil(ControlPushCapability.profileEnvironment(Data([0x30, 0x80])))
    }

    func testScannedPayloadsAreClassifiedAsPairingOrRouteOnly() throws {
        let key = OriginSigningKey()
        let origin = OriginIdentity(originID: .random(), publicJWK: key.publicJWK)
        let invitation = try PairingInvitation(
            origin: origin, route: try OriginRoute("https://mac.example.ts.net"), pairingID: .random(),
            pairingSecret: Base64URL.encode(Data(repeating: 4, count: 32)), expiresAt: ControlTimestamp(Date().addingTimeInterval(600))
        )
        guard case .pairing = ControlScannedPayload(try invitation.link().absoluteString) else { return XCTFail("expected pairing") }
        let update = try OriginRouteUpdate.sign(originID: origin.originID, route: try OriginRoute("https://renamed.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: key)
        guard case .routeUpdate = ControlScannedPayload(try update.link().absoluteString) else { return XCTFail("expected route update") }
        XCTAssertNil(ControlScannedPayload("https://abc.trycloudflare.com"))
        XCTAssertTrue(ControlScannedPayload.isControlLink(try invitation.link()))
        XCTAssertTrue(ControlScannedPayload.isControlLink(try update.link()))
    }

    /// A setup QR or link is only staged: nothing is contacted or trusted
    /// until the user confirms, and a different Mac key is flagged.
    func testAScannedInvitationWaitsForExplicitConfirmation() async throws {
        let key = OriginSigningKey()
        let origins = InMemoryPinnedOriginStore(try pinned(key))
        var stub = OriginStub(key: key)
        stub.unreachable = true
        let companion = ControlCompanion(credentials: try enrolledCredentials(), origins: origins, transport: stub)
        await companion.start()
        let other = OriginSigningKey()
        let invitation = try PairingInvitation(
            origin: OriginIdentity(originID: .random(), publicJWK: other.publicJWK),
            route: try OriginRoute("https://evil.example.ts.net"), pairingID: .random(),
            pairingSecret: Base64URL.encode(Data(repeating: 5, count: 32)), expiresAt: ControlTimestamp(Date().addingTimeInterval(600))
        )
        let staged = await companion.handleScanned(try invitation.link().absoluteString, fromLink: true)
        XCTAssertTrue(staged)
        XCTAssertEqual(companion.pendingPairing?.assessment, .differentOrigin)
        XCTAssertEqual(companion.pendingPairing?.fromLink, true)
        XCTAssertFalse(companion.isPairing)
        XCTAssertEqual(try origins.load()?.origin.publicJWK, key.publicJWK, "the trusted Mac is untouched")
        companion.cancelPendingPairing()
        XCTAssertNil(companion.pendingPairing)
    }

    func testWithoutAPinnedOriginTheCompanionIsNotConfigured() async throws {
        let companion = ControlCompanion(credentials: InMemoryCredentialStore(), origins: InMemoryPinnedOriginStore(), transport: OriginStub(key: OriginSigningKey()))
        await companion.start()
        XCTAssertEqual(companion.phase, .notConfigured)
    }

    func testAPinnedOriginWithoutASessionNeedsPairing() async throws {
        let key = OriginSigningKey()
        let companion = ControlCompanion(
            credentials: InMemoryCredentialStore(),
            origins: InMemoryPinnedOriginStore(try pinned(key)),
            transport: OriginStub(key: key)
        )
        await companion.start()
        XCTAssertEqual(companion.phase, .needsEnrollment)
    }

    /// A route change signed by the pinned key moves routing only: the
    /// session, key, and pin all survive (spec.iphone-gateway.md 7.3, 24).
    func testSignedRouteUpdateKeepsShellCredentials() async throws {
        let key = OriginSigningKey()
        let credentials = try enrolledCredentials()
        let origins = InMemoryPinnedOriginStore(try pinned(key))
        let companion = ControlCompanion(credentials: credentials, origins: origins, transport: OriginStub(key: key))
        await companion.start()
        XCTAssertEqual(companion.phase, .ready)

        let originID = try XCTUnwrap(try origins.load()).origin.originID
        let update = try OriginRouteUpdate.sign(originID: originID, route: try OriginRoute("https://renamed.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: key)
        let applied = await companion.applyRouteUpdate(update)
        XCTAssertTrue(applied)
        XCTAssertEqual(try origins.load()?.routes.first?.url.host, "renamed.example.ts.net")
        XCTAssertNotNil(try credentials.loadSession())
        XCTAssertEqual(companion.phase, .ready)
    }

    func testRouteUpdateFromAnotherKeyIsRejected() async throws {
        let key = OriginSigningKey()
        let credentials = try enrolledCredentials()
        let origins = InMemoryPinnedOriginStore(try pinned(key))
        let companion = ControlCompanion(credentials: credentials, origins: origins, transport: OriginStub(key: key))
        await companion.start()
        let originID = try XCTUnwrap(try origins.load()).origin.originID
        let forged = try OriginRouteUpdate.sign(originID: originID, route: try OriginRoute("https://evil.example.ts.net"), issuedAt: ControlTimestamp(Date()), key: OriginSigningKey())
        let applied = await companion.applyRouteUpdate(forged)
        XCTAssertFalse(applied)
        XCTAssertEqual(try origins.load()?.routes.first?.url.host, "mac.example.ts.net")
        XCTAssertNotNil(try credentials.loadSession())
    }

    /// Tailscale being off is a connectivity state, never a reason to drop
    /// Shell enrollment (spec.iphone-gateway.md section 28).
    func testUnreachableRouteKeepsCredentials() async throws {
        let key = OriginSigningKey()
        let credentials = try enrolledCredentials()
        let origins = InMemoryPinnedOriginStore(try pinned(key))
        var stub = OriginStub(key: key)
        stub.unreachable = true
        let companion = ControlCompanion(credentials: credentials, origins: origins, transport: stub)
        await companion.start()
        XCTAssertEqual(companion.phase, .ready)
        guard case .unavailable = companion.routeState else { return XCTFail("expected an unavailable route, got \(companion.routeState)") }
        XCTAssertNotNil(try credentials.loadSession())
        XCTAssertNotNil(try origins.load())
    }

    /// A refresh spends the old refresh token on the Mac. If the Keychain
    /// refuses the renewed session (the phone is locked), it is kept and used
    /// in memory, and saved once the Keychain accepts it — never lost.
    func testARefreshedSessionTheKeychainRefusesIsKeptAndSavedLater() async throws {
        let key = OriginSigningKey()
        let stale = DeviceSession(
            deviceID: .random(), accountID: .random(), accessToken: "old",
            accessTokenExpiresAt: ControlTimestamp(Date().addingTimeInterval(-60)),
            refreshToken: "refresh-1", grants: DeviceGrant.watchDefault
        )
        let renewed = DeviceSession(
            deviceID: stale.deviceID, accountID: stale.accountID, accessToken: "new",
            accessTokenExpiresAt: ControlTimestamp(Date().addingTimeInterval(600)),
            refreshToken: "refresh-2", grants: stale.grants
        )
        let credentials = LockableCredentialStore()
        try credentials.storeSession(stale)
        credentials.locked = true
        var stub = OriginStub(key: key)
        stub.refreshed = renewed
        let gateway = ControlGatewaySession(credentials: credentials, origins: InMemoryPinnedOriginStore(try pinned(key)), transport: stub)

        _ = try await gateway.authenticatedClient()
        let inMemory = await gateway.deviceSession
        XCTAssertEqual(inMemory?.refreshToken, "refresh-2")
        _ = try await gateway.authenticatedClient()
        XCTAssertEqual(stub.refreshes.count, 1, "the renewed session is reused, not refreshed again")

        credentials.locked = false
        _ = try await gateway.authenticatedClient()
        XCTAssertEqual(try credentials.loadSession()?.refreshToken, "refresh-2")
    }

    /// A refresh (every pull, every approval hint) fetches the whole
    /// approval history only once; after that it asks for the changes since
    /// the last cursor.
    func testRefreshAfterTheFirstFetchesOnlyChanges() async throws {
        let key = OriginSigningKey()
        let stub = OriginStub(key: key)
        let companion = ControlCompanion(
            credentials: try enrolledCredentials(),
            origins: InMemoryPinnedOriginStore(try pinned(key)),
            transport: stub,
            journalStore: { InMemoryCommandJournal() }
        )
        await companion.start()
        XCTAssertEqual(companion.phase, .ready)
        let refreshed = await companion.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(stub.paths.count(of: "/v1/snapshot"), 1)
        XCTAssertEqual(stub.paths.count(of: "/v1/changes"), 1)
    }

    /// Signed decisions whose outcome is unknown survive a relaunch: the
    /// phone's journal is file-backed like the Watch's, not in memory.
    func testThePhonesCommandJournalPersistsAcrossRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = PendingCommand(
            commandID: .random(),
            signedCommand: "header.payload.signature",
            type: .approvalDecide,
            targetID: .random(),
            notAfter: ControlTimestamp(Date().addingTimeInterval(60)),
            status: .outcomeUnknown
        )
        try await CommandJournal(store: try FileCommandJournalStore(directory: directory)).record(command)

        let relaunched = CommandJournal(store: try FileCommandJournalStore(directory: directory))
        let pending = await relaunched.pending
        XCTAssertEqual(pending.map(\.commandID), [command.commandID])
        XCTAssertEqual(pending.first?.status, .outcomeUnknown)
    }

    /// An unreadable journal is an error, never an empty journal whose next
    /// save would overwrite the entries it could not read.
    func testAnUnreadableJournalThrowsRatherThanReadingEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileCommandJournalStore(directory: directory)
        XCTAssertEqual(try store.load().count, 0, "a missing file is an empty journal")
        // A directory where the file should be cannot be read as one.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("control-commands.json"), withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try store.load())
    }

    func testSettingsExposesAControlSectionAndGatewayPairing() throws {
        let source = try controlSource()
        XCTAssertTrue(source.contains("case control"), "Settings must include the Control companion section")
        XCTAssertTrue(source.contains("SettingsControlSection"))
        XCTAssertTrue(source.contains("ControlPairingSupport.activate()"))
        XCTAssertTrue(source.contains("shell-control setup"))
        XCTAssertTrue(source.contains("Scan QR"))
        XCTAssertTrue(source.contains("didReceiveMessageData"), "the Watch gateway answers interactive messages")
    }

    // MARK: - Control companion setup (spec.control-companion-setup.md)

    /// A pairing without a recorded alert choice starts with remote alerts
    /// off, and nothing registers with a relay or the Mac.
    func testRemoteAlertsDefaultOffAndNothingRegisters() async throws {
        let key = OriginSigningKey()
        let stub = OriginStub(key: key)
        let companion = ControlCompanion(credentials: try enrolledCredentials(), origins: InMemoryPinnedOriginStore(try pinned(key)),
                                         transport: stub, journalStore: { InMemoryCommandJournal() },
                                         alertStore: InMemoryRemoteAlertPolicyStore())
        await companion.start()
        XCTAssertEqual(companion.alertPolicy?.choice, .off)
        XCTAssertEqual(companion.alertPolicy?.displayState, .off)
        XCTAssertEqual(stub.paths.count(of: "/v1/devices/me/push-capability"), 0)
    }

    /// An older Mac without the preference API is never reported as having
    /// stopped alerts.
    func testDisablingAlertsOnAnOlderMacNeedsAHostUpdate() async throws {
        let key = OriginSigningKey()
        let credentials = try enrolledCredentials()
        let store = InMemoryRemoteAlertPolicyStore()
        let deviceID = try XCTUnwrap(try credentials.loadSession()).deviceID.rawValue
        store.save(.migrated(priorUseEstablished: true, relayAvailable: true), originID: OriginStub.originID(for: key).rawValue, deviceID: deviceID)
        let stub = OriginStub(key: key)
        let companion = ControlCompanion(credentials: credentials, origins: InMemoryPinnedOriginStore(try pinned(key)),
                                         transport: stub, journalStore: { InMemoryCommandJournal() }, alertStore: store)
        await companion.start()
        XCTAssertEqual(companion.alertPolicy?.displayState, .configured)
        await companion.setRemoteAlerts(.off)
        XCTAssertEqual(companion.alertPolicy?.displayState, .disableNeedsHostUpdate)
        XCTAssertGreaterThan(stub.paths.count(of: NotificationPreference.path), 0)
    }

    /// With the Mac unreachable, local registration stops at once and the
    /// Mac's side shows as pending — not as done.
    func testDisablingAlertsWhileTheMacIsOfflineIsPending() async throws {
        let key = OriginSigningKey()
        let credentials = try enrolledCredentials()
        let store = InMemoryRemoteAlertPolicyStore()
        let deviceID = try XCTUnwrap(try credentials.loadSession()).deviceID.rawValue
        store.save(.migrated(priorUseEstablished: true, relayAvailable: true), originID: OriginStub.originID(for: key).rawValue, deviceID: deviceID)
        var stub = OriginStub(key: key)
        stub.unreachable = true
        let companion = ControlCompanion(credentials: credentials, origins: InMemoryPinnedOriginStore(try pinned(key)),
                                         transport: stub, journalStore: { InMemoryCommandJournal() }, alertStore: store)
        await companion.start()
        await companion.setRemoteAlerts(.off)
        XCTAssertEqual(companion.alertPolicy?.displayState, .disablePending)
        XCTAssertNil(companion.alertPolicy?.registration)
        XCTAssertNotNil(try credentials.loadSession(), "turning alerts off never touches pairing")
    }

    /// The iPhone reports its own vantage: route and identity it proved,
    /// Tailscale state it cannot see as unknown, and an optional Watch as
    /// not configured rather than broken.
    func testCheckConnectionReportsTheIPhonesOwnEvidence() async throws {
        let key = OriginSigningKey()
        let companion = ControlCompanion(credentials: try enrolledCredentials(), origins: InMemoryPinnedOriginStore(try pinned(key)),
                                         transport: OriginStub(key: key), journalStore: { InMemoryCommandJournal() },
                                         alertStore: InMemoryRemoteAlertPolicyStore())
        await companion.start()
        await companion.checkConnection()
        let report = try XCTUnwrap(companion.diagnostics)
        XCTAssertEqual(report.vantage, .iphone)
        XCTAssertEqual(report.readiness(for: .iphoneReview), .pass)
        XCTAssertEqual(report.check("origin_identity")?.code, .originVerified)
        XCTAssertEqual(report.check("tailscale_iphone")?.state, .unknown)
        XCTAssertNotEqual(report.check("watch")?.state, .fail)
        XCTAssertEqual(report.check("remote_alerts")?.code, .alertsDisabledByUser)
        let export = String(decoding: try XCTUnwrap(companion.diagnosticExport()), as: UTF8.self)
        XCTAssertFalse(export.contains("mac.example.ts.net"), "tailnet names are redacted")
        XCTAssertTrue(export.contains("origin_verified"))
    }

    func testCheckConnectionWithTheMacUnreachableKeepsCredentials() async throws {
        let key = OriginSigningKey()
        let credentials = try enrolledCredentials()
        var stub = OriginStub(key: key)
        stub.unreachable = true
        let companion = ControlCompanion(credentials: credentials, origins: InMemoryPinnedOriginStore(try pinned(key)),
                                         transport: stub, journalStore: { InMemoryCommandJournal() },
                                         alertStore: InMemoryRemoteAlertPolicyStore())
        await companion.start()
        await companion.checkConnection()
        let report = try XCTUnwrap(companion.diagnostics)
        XCTAssertEqual(report.check("mac_route")?.state, .fail)
        XCTAssertEqual(report.check("origin_identity")?.state, .unknown, "not reached is not a mismatch")
        XCTAssertEqual(companion.phase, .ready)
        XCTAssertNotNil(try credentials.loadSession())
    }

    /// Signing out asks the Mac to stop alerts first; when it cannot
    /// confirm (here an older Mac), the user is told how to stop them.
    func testSignOutTurnsAlertsOffAtTheMacOrSaysHow() async throws {
        let key = OriginSigningKey()
        let credentials = try enrolledCredentials()
        let store = InMemoryRemoteAlertPolicyStore()
        let deviceID = try XCTUnwrap(try credentials.loadSession()).deviceID.rawValue
        store.save(.migrated(priorUseEstablished: true, relayAvailable: true), originID: OriginStub.originID(for: key).rawValue, deviceID: deviceID)
        let stub = OriginStub(key: key)
        let companion = ControlCompanion(credentials: credentials, origins: InMemoryPinnedOriginStore(try pinned(key)),
                                         transport: stub, journalStore: { InMemoryCommandJournal() }, alertStore: store)
        await companion.start()
        await companion.signOut()
        XCTAssertGreaterThan(stub.paths.count(of: NotificationPreference.path), 0, "the Mac was asked before credentials went")
        XCTAssertTrue(companion.statusMessage?.contains("shell-control revoke \(deviceID)") ?? false, companion.statusMessage ?? "nil")
        XCTAssertNil(try credentials.loadSession())
    }

    func testControlSettingsOfferGuidedSetupAndSeparateRecovery() throws {
        let source = try controlSource()
        XCTAssertTrue(source.contains("Set up Control"))
        XCTAssertTrue(source.contains("shell-control setup --guided"))
        XCTAssertTrue(source.contains("ControlRecoveryView"))
        XCTAssertTrue(source.contains("Export diagnostics"))
        XCTAssertTrue(source.contains("Remote alerts are off. Open Control and refresh to check for requests."))
    }

    // MARK: Helpers

    private func pinned(_ key: OriginSigningKey) throws -> PinnedOrigin {
        PinnedOrigin(
            origin: OriginIdentity(originID: OriginStub.originID(for: key), publicJWK: key.publicJWK),
            routes: [try OriginRoute("https://mac.example.ts.net")],
            pairedAt: ControlTimestamp(Date())
        )
    }

    private func enrolledCredentials() throws -> InMemoryCredentialStore {
        let credentials = InMemoryCredentialStore()
        try credentials.storeSigningKey(InMemoryDeviceKey())
        try credentials.storeSession(DeviceSession(
            deviceID: .random(),
            accountID: .random(),
            accessToken: "access",
            accessTokenExpiresAt: ControlTimestamp(Date().addingTimeInterval(600)),
            refreshToken: "refresh",
            grants: DeviceGrant.watchDefault
        ))
        return credentials
    }
}

/// A Mac that proves `key` on every host and serves an empty inbox.
private struct OriginStub: ControlHTTPTransport {
    let key: OriginSigningKey
    var unreachable = false
    /// The session `/v1/oauth/token` hands back.
    var refreshed: DeviceSession?
    let refreshes = RefreshCounter()
    let paths = PathLog()

    func send(_ request: ControlHTTPRequest, baseURL: URL) async throws -> ControlHTTPResponse {
        if unreachable { throw TailnetUnavailable(reason: "Tailscale is off") }
        paths.record(request.path)
        func json(_ value: JSONValue) throws -> ControlHTTPResponse {
            ControlHTTPResponse(status: 200, body: try JSONCanonicalization.canonicalize(value))
        }
        switch request.path {
        case "/v1/origin/proof":
            // Each test key stands for exactly one origin ID.
            let nonce = request.query.first { $0.0 == "nonce" }?.1 ?? ""
            return try json(try OriginProof.sign(originID: OriginStub.originID(for: key), nonce: nonce, issuedAt: ControlTimestamp(Date()), key: key).document)
        case "/v1/oauth/token":
            guard let refreshed else { break }
            refreshes.increment()
            return try json(refreshed.json)
        case "/v1/snapshot":
            return try json(SnapshotPage(approvals: [], notifications: [], snapshotToken: "s1.1.t", nextPageToken: nil,
                                         cursor: ChangeCursor("c1.1.t"), serverTime: ControlTimestamp(Date())).json)
        case "/v1/changes":
            return try json(ChangePage(events: [], cursor: ChangeCursor("c1.2.t"), serverTime: ControlTimestamp(Date())).json)
        default:
            return ControlHTTPResponse(status: 404, body: try JSONCanonicalization.canonicalize(ControlError(code: .notFound, message: "no such endpoint").json))
        }
        return ControlHTTPResponse(status: 404, body: try JSONCanonicalization.canonicalize(ControlError(code: .notFound, message: "no such endpoint").json))
    }

    private static let registry = OriginRegistry()
    static func originID(for key: OriginSigningKey) -> ControlID { registry.id(for: key) }
}

private final class OriginRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String: ControlID] = [:]
    func id(for key: OriginSigningKey) -> ControlID {
        lock.withLock {
            let thumbprint = (try? key.publicJWK.thumbprint()) ?? ""
            if let id = ids[thumbprint] { return id }
            let id = ControlID.random()
            ids[thumbprint] = id
            return id
        }
    }
}

nonisolated final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func record(_ path: String) { lock.withLock { paths.append(path) } }
    func count(of path: String) -> Int { lock.withLock { paths.filter { $0 == path }.count } }
}

nonisolated final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

/// Credentials whose session writes fail while `locked`, the way a
/// `WhenUnlocked` Keychain item refuses writes on a locked phone.
private final class LockableCredentialStore: DeviceCredentialStore, @unchecked Sendable {
    private let inner = InMemoryCredentialStore()
    private let lock = NSLock()
    private var isLocked = false
    var locked: Bool {
        get { lock.withLock { isLocked } }
        set { lock.withLock { isLocked = newValue } }
    }
    struct Locked: Error {}

    func loadSigningKey() throws -> (any DeviceSigningKey)? { try inner.loadSigningKey() }
    func storeSigningKey(_ key: InMemoryDeviceKey) throws { try inner.storeSigningKey(key) }
    func loadSession() throws -> DeviceSession? { try inner.loadSession() }
    func storeSession(_ session: DeviceSession) throws {
        if locked { throw Locked() }
        try inner.storeSession(session)
    }
    func removeAll() throws { try inner.removeAll() }
}
