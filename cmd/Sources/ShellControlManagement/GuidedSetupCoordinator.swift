import Foundation
import ShellControlClient
import ShellControlHostSupport
import ShellControlProtocol
import ShellControlSecurity

/// `shell-control setup --guided` (spec.control-companion-setup.md section 7).
///
/// The complete primary workflow is Mac + iPhone: services, pairing, and a
/// live setup test. Apple Watch and remote alerts are optional stages that
/// never block it. Every stage observes the real installation, so a rerun
/// resumes rather than replaying mutations; checkpoints are non-secret notes
/// of what was already confirmed.
public enum GuidedSetupStage: String, Sendable, CaseIterable, Codable {
    case introduction, preflight
    case hostServices = "host_services"
    case iphonePairing = "iphone_pairing"
    case reviewTest = "review_test"
    case watch, alerts, finish
}

/// Non-secret progress. It never holds pairing material, keys, bearer
/// credentials, or approval content.
public struct GuidedSetupCheckpoint: Codable, Sendable, Equatable {
    public var format = "shell-control.guided-setup/1"
    public var completed: [String: String] = [:]
    public var iphoneDeviceID: String?
    public var reviewTestPassedAt: String?
    /// `skipped` or `configured`.
    public var watch: String?
    public var watchDeviceID: String?
    public var watchTestPassedAt: String?
    /// `off` or `existing`.
    public var alerts: String?

    enum CodingKeys: String, CodingKey {
        case format, completed, iphoneDeviceID = "iphone_device_id", reviewTestPassedAt = "review_test_passed_at"
        case watch, watchDeviceID = "watch_device_id", watchTestPassedAt = "watch_test_passed_at", alerts
    }

    public init() {}

    public func isComplete(_ stage: GuidedSetupStage) -> Bool { completed[stage.rawValue] != nil }
}

public struct GuidedSetupCheckpointStore: Sendable {
    public let installation: InstallationStore
    public init(installation: InstallationStore) { self.installation = installation }

    public func load() -> GuidedSetupCheckpoint {
        let url = installation.paths.guidedSetup
        guard FileManager.default.fileExists(atPath: url.path),
              let value = try? SecureFileSystem.decode(GuidedSetupCheckpoint.self, from: url),
              value.format == "shell-control.guided-setup/1" else { return GuidedSetupCheckpoint() }
        return value
    }

    /// Checkpoints live beside an existing installation only; before one
    /// exists there is nothing to resume.
    public func save(_ checkpoint: GuidedSetupCheckpoint) throws {
        guard installation.exists() else { return }
        try SecureFileSystem.atomicWrite(checkpoint, to: installation.paths.guidedSetup)
    }
}

/// A choice offered to the user. The first option is the default.
public struct GuidedChoice: Sendable, Equatable {
    public let key: String
    public let title: String
    public init(_ key: String, _ title: String) { self.key = key; self.title = title }
}

/// How the guide talks to the user; the CLI renders it on the terminal.
public protocol GuidedSetupPresenter: Sendable {
    func heading(_ text: String) async
    func say(_ text: String) async
    func show(_ checks: [DiagnosticCheck]) async
    func showPairing(_ invitation: PairingInvitation) async throws
    /// Returns the chosen key; the first choice is the default.
    func choose(_ question: String, _ choices: [GuidedChoice]) async throws -> String
}

extension GuidedSetupPresenter {
    public func confirm(_ question: String, defaultYes: Bool) async throws -> Bool {
        let yes = GuidedChoice("y", "yes"), no = GuidedChoice("n", "no")
        return try await choose(question, defaultYes ? [yes, no] : [no, yes]) == "y"
    }
}

public struct GuidedSetupOptions: Sendable {
    public var setup: SetupOptions
    /// Only the optional Apple Watch stage is suppressed. Unrelated to
    /// `setup --no-watch`, which disables enrollment monitoring.
    public var skipWatchSetup: Bool
    public init(setup: SetupOptions = SetupOptions(), skipWatchSetup: Bool = false) {
        self.setup = setup; self.skipWatchSetup = skipWatchSetup
    }
}

