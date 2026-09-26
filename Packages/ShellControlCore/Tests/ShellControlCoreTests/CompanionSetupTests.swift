import Foundation
import Testing
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlClient

/// Portable rules of Control companion setup: the diagnostic contract, its
/// redacted export, the fixed setup-test request, and the remote-alert policy
/// (docs/specs/control-setup.md).
@Suite
final class CompanionSetupTests {
    private let stamp = ControlTimestamp(Date(timeIntervalSince1970: 1_790_000_000))

    // MARK: Diagnostics

    @Test
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
        #expect(json["schema"]?.stringValue == "shell-control-diagnostics/1")
        #expect(json["checks"]?.arrayValue?.first?["required_for"] == JSONValue(strings: ["iphone_review", "watch_review"]))
        #expect(json["checks"]?.arrayValue?.last?["action"]?.isNull ?? false)
        #expect((try DiagnosticReport(json: json)) == report)
    }

    @Test
    func testReadinessNeedsEveryRequiredCheckToPass() throws {
        func report(_ states: [DiagnosticState]) -> DiagnosticReport {
            DiagnosticReport(generatedAt: stamp, vantage: .mac, checks: states.enumerated().map { index, state in
                DiagnosticCheck(id: "c\(index)", code: .brokerReady, state: state, requiredFor: [.host],
                                source: "test", observedAt: stamp, summary: "")
            })
        }
        #expect(report([.pass, .pass]).readiness(for: .host) == .pass)
        #expect(report([.pass, .unknown]).readiness(for: .host) == .unknown, "missing evidence is never a pass")
        #expect(report([.unknown, .fail]).readiness(for: .host) == .fail)
        #expect(report([.pass]).readiness(for: .watchReview) == .unknown, "no evidence at all is unknown")
        // Optional features never gate host readiness.
        let optional = DiagnosticReport(generatedAt: stamp, vantage: .mac, checks: [
            DiagnosticCheck(id: "a", code: .brokerReady, state: .pass, requiredFor: [.host], source: "t", observedAt: stamp, summary: ""),
            DiagnosticCheck(id: "w", code: .watchNotConfigured, state: .notConfigured, source: "t", observedAt: stamp, summary: ""),
            DiagnosticCheck(id: "r", code: .alertsNotConfigured, state: .disabled, source: "t", observedAt: stamp, summary: "")
        ])
        #expect(optional.isReady(.host, at: stamp.date, maxAge: 30))
        #expect(!(optional.isReady(.host, at: stamp.date.addingTimeInterval(31), maxAge: 30)), "stale evidence is not current")
    }

    @Test
    func testDefaultSeverityFollowsStateAndRequirement() throws {
        let optionalFailure = DiagnosticCheck(id: "x", code: .notificationRegistrationFailed, state: .fail,
                                              source: "t", observedAt: nil, summary: "")
        #expect(optionalFailure.severity == .warning, "an optional failure never reads as a broken setup")
        let skipped = DiagnosticCheck(id: "w", code: .watchNotConfigured, state: .notConfigured, source: "t", observedAt: nil, summary: "")
        #expect(skipped.severity == .info)
        #expect(!(skipped.isFresh(at: Date())), "no observation is never fresh")
    }

    @Test
    func testEveryMacActionIsFixedText() throws {
        for action in DiagnosticAction.allCases {
            if let command = action.macCommand { #expect(!(command.isEmpty)) }
        }
    }

    // MARK: Export redaction

    @Test
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
            #expect(!(text.contains(secret)), "export leaked \(secret)")
        }
        // Codes survive and identifiers are pseudonymised consistently.
        #expect(text.contains("route_unreachable"))
        #expect(text.components(separatedBy: "id-1").count - 1 == 2, "one device, one pseudonym, in both rows")
        let parsed = try JSONValue.parse(data)
        #expect(parsed["schema"]?.stringValue == DiagnosticExport.schema)
        #expect((parsed["reports"]?.arrayValue?.first?["checks"]?.arrayValue?.first?["source"]) == nil, "only allowlisted fields")
    }

    @Test
    func testExportRedactsPathsUnderAnyRoot() throws {
        let redactor = DiagnosticRedactor()
        for path in ["/var/folders/xy/T/shell-state/installation.json", "/Volumes/Work/state/broker.json",
                     "/opt/shell/state", "/Users/alice/Library/Application Support/x", "/private/var/folders/ab/C/y"] {
            let text = redactor.redact("installation unreadable: \(path) is malformed")
            #expect(!(text.contains(path.split(separator: "/").dropFirst().first.map(String.init) ?? "?")), "\(text)")
            #expect(text.contains("<path>"), "\(text)")
        }
        #expect(redactor.redact("route_unreachable 127.0.0.1:8443") == "route_unreachable 127.0.0.1:8443")
    }

    @Test
    func testSetupFixtureKindsAreDistinguished() throws {
        func spec(_ review: MinimumReview) throws -> ApprovalSpec {
            try ApprovalSpec(requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
                             createdAt: stamp, expiresAt: stamp.adding(60), summary: SetupTestFixture.summary,
                             operation: .exec(SetupTestFixture.operation), minimumReview: review, requiredFeatures: [])
        }
        #expect(SetupTestFixture.isIPhoneTest(try spec(.full)))
        #expect(!(SetupTestFixture.isWatchTest(try spec(.full))))
        #expect(SetupTestFixture.isWatchTest(try spec(.watch)))
    }

    @Test
    func testRemoveAllForgetsOnlyThatOrigin() throws {
        let store = InMemoryRemoteAlertPolicyStore()
        store.save(.freshDefault, originID: "a", deviceID: "1")
        store.save(.freshDefault, originID: "a", deviceID: "2")
        store.save(.freshDefault, originID: "b", deviceID: "1")
        store.removeAll(originID: "a")
        #expect((store.load(originID: "a", deviceID: "1")) == nil)
        #expect((store.load(originID: "a", deviceID: "2")) == nil)
        #expect((store.load(originID: "b", deviceID: "1")) != nil)
    }

    // MARK: Setup-test fixture

    @Test
    func testSetupFixtureIsFixedAndRecognised() throws {
        let body = SetupTestFixture.requestBody(forWatch: false)
        #expect(body["summary"]?.stringValue == "Setup test — no operation will be executed")
        #expect(body["minimum_review"]?.stringValue == "full")
        #expect(SetupTestFixture.requestBody(forWatch: true)["minimum_review"]?.stringValue == "watch")
        #expect((try ExecOperation(json: try #require(body["operation"]))) == SetupTestFixture.operation)
        #expect(SetupTestFixture.lifetimeSeconds <= Int64(ApprovalPolicy.maximumLifetime))

        func spec(summary: String, argv: [String]) throws -> ApprovalSpec {
            try ApprovalSpec(
                requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
                createdAt: stamp, expiresAt: stamp.adding(60), summary: summary,
                operation: .exec(try ExecOperation(argv: argv, cwd: "/", contextSHA256: SetupTestFixture.contextSHA256)),
                minimumReview: .full, requiredFeatures: []
            )
        }
        #expect(SetupTestFixture.matches(try spec(summary: SetupTestFixture.summary, argv: SetupTestFixture.argv)))
        #expect(!(SetupTestFixture.matches(try spec(summary: SetupTestFixture.summary, argv: ["/bin/rm", "-rf", "/"]))), "a reassuring label on another operation is not the fixture")
    }

    // MARK: Notification preference wire format

    @Test
    func testPreferenceDocumentsRejectUnknownFieldsAndBadTypes() throws {
        #expect((try NotificationPreference(json: .object(["enabled": true, "version": 1]))) == NotificationPreference(enabled: true, version: 1))
        #expect(throws: (any Error).self){ try NotificationPreferenceUpdate(json: .object(["enabled": false, "expected_version": 1, "extra": true])) }
        #expect(throws: (any Error).self){ try NotificationPreferenceUpdate(json: .object(["enabled": "false", "expected_version": 1])) }
        #expect(throws: (any Error).self){ try NotificationPreferenceUpdate(json: .object(["enabled": false, "expected_version": -1])) }
    }

    // MARK: Remote-alert policy

    @Test
    func testFreshSetupDefaultsOffAndNeverRegisters() async throws {
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(), initial: .freshDefault)
        let policy = await coordinator.policy
        #expect(policy.choice == .off)
        let begun = await coordinator.beginRegistration()
        #expect((begun) == nil, "off means no relay registration, whatever the build carries")
    }

    @Test
    func testDisablingWhileTheMacIsOfflineIsPendingThenAcknowledged() async throws {
        let service = FakePreferenceService(NotificationPreference(enabled: true, version: 0))
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .migrated(priorUseEstablished: true, relayAvailable: true))
        await service.setOffline(true)
        await coordinator.choose(.off)
        var policy = await coordinator.reconcile(with: service)
        #expect(policy.displayState == .disablePending, "local work stops; host suppression is pending")
        #expect((policy.registration) == nil)

        await service.setOffline(false)
        policy = await coordinator.reconcile(with: service)
        #expect(policy.displayState == .off)
        let remote = await service.current
        #expect(remote == NotificationPreference(enabled: false, version: 1))
        // Reconnecting again is idempotent.
        _ = await coordinator.reconcile(with: service)
        let writes = await service.writes
        #expect(writes == 1)
    }

    @Test
    func testALateRegistrationCannotRestoreDeliveryAfterOff() async throws {
        let service = FakePreferenceService(NotificationPreference(enabled: true, version: 3))
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .freshDefault)
        await coordinator.choose(.configured)
        await coordinator.reconcile(with: service)
        let generation = await coordinator.beginRegistration()
        #expect((generation) != nil)
        await coordinator.choose(.off)
        let registration = RemoteAlertRegistration(relayEndpoint: "https://relay.example", topic: "t", environment: "production",
                                                   originID: "o", deviceID: "d", tokenFingerprint: "f", expiresAt: Date().addingTimeInterval(86_400))
        let committed = await coordinator.completeRegistration(registration, generation: generation!)
        #expect(!(committed))
        await coordinator.recordFailure(.relayRejected, generation: generation!)
        let policy = await coordinator.policy
        #expect((policy.registration) == nil)
        #expect((policy.lastFailure) == nil)
        #expect(policy.choice == .off)
    }

    @Test
    func testAConflictRereadsAndWritesOnlyTheLatestIntent() async throws {
        let service = FakePreferenceService(NotificationPreference(enabled: true, version: 4))
        await service.setConflictOnce(NotificationPreference(enabled: true, version: 5))
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .migrated(priorUseEstablished: true, relayAvailable: true))
        await coordinator.choose(.off)
        let policy = await coordinator.reconcile(with: service)
        #expect(policy.displayState == .off)
        let remote = await service.current
        #expect(remote == NotificationPreference(enabled: false, version: 6))
    }

    @Test
    func testLateEnableWriteReconcilesOffBeforeReportingSuccess() async throws {
        let service = PausedEnablePreferenceService()
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .freshDefault)
        await coordinator.choose(.configured)
        let enabling = Task { await coordinator.reconcile(with: service) }
        await service.waitForEnableWrite()
        await coordinator.choose(.off)
        await service.releaseEnableWrite()
        let result = await enabling.value
        let remote = await service.preference()
        #expect(result.displayState == .off)
        #expect(remote == NotificationPreference(enabled: false, version: 3))
    }

    @Test
    func testOffChoicePreventsCapabilityUploadForOldGeneration() async throws {
        let service = FakePreferenceService(NotificationPreference(enabled: true, version: 1))
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .freshDefault)
        await coordinator.choose(.configured)
        await coordinator.reconcile(with: service)
        let generation = await coordinator.beginRegistration()
        #expect((generation) != nil)
        await coordinator.choose(.off)
        let upload = RecordingCapabilityService()
        let submitted = try await coordinator.registerCapability("sealed", generation: generation!, with: upload)
        let uploads = await upload.count
        #expect(!(submitted))
        #expect(uploads == 0)
    }

    @Test
    func testOffChoiceCancelsCapabilityUploadAlreadyInFlight() async throws {
        let service = FakePreferenceService(NotificationPreference(enabled: true, version: 1))
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .freshDefault)
        await coordinator.choose(.configured)
        await coordinator.reconcile(with: service)
        let currentGeneration = await coordinator.beginRegistration()
        let generation = try #require(currentGeneration)
        let upload = PausedCapabilityService()
        let pending = Task { try await coordinator.registerCapability("sealed", generation: generation, with: upload) }
        await upload.waitForCall()
        await coordinator.choose(.off)
        await upload.release()
        do {
            _ = try await pending.value
            Issue.record("the pending upload should have been cancelled")
        } catch is CancellationError {}
        let uploads = await upload.count
        #expect(uploads == 0)
    }

    @Test
    func testAnOlderHostIsNeverReportedAsDisabled() async throws {
        let service = FakePreferenceService(nil)
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(),
                                                 initial: .migrated(priorUseEstablished: true, relayAvailable: true))
        await coordinator.choose(.off)
        let policy = await coordinator.reconcile(with: service)
        #expect(policy.displayState == .disableNeedsHostUpdate)
        #expect(policy.displayState.dimension == "disable_pending")
    }

    @Test
    func testOptInWaitsForTheMacBeforeRegistering() async throws {
        let service = FakePreferenceService(NotificationPreference(enabled: false, version: 2))
        let coordinator = RemoteAlertCoordinator(originID: "o", deviceID: "d", store: InMemoryRemoteAlertPolicyStore(), initial: .freshDefault)
        await coordinator.choose(.configured)
        let early = await coordinator.beginRegistration()
        #expect((early) == nil, "no fresh delivery material before the Mac accepts the opt-in")
        await coordinator.reconcile(with: service)
        let later = await coordinator.beginRegistration()
        #expect((later) != nil)
        let remote = await service.current
        #expect(remote == NotificationPreference(enabled: true, version: 3))
    }

    @Test
    func testMigrationPreservesPriorUseAndOtherwiseAsksOnce() throws {
        let prior = RemoteAlertPolicy.migrated(priorUseEstablished: true, relayAvailable: true)
        #expect(prior.displayState == .configured)
        let unknown = RemoteAlertPolicy.migrated(priorUseEstablished: false, relayAvailable: true)
        #expect(unknown.choice == .off)
        #expect(unknown.displayState == .off, "no delivery material: effectively off, nothing written")
        #expect(unknown.needsChoice)
        #expect(!(RemoteAlertPolicy.migrated(priorUseEstablished: false, relayAvailable: false).needsChoice))
    }

    @Test
    func testRegistrationCacheIsBoundToEveryInput() throws {
        let base = RemoteAlertRegistration(relayEndpoint: "https://relay.example", topic: "dev.chr33s.shell", environment: "production",
                                           originID: "o", deviceID: "d", tokenFingerprint: RemoteAlertRegistration.fingerprint(token: "aa"),
                                           expiresAt: Date().addingTimeInterval(30 * 86_400))
        #expect(base.covers(base, at: Date(), margin: 7 * 86_400))
        var changed = base; changed.relayEndpoint = "https://other.example"
        #expect(!(base.covers(changed, at: Date(), margin: 0)))
        changed = base; changed.deviceID = "d2"
        #expect(!(base.covers(changed, at: Date(), margin: 0)))
        changed = base; changed.tokenFingerprint = RemoteAlertRegistration.fingerprint(token: "bb")
        #expect(!(base.covers(changed, at: Date(), margin: 0)))
        #expect(!(base.covers(base, at: Date().addingTimeInterval(25 * 86_400), margin: 7 * 86_400)), "near expiry renews")
        #expect(!(RemoteAlertRegistration.fingerprint(token: "aa").contains("aa")))
    }

    // MARK: Bounded passes

    @Test
    func testConcurrentPassesCoalesceAndAreBounded() async throws {
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
        #expect(count == 1, "a duplicate request joins the pass in flight")

        let slow = await coordinator.run(budget: .milliseconds(50), {
            try? await Task.sleep(for: .seconds(5))
            return DiagnosticReport(generatedAt: stamp, vantage: .iphone, checks: [])
        }, timedOut: { DiagnosticReport(generatedAt: stamp, vantage: .mac, checks: []) })
        #expect(slow.vantage == .mac, "the budget ends the pass")

        let probe = await withProbeDeadline(.milliseconds(20)) { () -> Int in
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        #expect((probe) == nil, "an unanswered probe is unknown, not a guessed result")

        // A probe that ignores cancellation still cannot hold the deadline.
        let clock = ContinuousClock()
        let start = clock.now
        let stuck = await withProbeDeadline(.milliseconds(50)) { () -> Int in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return 1
        }
        #expect((stuck) == nil)
        #expect(clock.now - start < .seconds(2))
        let quick = await withProbeDeadline(.seconds(5)) { 7 }
        #expect(quick == 7)
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

private actor PausedEnablePreferenceService: NotificationPreferenceService {
    private var current = NotificationPreference(enabled: false, version: 1)
    private var enableWrite: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func notificationPreference() -> NotificationPreference { current }
    func preference() -> NotificationPreference { current }

    func waitForEnableWrite() async {
        if enableWrite != nil { return }
        await withCheckedContinuation { entered = $0 }
    }

    func releaseEnableWrite() { enableWrite?.resume(); enableWrite = nil }

    func setNotificationPreference(_ update: NotificationPreferenceUpdate) async throws -> NotificationPreference {
        if update.enabled {
            await withCheckedContinuation { continuation in
                enableWrite = continuation
                entered?.resume()
                entered = nil
            }
        }
        guard update.expectedVersion == current.version else {
            throw ControlError(code: .idempotencyConflict, message: "stale")
        }
        current = NotificationPreference(enabled: update.enabled, version: current.version + 1)
        return current
    }
}

private actor RecordingCapabilityService: PushCapabilityRegistrationService {
    private(set) var count = 0
    func registerPushCapability(_ capability: String) { count += 1 }
}

private actor PausedCapabilityService: PushCapabilityRegistrationService {
    private(set) var count = 0
    private var call: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?

    func waitForCall() async {
        if call != nil { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release() { call?.resume(); call = nil }

    func registerPushCapability(_ capability: String) async throws {
        await withCheckedContinuation { continuation in
            call = continuation
            entered?.resume()
            entered = nil
        }
        try Task.checkCancellation()
        count += 1
    }
}
