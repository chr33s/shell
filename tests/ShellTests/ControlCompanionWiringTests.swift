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

    // MARK: - Baked broker and phone-first setup

    func testThePhoneInfoPlistCarriesTheBrokerURLKey() {
        XCTAssertNotNil(
            Bundle.main.object(forInfoDictionaryKey: "SHELLControlBrokerURL"),
            "the iOS Info.plist must substitute SHELL_CONTROL_BROKER_URL so TestFlight can bake a host"
        )
        if let url = ControlCompanion.shared.resolvedBrokerURL {
            XCTAssertTrue(
                ControlBrokerAddress.isAcceptable(url),
                "a baked broker must be HTTPS or loopback HTTP, not the placeholder"
            )
        }
    }

    func testThePlaceholderBrokerLeavesTheCompanionInert() {
        XCTAssertNil(ControlBrokerAddress.url(from: "https://control.invalid"))
        XCTAssertEqual(ControlBrokerAddress.unconfiguredHost, "control.invalid")
    }

    func testChangingTheBakedBrokerURLClearsCredentials() async throws {
        let suiteName = "control-companion-wipe-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryCredentialStore()
        try credentials.storeSigningKey(InMemoryDeviceKey())
        try credentials.storeSession(
            DeviceSession(
                deviceID: .random(),
                accountID: .random(),
                accessToken: "access",
                accessTokenExpiresAt: ControlTimestamp(Date().addingTimeInterval(600)),
                refreshToken: "refresh",
                grants: DeviceGrant.watchDefault
            )
        )
        let old = try XCTUnwrap(URL(string: "https://old.example"))
        let new = try XCTUnwrap(URL(string: "https://control.example"))
        suite.set(old.absoluteString, forKey: ControlBrokerAddress.defaultsKey)

        let companion = ControlCompanion(credentials: credentials, defaults: suite, brokerURL: new)
        await companion.start()

        XCTAssertNil(try credentials.loadSession())
        XCTAssertEqual(companion.phase, .needsEnrollment)
        XCTAssertEqual(suite.string(forKey: ControlBrokerAddress.defaultsKey), new.absoluteString)
    }

    func testTheSameBrokerURLKeepsCredentials() async throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "control-companion-keep-\(UUID().uuidString)"))
        let credentials = InMemoryCredentialStore()
        try credentials.storeSigningKey(InMemoryDeviceKey())
        try credentials.storeSession(
            DeviceSession(
                deviceID: .random(),
                accountID: .random(),
                accessToken: "access",
                accessTokenExpiresAt: ControlTimestamp(Date().addingTimeInterval(600)),
                refreshToken: "refresh",
                grants: DeviceGrant.watchDefault
            )
        )
        let url = try XCTUnwrap(URL(string: "https://control.example"))
        suite.set(url.absoluteString, forKey: ControlBrokerAddress.defaultsKey)
        let companion = ControlCompanion(credentials: credentials, defaults: suite, brokerURL: url)
        await companion.start()
        XCTAssertNotNil(try credentials.loadSession())
        XCTAssertEqual(companion.phase, .ready)
    }

    func testSettingsExposesAControlSectionAndSafariConfirm() throws {
        let source = try controlSource()
        XCTAssertTrue(source.contains("case control"), "Settings must include the Control companion section")
        XCTAssertTrue(source.contains("SettingsControlSection"))
        XCTAssertTrue(source.contains("ControlPairingSupport.activate()"))
        XCTAssertTrue(source.contains("npx @chr33s/shell"))
        XCTAssertTrue(source.contains("Scan QR"))
        XCTAssertTrue(source.contains("Waiting for confirmation on your Mac"))
        XCTAssertTrue(source.contains("shell-control"))
    }

    func testApplyPairedBrokerStoresARuntimeURLAndWipesOnChange() async throws {
        let suiteName = "control-companion-pair-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryCredentialStore()
        try credentials.storeSigningKey(InMemoryDeviceKey())
        try credentials.storeSession(
            DeviceSession(
                deviceID: .random(),
                accountID: .random(),
                accessToken: "access",
                accessTokenExpiresAt: ControlTimestamp(Date().addingTimeInterval(600)),
                refreshToken: "refresh",
                grants: DeviceGrant.watchDefault
            )
        )
        let first = try XCTUnwrap(URL(string: "https://old.example"))
        suite.set(first.absoluteString, forKey: ControlBrokerAddress.defaultsKey)
        let companion = ControlCompanion(credentials: credentials, defaults: suite, brokerURL: first)
        await companion.start()
        XCTAssertEqual(companion.phase, .ready)

        let next = try XCTUnwrap(URL(string: "https://random.trycloudflare.com"))
        let companion2 = ControlCompanion(credentials: credentials, defaults: suite, brokerURL: nil)
        let applied = await companion2.applyPairedBroker(next)
        XCTAssertTrue(applied)
        XCTAssertEqual(suite.string(forKey: ControlBrokerAddress.runtimeDefaultsKey), next.absoluteString)
        XCTAssertNil(try credentials.loadSession())
        XCTAssertEqual(companion2.phase, .needsEnrollment)
    }
}