public struct GuidedSetupSummary: Sendable, Equatable {
    public var configured: Bool
    public var servicesRunning: Bool
    public var persistent: Bool
    public var iphone: EnrolledDevice?
    public var reviewTestPassed: Bool
    public var watch: String
    public var alerts: String

    /// Primary completion: an enrolled iPhone passed the live setup test.
    public var primaryComplete: Bool { iphone != nil && reviewTestPassed }
}

/// The user stopped the guide at a point where continuing needs a decision
/// only they can make (for example, keeping services stopped).
public struct GuidedSetupStopped: Error, Sendable, CustomStringConvertible {
    public let description: String
}

public struct GuidedSetupCoordinator: Sendable {
    public typealias ReviewTestRunner = @Sendable (SetupReviewer, EnrolledDevice) async throws -> SetupReviewTestResult

    let lifecycle: LifecycleCoordinator
    let admin: any EnrollmentAdministration
    let pairing: any PairingAdministration
    let presenter: any GuidedSetupPresenter
    let reviewTest: ReviewTestRunner
    let checkpoints: GuidedSetupCheckpointStore
    let pollInterval: Duration
    /// How long to wait for a Watch before offering to skip.
    let watchWait: Duration

    public init(
        lifecycle: LifecycleCoordinator,
        presenter: any GuidedSetupPresenter,
        admin: any EnrollmentAdministration = LiveEnrollmentAdministration(),
        pairing: any PairingAdministration = LivePairingAdministration(),
        reviewTest: @escaping ReviewTestRunner,
        // Two admin reads per poll: every 6 s stays well inside the broker's
        // 30-per-minute admin limit, leaving room for `status` or `doctor`.
        pollInterval: Duration = .seconds(6),
        watchWait: Duration = .seconds(600)
    ) {
        self.lifecycle = lifecycle
        self.admin = admin
        self.pairing = pairing
        self.presenter = presenter
        self.reviewTest = reviewTest
        self.checkpoints = GuidedSetupCheckpointStore(installation: lifecycle.store)
        self.pollInterval = pollInterval
        self.watchWait = watchWait
    }

    public func run(_ options: GuidedSetupOptions) async throws -> GuidedSetupSummary {
        var checkpoint = checkpoints.load()
        var summary = GuidedSetupSummary(configured: false, servicesRunning: false, persistent: false, iphone: nil,
                                         reviewTestPassed: false, watch: "not configured", alerts: "off")

        // Introduction
        await presenter.heading("Shell Control setup")
        await presenter.say("""
            Shell Control lets you review permission requests from this Mac on your iPhone, privately over Tailscale.
            An Apple Watch and remote alerts are optional; you can finish without either.
            Terminal, SSH, and tmux in Shell never need this.
            """)
        guard try await presenter.confirm("Set up Shell Control on this Mac?", defaultYes: true) else {
            throw GuidedSetupStopped(description: "Nothing was changed.")
        }

        // Preflight
        await presenter.heading("Checking this Mac")
        while true {
            let checks = await lifecycle.preflight(options.setup)
            await presenter.show(checks)
            let blocking = checks.filter { !$0.requiredFor.isEmpty && ($0.state == .fail || $0.state == .unknown) }
            if blocking.isEmpty { break }
            let answer = try await presenter.choose("Fix the items above, then:", [GuidedChoice("r", "retry"), GuidedChoice("q", "quit")])
            if answer != "r" { throw GuidedSetupStopped(description: "Setup stopped before changing anything.") }
        }
        checkpoint.completed[GuidedSetupStage.preflight.rawValue] = Self.now()

        // Host services
        await presenter.heading("Control services")
        var loaded = try await hostServices(options.setup)
        summary.configured = true
        summary.servicesRunning = true
        loaded = try await persistence(loaded)
        summary.persistent = loaded.installation.persistent
        checkpoint.completed[GuidedSetupStage.hostServices.rawValue] = Self.now()
        try checkpoints.save(checkpoint)

        // iPhone pairing
        await presenter.heading("Pair your iPhone")
        let iphone = try await pairIPhone(loaded, checkpoint: checkpoint)
        summary.iphone = iphone
        if checkpoint.iphoneDeviceID != iphone.deviceID {
            checkpoint.iphoneDeviceID = iphone.deviceID
            checkpoint.reviewTestPassedAt = nil
        }
        checkpoint.completed[GuidedSetupStage.iphonePairing.rawValue] = Self.now()
        try checkpoints.save(checkpoint)

        // Review test
        await presenter.heading("Test a review")
        if try await runTest(.iphone, device: iphone, passedAt: checkpoint.reviewTestPassedAt) {
            checkpoint.reviewTestPassedAt = checkpoint.reviewTestPassedAt ?? Self.now()
            checkpoint.completed[GuidedSetupStage.reviewTest.rawValue] = Self.now()
            summary.reviewTestPassed = true
        }
        try checkpoints.save(checkpoint)

        // Optional Apple Watch
        if options.skipWatchSetup {
            summary.watch = try await currentWatch(loaded, behind: iphone) == nil ? "not configured" : "enrolled"
        } else {
            await presenter.heading("Apple Watch (optional)")
            summary.watch = try await watchStage(loaded, iphone: iphone, checkpoint: &checkpoint)
            try checkpoints.save(checkpoint)
        }

        // Optional remote alerts
        await presenter.heading("Remote alerts (optional)")
        summary.alerts = await alertsStage(loaded.installation.push)
        checkpoint.alerts = loaded.installation.push.enabled ? "existing" : "off"
        checkpoint.completed[GuidedSetupStage.alerts.rawValue] = Self.now()
        if summary.primaryComplete { checkpoint.completed[GuidedSetupStage.finish.rawValue] = Self.now() }
        try checkpoints.save(checkpoint)

        await finish(summary)
        return summary
    }

