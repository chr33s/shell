import Foundation
import Testing
import CryptoKit
@testable import ShellControlManagement
import ShellControlClient
import ShellControlHostSupport
import ShellControlProtocol
import ShellControlSecurity

extension FakeTailnet {
    func setProxy(_ hostPort: String, _ target: String) { serve.proxies[hostPort] = target }
    func setOtherMount(_ hostPort: String, _ path: String) { serve.otherMounts[hostPort, default: []].insert(path) }
    func setBackend(_ state: String) { status.backendState = state }
}

/// An admin API with a simulated iPhone and Watch: a pending enrollment
/// appears once the pairing QR is shown (or the Watch is opened), and the
/// device is enrolled after the Mac confirms it.
actor FakeEnrollment: EnrollmentAdministration {
    var devices: [EnrolledDevice] = []
    var pendingItems: [PendingEnrollment] = []
    var confirmed: [String] = []

    func seed(_ device: EnrolledDevice) { devices.append(device) }
    func offer(_ item: PendingEnrollment) { pendingItems.append(item) }

    func devices(port: Int, adminSecret: String) async throws -> [EnrolledDevice] { devices }
    func pending(port: Int, adminSecret: String) async throws -> [PendingEnrollment] { pendingItems }
    func describe(userCode: String, port: Int, adminSecret: String) async throws -> PendingEnrollment {
        guard let item = pendingItems.first(where: { $0.userCode == userCode }) else { throw ManagementError.unavailable("unknown code") }
        return item
    }
    func confirm(userCode: String, port: Int, adminSecret: String) async throws {
        guard let index = pendingItems.firstIndex(where: { $0.userCode == userCode }) else { throw ManagementError.unavailable("unknown code") }
        let item = pendingItems.remove(at: index)
        confirmed.append(userCode)
        let iphone = devices.first(where: \.isIPhone)
        devices.append(EnrolledDevice(deviceID: UUID().uuidString.lowercased(), platform: item.platform, label: item.label,
                                      fingerprint: item.fingerprint, gatewayDeviceID: item.isWatch ? iphone?.deviceID : nil))
    }
}

actor CountingPairing: PairingAdministration {
    var minted = 0
    nonisolated func createPairing(port: Int, adminSecret: String) async throws -> (pairingID: ControlID, secret: String, expiresAt: ControlTimestamp) {
        await increment()
        return (.random(), Base64URL.encode(Data(repeating: 9, count: 32)), ControlTimestamp(Date().addingTimeInterval(600)))
    }
    private func increment() { minted += 1 }
}

/// Answers prompts from a script keyed by question prefix; anything
/// unscripted takes the default. Records everything said.
actor ScriptedPresenter: GuidedSetupPresenter {
    var answers: [(String, String)]
    var transcript: [String] = []
    var shownChecks: [[DiagnosticCheck]] = []
    var pairingsShown = 0
    let onPairing: @Sendable () async -> Void
    let onWatchPrompt: @Sendable () async -> Void

    init(_ answers: [(String, String)] = [], onPairing: @escaping @Sendable () async -> Void = {}, onWatchPrompt: @escaping @Sendable () async -> Void = {}) {
        self.answers = answers
        self.onPairing = onPairing
        self.onWatchPrompt = onWatchPrompt
    }

    func heading(_ text: String) async { transcript.append("# \(text)") }
    func say(_ text: String) async {
        transcript.append(text)
        if text.hasPrefix("Open Shell on the Apple Watch") { await onWatchPrompt() }
    }
    func show(_ checks: [DiagnosticCheck]) async { shownChecks.append(checks) }
    func showPairing(_ invitation: PairingInvitation) async throws {
        pairingsShown += 1
        await onPairing()
    }
    func choose(_ question: String, _ choices: [GuidedChoice]) async throws -> String {
        transcript.append("? \(question)")
        if let index = answers.firstIndex(where: { question.hasPrefix($0.0) }) {
            return answers.remove(at: index).1
        }
        return choices[0].key
    }
    func said(_ fragment: String) -> Bool { transcript.contains { $0.contains(fragment) } }
}

