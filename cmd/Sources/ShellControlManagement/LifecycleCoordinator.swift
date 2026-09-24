import Foundation
import CryptoKit
import Security
import ShellControlHostSupport
import ShellControlProtocol
import ShellControlSecurity

public struct SetupOptions: Sendable {
    public var mode: AddressMode?
    public var port: Int?
    public var tailscalePath: String?
    /// Explicitly replaces the origin signing key. Every paired iPhone and
    /// Watch must pair again afterwards.
    public var resetOriginKey: Bool
    public init(mode: AddressMode? = nil, port: Int? = nil, tailscalePath: String? = nil, resetOriginKey: Bool = false) {
        self.mode = mode; self.port = port; self.tailscalePath = tailscalePath; self.resetOriginKey = resetOriginKey
    }
}

public actor LifecycleCoordinator {
    public nonisolated let store: InstallationStore
    let manager: any ServiceManager
    let installer: NativeBundleInstaller
    private let home: URL
    let health: any ControlHealthChecking
    private let origins: any OriginProvisioning
    let tailnet: any TailnetRuntime
    private let readinessDeadline: Duration
    private let readinessPoll: Duration

    public init(
        store: InstallationStore,
        manager: any ServiceManager = LaunchdServiceManager(),
        installer: NativeBundleInstaller = NativeBundleInstaller(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        health: any ControlHealthChecking = LiveControlHealth(),
        origins: any OriginProvisioning = LiveOriginProvisioning(),
        tailnet: any TailnetRuntime = LiveTailnetRuntime(),
        readinessDeadline: Duration = .seconds(60),
        readinessPoll: Duration = .milliseconds(200)
    ) {
        self.store = store
        self.manager = manager
        self.installer = installer
        self.home = home
        self.health = health
        self.origins = origins
        self.tailnet = tailnet
        self.readinessDeadline = readinessDeadline
        self.readinessPoll = readinessPoll
    }

    public func setup(_ options: SetupOptions) async throws -> LoadedInstallation {
        if let port = options.port, !(1...65535).contains(port) { throw ManagementError.invalid("port must be between 1 and 65535") }
        let manifest = try installer.validateBundle()
        let existing: LoadedInstallation? = store.exists() ? try store.load() : nil
        let mode = options.mode ?? existing?.installation.addressMode ?? .tailscale
        if mode == .loopback, options.tailscalePath != nil {
            throw ManagementError.invalid("loopback mode does not use Tailscale")
        }
        let tailscale = mode == .tailscale
            ? try TailscaleTools.resolve(explicit: options.tailscalePath ?? existing?.installation.tailscalePath)
            : nil
        let port = options.port ?? existing?.installation.port ?? 8443
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded: LoadedInstallation
        if store.exists() {
            loaded = try store.load()
            if loaded.installation.addressMode == .tailscale, loaded.installation.port != port || loaded.installation.servePorts == nil {
                // Serve may still point at the previous port, including on an
                // installation from before ports were recorded.
                loaded.installation.noteServePort(loaded.installation.port)
            }
            loaded.installation.addressMode = mode
            loaded.installation.port = port
            loaded.installation.tailscalePath = tailscale
            loaded.installation.releaseID = manifest.releaseID
        } else {
            loaded = try store.create(releaseID: manifest.releaseID, mode: mode, publicURL: nil, port: port)
            loaded.installation.tailscalePath = tailscale
        }
        // Loopback's route is derived from the port; tailscale's from MagicDNS
        // when the services start.
        loaded.installation.publicURL = mode == .loopback ? ControlLoopback.url(port: port) : existing?.installation.publicURL.flatMap {
            try? AddressPolicy.validate($0, mode: .tailscale)
        }
        if options.resetOriginKey { try resetOriginIdentity(&loaded) }
        try await reconcileIncompleteOperation(&loaded)
        try await removeLegacyTunnel(loaded)
        if loaded.installation.desiredState == .stopped {
            try store.save(loaded.installation)
            throw ManagementError.unavailable("installation is stopped; setup preserved stopped intent — run shell-control up")
        }
        let binaries = try installer.install(manifest)
        try store.save(loaded.installation)
        if let previous = existing?.installation, previous.addressMode == .tailscale, mode != .tailscale,
           let path = previous.tailscalePath {
            // Leaving the tailnet profile withdraws the Serve handler it owned
            // — only that one, and never another app's configuration.
            await withdrawOwnedServe(previous, tailscale: path)
        }
        return try await start(&loaded, binaries: binaries)
    }

    public func up() async throws -> LoadedInstallation {
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded = try store.load()
        try await reconcileIncompleteOperation(&loaded)
        let manifest = try installer.validateBundle()
        guard manifest.releaseID == loaded.installation.releaseID else {
            throw ManagementError.unsupported("installed release differs from the invoking CLI; run setup to reconcile")
        }
        let binaries = try installer.install(manifest)
        loaded.installation.desiredState = .running
        try store.save(loaded.installation)
        return try await start(&loaded, binaries: binaries)
    }

    public func down() async throws {
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded = try store.load()
        loaded.installation.desiredState = .stopped
        try store.save(loaded.installation)
        loaded.runtime.generation += 1
        loaded.runtime.operation = ManagementOperation(command: "down", plan: Component.allCases.map(\.rawValue))
        try store.save(loaded.runtime)
        var failures: [String] = []
        for component in [Component.daemon, .broker] {
            let label = label(component, loaded.installation.installationID)
            do { try await manager.disable(label: label) } catch { failures.append("disable \(component.rawValue): \(error)") }
            do { try await manager.stop(label: label) } catch { failures.append("stop \(component.rawValue): \(error)") }
        }
        for component in Component.allCases {
            let observation = await manager.observe(label: label(component, loaded.installation.installationID))
            if observation.reason?.hasPrefix("launchctl observation failed:") == true {
                failures.append("\(component.rawValue) absence is unverified: \(observation.reason!)")
            }
            if observation.loaded || observation.pid != nil { failures.append("\(component.rawValue) is still loaded") }
            if observation.enabled { failures.append("\(component.rawValue) is not durably disabled") }
        }
        guard failures.isEmpty else { throw ManagementError.unavailable(failures.joined(separator: "; ")) }
        loaded.runtime.operation = nil; try store.save(loaded.runtime)
    }

    public func restart(_ selection: [Component]) async throws {
        guard !selection.isEmpty else { throw ManagementError.invalid("select a component to restart") }
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded = try store.load()
        try await reconcileIncompleteOperation(&loaded)
        guard loaded.installation.desiredState == .running else { throw ManagementError.unavailable("installation is stopped; run up first") }
        let manifest = try installer.validateBundle()
        guard manifest.releaseID == loaded.installation.releaseID else { throw ManagementError.unsupported("release integrity mismatch") }
        let binaries = try installer.install(manifest)
        for component in selection {
            try await manager.restart(try serviceSpec(component, loaded: loaded, binaries: binaries))
        }
        let status = await status(loaded: loaded)
        guard isReady(status) else { throw ManagementError.unavailable("restart completed but the control path is degraded") }
    }

    public func installPersistence() async throws {
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded = try store.load()
        try await reconcileIncompleteOperation(&loaded)
        guard loaded.installation.addressMode == .tailscale, loaded.installation.publicURL?.hasPrefix("https://") == true else {
            throw ManagementError.invalid("login persistence requires tailscale mode with its HTTPS route")
        }
        let manifest = try installer.validateBundle()
        guard manifest.releaseID == loaded.installation.releaseID else { throw ManagementError.unsupported("release integrity mismatch; run setup first") }
        let binaries = try installer.install(manifest)
        loaded.installation.persistent = true; try store.save(loaded.installation)
        for component in Component.allCases {
            let spec = try serviceSpec(component, loaded: loaded, binaries: binaries)
            try await manager.install(spec, persistent: true, start: loaded.installation.desiredState == .running)
        }
    }

    public func uninstallPersistence() async throws {
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded = try store.load()
        try await reconcileIncompleteOperation(&loaded)
        let manifest = try installer.validateBundle()
        guard manifest.releaseID == loaded.installation.releaseID else { throw ManagementError.unsupported("release integrity mismatch; run setup first") }
        let binaries = try installer.install(manifest)
        for component in Component.allCases {
            try await manager.removePersistence(try serviceSpec(component, loaded: loaded, binaries: binaries))
        }
        loaded.installation.persistent = false; try store.save(loaded.installation)
    }

    public func configurePush(keyID: String, teamID: String, keyFile: String, topics: [String]) async throws {
        let identifier = try NSRegularExpression(pattern: #"^[A-Z0-9]{10}$"#)
        func validIdentifier(_ value: String) -> Bool { identifier.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil }
        guard validIdentifier(keyID), validIdentifier(teamID), !topics.isEmpty,
              topics.allSatisfy({ !$0.isEmpty && $0.count <= 255 && !$0.contains(where: { $0.isWhitespace || $0.isNewline }) }) else {
            throw ManagementError.invalid("complete APNs key id, team id, and valid allowed topics are required")
        }
        try SecureFileSystem.validateAbsolute(keyFile); try SecureFileSystem.validateOwnedPath(keyFile, type: .typeRegular)
        let pem = try String(contentsOfFile: keyFile, encoding: .utf8)
        do { _ = try P256.Signing.PrivateKey(pemRepresentation: pem) } catch { throw ManagementError.invalid("APNs key is not a valid P-256 PKCS#8 private key") }
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded = try store.load()
        try await reconcileIncompleteOperation(&loaded)
        let destination = loaded.paths.credentials.appendingPathComponent("apns.p8")
        try SecureFileSystem.atomicWrite(Data(pem.utf8), to: destination)
        loaded.installation.push = PushConfiguration(enabled: true, keyID: keyID, teamID: teamID,
                                                     keyPath: destination.path, topics: topics,
                                                     relayURL: loaded.installation.push.relayURL)
        try store.save(loaded.installation)
        try writeServiceConfigurations(loaded)
        try await applyBrokerConfiguration(loaded)
    }

    /// Sends approval hints through the stateless Shell Push Relay. The Mac
    /// holds no APNs credential in this configuration
    /// (spec.iphone-gateway.md section 16).
    public func configurePushRelay(url: String) async throws {
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil,
              parsed.user == nil, parsed.query == nil, parsed.fragment == nil else {
            throw ManagementError.invalid("--relay-url must be an https URL")
        }
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded = try store.load()
        try await reconcileIncompleteOperation(&loaded)
        loaded.installation.push.relayURL = parsed.absoluteString
        loaded.installation.push.enabled = true
        try store.save(loaded.installation)
        try writeServiceConfigurations(loaded)
        try await applyBrokerConfiguration(loaded)
    }

    public func disablePush() async throws {
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded = try store.load()
        try await reconcileIncompleteOperation(&loaded)
        loaded.installation.push = PushConfiguration(); try store.save(loaded.installation)
        try writeServiceConfigurations(loaded)
        try await applyBrokerConfiguration(loaded)
        let key = loaded.paths.credentials.appendingPathComponent("apns.p8")
        if FileManager.default.fileExists(atPath: key.path) { try SecureFileSystem.validateOwnedPath(key.path, type: .typeRegular); try FileManager.default.removeItem(at: key) }
    }

    public func status() async -> ManagementStatus {
        guard store.exists() else {
            let stamp = timestamp(), absent = ComponentObservation(state: "stopped", checkedAt: stamp, reason: "not installed")
            return ManagementStatus(overall: "unavailable", readinessScope: "none", desiredState: "stopped",
                                    persistent: false, publicURL: nil,
                                    components: ["broker": absent, "daemon": absent,
                                                 "public_route": absent, "push": .init(state: "not_configured", checkedAt: stamp, reason: "push is disabled")])
        }
        do { return await status(loaded: try store.load()) } catch {
            let stamp = timestamp(), failed = ComponentObservation(state: "not_ready", checkedAt: stamp, reason: String(describing: error))
            return ManagementStatus(overall: "unavailable", readinessScope: "unknown", desiredState: "unknown",
                                    persistent: false, publicURL: nil, components: ["installation": failed])
        }
    }

    public nonisolated func isReady(_ status: ManagementStatus) -> Bool { status.overall == "ready" }

    private func reconcileIncompleteOperation(_ loaded: inout LoadedInstallation) async throws {
        guard let operation = loaded.runtime.operation else { return }
        note("reconciling incomplete native operation \(operation.id.uuidString.lowercased())\n")
        let components = loaded.installation.desiredState == .stopped ? Component.allCases : operation.createdResources
        for component in components {
            let ownedLabel = label(component, loaded.installation.installationID)
            let observation = await manager.observe(label: ownedLabel)
            if observation.reason?.hasPrefix("launchctl observation failed:") == true {
                throw ManagementError.unavailable("cannot reconcile \(ownedLabel): \(observation.reason!)")
            }
            if loaded.installation.desiredState == .stopped {
                if observation.enabled { try await manager.disable(label: ownedLabel) }
                if observation.loaded { try await manager.stop(label: ownedLabel) }
            }
        }
        if loaded.installation.desiredState == .stopped {
            loaded.runtime.operation = nil; try store.save(loaded.runtime)
        }
    }

    private func start(_ loaded: inout LoadedInstallation, binaries: InstalledBinaries) async throws -> LoadedInstallation {
        var operation = ManagementOperation(command: "start", plan: ["route", "broker", "origin", "daemon", "serve", "readiness"])
        loaded.runtime.generation += 1
        loaded.runtime.operation = operation
        try store.save(loaded.runtime)
        var localCommitted = false
        do {
            if loaded.installation.addressMode == .tailscale { try await refreshTailnetRoute(&loaded) }
            try ensureOriginIdentity(&loaded)
            try writeServiceConfigurations(loaded)
            try await startBroker(&loaded, binaries: binaries, operation: &operation)
            let expectedIdentity = serviceIdentity(loaded.installation.installationID)
            try await waitUntil {
                (await health.broker(
                    url: URL(string: ControlLoopback.url(port: loaded.installation.port))!,
                    expectedIdentity: expectedIdentity
                )).state == "ready"
            }
            try await provisionOriginIfNeeded(&loaded)
            try await startDaemon(&loaded, binaries: binaries, operation: &operation)
            localCommitted = true
            if loaded.installation.addressMode == .tailscale { try await configureServe(&loaded) }
            do {
                try await waitUntil { self.isReady(await self.status(loaded: loaded)) }
            } catch {
                throw ManagementError.unavailable("local services committed, but the configured control route is degraded: \(error)")
            }
            loaded.runtime.operation = nil
            try store.save(loaded.runtime)
            return loaded
        } catch {
            if !localCommitted {
                for component in operation.createdResources.reversed() {
                    let ownedLabel = label(component, loaded.installation.installationID)
                    try? await manager.disable(label: ownedLabel)
                    try? await manager.stop(label: ownedLabel)
                }
            }
            throw error
        }
    }

    private func note(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
    }

    private func recordCreated(_ operation: inout ManagementOperation, loaded: inout LoadedInstallation, _ component: Component) throws {
        operation.createdResources.append(component)
        loaded.runtime.operation = operation
        try store.save(loaded.runtime)
    }

    private func startBroker(_ loaded: inout LoadedInstallation, binaries: InstalledBinaries,
                             operation: inout ManagementOperation) async throws {
        let spec = try serviceSpec(.broker, loaded: loaded, binaries: binaries)
        let before = await manager.observe(label: spec.label)
        if !before.registered { try recordCreated(&operation, loaded: &loaded, .broker) }
        try await manager.install(spec, persistent: loaded.installation.persistent, start: true)
    }

    /// Releases before the iPhone-gateway profile could own a cloudflared
    /// launchd job and its files. They are withdrawn, never adopted.
    private func removeLegacyTunnel(_ loaded: LoadedInstallation) async throws {
        let legacy = "dev.chr33s.shell.control.\(loaded.installation.installationID.uuidString.lowercased()).tunnel"
        let observation = await manager.observe(label: legacy)
        var removed = false
        if observation.registered || observation.loaded || observation.enabled {
            try? await manager.disable(label: legacy)
            try? await manager.stop(label: legacy)
            removed = true
        }
        let files = [
            home.appendingPathComponent("Library/LaunchAgents/\(legacy).plist"),
            loaded.paths.launchd.appendingPathComponent("\(legacy).plist"),
            loaded.paths.credentials.appendingPathComponent("tunnel.json"),
            loaded.paths.services.appendingPathComponent("tunnel.yml"),
            loaded.paths.logs.appendingPathComponent("tunnel.transport.log")
        ]
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            try SecureFileSystem.validateOwnedPath(url.path, type: .typeRegular)
            try FileManager.default.removeItem(at: url)
            removed = true
        }
        if removed { note("removed the legacy Cloudflare tunnel; this Mac is now reached over Tailscale only\n") }
    }

    private func provisionOriginIfNeeded(_ loaded: inout LoadedInstallation) async throws {
        let provisioned = loaded.secrets.originProvisioned ?? (loaded.secrets.originID != nil)
        guard !provisioned, let originID = loaded.secrets.originID, let secret = loaded.secrets.originSecret else { return }
        try await origins.provisionOrigin(
            port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret,
            label: Host.current().localizedName ?? "Mac",
            originID: originID, originSecret: secret
        )
        loaded.secrets.originProvisioned = true
        try store.save(loaded.secrets)
    }

    /// The origin ID and its signing key exist before the broker starts, so
    /// the broker can prove the identity the setup QR pins
    /// (spec.iphone-gateway.md section 7.1). A key that disappears after it
    /// was recorded is never silently regenerated.
    private func ensureOriginIdentity(_ loaded: inout LoadedInstallation) throws {
        if loaded.secrets.originID == nil {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw ManagementError.unavailable("secure random generation failed")
            }
            loaded.secrets.originID = UUID()
            loaded.secrets.originSecret = bytes.map { String(format: "%02x", $0) }.joined()
            loaded.secrets.originProvisioned = false
            try store.save(loaded.secrets)
        }
        let keyURL = loaded.paths.originKey
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let key = try OriginKeyFile.load(keyURL)
            let fingerprint = OriginIdentity.fingerprint(of: key.publicJWK)
            if let recorded = loaded.secrets.originKeyFingerprint, recorded != fingerprint {
                throw ManagementError.corrupt("origin signing key does not match the recorded fingerprint \(recorded); refusing to change Shell trust — rerun setup with --reset-origin-key to re-pair every device")
            }
            if loaded.secrets.originKeyFingerprint == nil {
                loaded.secrets.originKeyFingerprint = fingerprint
                try store.save(loaded.secrets)
            }
            return
        }
        if let recorded = loaded.secrets.originKeyFingerprint {
            throw ManagementError.corrupt("origin signing key \(recorded) is missing; refusing to mint a new Shell identity — rerun setup with --reset-origin-key to re-pair every device")
        }
        let key = OriginSigningKey()
        try OriginKeyFile.write(key, to: keyURL)
        loaded.secrets.originKeyFingerprint = OriginIdentity.fingerprint(of: key.publicJWK)
        try store.save(loaded.secrets)
        note("created Shell origin signing key \(loaded.secrets.originKeyFingerprint!)\n")
    }

    private func resetOriginIdentity(_ loaded: inout LoadedInstallation) throws {
        let keyURL = loaded.paths.originKey
        if FileManager.default.fileExists(atPath: keyURL.path) {
            try SecureFileSystem.validateOwnedPath(keyURL.path, type: .typeRegular)
            try FileManager.default.removeItem(at: keyURL)
        }
        loaded.secrets.originKeyFingerprint = nil
        try store.save(loaded.secrets)
        note("origin signing key reset: every iPhone and Watch must pair again\n")
    }

    /// Re-reads this Mac's MagicDNS name. A changed name is a route change,
    /// never a trust change (spec.iphone-gateway.md sections 7.5 and 24).
    private func refreshTailnetRoute(_ loaded: inout LoadedInstallation) async throws {
        let path = try tailscalePath(loaded.installation)
        note("Checking Tailscale...\n")
        let name = try TailscaleTools.requireReady(try await tailnet.status(tailscale: path))
        note("  connected\n  MagicDNS: available\n")
        let url = try AddressPolicy.validate("https://\(name)", mode: .tailscale)
        if let previous = loaded.installation.publicURL, previous != url {
            note("Tailscale route changed from \(previous) to \(url); Shell trust is unchanged — run `shell-control route` to show the signed route update\n")
        }
        if loaded.installation.publicURL != url {
            loaded.installation.publicURL = url
            try store.save(loaded.installation)
        }
    }

    /// Configures Tailscale Serve and then validates the resulting state
    /// rather than trusting the CLI's exit status
    /// (spec.iphone-gateway.md section 4.4).
    private func configureServe(_ loaded: inout LoadedInstallation) async throws {
        let path = try tailscalePath(loaded.installation)
        guard let host = loaded.installation.publicURL.flatMap({ URL(string: $0)?.host }) else {
            throw ManagementError.unavailable("tailscale route is not known")
        }
        var state = try await tailnet.serveStatus(tailscale: path)
        guard !state.isFunnelled(host: host) else {
            throw ManagementError.unavailable("serve_public_exposure: Tailscale Funnel is enabled for https://\(host); the broker must not be public — run `tailscale funnel 443 off`")
        }
        if case .conflict(let reason) = state.ownership(host: host, ownedPorts: loaded.installation.ownedServePorts) {
            // Another application owns the endpoint: stop before replacing it
            // (spec.control-companion-setup.md section 7.3).
            throw ManagementError.unavailable("serve_conflict: \(reason); Shell did not change it — move that handler or free HTTPS 443, then rerun setup")
        }
        if !state.servesBroker(host: host, port: loaded.installation.port) {
            // Recorded before Serve changes, so a failure after this point
            // never leaves Shell's own handler looking like another app's.
            loaded.installation.noteServePort(loaded.installation.port)
            try store.save(loaded.installation)
            try await tailnet.configureServe(tailscale: path, port: loaded.installation.port)
            state = try await tailnet.serveStatus(tailscale: path)
        }
        guard state.servesBroker(host: host, port: loaded.installation.port) else {
            throw ManagementError.unavailable("Tailscale Serve is not proxying https://\(host) to the loopback broker")
        }
        guard !state.isFunnelled(host: host) else {
            throw ManagementError.unavailable("Tailscale Funnel is enabled for https://\(host); the broker must not be public — run `tailscale funnel 443 off`")
        }
        if loaded.installation.servePorts != [loaded.installation.port] {
            loaded.installation.servePorts = [loaded.installation.port]
            try store.save(loaded.installation)
        }
        note("Configuring private HTTPS...\n  https://\(host)\n  Tailscale Serve: active\n")
    }

    /// Removes Shell's Serve handler if — and only if — Shell owns it. Other
    /// apps' mounts on HTTPS 443 are kept by removing only the `/` mount, and
    /// the result is checked rather than assumed.
    private func withdrawOwnedServe(_ installation: Installation, tailscale path: String) async {
        guard let host = installation.publicURL.flatMap({ URL(string: $0)?.host }) else { return }
        let manual = "check `tailscale serve status` and remove Shell's https://\(host)/ handler, or the loopback broker stays reachable from the tailnet"
        let state: ServeState
        do { state = try await tailnet.serveStatus(tailscale: path) } catch {
            note("Tailscale Serve status could not be read (\(error)); \(manual)\n")
            return
        }
        guard case .shell = state.ownership(host: host, ownedPorts: installation.ownedServePorts) else { return }
        let shared = !(state.otherMounts["\(host.lowercased()):443"] ?? []).isEmpty
        do {
            try await tailnet.disableServe(tailscale: path, rootOnly: shared)
            let after = try await tailnet.serveStatus(tailscale: path)
            if case .shell = after.ownership(host: host, ownedPorts: installation.ownedServePorts) {
                note("Shell's Tailscale Serve handler is still present; \(manual)\n")
            }
        } catch {
            note("Removing Shell's Tailscale Serve handler failed (\(error)); \(manual)\n")
        }
    }

    func tailscalePath(_ installation: Installation) throws -> String {
        guard let path = installation.tailscalePath else { throw ManagementError.corrupt("tailscale mode is missing tailscale_path") }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ManagementError.unavailable("the Tailscale CLI moved or was removed: \(path); rerun setup")
        }
        return path
    }

    private func startDaemon(_ loaded: inout LoadedInstallation, binaries: InstalledBinaries,
                             operation: inout ManagementOperation) async throws {
        let daemon = try serviceSpec(.daemon, loaded: loaded, binaries: binaries)
        let daemonBefore = await manager.observe(label: daemon.label)
        if !daemonBefore.registered { try recordCreated(&operation, loaded: &loaded, .daemon) }
        try await manager.install(daemon, persistent: loaded.installation.persistent, start: true)
        try await waitUntil { (await health.daemon(path: loaded.paths.healthSocket.path)).state == "ready" }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + readinessDeadline
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if await predicate() { return }
            try await Task.sleep(for: readinessPoll)
        }
        throw ManagementError.unavailable("service readiness deadline exceeded")
    }

    func status(loaded: LoadedInstallation) async -> ManagementStatus {
        let stamp = timestamp(), id = loaded.installation.installationID
        async let brokerJob = manager.observe(label: label(.broker, id)); async let daemonJob = manager.observe(label: label(.daemon, id))
        async let brokerHealth = health.broker(url: URL(string: ControlLoopback.url(port: loaded.installation.port))!, expectedIdentity: serviceIdentity(id))
        async let daemonHealth = health.daemon(path: loaded.paths.healthSocket.path)
        let bj = await brokerJob, dj = await daemonJob, bh = await brokerHealth, dh = await daemonHealth
        var broker = bh; broker.pid = bj.pid; if !bj.loaded { broker.state = bj.enabled ? "stopped" : "disabled"; broker.reason = bj.reason }
        var daemon = dh; daemon.pid = dj.pid; if !dj.loaded { daemon.state = dj.enabled ? "stopped" : "disabled"; daemon.reason = dj.reason }
        let tailnetComponents = loaded.installation.addressMode == .tailscale ? await tailnetObservations(loaded, stamp: stamp) : [:]
        let publicRoute: ComponentObservation
        if loaded.installation.addressMode == .loopback { publicRoute = broker } else if let text = loaded.installation.publicURL, let url = URL(string: text) { publicRoute = await health.broker(url: url, expectedIdentity: serviceIdentity(id)) } else { publicRoute = .init(state: "not_ready", checkedAt: stamp, reason: "public origin is not configured") }
        let pushConfig = loaded.installation.push
        let push = ComponentObservation(
            state: pushConfig.enabled ? "configured" : "not_configured", checkedAt: stamp,
            reason: pushConfig.relayURL.map { "push relay \($0); delivery is not proven" }
                ?? (pushConfig.enabled ? "provider credentials present; delivery is not proven" : "push is disabled")
        )
        let localReady = broker.state == "ready" && daemon.state == "ready"
        // In tailscale mode readiness is the validated Serve state plus a
        // connected tailnet (spec.iphone-gateway.md 4.4); the Mac's HTTPS probe
        // of its own Serve name is reported but can fail on some Tailscale
        // clients without the phone's route being affected.
        let routeReady = loaded.installation.addressMode == .loopback
            || (tailnetComponents["tailscale"]?.state == "connected" && tailnetComponents["serve"]?.state == "active")
        let overall = loaded.installation.desiredState == .stopped ? "stopped" : (localReady && routeReady ? "ready" : (localReady ? "degraded" : "unavailable"))
        var components = ["broker": broker, "daemon": daemon, "public_route": publicRoute, "push": push]
        components.merge(tailnetComponents) { _, new in new }
        if let fingerprint = loaded.secrets.originKeyFingerprint, let originID = loaded.secrets.originID {
            components["origin"] = .init(state: "ready", checkedAt: stamp, reason: "\(originID.uuidString.lowercased()) \(fingerprint)")
        }
        if let operation = loaded.runtime.operation {
            components["management_operation"] = .init(state: "reconciling", checkedAt: stamp,
                                                        reason: "\(operation.command) operation \(operation.id.uuidString.lowercased()) is incomplete")
        }
        var result = ManagementStatus(overall: overall, readinessScope: loaded.installation.addressMode == .loopback ? "local" : "remote",
                                      desiredState: loaded.installation.desiredState.rawValue, persistent: loaded.installation.persistent,
                                      publicURL: loaded.installation.publicURL, components: components)
        if let originID = loaded.secrets.originID, let fingerprint = loaded.secrets.originKeyFingerprint {
            result.origin = .init(originID: originID.uuidString.lowercased(), fingerprint: fingerprint)
        }
        if broker.state == "ready" {
            result.enrollment = await health.enrollment(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
        }
        return result
    }

    private func tailnetObservations(_ loaded: LoadedInstallation, stamp: String) async -> [String: ComponentObservation] {
        guard let path = try? tailscalePath(loaded.installation) else {
            let missing = ComponentObservation(state: "not_ready", checkedAt: stamp, reason: "Tailscale CLI unavailable")
            return ["tailscale": missing, "serve": missing]
        }
        let tailscale: ComponentObservation
        do {
            let status = try await tailnet.status(tailscale: path)
            tailscale = status.isConnected
                ? .init(state: "connected", checkedAt: stamp, reason: status.magicDNSEnabled ? "MagicDNS available" : "MagicDNS unavailable", mode: "tailscale")
                : .init(state: "not_connected", checkedAt: stamp, reason: "backend \(status.backendState); run `tailscale up`", mode: "tailscale")
        } catch {
            tailscale = .init(state: "not_ready", checkedAt: stamp, reason: String(describing: error))
        }
        let serve: ComponentObservation
        if let host = loaded.installation.publicURL.flatMap({ URL(string: $0)?.host }),
           let state = try? await tailnet.serveStatus(tailscale: path) {
            if state.isFunnelled(host: host) {
                serve = .init(state: "public", checkedAt: stamp, reason: "Tailscale Funnel exposes the broker; disable it")
            } else if state.servesBroker(host: host, port: loaded.installation.port) {
                serve = .init(state: "active", checkedAt: stamp, reason: "https://\(host) → 127.0.0.1:\(loaded.installation.port)")
            } else {
                serve = .init(state: "not_configured", checkedAt: stamp, reason: "run `shell-control up` to configure Tailscale Serve")
            }
        } else {
            serve = .init(state: "not_ready", checkedAt: stamp, reason: "Tailscale Serve status unavailable")
        }
        return ["tailscale": tailscale, "serve": serve]
    }

    // MARK: Pairing, routes, and devices

    public func originIdentity() throws -> (identity: OriginIdentity, key: OriginSigningKey) {
        try originIdentity(try store.load())
    }

    private func originIdentity(_ loaded: LoadedInstallation) throws -> (identity: OriginIdentity, key: OriginSigningKey) {
        guard let uuid = loaded.secrets.originID else {
            throw ManagementError.unavailable("the Shell origin is not provisioned yet — run shell-control setup")
        }
        let originID = ControlID(uuid)
        let key = try OriginKeyFile.load(loaded.paths.originKey)
        return (OriginIdentity(originID: originID, publicJWK: key.publicJWK), key)
    }

    /// Mints a one-use pairing on the running broker and builds the setup QR
    /// payload around the pinned origin identity (spec.iphone-gateway.md 9.1).
    public func pairingInvitation(admin: any PairingAdministration = LivePairingAdministration()) async throws -> PairingInvitation {
        let loaded = try store.load()
        guard let routeText = loaded.installation.publicURL else {
            throw ManagementError.unavailable("the control route is not known yet — run shell-control up")
        }
        let route = try OriginRoute(routeText)
        let origin = try originIdentity(loaded)
        let minted = try await admin.createPairing(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
        return try PairingInvitation(origin: origin.identity, route: route, pairingID: minted.pairingID,
                                     pairingSecret: minted.secret, expiresAt: minted.expiresAt)
    }

    /// The origin-signed route update for the current route. It changes no
    /// trust state (spec.iphone-gateway.md section 25.3).
    public func routeUpdate() throws -> OriginRouteUpdate {
        let loaded = try store.load()
        guard let routeText = loaded.installation.publicURL else {
            throw ManagementError.unavailable("the control route is not known yet — run shell-control up")
        }
        let origin = try originIdentity(loaded)
        return try OriginRouteUpdate.sign(originID: origin.identity.originID, route: try OriginRoute(routeText),
                                          issuedAt: ControlTimestamp(Date()), key: origin.key)
    }

    private func applyBrokerConfiguration(_ loaded: LoadedInstallation) async throws {
        guard loaded.installation.desiredState == .running else { return }
        let manifest = try installer.validateBundle()
        guard manifest.releaseID == loaded.installation.releaseID else { throw ManagementError.unsupported("release integrity mismatch") }
        let binaries = try installer.install(manifest)
        try await manager.restart(try serviceSpec(.broker, loaded: loaded, binaries: binaries))
        let identity = serviceIdentity(loaded.installation.installationID)
        try await waitUntil { (await health.broker(url: URL(string: ControlLoopback.url(port: loaded.installation.port))!, expectedIdentity: identity)).state == "ready" }
    }

    private func writeServiceConfigurations(_ loaded: LoadedInstallation) throws {
        let push = loaded.installation.push
        let broker: [String: Any] = ["port": loaded.installation.port, "bind_loopback": true,
            "state_path": loaded.paths.brokerLedger.path, "state_directory": loaded.paths.root.path,
            "account_id": loaded.secrets.accountID.uuidString.lowercased(), "admin_secret": loaded.secrets.adminSecret,
            "cursor_secret": loaded.secrets.cursorSecret,
            "verification_uri": (loaded.installation.publicURL.map { "\($0)/v1/oauth/confirm" } ?? ""),
            "identity": serviceIdentity(loaded.installation.installationID),
            "apns_topics": push.usesDirectAPNs ? push.topics.joined(separator: ",") : "",
            "apns_key_id": push.usesDirectAPNs ? push.keyID! : "", "apns_team_id": push.usesDirectAPNs ? push.teamID! : "",
            "apns_key_file": push.usesDirectAPNs ? push.keyPath! : "",
            "push_relay_url": push.enabled ? (push.relayURL ?? "") : "",
            "origin_id": loaded.secrets.originID?.uuidString.lowercased() ?? "",
            "origin_key_file": FileManager.default.fileExists(atPath: loaded.paths.originKey.path) ? loaded.paths.originKey.path : "",
            // The key file path never changes, so the fingerprint is what makes
            // a replaced key change this file, and with it the job's config
            // generation: the broker restarts and loads the new key.
            "origin_key_fingerprint": loaded.secrets.originKeyFingerprint ?? ""]
        let daemon: [String: Any] = ["broker_url": ControlLoopback.url(port: loaded.installation.port),
            "origin_id": loaded.secrets.originID?.uuidString.lowercased() ?? "", "origin_secret": loaded.secrets.originSecret ?? "",
            "state_directory": loaded.paths.root.path, "socket_path": loaded.paths.controlSocket.path,
            "health_socket_path": loaded.paths.healthSocket.path, "journal_path": loaded.paths.journal.path]
        try writeJSONIfChanged(broker, loaded.paths.services.appendingPathComponent("broker.json"))
        try writeJSONIfChanged(daemon, loaded.paths.services.appendingPathComponent("daemon.json"))
    }

    private func writeJSONIfChanged(_ object: Any, _ url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]); data.append(0x0a)
        if (try? Data(contentsOf: url)) == data { return }
        try SecureFileSystem.atomicWrite(data, to: url)
    }

    private func serviceSpec(_ component: Component, loaded: LoadedInstallation, binaries: InstalledBinaries) throws -> JobSpec {
        let (executable, config): (String, URL) = switch component {
        case .broker: (binaries.broker.path, loaded.paths.services.appendingPathComponent("broker.json"))
        case .daemon: (binaries.daemon.path, loaded.paths.services.appendingPathComponent("daemon.json"))
        }
        let generation = SHA256.hash(data: try Data(contentsOf: config)).map { String(format: "%02x", $0) }.joined()
        return JobSpec(component: component, installationID: loaded.installation.installationID,
                       executable: executable, arguments: ["--config", config.path], workingDirectory: loaded.paths.root.path,
                       stdoutPath: loaded.paths.logs.appendingPathComponent("\(component.rawValue).out.log").path,
                       stderrPath: loaded.paths.logs.appendingPathComponent("\(component.rawValue).err.log").path,
                       keepAlive: true, environment: ["SHELL_CONTROL_CONFIG_GENERATION": generation],
                       sessionPlistDirectory: loaded.paths.launchd.path,
                       launchAgentsDirectory: home.appendingPathComponent("Library/LaunchAgents").path)
    }

    func label(_ component: Component, _ id: UUID) -> String { "dev.chr33s.shell.control.\(id.uuidString.lowercased()).\(component.rawValue)" }
    func serviceIdentity(_ id: UUID) -> String { "shell-control:\(id.uuidString.lowercased())" }
    private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