    // MARK: Stages

    private func hostServices(_ options: SetupOptions) async throws -> LoadedInstallation {
        if lifecycle.store.exists() {
            let existing = try lifecycle.store.load()
            if existing.installation.desiredState == .stopped {
                await presenter.say("Control services are stopped because you stopped them (shell-control down).")
                guard try await presenter.confirm("Start Control services?", defaultYes: false) else {
                    throw GuidedSetupStopped(description: "Control services were left stopped. Run the guide again, or shell-control up, when you want to continue.")
                }
                _ = try await lifecycle.up()
            }
            let status = await lifecycle.status()
            let sameRelease = (try? lifecycle.installer.validateBundle().releaseID) == existing.installation.releaseID
            let current = try lifecycle.store.load()
            if lifecycle.isReady(status), sameRelease, current.runtime.operation == nil,
               options.mode == nil || options.mode == existing.installation.addressMode,
               options.port == nil || options.port == existing.installation.port {
                await presenter.say("Control services are already running.")
                return try lifecycle.store.load()
            }
        }
        await presenter.say("Installing and starting Control services…")
        let loaded = try await lifecycle.setup(options)
        await presenter.say("Control services are running. Closing this guide does not stop them.")
        return loaded
    }

    private func persistence(_ loaded: LoadedInstallation) async throws -> LoadedInstallation {
        if loaded.installation.persistent {
            await presenter.say("Control services already start at login; that setting is kept.")
            return loaded
        }
        guard loaded.installation.addressMode == .tailscale else { return loaded }
        await presenter.say("Starting at login keeps Control running after you log out and back in. It cannot keep a sleeping or logged-out Mac reachable.")
        if try await presenter.confirm("Start Control services at login?", defaultYes: false) {
            try await lifecycle.installPersistence()
            return try lifecycle.store.load()
        }
        return loaded
    }

