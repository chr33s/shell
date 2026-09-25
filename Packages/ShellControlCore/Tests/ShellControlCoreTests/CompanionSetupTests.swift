import XCTest
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlClient

/// Portable rules of Control companion setup: the diagnostic contract, its
/// redacted export, the fixed setup-test request, and the remote-alert policy
/// (docs/specs/control-setup.md).
final class CompanionSetupTests: XCTestCase {
    private let stamp = ControlTimestamp(Date(timeIntervalSince1970: 1_790_000_000))

    // MARK: Diagnostics

    func testReportRoundTripsTheSchema() throws {
        let report = DiagnosticReport(generatedAt: stamp, vantage: .iphone, checks: [
            DiagnosticCheck(id: "origin_identity", code: .originVerified, state: .pass,
                            requiredFor: [.iphoneReview, .watchReview], source: "authenticated_origin_proof",
                            observedAt: stamp, summary: "The Mac proved the pinned origin identity."),
            DiagnosticCheck(id: "remote_alerts", code: .alertsDisabledByUser, state: .disabled,
                            source: "local_preference_and_host_acknowledgement", observedAt: stamp,
                            summary: "Remote Control alerts are off.")
        ])
        let json = report.json
        XCTAssertEqual(json["schema"]?.stringValue, "shell-control-diagnostics/1")
        XCTAssertEqual(json["checks"]?.arrayValue?.first?["required_for"], JSONValue(strings: ["iphone_review", "watch_review"]))
        XCTAssertTrue(json["checks"]?.arrayValue?.last?["action"]?.isNull ?? false)
        XCTAssertEqual(try DiagnosticReport(json: json), report)
    }

    func testReadinessNeedsEveryRequiredCheckToPass() {
        func report(_ states: [DiagnosticState]) -> DiagnosticReport {
            DiagnosticReport(generatedAt: stamp, vantage: .mac, checks: states.enumerated().map { index, state in
                DiagnosticCheck(id: "c\(index)", code: .brokerReady, state: state, requiredFor: [.host],
                                source: "test", observedAt: stamp, summary: "")
            })
        }
        XCTAssertEqual(report([.pass, .pass]).readiness(for: .host), .pass)
        XCTAssertEqual(report([.pass, .unknown]).readiness(for: .host), .unknown, "missing evidence is never a pass")
        XCTAssertEqual(report([.unknown, .fail]).readiness(for: .host), .fail)
        XCTAssertEqual(report([.pass]).readiness(for: .watchReview), .unknown, "no evidence at all is unknown")
        // Optional features never gate host readiness.
        let optional = DiagnosticReport(generatedAt: stamp, vantage: .mac, checks: [
            DiagnosticCheck(id: "a", code: .brokerReady, state: .pass, requiredFor: [.host], source: "t", observedAt: stamp, summary: ""),
            DiagnosticCheck(id: "w", code: .watchNotConfigured, state: .notConfigured, source: "t", observedAt: stamp, summary: ""),
            DiagnosticCheck(id: "r", code: .alertsNotConfigured, state: .disabled, source: "t", observedAt: stamp, summary: "")
        ])
        XCTAssertTrue(optional.isReady(.host, at: stamp.date, maxAge: 30))
        XCTAssertFalse(optional.isReady(.host, at: stamp.date.addingTimeInterval(31), maxAge: 30), "stale evidence is not current")
    }

    func testDefaultSeverityFollowsStateAndRequirement() {
        let optionalFailure = DiagnosticCheck(id: "x", code: .notificationRegistrationFailed, state: .fail,
                                              source: "t", observedAt: nil, summary: "")
        XCTAssertEqual(optionalFailure.severity, .warning, "an optional failure never reads as a broken setup")
        let skipped = DiagnosticCheck(id: "w", code: .watchNotConfigured, state: .notConfigured, source: "t", observedAt: nil, summary: "")
        XCTAssertEqual(skipped.severity, .info)
        XCTAssertFalse(skipped.isFresh(at: Date()), "no observation is never fresh")
    }

