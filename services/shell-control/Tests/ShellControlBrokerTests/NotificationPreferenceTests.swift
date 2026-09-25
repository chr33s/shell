import Foundation
import XCTest
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient
@testable import ShellControlBroker

/// The per-device notification preference: an additive API that changes
/// delivery, never authorization (docs/specs/control-setup.md 7.3).
final class NotificationPreferenceTests: XCTestCase {
    private func raw(_ fixture: GatewayFixture, _ method: String, token: String?, body: Data?) async throws -> ControlHTTPResponse {
        var headers = ["Content-Type": "application/json"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        return try await fixture.transport.send(ControlHTTPRequest(
            method: method, path: NotificationPreference.path, headers: headers, body: body
        ), baseURL: fixture.route.url)
    }

    func testAnAbsentPreferenceIsVersionZeroWithItsLegacyValue() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let preference = try await phone.client.notificationPreference()
        XCTAssertEqual(preference, NotificationPreference(enabled: true, version: 0))
        let capabilities = try await phone.client.capabilities()
        XCTAssertTrue(capabilities.requiredFeatures.contains(ControlFeature.notificationPreference))
    }

    func testOffRemovesDeliveryMaterialAndSuppressesRelayAndDirectSends() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        try await phone.client.registerPushCapability("capability.v1.phone")
        let principal = try await phone.session.principal(fixture.harness.store)
        try await fixture.harness.store.registerPush(
            principal: principal,
            registration: try PushRegistration(token: String(repeating: "ab", count: 32), platform: .iOS, environment: .production, topic: "dev.chr33s.shell"),
            allowedTopics: ["dev.chr33s.shell"]
        )

        let off = try await phone.client.setNotificationPreference(.init(enabled: false, expectedVersion: 0))
        XCTAssertEqual(off, NotificationPreference(enabled: false, version: 1))

        _ = try await fixture.publishApproval()
        let relayed = await fixture.harness.store.drainRelayOutbox()
        let direct = await fixture.harness.store.drainOutbox()
        XCTAssertTrue(relayed.isEmpty, "no relay send to a suppressed reviewer")
        XCTAssertTrue(direct.isEmpty, "no direct-APNs send to a suppressed reviewer")

        // Registration never implicitly re-enables an explicit off.
        do {
            try await phone.client.registerPushCapability("capability.v1.late")
            XCTFail("a late registration must not restore delivery")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .notAuthorized)
        }
        let after = try await phone.client.notificationPreference()
        XCTAssertEqual(after, off)
        let summary = await fixture.harness.store.deviceSummary()
        let row = summary["devices"]?.arrayValue?.first { $0["device_id"]?.stringValue == phone.session.deviceID.rawValue }
        XCTAssertEqual(row?["push"]?.boolValue, false, "stored delivery material was removed")
        XCTAssertEqual(row?["alerts_enabled"]?.boolValue, false)
    }

    func testTurningAlertsOffNeverChangesReviewerAuthority() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        _ = try await phone.client.setNotificationPreference(.init(enabled: false, expectedVersion: 0))
        let record = try await fixture.publishApproval()
        let snapshot = try await phone.client.snapshot()
        XCTAssertTrue(snapshot.approvals.contains { $0.spec.requestID == record.spec.requestID }, "review still works with alerts off")
    }

    func testAStaleWriteIsAConflictAndCannotUndoALaterChoice() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        _ = try await phone.client.setNotificationPreference(.init(enabled: true, expectedVersion: 0))
        _ = try await phone.client.setNotificationPreference(.init(enabled: false, expectedVersion: 1))
        // A delayed enable written against version 1 arrives last.
        let response = try await raw(fixture, "PUT", token: phone.session.accessToken,
                                     body: try JSONCanonicalization.canonicalize(NotificationPreferenceUpdate(enabled: true, expectedVersion: 1).json))
        XCTAssertEqual(response.status, 409)
        let error = try ControlError(json: try JSONValue.parse(response.body))
        XCTAssertEqual(error.code, .idempotencyConflict)
        let current = try await phone.client.notificationPreference()
        XCTAssertEqual(current, NotificationPreference(enabled: false, version: 2))
        // Repeating an off at the current version is accepted and stays off.
        let again = try await phone.client.setNotificationPreference(.init(enabled: false, expectedVersion: 2))
        XCTAssertEqual(again, NotificationPreference(enabled: false, version: 3))
    }

    func testDisablingOneIPhoneLeavesAnotherReviewersAlerts() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let first = try await fixture.pairPhone()
        let second = try await fixture.pairPhone()
        try await first.client.registerPushCapability("capability.v1.first")
        try await second.client.registerPushCapability("capability.v1.second")
        _ = try await first.client.setNotificationPreference(.init(enabled: false, expectedVersion: 0))
        _ = try await fixture.publishApproval()
        let relayed = await fixture.harness.store.drainRelayOutbox()
        XCTAssertEqual(relayed.map(\.capability), ["capability.v1.second"])
    }

    func testMalformedAndUnauthenticatedCallsAreRejected() async throws {
        let fixture = GatewayFixture()
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        let unknownField = try await raw(fixture, "PUT", token: phone.session.accessToken,
                                         body: Data(#"{"enabled":false,"expected_version":0,"device_id":"x"}"#.utf8))
        XCTAssertEqual(unknownField.status, 400)
        let wrongType = try await raw(fixture, "PUT", token: phone.session.accessToken,
                                      body: Data(#"{"enabled":"no","expected_version":0}"#.utf8))
        XCTAssertEqual(wrongType.status, 400)
        let unauthenticated = try await raw(fixture, "GET", token: nil, body: nil)
        XCTAssertEqual(unauthenticated.status, 401)
        let untouched = try await phone.client.notificationPreference()
        XCTAssertEqual(untouched.version, 0)
    }

    func testTheExplicitChoiceSurvivesARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = try FileBrokerPersistence(url: directory.appendingPathComponent("broker.json"))
        let fixture = GatewayFixture(persistence: persistence)
        try await fixture.harness.bootstrap()
        let phone = try await fixture.pairPhone()
        _ = try await phone.client.setNotificationPreference(.init(enabled: false, expectedVersion: 0))

        let clock = fixture.harness.clock
        let restored = BrokerStore(serviceIdentity: "test-broker", cursorSecret: Data(repeating: 7, count: 32), persistence: persistence, now: { clock.now })
        try await restored.restore()
        let principal = try await restored.authenticate(bearer: phone.session.accessToken)
        let preference = try await restored.notificationPreference(principal: principal)
        XCTAssertEqual(preference, NotificationPreference(enabled: false, version: 1))
    }
}