@Suite
final class CompanionSetupManagementTests {
    private func directory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-companion-\(UUID())")
    }

    private func bundle(in root: URL) throws -> (installer: NativeBundleInstaller, home: URL) {
        let source = root.appendingPathComponent("bundle"), home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var hashes: [String: String] = [:]
        for name in ["shell-control", "shell-controld", "shell-control-broker"] {
            let data = Data("companion-\(name)".utf8)
            try data.write(to: source.appendingPathComponent(name))
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        try JSONEncoder().encode(ReleaseManifest(releaseID: "companion-release", architecture: architecture,
                                                 minimumOS: "26.0", toolchain: "test", executables: hashes))
            .write(to: source.appendingPathComponent("release-manifest.json"))
        return (NativeBundleInstaller(executablePath: source.appendingPathComponent("shell-control").path, home: home), home)
    }

    private struct Rig {
        let manager: LifecycleCoordinator
        let tailnet: FakeTailnet
        let services: FakeServices
        let state: URL
    }

    private func rig(_ root: URL, tailnet: FakeTailnet = FakeTailnet()) throws -> Rig {
        let made = try bundle(in: root)
        let services = FakeServices(), state = root.appendingPathComponent("state")
        let manager = LifecycleCoordinator(store: InstallationStore(root: state), manager: services, installer: made.installer,
                                           home: made.home, health: FakeHealth(), origins: FakeOrigins(), tailnet: tailnet,
                                           readinessDeadline: .milliseconds(200))
        return Rig(manager: manager, tailnet: tailnet, services: services, state: state)
    }

    // MARK: Serve ownership

    @Test
    func testAnotherAppsServeEndpointStopsSetupUnchanged() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let tailnet = FakeTailnet()
        await tailnet.setProxy("macbook.example.ts.net:443", "http://127.0.0.1:3000")
        let rig = try rig(root, tailnet: tailnet)
        do {
            _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
            Issue.record("setup must not replace another application's handler")
        } catch let error as ManagementError {
            #expect(error.description.hasPrefix("serve_conflict"), "\(error.description)")
        }
        let configured = await rig.tailnet.configureCalls
        #expect(configured == 0)
        let proxy = await rig.tailnet.serve.proxies["macbook.example.ts.net:443"]
        #expect(proxy == "http://127.0.0.1:3000")
    }

    @Test
    func testShellsOwnHandlerOnAPreviousPortIsNotAConflict() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let first = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        #expect(first.installation.servePorts == [8443])
        let moved = try await rig.manager.setup(SetupOptions(port: 9443))
        #expect(moved.installation.servePorts == [9443], "narrowed once the new handler is verified")
        let proxy = await rig.tailnet.serve.proxies["macbook.example.ts.net:443"]
        #expect(proxy == "http://127.0.0.1:9443")
    }

    @Test
    func testLeavingTailscaleNeverResetsOtherServeMounts() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        await rig.tailnet.setOtherMount("macbook.example.ts.net:443", "/grafana")
        _ = try await rig.manager.setup(SetupOptions(mode: .loopback))
        let serve = await rig.tailnet.serve
        #expect((serve.proxies["macbook.example.ts.net:443"]) == nil, "Shell's own handler is withdrawn")
        #expect(serve.otherMounts["macbook.example.ts.net:443"] == ["/grafana"], "another app's mount on 443 must survive")
    }

    /// An installation from before Serve ports were recorded changes port
    /// without mistaking its own handler for another app's.
    @Test
    func testAnUpgradedInstallationCanChangeItsPort() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let first = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: first.paths.installation)) as? [String: Any] ?? [:]
        json["serve_ports"] = nil
        try SecureFileSystem.atomicWrite(try JSONSerialization.data(withJSONObject: json), to: first.paths.installation)
        let preflight = await rig.manager.preflight(SetupOptions(port: 9443))
        #expect(preflight.first { $0.id == "serve" }?.state == .pass)
        let moved = try await rig.manager.setup(SetupOptions(port: 9443))
        let proxy = await rig.tailnet.serve.proxies["macbook.example.ts.net:443"]
        #expect(proxy == "http://127.0.0.1:9443")
        #expect(moved.installation.servePorts == [9443])
    }

    /// A Serve change that fails validation still leaves the new port
    /// recorded as Shell's, so the next change is not a false conflict.
    @Test
    func testAFailedServeValidationKeepsTheAttemptedPortAsShells() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        await rig.tailnet.setConfigureTakesEffect(false)
        do {
            _ = try await rig.manager.setup(SetupOptions(port: 9443))
            Issue.record("an ineffective Serve change must fail validation")
        } catch {}
        let installation = try InstallationStore(root: rig.state).load().installation
        #expect(installation.ownedServePorts.isSuperset(of: [8443, 9443]))
        // Serve did change after all (the CLI took effect late).
        await rig.tailnet.setProxy("macbook.example.ts.net:443", "http://127.0.0.1:9443")
        await rig.tailnet.setConfigureTakesEffect(true)
        _ = try await rig.manager.setup(SetupOptions(port: 7443))
        let proxy = await rig.tailnet.serve.proxies["macbook.example.ts.net:443"]
        #expect(proxy == "http://127.0.0.1:7443")
    }

    @Test
    func testServeOwnershipClassification() throws {
        let json = #"{"TCP":{"443":{"HTTPS":true}},"Web":{"m.example.ts.net:443":{"Handlers":{"/":{"Path":"/srv"},"/x":{"Proxy":"http://127.0.0.1:1"}}}}}"#
        let state = try ServeState(json: Data(json.utf8))
        guard case .conflict = state.ownership(host: "m.example.ts.net", ownedPorts: [8443]) else { Issue.record("a file handler is not Shell's")
return }
        #expect(state.otherMounts["m.example.ts.net:443"] == ["/x"])
        let tcp = try ServeState(json: Data(#"{"TCP":{"443":{"TCPForward":"127.0.0.1:22"}}}"#.utf8))
        guard case .conflict = tcp.ownership(host: "m.example.ts.net", ownedPorts: [8443]) else { Issue.record("raw TCP 443 is a conflict")
return }
        #expect(ServeState().ownership(host: "m.example.ts.net", ownedPorts: [8443]) == .absent)
        #expect(ServeState(proxies: ["m.example.ts.net:443": "http://localhost:8443"]).ownership(host: "m.example.ts.net", ownedPorts: [8443]) == .shell(port: 8443))

        // Foreground sessions nest whole configurations; they are not absent.
        let foreground = try ServeState(json: Data(#"{"Foreground":{"session-1":{"TCP":{"443":{"HTTPS":true}},"Web":{"m.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}},"AllowFunnel":{"m.example.ts.net:443":true}}}}"#.utf8))
        #expect(foreground.isFunnelled(host: "m.example.ts.net"))
        guard case .conflict = foreground.ownership(host: "m.example.ts.net", ownedPorts: [8443]) else { Issue.record("a foreground session is not free")
return }
    }

    // MARK: Doctor

    @Test
    func testDoctorWithoutAnInstallationIsReadOnlyAndNotReady() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let report = await rig.manager.diagnose(enrollment: FakeEnrollment())
        #expect(report.check("installation")?.state == .notConfigured)
        #expect(!(report.isReady(.host, at: Date(), maxAge: 30)))
        #expect(!(FileManager.default.fileExists(atPath: rig.state.path)), "doctor must not create state")
    }

    @Test
    func testDoctorReadyHostIgnoresOptionalWatchAndAlerts() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        let admin = FakeEnrollment()
        await admin.seed(EnrolledDevice(deviceID: UUID().uuidString.lowercased(), platform: "iOS", label: "iPhone", fingerprint: "AAAA-BBBB-CCCC-DDDD"))
        let report = await rig.manager.diagnose(enrollment: admin)
        #expect(report.isReady(.host, at: Date(), maxAge: 30), "\(DoctorText.render(report))")
        #expect(report.check("watch_enrollment")?.state == .notConfigured)
        #expect(report.check("remote_alerts")?.code == .alertsNotConfigured)
        #expect(report.check("iphone_enrollment")?.code == .iphoneEnrolled)
        #expect(report.check("iphone_enrollment")?.summary.contains("does not show the iPhone can reach") ?? false, "the Mac never claims phone reachability")
        #expect(DoctorText.render(report).contains("checks the host only"))
        #expect((try DiagnosticReport(json: report.json)) == report)
    }

    @Test
    func testDoctorFlagsPublicExposureAndStoppedIntent() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        await rig.tailnet.setFunnel("macbook.example.ts.net")
        var report = await rig.manager.diagnose(enrollment: FakeEnrollment())
        #expect(report.check("serve")?.code == .servePublicExposure)
        #expect(!(report.isReady(.host, at: Date(), maxAge: 30)), "public exposure is never ready")
        let status = await rig.manager.status()
        #expect(status.overall != "ready")

        try await rig.manager.down()
        report = await rig.manager.diagnose(enrollment: FakeEnrollment())
        #expect(report.check("host_intent")?.code == .hostStoppedByUser)
        #expect(report.check("host_intent")?.action == .startServices)
        #expect(report.check("broker")?.state == .disabled, "a stopped broker is the user's choice, not a failure")
        let desired = try InstallationStore(root: rig.state).load().installation.desiredState
        #expect(desired == .stopped, "diagnostics never repair stopped intent")
    }

    @Test
    func testDoctorReportsAMismatchedOriginKey() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let loaded = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        try OriginKeyFile.write(OriginSigningKey(), to: loaded.paths.originKey)
        let report = await rig.manager.diagnose(enrollment: FakeEnrollment())
        #expect(report.check("origin_key")?.code == .originKeyMismatch)
        #expect(report.check("origin_key")?.action == .recoverOriginIdentity)
        #expect(report.readiness(for: .iphoneReview) == .fail)
    }

    // MARK: Guided setup

    private func pendingPhone() -> PendingEnrollment {
        PendingEnrollment(userCode: "ABCD-1234", platform: "iOS", label: "Test iPhone", fingerprint: "AAAA-BBBB-CCCC-DDDD",
                          requestedGrants: ["approvals.decide"])
    }

    @Test
    func testGuidedSetupCompletesWithIPhoneOnlyAndNoRelay() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let admin = FakeEnrollment(), pairing = CountingPairing()
        let phone = pendingPhone()
        let presenter = ScriptedPresenter(onPairing: { await admin.offer(phone) })
        let tested = TestRecorder()
        let guide = GuidedSetupCoordinator(
            lifecycle: rig.manager, presenter: presenter, admin: admin, pairing: pairing,
            reviewTest: { reviewer, device in
                await tested.record(reviewer, device.deviceID)
                return .succeeded(receiptID: .random())
            },
            pollInterval: .milliseconds(5)
        )
        // Defaults: yes to setup, no to login persistence, approve? default
        // is no — so script the approval, and skip the Watch.
        await presenter.setAnswers([("Does this match", "y")])
        let summary = try await guide.run(GuidedSetupOptions(setup: SetupOptions(tailscalePath: "/usr/bin/true")))
        #expect(summary.primaryComplete)
        #expect(summary.watch == "not configured")
        #expect(summary.alerts == "off")
        #expect(!(summary.persistent))
        let confirmed = await admin.confirmed
        #expect(confirmed == ["ABCD-1234"])
        let calls = await tested.calls
        #expect(calls.map(\.0) == [.iphone])
        let said = await presenter.said("Remote alerts are off. Open Control and refresh to check for requests.")
        #expect(said)

        let checkpoint = GuidedSetupCheckpointStore(installation: InstallationStore(root: rig.state)).load()
        #expect(checkpoint.watch == "skipped")
        #expect(checkpoint.alerts == "off")
        #expect((checkpoint.reviewTestPassedAt) != nil)
        #expect(checkpoint.isComplete(.finish))
        let text = try String(contentsOf: rig.state.appendingPathComponent("guided-setup.json"), encoding: .utf8)
        let secrets = try InstallationStore(root: rig.state).load().secrets
        #expect(!(text.contains(secrets.adminSecret)))
        #expect(!(text.contains(Base64URL.encode(Data(repeating: 9, count: 32)))), "no pairing secret in checkpoints")
        #expect(!(text.contains("invite")))
    }

    @Test
    func testRerunResumesWithoutRepairingOrRetesting() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let admin = FakeEnrollment(), pairing = CountingPairing()
        let phone = pendingPhone()
        let first = ScriptedPresenter([("Does this match", "y")], onPairing: { await admin.offer(phone) })
        _ = try await GuidedSetupCoordinator(lifecycle: rig.manager, presenter: first, admin: admin, pairing: pairing,
                                             reviewTest: { _, _ in .succeeded(receiptID: .random()) }, pollInterval: .milliseconds(5))
            .run(GuidedSetupOptions(setup: SetupOptions(tailscalePath: "/usr/bin/true")))
        let installsBefore = await rig.services.calls.filter { $0.hasPrefix("install:") }.count

        let second = ScriptedPresenter()
        let tested = TestRecorder()
        let summary = try await GuidedSetupCoordinator(
            lifecycle: rig.manager, presenter: second, admin: admin, pairing: pairing,
            reviewTest: { reviewer, device in await tested.record(reviewer, device.deviceID); return .succeeded(receiptID: .random()) },
            pollInterval: .milliseconds(5)
        ).run(GuidedSetupOptions(skipWatchSetup: true))
        #expect(summary.primaryComplete)
        let minted = await pairing.minted
        #expect(minted == 1, "an enrolled iPhone is observed, not paired again")
        let retested = await tested.calls
        #expect(retested.isEmpty, "a passed test is not rerun without asking")
        let installsAfter = await rig.services.calls.filter { $0.hasPrefix("install:") }.count
        #expect(installsAfter == installsBefore, "running services are observed, not reinstalled")
        let skippedWatchPrompt = await second.said("Apple Watch (optional)")
        #expect(!(skippedWatchPrompt), "--skip-watch-setup suppresses only the Watch step")
    }

    @Test
    func testGuideAfterDownKeepsStoppedIntentUnlessStartIsChosen() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        try await rig.manager.down()
        let callsBefore = await rig.services.calls.count
        let presenter = ScriptedPresenter()
        do {
            _ = try await GuidedSetupCoordinator(lifecycle: rig.manager, presenter: presenter, admin: FakeEnrollment(),
                                                 pairing: CountingPairing(), reviewTest: { _, _ in .expired })
                .run(GuidedSetupOptions())
            Issue.record("declining to start must stop the guide")
        } catch is GuidedSetupStopped {}
        #expect((try InstallationStore(root: rig.state).load().installation.desiredState) == .stopped)
        let callsAfter = await rig.services.calls.count
        #expect(callsAfter == callsBefore, "no service was started")
    }

    /// The broker rate-limits admin calls; a refused poll backs off instead
    /// of ending the guide mid-pairing.
    @Test
    func testRefusedPollsBackOffInsteadOfEndingTheGuide() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        // The first read (before pairing) succeeds; the polls that follow are refused.
        let admin = FlakyEnrollment(failures: 3, after: 1)
        let phone = pendingPhone()
        let presenter = ScriptedPresenter([("Does this match", "y")], onPairing: { await admin.inner.offer(phone) })
        let summary = try await GuidedSetupCoordinator(
            lifecycle: rig.manager, presenter: presenter, admin: admin, pairing: CountingPairing(),
            reviewTest: { _, _ in .succeeded(receiptID: .random()) }, pollInterval: .milliseconds(5)
        ).run(GuidedSetupOptions(setup: SetupOptions(tailscalePath: "/usr/bin/true"), skipWatchSetup: true))
        #expect(summary.primaryComplete)
        let warned = await presenter.said("still waiting")
        #expect(warned)
    }

    @Test
    func testASetupTestErrorOffersAnotherTryInsteadOfEndingTheGuide() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let admin = FakeEnrollment()
        await admin.seed(EnrolledDevice(deviceID: UUID().uuidString.lowercased(), platform: "iOS", label: "iPhone", fingerprint: "AAAA-BBBB-CCCC-DDDD"))
        let attempts = TestRecorder()
        let summary = try await GuidedSetupCoordinator(
            lifecycle: rig.manager, presenter: ScriptedPresenter(), admin: admin, pairing: CountingPairing(),
            reviewTest: { reviewer, device in
                await attempts.record(reviewer, device.deviceID)
                if await attempts.calls.count == 1 { throw ManagementError.unavailable("daemon restarting") }
                return .succeeded(receiptID: .random())
            }, pollInterval: .milliseconds(5)
        ).run(GuidedSetupOptions(setup: SetupOptions(tailscalePath: "/usr/bin/true"), skipWatchSetup: true))
        #expect(summary.primaryComplete)
        let count = await attempts.calls.count
        #expect(count == 2)
    }

    /// A replacement Watch never inherits the previous Watch's passed test.
    @Test
    func testAReplacementWatchMustPassItsOwnTest() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let admin = FakeEnrollment()
        let iphoneID = UUID().uuidString.lowercased()
        await admin.seed(EnrolledDevice(deviceID: iphoneID, platform: "iOS", label: "iPhone", fingerprint: "AAAA-BBBB-CCCC-DDDD"))
        await admin.seed(EnrolledDevice(deviceID: UUID().uuidString.lowercased(), platform: "watchOS", label: "Watch B",
                                        fingerprint: "EEEE-FFFF-0000-1111", gatewayDeviceID: iphoneID))
        _ = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        var checkpoint = GuidedSetupCheckpoint()
        checkpoint.iphoneDeviceID = iphoneID
        checkpoint.reviewTestPassedAt = "2026-09-01T00:00:00Z"
        checkpoint.watch = "configured"
        checkpoint.watchDeviceID = UUID().uuidString.lowercased()
        checkpoint.watchTestPassedAt = "2026-09-01T00:00:00Z"
        try GuidedSetupCheckpointStore(installation: InstallationStore(root: rig.state)).save(checkpoint)

        let tested = TestRecorder()
        let presenter = ScriptedPresenter([("Send the setup test", "n")])
        let summary = try await GuidedSetupCoordinator(
            lifecycle: rig.manager, presenter: presenter, admin: admin, pairing: CountingPairing(),
            reviewTest: { reviewer, device in await tested.record(reviewer, device.deviceID); return .succeeded(receiptID: .random()) },
            pollInterval: .milliseconds(5)
        ).run(GuidedSetupOptions())
        #expect(summary.watch == "enrolled", "Watch B has not passed a test")
        let saved = GuidedSetupCheckpointStore(installation: InstallationStore(root: rig.state)).load()
        #expect((saved.watchTestPassedAt) == nil)
        #expect(!(saved.isComplete(.watch)))
    }

    @Test
    func testAFailedTestDoesNotCompleteThePrimaryWorkflow() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let admin = FakeEnrollment()
        await admin.seed(EnrolledDevice(deviceID: UUID().uuidString.lowercased(), platform: "iOS", label: "iPhone", fingerprint: "AAAA-BBBB-CCCC-DDDD"))
        // Send the test once, get no receipt, then decline to retry.
        let presenter = ScriptedPresenter([("Send the setup test", "y"), ("Send the setup test", "n")])
        let summary = try await GuidedSetupCoordinator(
            lifecycle: rig.manager, presenter: presenter, admin: admin, pairing: CountingPairing(),
            reviewTest: { _, _ in .receiptNotRecorded("socket closed") }, pollInterval: .milliseconds(5)
        ).run(GuidedSetupOptions(setup: SetupOptions(tailscalePath: "/usr/bin/true"), skipWatchSetup: true))
        #expect(!(summary.primaryComplete))
        let explained = await presenter.said("the receipt was not")
        #expect(explained)
    }

    @Test
    func testPreflightBlocksBeforeAnyMutation() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root, tailnet: FakeTailnet(backendState: "NeedsLogin"))
        let presenter = ScriptedPresenter([("Fix the items above", "q")])
        do {
            _ = try await GuidedSetupCoordinator(lifecycle: rig.manager, presenter: presenter, admin: FakeEnrollment(),
                                                 pairing: CountingPairing(), reviewTest: { _, _ in .expired })
                .run(GuidedSetupOptions(setup: SetupOptions(tailscalePath: "/usr/bin/true")))
            Issue.record("a disconnected tailnet must stop the guide")
        } catch is GuidedSetupStopped {}
        let shown = await presenter.shownChecks.first ?? []
        #expect(shown.first { $0.id == "tailscale" }?.code == .tailscaleNotConnected)
        #expect(!(InstallationStore(root: rig.state).exists()))
    }

    @Test
    func testOptionalWatchSetupEnrollsThroughTheIPhone() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let admin = FakeEnrollment()
        let iphoneID = UUID().uuidString.lowercased()
        await admin.seed(EnrolledDevice(deviceID: iphoneID, platform: "iOS", label: "iPhone", fingerprint: "AAAA-BBBB-CCCC-DDDD"))
        let watch = PendingEnrollment(userCode: "WXYZ-0000", platform: "watchOS", label: "Apple Watch", fingerprint: "EEEE-FFFF-0000-1111", gateway: "iPhone")
        let presenter = ScriptedPresenter([("Apple Watch:", "w"), ("Does this match", "y")], onWatchPrompt: { await admin.offer(watch) })
        let tested = TestRecorder()
        let summary = try await GuidedSetupCoordinator(
            lifecycle: rig.manager, presenter: presenter, admin: admin, pairing: CountingPairing(),
            reviewTest: { reviewer, device in await tested.record(reviewer, device.deviceID); return .succeeded(receiptID: .random()) },
            pollInterval: .milliseconds(5)
        ).run(GuidedSetupOptions(setup: SetupOptions(tailscalePath: "/usr/bin/true")))
        #expect(summary.watch == "ready")
        let calls = await tested.calls
        #expect(calls.map(\.0) == [.iphone, .watch])
        let devices = await admin.devices
        #expect(devices.first { $0.isWatch }?.gatewayDeviceID == iphoneID)
        #expect(devices.filter(\.isIPhone).map(\.deviceID) == [iphoneID], "adding a Watch leaves the iPhone pairing unchanged")
    }

    // MARK: Setup review test

    @Test
    func testReviewTestSucceedsOnlyWithTheSelectedReviewerAndAReceipt() async throws {
        let reviewer = ControlID.random()
        let adapter = FakeAdapter(decidedBy: reviewer)
        let result = try await SetupReviewTest(adapter: adapter, admin: FakeEnrollment()).run(reviewer: .iphone, deviceID: reviewer.rawValue)
        guard case .succeeded = result else { Issue.record("\(result)")
return }
        let receipts = await adapter.receipts
        #expect(receipts.first?["result"]?.stringValue == "applied")
        #expect(receipts.first?["reason_code"]?.stringValue == SetupTestFixture.receiptReason)
        let request = await adapter.requests.first
        #expect(request?["summary"]?.stringValue == SetupTestFixture.summary)
        #expect(request?["minimum_review"]?.stringValue == "full")
        #expect((try ExecOperation(json: try #require(request?["operation"]))) == SetupTestFixture.operation)
    }

    @Test
    func testAnApprovalWithoutAReceiptIsNotASuccess() async throws {
        let reviewer = ControlID.random()
        let adapter = FakeAdapter(decidedBy: reviewer, failReceipt: true)
        let result = try await SetupReviewTest(adapter: adapter, admin: FakeEnrollment()).run(reviewer: .iphone, deviceID: reviewer.rawValue)
        guard case .receiptNotRecorded = result else { Issue.record("\(result)")
return }
        #expect(result.exitCode == 1)
    }

    @Test
    func testAnotherReviewersApprovalDoesNotPassAndIsNotApplied() async throws {
        let adapter = FakeAdapter(decidedBy: .random())
        let result = try await SetupReviewTest(adapter: adapter, admin: FakeEnrollment()).run(reviewer: .watch, deviceID: ControlID.random().rawValue)
        #expect(result == .decidedByAnotherReviewer)
        let receipts = await adapter.receipts
        #expect(receipts.first?["result"]?.stringValue == "not_applied")
        let request = await adapter.requests.first
        #expect(request?["minimum_review"]?.stringValue == "watch")
    }

    @Test
    func testAnAmbiguousPublicationIsRetransmittedNotReminted() async throws {
        let reviewer = ControlID.random()
        let adapter = FakeAdapter(decidedBy: reviewer, dropFirstRequestReply: true)
        let result = try await SetupReviewTest(adapter: adapter, admin: FakeEnrollment()).run(reviewer: .iphone, deviceID: reviewer.rawValue)
        #expect(result.succeeded)
        let messages = await adapter.requestMessageIDs
        #expect(messages.count == 2)
        #expect(Set(messages).count == 1, "the retry is the same message, so the daemon answers from its record")
        let requestIDs = await adapter.requests.compactMap { $0["request_id"]?.stringValue }
        #expect(Set(requestIDs).count == 1, "one request identity, never a second approval")
    }

    @Test
    func testARejectionIsAValidOutcomeButNotAPass() async throws {
        let adapter = FakeAdapter(decidedBy: .random(), reject: true)
        let result = try await SetupReviewTest(adapter: adapter, admin: FakeEnrollment()).run(reviewer: .iphone, deviceID: ControlID.random().rawValue)
        #expect(result == .rejected)
        #expect(result.exitCode == 10)
        let receipts = await adapter.receipts
        #expect(receipts.isEmpty)
    }

    @Test
    func testTheReviewerMustBeAnEnrolledDeviceOfThatKind() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let rig = try rig(root)
        let loaded = try await rig.manager.setup(SetupOptions(tailscalePath: "/usr/bin/true"))
        let admin = FakeEnrollment()
        let iphone = UUID().uuidString.lowercased()
        await admin.seed(EnrolledDevice(deviceID: iphone, platform: "iOS", label: "iPhone", fingerprint: "AAAA-BBBB-CCCC-DDDD"))
        let test = SetupReviewTest(adapter: FakeAdapter(decidedBy: .random()), admin: admin)
        _ = try await test.validateReviewer(.iphone, deviceID: iphone, loaded: loaded)
        do { _ = try await test.validateReviewer(.watch, deviceID: iphone, loaded: loaded); Issue.record("an iPhone is not a Watch") } catch {}
        do { _ = try await test.validateReviewer(.iphone, deviceID: UUID().uuidString, loaded: loaded); Issue.record("unknown device") } catch {}
    }
}