    func testEveryMacActionIsFixedText() {
        for action in DiagnosticAction.allCases {
            if let command = action.macCommand { XCTAssertFalse(command.isEmpty) }
        }
    }

    // MARK: Export redaction

    func testExportRedactsSecretsContentAndNames() throws {
        let deviceID = "0b0e5d2a-1c3d-4e5f-8a9b-0c1d2e3f4a5b"
        let secrets = [
            "shell-control://pair?invite=eyJvcmlnaW4iOiJ4In0.c2VjcmV0cGFpcmluZw",
            "Bearer abcDEF1234567890abcdefGHIJ",
            "Admin 9f8e7d6c5b4a39281706f5e4d3c2b1a0",
            "https://macbook.example-tailnet.ts.net/v1/snapshot",
            "macbook.example-tailnet.ts.net",
            "/Users/alice/Library/Keys/origin-signing-key.pem",
            "alice@example.com",
            "capability.v1.QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo0NTY3ODk",
            "ABCD-EF12",
            "SHA256:q1w2e3r4t5y6u7i8o9p0",
            "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg\n-----END PRIVATE KEY-----"
        ]
        let summary = "device \(deviceID) failed: " + secrets.joined(separator: " | ")
        let report = DiagnosticReport(generatedAt: stamp, vantage: .iphone, checks: [
            DiagnosticCheck(id: "route", code: .routeUnreachable, state: .fail, requiredFor: [.iphoneReview],
                            source: "authenticated_route_check", observedAt: stamp, summary: summary),
            DiagnosticCheck(id: "watch", code: .watchReady, state: .pass, source: "watch_gateway_round_trip",
                            observedAt: stamp, summary: "Watch \(deviceID) answered")
        ])
        let data = try DiagnosticExport.data(reports: [report], applicationVersion: "1.0 (42)", osVersion: "iOS 26.0")
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["eyJvcmlnaW4", "abcDEF1234567890", "9f8e7d6c5b4a", "example-tailnet", "alice",
                       "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo0NTY3ODk", "ABCD-EF12", "q1w2e3r4t5y6", "MIGHAgEA", deviceID] {
            XCTAssertFalse(text.contains(secret), "export leaked \(secret)")
        }
        // Codes survive and identifiers are pseudonymised consistently.
        XCTAssertTrue(text.contains("route_unreachable"))
        XCTAssertEqual(text.components(separatedBy: "id-1").count - 1, 2, "one device, one pseudonym, in both rows")
        let parsed = try JSONValue.parse(data)
        XCTAssertEqual(parsed["schema"]?.stringValue, DiagnosticExport.schema)
        XCTAssertNil(parsed["reports"]?.arrayValue?.first?["checks"]?.arrayValue?.first?["source"], "only allowlisted fields")
    }

    func testExportRedactsPathsUnderAnyRoot() {
        let redactor = DiagnosticRedactor()
        for path in ["/var/folders/xy/T/shell-state/installation.json", "/Volumes/Work/state/broker.json",
                     "/opt/shell/state", "/Users/alice/Library/Application Support/x", "/private/var/folders/ab/C/y"] {
            let text = redactor.redact("installation unreadable: \(path) is malformed")
            XCTAssertFalse(text.contains(path.split(separator: "/").dropFirst().first.map(String.init) ?? "?"), text)
            XCTAssertTrue(text.contains("<path>"), text)
        }
        XCTAssertEqual(redactor.redact("route_unreachable 127.0.0.1:8443"), "route_unreachable 127.0.0.1:8443")
    }

    func testSetupFixtureKindsAreDistinguished() throws {
        func spec(_ review: MinimumReview) throws -> ApprovalSpec {
            try ApprovalSpec(requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
                             createdAt: stamp, expiresAt: stamp.adding(60), summary: SetupTestFixture.summary,
                             operation: .exec(SetupTestFixture.operation), minimumReview: review, requiredFeatures: [])
        }
        XCTAssertTrue(SetupTestFixture.isIPhoneTest(try spec(.full)))
        XCTAssertFalse(SetupTestFixture.isWatchTest(try spec(.full)))
        XCTAssertTrue(SetupTestFixture.isWatchTest(try spec(.watch)))
    }