    private func pairIPhone(_ loaded: LoadedInstallation, checkpoint: GuidedSetupCheckpoint) async throws -> EnrolledDevice {
        let port = loaded.installation.port, secret = loaded.secrets.adminSecret
        let before = try await retrying("Reading enrolled devices") {
            try await admin.devices(port: port, adminSecret: secret)
        }.filter(\.isIPhone)
        if let existing = before.first(where: { $0.deviceID == checkpoint.iphoneDeviceID }) ?? before.first {
            await presenter.say("Paired iPhone: \(existing.label) (\(existing.deviceID)).")
            if !(try await presenter.confirm("Pair another iPhone?", defaultYes: false)) { return existing }
        }
        let known = Set(before.map(\.deviceID))
        while true {
            let invitation = try await retrying("Creating a pairing code") {
                try await lifecycle.pairingInvitation(admin: pairing)
            }
            try await presenter.showPairing(invitation)
            await presenter.say("On the iPhone open Shell → Settings → Control → Set up Control and scan this code, or paste the link. Waiting for the iPhone… (Ctrl+C stops the guide; nothing already set up is undone)")
            if let device = try await awaitEnrollment(loaded, watch: false, known: known, until: invitation.expiresAt.date) {
                await presenter.say("Paired \(device.label). Enrolled means confirmed; the setup test checks the live path.")
                return device
            }
            await presenter.say("That pairing code expired. Here is a new one.")
        }
    }