actor TestRecorder {
    var calls: [(SetupReviewer, String)] = []
    func record(_ reviewer: SetupReviewer, _ id: String) { calls.append((reviewer, id)) }
}

extension ScriptedPresenter {
    func setAnswers(_ value: [(String, String)]) { answers = value }
}

/// `shell-controld` for the setup test: hello, request, wait, receipt.
actor FakeAdapter: SetupTestAdapter {
    let decidedBy: ControlID
    let failReceipt: Bool
    let reject: Bool
    var dropFirstRequestReply: Bool
    var requests: [JSONValue] = []
    var requestMessageIDs: [ControlID] = []
    var receipts: [JSONValue] = []
    private var answered: [ControlID: IPCResponse] = [:]

    init(decidedBy: ControlID, failReceipt: Bool = false, reject: Bool = false, dropFirstRequestReply: Bool = false) {
        self.decidedBy = decidedBy; self.failReceipt = failReceipt; self.reject = reject
        self.dropFirstRequestReply = dropFirstRequestReply
    }

    func exchange(_ request: IPCRequest, timeout: TimeInterval) async throws -> IPCResponse {
        if request.type == .approvalRequest { requestMessageIDs.append(request.messageID) }
        if let recorded = answered[request.messageID] { return recorded }
        switch request.type {
        case .hello:
            return IPCResponse(messageID: request.messageID, ok: true, body: .object([
                "run_capability": "cap-1", "run_id": JSONValue(ControlID.random())
            ]))
        case .approvalRequest:
            requests.append(request.body)
            let response = IPCResponse(messageID: request.messageID, ok: true, body: .object([
                "request_id": request.body["request_id"] ?? .null, "request_hash": .string("sha256:" + String(repeating: "a", count: 64))
            ]))
            answered[request.messageID] = response
            if dropFirstRequestReply {
                dropFirstRequestReply = false
                throw URLError(.timedOut)
            }
            return response
        case .approvalWait:
            if reject {
                return IPCResponse(messageID: request.messageID, ok: true, body: ApprovalWaitOutcome.rejected(decisionID: .random()).json)
            }
            let header = Base64URL.encode(try JSONCanonicalization.canonicalize(.object([
                "alg": "ES256", "kid": JSONValue(decidedBy), "typ": "shell-control+jws"
            ])))
            let permit = ConsumePermit(consumeID: .random(), decisionID: .random(), originID: .random(), runID: .random(),
                                       requestHash: "sha256:" + String(repeating: "a", count: 64),
                                       applyBefore: ControlTimestamp(Date().addingTimeInterval(60)), decision: .approve,
                                       decisionJWS: "\(header).e30.sig")
            return IPCResponse(messageID: request.messageID, ok: true, body: ApprovalWaitOutcome.approved(permit).json)
        case .receipt:
            receipts.append(request.body)
            if failReceipt { return IPCResponse(messageID: request.messageID, ok: false, errorCode: "temporarily_unavailable", errorMessage: "broker unavailable") }
            return IPCResponse(messageID: request.messageID, ok: true, body: .object(["receipt_id": JSONValue(ControlID.random())]))
        case .approvalWithdraw, .notify:
            return IPCResponse(messageID: request.messageID, ok: true)
        case .agentRegister, .agentEvent, .inputRequest, .inputWait, .inputWithdraw, .agentReceipt, .sessionCommandWait:
            return IPCResponse(messageID: request.messageID, ok: false, errorCode: "unsupported_command", errorMessage: "not scripted")
        }
    }
}

/// Refuses `failures` device reads after the first `after`, as a
/// rate-limited broker does.
actor FlakyEnrollment: EnrollmentAdministration {
    let inner = FakeEnrollment()
    var failures: Int
    var after: Int
    init(failures: Int, after: Int = 0) { self.failures = failures; self.after = after }
    func devices(port: Int, adminSecret: String) async throws -> [EnrolledDevice] {
        if after > 0 {
            after -= 1
        } else if failures > 0 {
            failures -= 1
            throw ManagementError.unavailable("GET /v1/admin/devices returned HTTP 429: too many attempts")
        }
        return try await inner.devices(port: port, adminSecret: adminSecret)
    }
    func pending(port: Int, adminSecret: String) async throws -> [PendingEnrollment] { try await inner.pending(port: port, adminSecret: adminSecret) }
    func describe(userCode: String, port: Int, adminSecret: String) async throws -> PendingEnrollment {
        try await inner.describe(userCode: userCode, port: port, adminSecret: adminSecret)
    }
    func confirm(userCode: String, port: Int, adminSecret: String) async throws {
        try await inner.confirm(userCode: userCode, port: port, adminSecret: adminSecret)
    }
}