    func testRemoveAllForgetsOnlyThatOrigin() {
        let store = InMemoryRemoteAlertPolicyStore()
        store.save(.freshDefault, originID: "a", deviceID: "1")
        store.save(.freshDefault, originID: "a", deviceID: "2")
        store.save(.freshDefault, originID: "b", deviceID: "1")
        store.removeAll(originID: "a")
        XCTAssertNil(store.load(originID: "a", deviceID: "1"))
        XCTAssertNil(store.load(originID: "a", deviceID: "2"))
        XCTAssertNotNil(store.load(originID: "b", deviceID: "1"))
    }

    // MARK: Setup-test fixture

    func testSetupFixtureIsFixedAndRecognised() throws {
        let body = SetupTestFixture.requestBody(forWatch: false)
        XCTAssertEqual(body["summary"]?.stringValue, "Setup test — no operation will be executed")
        XCTAssertEqual(body["minimum_review"]?.stringValue, "full")
        XCTAssertEqual(SetupTestFixture.requestBody(forWatch: true)["minimum_review"]?.stringValue, "watch")
        XCTAssertEqual(try ExecOperation(json: try XCTUnwrap(body["operation"])), SetupTestFixture.operation)
        XCTAssertLessThanOrEqual(SetupTestFixture.lifetimeSeconds, Int64(ApprovalPolicy.maximumLifetime))

        func spec(summary: String, argv: [String]) throws -> ApprovalSpec {
            try ApprovalSpec(
                requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
                createdAt: stamp, expiresAt: stamp.adding(60), summary: summary,
                operation: .exec(try ExecOperation(argv: argv, cwd: "/", contextSHA256: SetupTestFixture.contextSHA256)),
                minimumReview: .full, requiredFeatures: []
            )
        }
        XCTAssertTrue(SetupTestFixture.matches(try spec(summary: SetupTestFixture.summary, argv: SetupTestFixture.argv)))
        XCTAssertFalse(SetupTestFixture.matches(try spec(summary: SetupTestFixture.summary, argv: ["/bin/rm", "-rf", "/"])),
                       "a reassuring label on another operation is not the fixture")
    }

    // MARK: Notification preference wire format

    func testPreferenceDocumentsRejectUnknownFieldsAndBadTypes() throws {
        XCTAssertEqual(try NotificationPreference(json: .object(["enabled": true, "version": 1])), NotificationPreference(enabled: true, version: 1))
        XCTAssertThrowsError(try NotificationPreferenceUpdate(json: .object(["enabled": false, "expected_version": 1, "extra": true])))
        XCTAssertThrowsError(try NotificationPreferenceUpdate(json: .object(["enabled": "false", "expected_version": 1])))
        XCTAssertThrowsError(try NotificationPreferenceUpdate(json: .object(["enabled": false, "expected_version": -1])))
    }

    // MARK: Remote-alert policy