    /// Confirms pending enrollments of the wanted kind as the user approves
    /// them, until a new device of that kind is enrolled or `deadline`. A
    /// refused or failed poll (the broker rate-limits admin calls) backs off
    /// and retries instead of ending the guide.
    private func awaitEnrollment(_ loaded: LoadedInstallation, watch: Bool, known: Set<String>, until deadline: Date) async throws -> EnrolledDevice? {
        let port = loaded.installation.port, secret = loaded.secrets.adminSecret
        var asked = Set<String>()
        var interval = pollInterval
        var warned = false
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let enrolled = try await admin.devices(port: port, adminSecret: secret)
                if let new = enrolled.first(where: { (watch ? $0.isWatch : $0.isIPhone) && !known.contains($0.deviceID) }) {
                    return new
                }
                for item in try await admin.pending(port: port, adminSecret: secret) where item.isWatch == watch && !asked.contains(item.userCode) {
                    asked.insert(item.userCode)
                    try await offer(item, port: port, secret: secret, watch: watch)
                }
                interval = pollInterval
                warned = false
            } catch let error where Self.isCancellation(error) {
                throw error
            } catch {
                if !warned {
                    await presenter.say("The Mac's broker did not answer (\(error)); still waiting…")
                    warned = true
                }
                interval = min(interval * 2, .seconds(30))
            }
            try await Task.sleep(for: interval)
        }
        return nil
    }

    private func offer(_ item: PendingEnrollment, port: Int, secret: String, watch: Bool) async throws {
        let described = (try? await admin.describe(userCode: item.userCode, port: port, adminSecret: secret)) ?? item
        var lines = ["\(watch ? "Apple Watch" : "iPhone"): \(described.label)", "code: \(described.userCode)", "key fingerprint: \(described.fingerprint)"]
        if !described.requestedGrants.isEmpty { lines.append("permissions: \(described.requestedGrants.joined(separator: ", "))") }
        if let gateway = described.gateway { lines.append("via iPhone: \(gateway)") }
        if described.rebinding { lines.append("this re-binds a Watch enrolled through another iPhone") }
        await presenter.say(lines.joined(separator: "\n"))
        if try await presenter.confirm("Does this match the device? Approve it?", defaultYes: false) {
            try await retrying("Approving the device") {
                try await admin.confirm(userCode: described.userCode, port: port, adminSecret: secret)
            }
            await presenter.say("Approved; waiting for the device to finish.")
        } else {
            await presenter.say("Not approved.")
        }
    }

    /// Retries a broker call that failed for a transient reason, with
    /// backoff, before giving up.
    private func retrying<T: Sendable>(_ what: String, _ body: @Sendable () async throws -> T) async throws -> T {
        var interval = pollInterval
        for attempt in 1...4 {
            do { return try await body() } catch let error where Self.isCancellation(error) || attempt == 4 {
                throw error
            } catch {
                await presenter.say("\(what) failed (\(error)); retrying…")
                try await Task.sleep(for: interval)
                interval = min(interval * 2, .seconds(30))
            }
        }
        preconditionFailure("unreachable")
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || error is SignalCancellation
    }

    /// Runs the live setup test when the user asks. Returns whether it passed.
    private func runTest(_ reviewer: SetupReviewer, device: EnrolledDevice, passedAt: String?) async throws -> Bool {
        if let passedAt {
            await presenter.say("The setup test already passed with \(device.label) at \(passedAt).")
            if !(try await presenter.confirm("Run it again?", defaultYes: false)) { return true }
        }
        await presenter.say("The setup test sends \"\(SetupTestFixture.summary)\" to \(device.label). Approve it there. Nothing is executed.")
        while true {
            guard try await presenter.confirm("Send the setup test now?", defaultYes: true) else {
                await presenter.say("Skipped. Run shell-control test-review --reviewer \(reviewer.rawValue) --device-id \(device.deviceID) later.")
                return false
            }
            do {
                let result = try await reviewTest(reviewer, device)
                await presenter.say(result.description)
                if result.succeeded { return true }
            } catch let error where Self.isCancellation(error) {
                throw error
            } catch {
                // A daemon restart or a refused request is not the end of
                // setup: say what happened and offer the test again.
                await presenter.say("The setup test could not run: \(error)")
            }
        }
    }

    private func currentWatch(_ loaded: LoadedInstallation, behind iphone: EnrolledDevice) async throws -> EnrolledDevice? {
        try await retrying("Reading enrolled devices") {
            try await admin.devices(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
        }.first { $0.isWatch && $0.gatewayDeviceID == iphone.deviceID }
    }

    private func watchStage(_ loaded: LoadedInstallation, iphone: EnrolledDevice, checkpoint: inout GuidedSetupCheckpoint) async throws -> String {
        if let watch = try await currentWatch(loaded, behind: iphone) {
            await presenter.say("Apple Watch enrolled through \(iphone.label): \(watch.label).")
            // A pass belongs to the Watch that earned it, never to a
            // replacement enrolled under a new device ID.
            let previousPass = checkpoint.watchDeviceID == watch.deviceID ? checkpoint.watchTestPassedAt : nil
            checkpoint.watch = "configured"
            checkpoint.watchDeviceID = watch.deviceID
            checkpoint.watchTestPassedAt = previousPass
            if try await runTest(.watch, device: watch, passedAt: previousPass) {
                checkpoint.watchTestPassedAt = checkpoint.watchTestPassedAt ?? Self.now()
                checkpoint.completed[GuidedSetupStage.watch.rawValue] = Self.now()
                return "ready"
            }
            return "enrolled"
        }
        await presenter.say("Your iPhone is ready on its own. An Apple Watch can review glance-sized requests through it.")
        let answer = try await presenter.choose("Apple Watch:", [GuidedChoice("s", "skip for now"), GuidedChoice("w", "set up Apple Watch")])
        guard answer == "w" else {
            // Skipping never revokes a Watch; it only records the choice.
            checkpoint.watch = "skipped"
            await presenter.say("Skipped. Add it later from Settings → Control on the iPhone.")
            return "not configured"
        }
        await presenter.say("Open Shell on the Apple Watch. It asks your iPhone to enroll it; confirm its code here. The Watch keeps its own key and gets no Mac network credential.")
        let known = Set(try await retrying("Reading enrolled devices") {
            try await admin.devices(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
        }.map(\.deviceID))
        guard let watch = try await awaitEnrollment(loaded, watch: true, known: known,
                                                     until: Date().addingTimeInterval(TimeInterval(watchWait.components.seconds))) else {
            checkpoint.watch = "skipped"
            await presenter.say("No Watch enrolled yet. Nothing was changed; add it later from the iPhone.")
            return "not configured"
        }
        checkpoint.watch = "configured"
        checkpoint.watchDeviceID = watch.deviceID
        if try await runTest(.watch, device: watch, passedAt: nil) {
            checkpoint.watchTestPassedAt = Self.now()
            checkpoint.completed[GuidedSetupStage.watch.rawValue] = Self.now()
            return "ready"
        }
        return "enrolled"
    }

    private func alertsStage(_ push: PushConfiguration) async -> String {
        if push.enabled, let relay = push.relayURL {
            await presenter.say("Remote alerts use the configured push relay (\(URL(string: relay)?.host ?? "relay")). That setting is kept; delivery is not proven until an alert arrives.")
            return "configured"
        }
        if push.usesDirectAPNs {
            await presenter.say("Remote alerts use advanced direct-APNs credentials on this Mac (not a shared relay). That setting is kept.")
            return "configured"
        }
        await presenter.say("Remote alerts are off. Open Control and refresh to check for requests. Live review still requires a connection to your Mac.")
        return "off"
    }

    private func finish(_ summary: GuidedSetupSummary) async {
        await presenter.heading(summary.primaryComplete ? "Shell Control is ready" : "Setup paused")
        let review = summary.primaryComplete ? "ready (setup test passed)" : (summary.iphone == nil ? "not paired" : "paired; setup test not passed")
        await presenter.say("""
            Control review   \(review)
            Apple Watch      \(summary.watch)
            Remote alerts    \(summary.alerts)
            Services         running\(summary.persistent ? ", start at login" : "; not started at login")

            Check this Mac any time with shell-control doctor; check the iPhone in Settings → Control.
            Services keep running after this guide exits. Stop them with shell-control down.
            """)
    }

    static func now() -> String { ControlTimestamp(Date()).rfc3339 }
}

// MARK: - Preflight

extension LifecycleCoordinator {
    /// Read-only checks before guided setup changes anything
    /// (spec.control-companion-setup.md section 7.2).
    public func preflight(_ options: SetupOptions) async -> [DiagnosticCheck] {
        let now = ControlTimestamp(Date())
        func check(_ id: String, _ code: DiagnosticCode, _ state: DiagnosticState, required: Bool = true,
                   source: String, _ summary: String, action: DiagnosticAction? = nil) -> DiagnosticCheck {
            DiagnosticCheck(id: id, code: code, state: state, requiredFor: required ? [.host] : [], source: source,
                            observedAt: now, summary: summary, action: action)
        }
        var checks: [DiagnosticCheck] = []
        do {
            let manifest = try installer.validateBundle()
            checks.append(check("bundle", .bundleVerified, .pass, source: "release_manifest", "Verified Shell Control release \(manifest.releaseID)."))
        } catch {
            checks.append(check("bundle", .bundleUnverified, .fail, source: "release_manifest",
                                "This is not a verified native release bundle: \(error)"))
        }
        let existing = store.exists() ? try? store.load() : nil
        if store.exists(), existing == nil {
            checks.append(check("installation", .installationUnreadable, .fail, source: "installation_state",
                                "The existing installation could not be read; setup will not reset it."))
        } else if let existing {
            let stopped = existing.installation.desiredState == .stopped
            checks.append(check("installation", stopped ? .hostStoppedByUser : .installationPresent, stopped ? .warn : .pass, required: false,
                                source: "installation_state",
                                stopped ? "Existing installation, stopped by you. It stays stopped unless you choose to start it."
                                        : "Existing installation found; it will be reconciled, not replaced."))
        } else {
            checks.append(check("installation", .installationMissing, .pass, required: false, source: "installation_state",
                                "No installation yet; setup will create one."))
        }
        let mode = options.mode ?? existing?.installation.addressMode ?? .tailscale
        guard mode == .tailscale else {
            checks.append(check("route", .loopbackOnly, .warn, required: false, source: "options",
                                "Loopback mode is for the simulator; physical devices cannot reach it."))
            return checks
        }
        let path: String
        do {
            path = try TailscaleTools.resolve(explicit: options.tailscalePath ?? existing?.installation.tailscalePath)
        } catch {
            checks.append(check("tailscale", .tailscaleMissing, .fail, source: "tailscale_cli",
                                "Tailscale is not installed on this Mac. Install it, sign in, then retry.", action: .installTailscale))
            return checks
        }
        // Setup records the previous port as Shell's before changing it, so
        // preflight counts it as Shell's too.
        var owned = existing?.installation.ownedServePorts ?? []
        owned.insert(options.port ?? existing?.installation.port ?? 8443)
        checks += await tailnetEvidence(
            tailscale: path,
            recordedHost: existing?.installation.publicURL.flatMap { URL(string: $0)?.host },
            ownedPorts: owned,
            brokerPort: options.port ?? existing?.installation.port ?? 8443,
            expectServing: false,
            stopped: existing?.installation.desiredState == .stopped,
            now: now
        )
        return checks
    }
}
