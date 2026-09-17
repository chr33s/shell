import Foundation
import CryptoKit
import Security
import ShellControlHostSupport

public struct SetupOptions: Sendable {
    public var mode: AddressMode?
    public var publicURL: String?
    public var port: Int?
    public var tunnelID: UUID?
    public var tunnelCredentials: String?
    public var cloudflaredPath: String?
    public var rotateURL: Bool
    public init(mode: AddressMode? = nil, publicURL: String? = nil, port: Int? = nil,
                tunnelID: UUID? = nil, tunnelCredentials: String? = nil,
                cloudflaredPath: String? = nil, rotateURL: Bool = false) {
        self.mode = mode; self.publicURL = publicURL; self.port = port; self.tunnelID = tunnelID
        self.tunnelCredentials = tunnelCredentials; self.cloudflaredPath = cloudflaredPath; self.rotateURL = rotateURL
    }
}

public actor LifecycleCoordinator {
    public let store: InstallationStore
    private let manager: any ServiceManager
    private let installer: NativeBundleInstaller
    private let home: URL
    private let health: any ControlHealthChecking
    private let origins: any OriginProvisioning
    private let tunnels: any TunnelRuntime
    private let readinessDeadline: Duration
    private let readinessPoll: Duration

    public init(
        store: InstallationStore,
        manager: any ServiceManager = LaunchdServiceManager(),
        installer: NativeBundleInstaller = NativeBundleInstaller(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        health: any ControlHealthChecking = LiveControlHealth(),
        origins: any OriginProvisioning = LiveOriginProvisioning(),
        tunnels: any TunnelRuntime = LiveTunnelRuntime(),
        readinessDeadline: Duration = .seconds(60),
        readinessPoll: Duration = .milliseconds(200)
    ) {
        self.store = store
        self.manager = manager
        self.installer = installer
        self.home = home
        self.health = health
        self.origins = origins
        self.tunnels = tunnels
        self.readinessDeadline = readinessDeadline
        self.readinessPoll = readinessPoll
    }

    public func setup(_ options: SetupOptions) async throws -> LoadedInstallation {
        if let port = options.port, !(1...65535).contains(port) { throw ManagementError.invalid("port must be between 1 and 65535") }
        let manifest = try installer.validateBundle()
        let existing: LoadedInstallation? = store.exists() ? try store.load() : nil
        let mode = options.mode ?? existing?.installation.addressMode ?? .quick
        let changesMode = existing.map { $0.installation.addressMode != mode } ?? false
        try validateAddressOptions(options, mode: mode, existing: changesMode ? nil : existing)
        if mode == .named, let source = options.tunnelCredentials, let id = options.tunnelID ?? existing?.installation.tunnel.id {
            try TunnelTools.validateNamedCredential(source: source, tunnelID: id)
        }
        let cloudflared = try managedExecutable(mode: mode, explicit: options.cloudflaredPath,
                                                stored: changesMode ? nil : existing?.installation.tunnel.cloudflaredPath)
        let port = options.port ?? existing?.installation.port ?? 8443
        let deriveLoopbackURL = mode == .loopback && options.port != nil && options.publicURL == nil
        let rawURL = options.publicURL ?? (changesMode || deriveLoopbackURL ? nil : existing?.installation.publicURL)
        let normalizedURL = try rawURL.map { try AddressPolicy.validate($0, mode: mode) }
            ?? (mode == .loopback ? ControlLoopback.url(port: port) : nil)
        if mode == .loopback, let normalizedURL,
           (URL(string: normalizedURL)?.port ?? 80) != port {
            throw ManagementError.invalid("loopback --public-url port must match --port")
        }
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded: LoadedInstallation
        if store.exists() {
            loaded = try store.load()
            if options.mode != nil { loaded.installation.addressMode = mode; loaded.installation.publicURL = normalizedURL }
            if options.port != nil { loaded.installation.port = port }
            if mode == .loopback, options.port != nil { loaded.installation.publicURL = ControlLoopback.url(port: port) } else if let normalizedURL { loaded.installation.publicURL = normalizedURL }
            if let id = options.tunnelID { loaded.installation.tunnel.id = id }
            if let cloudflared { loaded.installation.tunnel.cloudflaredPath = cloudflared }
            if mode != .named {
                loaded.installation.tunnel.id = nil
                loaded.installation.tunnel.credentialsPath = nil
            }
            if mode == .externalProxy || mode == .loopback { loaded.installation.tunnel.cloudflaredPath = nil }
            loaded.installation.releaseID = manifest.releaseID
        } else {
            loaded = try store.create(releaseID: manifest.releaseID, mode: mode, publicURL: normalizedURL,
                                      port: port,
                                      tunnel: TunnelConfiguration(id: options.tunnelID, cloudflaredPath: cloudflared))
        }
        try await reconcileIncompleteOperation(&loaded)
        if loaded.installation.desiredState == .stopped {
            try store.save(loaded.installation)
            throw ManagementError.unavailable("installation is stopped; setup preserved stopped intent — run shell-control up")
        }
        let binaries = try installer.install(manifest)
        try store.save(loaded.installation)
        if let previous = existing?.installation,
           previous.addressMode != loaded.installation.addressMode || previous.publicURL != loaded.installation.publicURL {
            note("control endpoint configuration changed; enrolled devices may require re-pairing\n")
        }
        return try await start(&loaded, binaries: binaries, rotateURL: options.rotateURL,
                               namedCredentialSource: options.tunnelCredentials,
                               removeObsoleteTunnel: changesMode && ![.quick, .named].contains(mode))
    }

    public func up(rotateURL: Bool) async throws -> LoadedInstallation {
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded = try store.load()
        try await reconcileIncompleteOperation(&loaded)
        guard !rotateURL || loaded.installation.addressMode == .quick else {
            throw ManagementError.invalid("--rotate-url is valid only for quick mode")
        }
        try validateManagedDependency(loaded.installation)
        let manifest = try installer.validateBundle()
        guard manifest.releaseID == loaded.installation.releaseID else {
            throw ManagementError.unsupported("installed release differs from the invoking CLI; run setup to reconcile")
        }
        let binaries = try installer.install(manifest)
        loaded.installation.desiredState = .running
        try store.save(loaded.installation)
        return try await start(&loaded, binaries: binaries, rotateURL: rotateURL, namedCredentialSource: nil,
                               removeObsoleteTunnel: false)
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
        for component in [Component.daemon, .tunnel, .broker] {
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
        // Validate the whole operation before the first restart.
        if selection.contains(.tunnel) {
            switch loaded.installation.addressMode {
            case .quick: throw ManagementError.invalid("restarting a quick tunnel would rotate its hostname; use up --rotate-url")
            case .externalProxy, .loopback: throw ManagementError.invalid("no tunnel is owned in \(loaded.installation.addressMode.rawValue) mode")
            case .named: break
            }
        }
        try validateManagedDependency(loaded.installation)
        let manifest = try installer.validateBundle()
        guard manifest.releaseID == loaded.installation.releaseID else { throw ManagementError.unsupported("release integrity mismatch") }
        let binaries = try installer.install(manifest)
        for component in selection {
            guard let spec = try serviceSpec(component, loaded: loaded, binaries: binaries) else {
                throw ManagementError.invalid("no \(component.rawValue) service is owned")
            }
            try await manager.restart(spec)
        }
        let status = await status(loaded: loaded)
        guard isReady(status) else { throw ManagementError.unavailable("restart completed but the control path is degraded") }
    }

    public func installPersistence() async throws {
        let lock = try store.lock(cancelled: { Task.isCancelled }); defer { lock.release() }
        var loaded = try store.load()
        try await reconcileIncompleteOperation(&loaded)
        guard [.named, .externalProxy].contains(loaded.installation.addressMode),
              loaded.installation.publicURL?.hasPrefix("https://") == true else {
            throw ManagementError.invalid("login persistence requires named or external-proxy mode with a stable HTTPS origin")
        }
        try validateManagedDependency(loaded.installation)
        let manifest = try installer.validateBundle()
        guard manifest.releaseID == loaded.installation.releaseID else { throw ManagementError.unsupported("release integrity mismatch; run setup first") }
        let binaries = try installer.install(manifest)
        loaded.installation.persistent = true; try store.save(loaded.installation)
        for component in Component.allCases {
            guard let spec = try serviceSpec(component, loaded: loaded, binaries: binaries) else { continue }
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
            if let spec = try serviceSpec(component, loaded: loaded, binaries: binaries) { try await manager.removePersistence(spec) }
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
                                                     keyPath: destination.path, topics: topics)
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
                                    components: ["broker": absent, "daemon": absent, "tunnel": absent,
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

    private func start(_ loaded: inout LoadedInstallation, binaries: InstalledBinaries, rotateURL: Bool,
                       namedCredentialSource: String?, removeObsoleteTunnel: Bool) async throws -> LoadedInstallation {
        var operation = ManagementOperation(command: "start", plan: ["tunnel", "broker", "origin", "daemon", "readiness"])
        loaded.runtime.generation += 1
        loaded.runtime.operation = operation
        try store.save(loaded.runtime)
        var localCommitted = false
        do {
            try await prepareTunnel(
                &loaded, binaries: binaries, rotateURL: rotateURL,
                namedCredentialSource: namedCredentialSource,
                removeObsoleteTunnel: removeObsoleteTunnel, operation: &operation
            )
            try writeServiceConfigurations(loaded)
            try await startConnectorAndBroker(&loaded, binaries: binaries, operation: &operation)
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

    private func ensureTunnelLog(_ tunnelLog: URL) throws {
        if !FileManager.default.fileExists(atPath: tunnelLog.path) {
            guard FileManager.default.createFile(atPath: tunnelLog.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ManagementError.unavailable("cannot create protected tunnel log")
            }
        }
        try SecureFileSystem.validateOwnedPath(tunnelLog.path, type: .typeRegular)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tunnelLog.path)
    }

    private func prepareTunnel(_ loaded: inout LoadedInstallation, binaries: InstalledBinaries, rotateURL: Bool,
                               namedCredentialSource: String?, removeObsoleteTunnel: Bool,
                               operation: inout ManagementOperation) async throws {
        if loaded.installation.addressMode != .named {
            for url in [loaded.paths.credentials.appendingPathComponent("tunnel.json"),
                        loaded.paths.services.appendingPathComponent("tunnel.yml")] {
                if FileManager.default.fileExists(atPath: url.path) {
                    try SecureFileSystem.validateOwnedPath(url.path, type: .typeRegular)
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        if removeObsoleteTunnel {
            let obsoleteLabel = label(.tunnel, loaded.installation.installationID)
            try await manager.disable(label: obsoleteLabel)
            try await manager.stop(label: obsoleteLabel)
            let persistenceOnly = JobSpec(
                component: .tunnel, installationID: loaded.installation.installationID,
                executable: "/usr/bin/true", arguments: [], workingDirectory: loaded.paths.root.path,
                stdoutPath: "/dev/null", stderrPath: "/dev/null", keepAlive: false, environment: [:],
                sessionPlistDirectory: loaded.paths.launchd.path,
                launchAgentsDirectory: home.appendingPathComponent("Library/LaunchAgents").path
            )
            try await manager.removePersistence(persistenceOnly)
        }
        if loaded.installation.addressMode == .quick || loaded.installation.addressMode == .named {
            try ensureTunnelLog(loaded.paths.logs.appendingPathComponent("tunnel.transport.log"))
        }
        if loaded.installation.addressMode == .named {
            try await configureNamedTunnel(&loaded, namedCredentialSource: namedCredentialSource)
        }
        if loaded.installation.addressMode == .quick {
            try await configureQuickTunnel(&loaded, binaries: binaries, rotateURL: rotateURL, operation: &operation)
        }
    }

    private func configureNamedTunnel(_ loaded: inout LoadedInstallation, namedCredentialSource: String?) async throws {
        guard let id = loaded.installation.tunnel.id else { throw ManagementError.invalid("named mode requires --tunnel-id") }
        let credential: URL
        if let namedCredentialSource {
            credential = try TunnelTools.installNamedCredential(source: namedCredentialSource, tunnelID: id, paths: loaded.paths)
        } else {
            credential = loaded.paths.credentials.appendingPathComponent("tunnel.json")
            try SecureFileSystem.validateOwnedPath(credential.path, type: .typeRegular)
        }
        loaded.installation.tunnel.credentialsPath = credential.path
        try store.save(loaded.installation)
        let config = try TunnelTools.writeNamedConfiguration(
            publicURL: loaded.installation.publicURL!, port: loaded.installation.port,
            tunnelID: id, credential: credential, paths: loaded.paths
        )
        try await tunnels.validateNamedConfiguration(cloudflared: loaded.installation.tunnel.cloudflaredPath!, config: config)
    }

    private func configureQuickTunnel(_ loaded: inout LoadedInstallation, binaries: InstalledBinaries,
                                      rotateURL: Bool, operation: inout ManagementOperation) async throws {
        let tunnel = await manager.observe(label: label(.tunnel, loaded.installation.installationID))
        if rotateURL {
            let old = loaded.installation.publicURL
            loaded.installation.publicURL = nil
            try store.save(loaded.installation)
            try await manager.stop(label: tunnel.label)
            note("public URL rotation authorized; old endpoint: \(old ?? "(none)")\n")
        }
        guard loaded.installation.publicURL == nil else { return }
        let generation = "generation-\(loaded.runtime.generation)-\(UUID().uuidString)"
        let tunnelLog = loaded.paths.logs.appendingPathComponent("tunnel.transport.log")
        try ensureTunnelLog(tunnelLog)
        let handle = try FileHandle(forWritingTo: tunnelLog)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n--- \(generation) ---\n".utf8))
        try handle.close()
        let spec = try serviceSpec(.tunnel, loaded: loaded, binaries: binaries)!
        try recordCreated(&operation, loaded: &loaded, .tunnel)
        try await manager.start(spec)
        let discovered = try await tunnels.discoverQuickURL(logURLs: [tunnelLog], generation: generation)
        loaded.installation.publicURL = discovered
        try store.save(loaded.installation)
        if rotateURL { note("new endpoint: \(discovered)\nRe-pair every device against the replacement.\n") }
    }

    private func startConnectorAndBroker(_ loaded: inout LoadedInstallation, binaries: InstalledBinaries,
                                         operation: inout ManagementOperation) async throws {
        for component in [Component.tunnel, .broker] {
            guard let spec = try serviceSpec(component, loaded: loaded, binaries: binaries) else { continue }
            if component == .tunnel && loaded.installation.addressMode == .quick && loaded.installation.publicURL != nil {
                let observation = await manager.observe(label: spec.label)
                if observation.pid == nil { continue }
            }
            let before = await manager.observe(label: spec.label)
            if !before.registered { try recordCreated(&operation, loaded: &loaded, component) }
            try await manager.install(spec, persistent: loaded.installation.persistent, start: true)
        }
    }

    private func provisionOriginIfNeeded(_ loaded: inout LoadedInstallation) async throws {
        guard loaded.secrets.originID == nil else { return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ManagementError.unavailable("secure random generation failed")
        }
        loaded.secrets.originID = UUID()
        loaded.secrets.originSecret = bytes.map { String(format: "%02x", $0) }.joined()
        try store.save(loaded.secrets)
        try await origins.provisionOrigin(
            port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret,
            label: Host.current().localizedName ?? "Mac",
            originID: loaded.secrets.originID!, originSecret: loaded.secrets.originSecret!
        )
        try writeServiceConfigurations(loaded)
    }

    private func startDaemon(_ loaded: inout LoadedInstallation, binaries: InstalledBinaries,
                             operation: inout ManagementOperation) async throws {
        let daemon = try serviceSpec(.daemon, loaded: loaded, binaries: binaries)!
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

    private func status(loaded: LoadedInstallation) async -> ManagementStatus {
        let stamp = timestamp(), id = loaded.installation.installationID
        async let brokerJob = manager.observe(label: label(.broker, id)); async let daemonJob = manager.observe(label: label(.daemon, id)); async let tunnelJob = manager.observe(label: label(.tunnel, id))
        async let brokerHealth = health.broker(url: URL(string: ControlLoopback.url(port: loaded.installation.port))!, expectedIdentity: serviceIdentity(id))
        async let daemonHealth = health.daemon(path: loaded.paths.healthSocket.path)
        let bj = await brokerJob, dj = await daemonJob, tj = await tunnelJob, bh = await brokerHealth, dh = await daemonHealth
        var broker = bh; broker.pid = bj.pid; if !bj.loaded { broker.state = bj.enabled ? "stopped" : "disabled"; broker.reason = bj.reason }
        var daemon = dh; daemon.pid = dj.pid; if !dj.loaded { daemon.state = dj.enabled ? "stopped" : "disabled"; daemon.reason = dj.reason }
        let tunnel: ComponentObservation
        switch loaded.installation.addressMode {
        case .externalProxy: tunnel = .init(state: "externally_managed", checkedAt: stamp, mode: "external-proxy")
        case .loopback: tunnel = .init(state: "not_configured", checkedAt: stamp, reason: "loopback mode owns no tunnel", mode: "loopback")
        case .quick, .named: tunnel = .init(state: tj.pid == nil ? "stopped" : "running", checkedAt: stamp,
                                            reason: tj.pid == nil ? (tj.reason ?? "managed tunnel is not running") : nil, pid: tj.pid,
                                            mode: loaded.installation.addressMode.rawValue)
        }
        let publicRoute: ComponentObservation
        if loaded.installation.addressMode == .loopback { publicRoute = broker } else if let text = loaded.installation.publicURL, let url = URL(string: text) { publicRoute = await health.broker(url: url, expectedIdentity: serviceIdentity(id)) } else { publicRoute = .init(state: "not_ready", checkedAt: stamp, reason: "public origin is not configured") }
        let push = ComponentObservation(state: loaded.installation.push.enabled ? "configured" : "not_configured", checkedAt: stamp,
                                        reason: loaded.installation.push.enabled ? "provider credentials present; delivery is not proven" : "push is disabled")
        let localReady = broker.state == "ready" && daemon.state == "ready"
        let routeReady = loaded.installation.addressMode == .loopback || publicRoute.state == "ready"
        let connectorReady = [.externalProxy, .loopback].contains(loaded.installation.addressMode) || tunnel.state == "running"
        let overall = loaded.installation.desiredState == .stopped ? "stopped" : (localReady && routeReady && connectorReady ? "ready" : (localReady ? "degraded" : "unavailable"))
        var components = ["broker": broker, "daemon": daemon, "tunnel": tunnel, "public_route": publicRoute, "push": push]
        if let operation = loaded.runtime.operation {
            components["management_operation"] = .init(state: "reconciling", checkedAt: stamp,
                                                        reason: "\(operation.command) operation \(operation.id.uuidString.lowercased()) is incomplete")
        }
        return ManagementStatus(overall: overall, readinessScope: loaded.installation.addressMode == .loopback ? "local" : "remote",
                                desiredState: loaded.installation.desiredState.rawValue, persistent: loaded.installation.persistent,
                                publicURL: loaded.installation.publicURL, components: components)
    }

    private func applyBrokerConfiguration(_ loaded: LoadedInstallation) async throws {
        guard loaded.installation.desiredState == .running else { return }
        let manifest = try installer.validateBundle()
        guard manifest.releaseID == loaded.installation.releaseID else { throw ManagementError.unsupported("release integrity mismatch") }
        let binaries = try installer.install(manifest)
        try await manager.restart(try serviceSpec(.broker, loaded: loaded, binaries: binaries)!)
        let identity = serviceIdentity(loaded.installation.installationID)
        try await waitUntil { (await health.broker(url: URL(string: ControlLoopback.url(port: loaded.installation.port))!, expectedIdentity: identity)).state == "ready" }
    }

    private func writeServiceConfigurations(_ loaded: LoadedInstallation) throws {
        let push = loaded.installation.push
        let broker: [String: Any] = ["port": loaded.installation.port, "bind_loopback": true,
            "state_path": loaded.paths.brokerLedger.path, "state_directory": loaded.paths.root.path,
            "account_id": loaded.secrets.accountID.uuidString.lowercased(), "admin_secret": loaded.secrets.adminSecret,
            "cursor_secret": loaded.secrets.cursorSecret, "public_url": loaded.installation.publicURL ?? "",
            "verification_uri": (loaded.installation.publicURL.map { "\($0)/v1/oauth/confirm" } ?? ""),
            "identity": serviceIdentity(loaded.installation.installationID), "apns_topics": push.enabled ? push.topics.joined(separator: ",") : "",
            "apns_key_id": push.enabled ? push.keyID! : "", "apns_team_id": push.enabled ? push.teamID! : "",
            "apns_key_file": push.enabled ? push.keyPath! : ""]
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

    private func serviceSpec(_ component: Component, loaded: LoadedInstallation, binaries: InstalledBinaries) throws -> JobSpec? {
        let executable: String, arguments: [String], keepAlive: Bool
        switch component {
        case .broker: executable = binaries.broker.path; arguments = ["--config", loaded.paths.services.appendingPathComponent("broker.json").path]; keepAlive = true
        case .daemon: executable = binaries.daemon.path; arguments = ["--config", loaded.paths.services.appendingPathComponent("daemon.json").path]; keepAlive = true
        case .tunnel:
            guard [.quick, .named].contains(loaded.installation.addressMode) else { return nil }
            guard let path = loaded.installation.tunnel.cloudflaredPath else { throw ManagementError.unavailable("configured cloudflared path is missing") }
            guard FileManager.default.isExecutableFile(atPath: path) else { throw ManagementError.unavailable("configured cloudflared executable changed or disappeared: \(path)") }
            executable = path; keepAlive = loaded.installation.addressMode == .named
            // cloudflared's --logfile uses its bounded rotating (lumberjack)
            // writer; launchd output is /dev/null so a quick tunnel never has
            // to be restarted merely to retain diagnostics.
            let transportLog = loaded.paths.logs.appendingPathComponent("tunnel.transport.log").path
            arguments = loaded.installation.addressMode == .quick
                ? ["tunnel", "--logfile", transportLog, "--url", ControlLoopback.url(port: loaded.installation.port), "--no-autoupdate"]
                : ["tunnel", "--logfile", transportLog, "--config", loaded.paths.services.appendingPathComponent("tunnel.yml").path, "--no-autoupdate", "run"]
        }
        let generationURL: URL? = switch component {
        case .broker: loaded.paths.services.appendingPathComponent("broker.json")
        case .daemon: loaded.paths.services.appendingPathComponent("daemon.json")
        case .tunnel: loaded.installation.addressMode == .named ? loaded.paths.services.appendingPathComponent("tunnel.yml") : nil
        }
        let generation = try generationURL.map { url in
            SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
        let stdoutPath = component == .tunnel ? "/dev/null" : loaded.paths.logs.appendingPathComponent("\(component.rawValue).out.log").path
        let stderrPath = component == .tunnel ? "/dev/null" : loaded.paths.logs.appendingPathComponent("\(component.rawValue).err.log").path
        return JobSpec(component: component, installationID: loaded.installation.installationID,
                       executable: executable, arguments: arguments, workingDirectory: loaded.paths.root.path,
                       stdoutPath: stdoutPath, stderrPath: stderrPath,
                       keepAlive: keepAlive, environment: generation.map { ["SHELL_CONTROL_CONFIG_GENERATION": $0] } ?? [:],
                       sessionPlistDirectory: loaded.paths.launchd.path,
                       launchAgentsDirectory: home.appendingPathComponent("Library/LaunchAgents").path)
    }

    private func validateAddressOptions(_ options: SetupOptions, mode: AddressMode, existing: LoadedInstallation?) throws {
        if options.rotateURL && mode != .quick { throw ManagementError.invalid("--rotate-url is valid only in quick mode") }
        if options.rotateURL && existing == nil { throw ManagementError.invalid("--rotate-url requires an existing quick-mode installation") }
        switch mode {
        case .named:
            guard (options.tunnelID ?? existing?.installation.tunnel.id) != nil,
                  options.tunnelCredentials != nil || existing != nil,
                  options.publicURL != nil || existing?.installation.publicURL != nil else {
                throw ManagementError.invalid("named mode requires --public-url, --tunnel-id, and --tunnel-credentials")
            }
        case .externalProxy: guard options.publicURL != nil || existing?.installation.publicURL != nil else { throw ManagementError.invalid("external-proxy mode requires --public-url") }
        case .loopback:
            if options.tunnelID != nil || options.tunnelCredentials != nil || options.cloudflaredPath != nil { throw ManagementError.invalid("loopback mode does not accept managed tunnel options") }
        case .quick:
            if options.publicURL != nil { throw ManagementError.invalid("quick mode discovers its public URL and does not accept --public-url") }
            if options.tunnelID != nil || options.tunnelCredentials != nil { throw ManagementError.invalid("quick mode does not accept named tunnel options") }
            if let requestedPort = options.port, let existing, requestedPort != existing.installation.port, !options.rotateURL {
                throw ManagementError.invalid("changing a quick-tunnel port requires explicit --rotate-url")
            }
        }
    }

    private func validateManagedDependency(_ installation: Installation) throws {
        guard installation.addressMode == .quick || installation.addressMode == .named else { return }
        guard let path = installation.tunnel.cloudflaredPath else {
            throw ManagementError.corrupt("managed tunnel configuration is missing cloudflared_path")
        }
        try TunnelTools.validateCloudflared(path)
    }

    private func managedExecutable(mode: AddressMode, explicit: String?, stored: String?) throws -> String? {
        guard [.quick, .named].contains(mode) else { return nil }
        if let stored, explicit == nil {
            guard FileManager.default.isExecutableFile(atPath: stored) else { throw ManagementError.unavailable("configured cloudflared disappeared: \(stored)") }
            return stored
        }
        return try TunnelTools.resolveCloudflared(explicit: explicit)
    }
    private func label(_ component: Component, _ id: UUID) -> String { "dev.chr33s.shell.control.\(id.uuidString.lowercased()).\(component.rawValue)" }
    private func serviceIdentity(_ id: UUID) -> String { "shell-control:\(id.uuidString.lowercased())" }
    private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