    func testFreshSetupDefaultsOffAndNeverRegisters() async {
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(), initial: .freshDefault)
        let policy = await coordinator.policy
        XCTAssertEqual(policy.choice, .off)
        let begun = await coordinator.beginRegistration()
        XCTAssertNil(begun, "off means no relay registration, whatever the build carries")
    }

    func testDisablingWhileTheMacIsOfflineIsPendingThenAcknowledged() async {
        let service = FakePreferenceService(NotificationPreference(enabled: true, version: 0))
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .migrated(priorUseEstablished: true, relayAvailable: true))
        await service.setOffline(true)
        await coordinator.choose(.off)
        var policy = await coordinator.reconcile(with: service)
        XCTAssertEqual(policy.displayState, .disablePending, "local work stops; host suppression is pending")
        XCTAssertNil(policy.registration)

        await service.setOffline(false)
        policy = await coordinator.reconcile(with: service)
        XCTAssertEqual(policy.displayState, .off)
        let remote = await service.current
        XCTAssertEqual(remote, NotificationPreference(enabled: false, version: 1))
        // Reconnecting again is idempotent.
        _ = await coordinator.reconcile(with: service)
        let writes = await service.writes
        XCTAssertEqual(writes, 1)
    }

    func testALateRegistrationCannotRestoreDeliveryAfterOff() async {
        let service = FakePreferenceService(NotificationPreference(enabled: true, version: 3))
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .freshDefault)
        await coordinator.choose(.configured)
        await coordinator.reconcile(with: service)
        let generation = await coordinator.beginRegistration()
        XCTAssertNotNil(generation)
        await coordinator.choose(.off)
        let registration = RemoteAlertRegistration(relayEndpoint: "https://relay.example", topic: "t", environment: "production",
                                                   originID: "o", deviceID: "d", tokenFingerprint: "f", expiresAt: Date().addingTimeInterval(86_400))
        let committed = await coordinator.completeRegistration(registration, generation: generation!)
        XCTAssertFalse(committed)
        await coordinator.recordFailure(.relayRejected, generation: generation!)
        let policy = await coordinator.policy
        XCTAssertNil(policy.registration)
        XCTAssertNil(policy.lastFailure)
        XCTAssertEqual(policy.choice, .off)
    }

    func testAConflictRereadsAndWritesOnlyTheLatestIntent() async {
        let service = FakePreferenceService(NotificationPreference(enabled: true, version: 4))
        await service.setConflictOnce(NotificationPreference(enabled: true, version: 5))
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .migrated(priorUseEstablished: true, relayAvailable: true))
        await coordinator.choose(.off)
        let policy = await coordinator.reconcile(with: service)
        XCTAssertEqual(policy.displayState, .off)
        let remote = await service.current
        XCTAssertEqual(remote, NotificationPreference(enabled: false, version: 6))
    }

    func testAnOlderHostIsNeverReportedAsDisabled() async {
        let service = FakePreferenceService(nil)
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .migrated(priorUseEstablished: true, relayAvailable: true))
        await coordinator.choose(.off)
        let policy = await coordinator.reconcile(with: service)
        XCTAssertEqual(policy.displayState, .disableNeedsHostUpdate)
        XCTAssertEqual(policy.displayState.dimension, "disable_pending")
    }

    func testOptInWaitsForTheMacBeforeRegistering() async {
        let service = FakePreferenceService(NotificationPreference(enabled: false, version: 2))
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(), initial: .freshDefault)
        await coordinator.choose(.configured)
        let early = await coordinator.beginRegistration()
        XCTAssertNil(early, "no fresh delivery material before the Mac accepts the opt-in")
        await coordinator.reconcile(with: service)
        let later = await coordinator.beginRegistration()
        XCTAssertNotNil(later)
        let remote = await service.current
        XCTAssertEqual(remote, NotificationPreference(enabled: true, version: 3))
    }

    func testMigrationPreservesPriorUseAndOtherwiseAsksOnce() {
        let prior = RemoteAlertPolicy.migrated(priorUseEstablished: true, relayAvailable: true)
        XCTAssertEqual(prior.displayState, .configured)
        let unknown = RemoteAlertPolicy.migrated(priorUseEstablished: false, relayAvailable: true)
        XCTAssertEqual(unknown.choice, .off)
        XCTAssertEqual(unknown.displayState, .off, "no delivery material: effectively off, nothing written")
        XCTAssertTrue(unknown.needsChoice)
        XCTAssertFalse(RemoteAlertPolicy.migrated(priorUseEstablished: false, relayAvailable: false).needsChoice)
    }

    func testRegistrationCacheIsBoundToEveryInput() {
        let base = RemoteAlertRegistration(relayEndpoint: "https://relay.example", topic: "dev.chr33s.shell", environment: "production",
                                           originID: "o", deviceID: "d", tokenFingerprint: RemoteAlertRegistration.fingerprint(token: "aa"),
                                           expiresAt: Date().addingTimeInterval(30 * 86_400))
        XCTAssertTrue(base.covers(base, at: Date(), margin: 7 * 86_400))
        var changed = base; changed.relayEndpoint = "https://other.example"
        XCTAssertFalse(base.covers(changed, at: Date(), margin: 0))
        changed = base; changed.deviceID = "d2"
        XCTAssertFalse(base.covers(changed, at: Date(), margin: 0))
        changed = base; changed.tokenFingerprint = RemoteAlertRegistration.fingerprint(token: "bb")
        XCTAssertFalse(base.covers(changed, at: Date(), margin: 0))
        XCTAssertFalse(base.covers(base, at: Date().addingTimeInterval(25 * 86_400), margin: 7 * 86_400), "near expiry renews")
        XCTAssertFalse(RemoteAlertRegistration.fingerprint(token: "aa").contains("aa"))
    }

    // MARK: Bounded passes

    func testConcurrentPassesCoalesceAndAreBounded() async {
        let coordinator = DiagnosticPassCoordinator()
        let counter = Counter()
        let stamp = stamp
        async let first = coordinator.run(budget: .seconds(5), {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(100))
            return DiagnosticReport(generatedAt: stamp, vantage: .iphone, checks: [])
        }, timedOut: { DiagnosticReport(generatedAt: stamp, vantage: .mac, checks: []) })
        try? await Task.sleep(for: .milliseconds(20))
        async let second = coordinator.run(budget: .seconds(5), {
            await counter.increment()
            return DiagnosticReport(generatedAt: stamp, vantage: .iphone, checks: [])
        }, timedOut: { DiagnosticReport(generatedAt: stamp, vantage: .mac, checks: []) })
        _ = await (first, second)
        let count = await counter.value
        XCTAssertEqual(count, 1, "a duplicate request joins the pass in flight")

        let slow = await coordinator.run(budget: .milliseconds(50), {
            try? await Task.sleep(for: .seconds(5))
            return DiagnosticReport(generatedAt: stamp, vantage: .iphone, checks: [])
        }, timedOut: { DiagnosticReport(generatedAt: stamp, vantage: .mac, checks: []) })
        XCTAssertEqual(slow.vantage, .mac, "the budget ends the pass")

        let probe = await withProbeDeadline(.milliseconds(20)) { () -> Int in
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        XCTAssertNil(probe, "an unanswered probe is unknown, not a guessed result")

        // A probe that ignores cancellation still cannot hold the deadline.
        let clock = ContinuousClock()
        let start = clock.now
        let stuck = await withProbeDeadline(.milliseconds(50)) { () -> Int in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return 1
        }
        XCTAssertNil(stuck)
        XCTAssertLessThan(clock.now - start, .seconds(2))
        let quick = await withProbeDeadline(.seconds(5)) { 7 }
        XCTAssertEqual(quick, 7)
    }
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

/// A Mac-side preference with compare-and-set semantics, an offline switch,
/// and a missing-endpoint mode (`nil`) for an older broker.
actor FakePreferenceService: NotificationPreferenceService {
    private(set) var current: NotificationPreference?
    private(set) var writes = 0
    private var offline = false
    private var conflictOnce: NotificationPreference?

    init(_ initial: NotificationPreference?) { current = initial }

    func setOffline(_ value: Bool) { offline = value }
    func setConflictOnce(_ value: NotificationPreference) { conflictOnce = value }

    func notificationPreference() async throws -> NotificationPreference {
        if offline { throw URLError(.notConnectedToInternet) }
        guard let current else { throw NotificationPreferenceUnsupported() }
        return current
    }

    func setNotificationPreference(_ update: NotificationPreferenceUpdate) async throws -> NotificationPreference {
        if offline { throw URLError(.notConnectedToInternet) }
        guard let existing = current else { throw NotificationPreferenceUnsupported() }
        if let conflict = conflictOnce {
            conflictOnce = nil
            current = conflict
            throw ControlError(code: .idempotencyConflict, message: "stale")
        }
        guard update.expectedVersion == existing.version else {
            throw ControlError(code: .idempotencyConflict, message: "stale")
        }
        writes += 1
        let next = NotificationPreference(enabled: update.enabled, version: existing.version + 1)
        current = next
        return next
    }
}
