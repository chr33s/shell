import Foundation
#if canImport(Darwin)
import Darwin
#endif
import ShellControlBroker
import ShellControlDaemon
import ShellControlHostSupport
import ShellControlHTTPServer
import ShellControlProtocol
import ShellControlSecurity

/// The bundled Control host: the broker and daemon libraries composed in one
/// supervised process (spec.agent-relay.md sections 3.1 and 19.2).
///
/// Order of authority: single-writer lock, identity, legacy detection, ledger
/// restore, loopback broker, journal recovery, and only then adapter ingress
/// and a `ready` phase (spec 19.3). Nothing here installs, spawns, or manages
/// another service; that legacy lifecycle lives in `ShellControlManagement`,
/// which this target does not link.
public actor HostRuntime {
    public struct Configuration: Sendable {
        public var layout: HostStorageLayout
        /// `CFBundleVersion` of the host bundle, reported to the UI.
        public var hostBuild: String
        public var serviceIdentity: String
        public var legacyDetector: LegacyInstallationDetector
        public var routeVerifier: TailscaleRouteVerifier
        public var heartbeatInterval: TimeInterval
        /// Overrides the persisted broker port; tests pick a free port.
        public var brokerPortOverride: UInt16?
        public var maximumAdapterConnections: Int
        public var log: @Sendable (String) -> Void

        public init(
            layout: HostStorageLayout,
            hostBuild: String,
            serviceIdentity: String = "shell-control-host",
            legacyDetector: LegacyInstallationDetector = LegacyInstallationDetector(),
            routeVerifier: TailscaleRouteVerifier = TailscaleRouteVerifier(),
            heartbeatInterval: TimeInterval = ApprovalPolicy.heartbeatInterval,
            brokerPortOverride: UInt16? = nil,
            maximumAdapterConnections: Int = 64,
            log: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.layout = layout
            self.hostBuild = hostBuild
            self.serviceIdentity = serviceIdentity
            self.legacyDetector = legacyDetector
            self.routeVerifier = routeVerifier
            self.heartbeatInterval = heartbeatInterval
            self.brokerPortOverride = brokerPortOverride
            self.maximumAdapterConnections = maximumAdapterConnections
            self.log = log
        }
    }

    public enum OwnershipError: Error, CustomStringConvertible, Sendable, Equatable {
        /// Another host process already holds the ledger's single-writer lock.
        case duplicateInstance(String)
        case storage(String)

        public var description: String {
            switch self {
            case .duplicateInstance(let path): "another Control host already holds \(path)"
            case .storage(let detail): "host storage is unavailable: \(detail)"
            }
        }
    }

    /// The running adapter half. It can be stopped and started again without
    /// restarting the broker, which is how Disable/re-enable work in place.
    private struct DaemonComponent {
        let core: DaemonCore
        let heartbeat: Task<Void, Never>
        let server: FramedIPCServer
    }

    let configuration: Configuration
    private var lock: ProcessLock?
    private var settings = HostSettings()
    private(set) var identity: HostIdentity?
    private var store: BrokerStore?
    private var http: HTTPServer?
    private var outbox: Task<Void, Never>?
    private var daemon: DaemonComponent?
    private var phase: ControlHostStatus.Phase = .starting
    private var detail: String?
    private var route = ControlHostRouteStatus()
    private var legacyConflict: LegacyConflict?
    private var started = false
    private let adapterQueue = DispatchQueue(label: "dev.chr33s.shell.control-host.adapters", attributes: .concurrent)

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    private var port: UInt16 { configuration.brokerPortOverride ?? settings.brokerPort }

    // MARK: Lifecycle

    /// Takes the single-writer lock before anything else is opened; a
    /// duplicate instance is refused here (spec 19.3).
    public func acquireOwnership() throws {
        guard lock == nil else { return }
        do {
            try configuration.layout.prepare()
        } catch {
            throw OwnershipError.storage("\(error)")
        }
        do {
            lock = try ProcessLock.acquire(path: configuration.layout.lockPath)
        } catch ProcessLock.LockError.alreadyHeld {
            throw OwnershipError.duplicateInstance(configuration.layout.lockPath)
        } catch {
            throw OwnershipError.storage("cannot open \(configuration.layout.lockPath): \(error)")
        }
    }

    /// Brings the host up. Failures after ownership are not thrown: they
    /// become an honest `degraded` or `legacy_conflict` phase the UI can
    /// report, and the process stays idle instead of crash-looping under
    /// `KeepAlive` (spec 19.3, A50).
    public func start() async throws {
        try acquireOwnership()
        guard !started else { return }
        started = true
        let layout = configuration.layout
        do {
            settings = try HostSettings.load(layout.settingsURL)
        } catch {
            return degrade("host settings are unreadable: \(error)")
        }
        do {
            identity = try HostIdentity.loadOrCreate(layout: layout)
        } catch {
            return degrade("\(error)")
        }
        guard let identity else { return }

        // No second authority beside a standalone installation (spec A49).
        if let conflict = await configuration.legacyDetector.detect(port: port, ownServiceIdentity: configuration.serviceIdentity) {
            return enterLegacyConflict(conflict)
        }

        let persistence: FileBrokerPersistence
        do {
            persistence = try FileBrokerPersistence(url: layout.ledgerURL)
        } catch {
            // Never run an authority whose records would not survive a restart.
            return degrade("the ledger cannot be opened: \(error)")
        }
        let store = BrokerStore(
            serviceIdentity: configuration.serviceIdentity,
            cursorSecret: identity.cursorSecret,
            persistence: persistence,
            originSigner: OriginSigner(originID: identity.originID, key: identity.originKey)
        )
        do {
            try await store.restore()
            // Idempotent: the daemon half authenticates to the broker half
            // with this origin credential over loopback.
            _ = try await store.provisionOrigin(
                originID: identity.originID, secret: identity.originSecret,
                accountID: identity.accountID, label: "Shell Control host"
            )
        } catch {
            return degrade("the ledger cannot be restored: \(error)")
        }
        self.store = store

        let service = BrokerService(store: store, configuration: BrokerService.Configuration(
            verificationURI: "https://example.invalid/activate",
            // The bundled host registers no direct-APNs topics; pairing and
            // review work without push (spec.iphone-gateway.md 16.5).
            allowedAPNsTopics: [],
            adminSecret: identity.adminSecret,
            adminAccountID: identity.accountID
        ))
        let server = HTTPServer(port: port, bindLoopback: true) { request in await service.handle(request) }
        do {
            try server.start()
        } catch HTTPServer.ServerError.bind(let code) where code == EADDRINUSE {
            server.stop()
            return enterLegacyConflict(LegacyConflict(
                evidence: .portInUse, detail: "Another program already listens on 127.0.0.1:\(port)."
            ))
        } catch {
            server.stop()
            return degrade("the loopback broker cannot listen: \(error)")
        }
        http = server
        Thread.detachNewThread { server.acceptLoop() }
        // Hints are recorded and dropped until a push mode is configured; the
        // outbox must still drain so it stays bounded. A long interval keeps
        // the idle host quiet (spec A50).
        let worker = OutboxWorker(store: store, sender: DiscardingPushSender())
        outbox = Task { await worker.run(interval: 30) }
        configuration.log("broker listening on 127.0.0.1:\(port)")

        if settings.acceptingWork {
            await startDaemon()
        } else {
            phase = .stopped
            detail = "Control is disabled; no new agent work is accepted."
        }
        if let routeURL = settings.routeURL {
            route = await configuration.routeVerifier.verify(routeURL, origin: identity.origin)
        }
    }

    /// Stops everything this process owns, for SIGTERM from launchd.
    public func shutdown() async {
        await stopDaemon()
        http?.stop()
        http = nil
        outbox?.cancel()
        outbox = nil
        lock?.release()
        lock = nil
    }

    // MARK: Adapter half

    private func startDaemon() async {
        guard daemon == nil, let identity, http != nil else { return }
        let layout = configuration.layout
        phase = .recovering
        detail = nil
        let core: DaemonCore
        do {
            core = try DaemonCore(configuration: DaemonCore.Configuration(
                brokerURL: URL(string: "http://127.0.0.1:\(port)")!,
                originID: identity.originID,
                originSecret: identity.originSecret,
                socketPath: layout.adapterSocketPath,
                journalURL: layout.journalURL,
                healthSocketPath: layout.healthSocketPath,
                heartbeatInterval: configuration.heartbeatInterval
            ))
        } catch {
            return degrade("the dispatch journal cannot be opened: \(error)")
        }
        // The startup frontier is captured before any adapter is admitted;
        // an unreadable journal is retried with bounded backoff rather than
        // by exiting into a launchd restart loop (spec.cli.md 10.1, spec 19.3).
        var delay: UInt64 = 1
        while true {
            do {
                try await core.discoverInterruptedWorkAtStartup()
                break
            } catch {
                detail = "journal recovery is retrying: \(error)"
                configuration.log("journal recovery failed, retrying in \(delay)s: \(error)")
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 60)
                if Task.isCancelled { return }
            }
        }
        do {
            try await core.reconcileAfterRestart()
        } catch {
            configuration.log("startup recovery is incomplete and will be retried: \(error)")
        }
        let heartbeat = Task { await core.runHeartbeats() }
        let listener: Int32
        do {
            listener = try UnixSocketServer(path: layout.adapterSocketPath).makeListener()
        } catch {
            heartbeat.cancel()
            await core.shutdown()
            return degrade("the adapter socket cannot listen at \(layout.adapterSocketPath): \(error)")
        }
        let server = FramedIPCServer(
            listener: listener, queue: adapterQueue,
            maximumConnections: configuration.maximumAdapterConnections
        ) { request in await core.handle(request) }
        Thread.detachNewThread { server.acceptLoop() }
        daemon = DaemonComponent(core: core, heartbeat: heartbeat, server: server)
        phase = .ready
        detail = nil
        configuration.log("adapter ingress listening on \(layout.adapterSocketPath)")
    }

    private func stopDaemon() async {
        guard let daemon else { return }
        self.daemon = nil
        await daemon.core.shutdown()
        daemon.server.stop()
        await daemon.core.waitUntilIdle(timeout: 15)
        daemon.heartbeat.cancel()
        // A dead socket file would only mislead adapter discovery.
        unlink(configuration.layout.adapterSocketPath)
    }

    /// Disable Control: persist stopped intent, stop admitting adapter work,
    /// and drain in-flight requests. Identity, ledger, and journal are kept;
    /// an operation already dispatched cannot be retracted (spec 19.4).
    public func stopAcceptingWork() async throws {
        settings.acceptingWork = false
        try settings.save(configuration.layout.settingsURL)
        await stopDaemon()
        if phase == .ready || phase == .recovering {
            phase = .stopped
            detail = "Control is disabled; no new agent work is accepted."
        }
    }

    /// Re-enable after an explicit user action in the UI. A host that never
    /// got its broker up (a legacy conflict the user has since resolved, or
    /// storage that is readable again) retries startup instead.
    public func resumeAcceptingWork() async throws {
        if store == nil, started, phase == .legacyConflict || phase == .degraded {
            started = false
            legacyConflict = nil
            phase = .starting
            detail = nil
            try await start()
        }
        settings.acceptingWork = true
        try settings.save(configuration.layout.settingsURL)
        if phase == .stopped { await startDaemon() }
    }

    private func degrade(_ reason: String) {
        phase = .degraded
        detail = reason
        configuration.log("degraded: \(reason)")
    }

    private func enterLegacyConflict(_ conflict: LegacyConflict) {
        legacyConflict = conflict
        phase = .legacyConflict
        detail = "\(conflict.detail) \(conflict.remedy)"
        configuration.log("legacy conflict: \(conflict.detail)")
    }

    // MARK: Status

    public func status() async -> ControlHostStatus {
        var daemonState: String?
        var quarantined = false
        if let daemon {
            let health = await daemon.core.health()
            if var reader = try? JSONReader(health) {
                daemonState = try? reader.string("state", maxLength: 32)
            }
            if case .object(let members) = health, let value = members["journal_quarantined"], value != .null {
                quarantined = true
            }
        }
        var devices = 0, pending = 0
        if let store {
            if case .object(let members) = await store.deviceSummary(), case .array(let items)? = members["devices"] {
                devices = items.count
            }
            if let value = try? await store.pendingDeviceAuthorizations(),
               case .object(let members) = value, case .array(let items)? = members["pending"] {
                pending = items.count
            }
        }
        return ControlHostStatus(
            hostBuild: configuration.hostBuild,
            phase: phase,
            detail: detail,
            acceptingWork: settings.acceptingWork && daemon != nil,
            brokerPort: Int(port),
            originID: identity?.originID.rawValue,
            originFingerprint: identity?.origin.fingerprint,
            route: route,
            daemonState: daemonState,
            adapterSocketPath: daemon == nil ? nil : configuration.layout.adapterSocketPath,
            enrolledDevices: devices,
            pendingPairings: pending,
            journalQuarantined: quarantined
        )
    }

    public var currentPhase: ControlHostStatus.Phase { phase }

    // MARK: Route (spec 19.7)

    /// Records the user's MagicDNS name and verifies it. The name is kept
    /// even when verification fails, so it can be re-checked once Tailscale
    /// or Serve is fixed.
    public func setRoute(_ text: String) async throws -> ControlHostRouteStatus {
        guard text.count <= ControlHostWire.maximumRouteLength + 8 else {
            throw HostOperationError(.invalidArgument, "the route name is too long")
        }
        let normalized = try? TailscaleRouteVerifier.normalize(text)
        route = await configuration.routeVerifier.verify(text, origin: identity?.origin)
        if let normalized {
            settings.routeURL = normalized.url.absoluteString
            try settings.save(configuration.layout.settingsURL)
        }
        return route
    }

    public func verifyRoute() async -> ControlHostRouteStatus {
        guard let routeURL = settings.routeURL else {
            route = ControlHostRouteStatus()
            return route
        }
        route = await configuration.routeVerifier.verify(routeURL, origin: identity?.origin)
        return route
    }

    // MARK: Administration (the XPC layer's direct store access, spec 19.5)

    private func administeredStore() throws -> (BrokerStore, HostIdentity) {
        if phase == .legacyConflict, let legacyConflict {
            throw HostOperationError(.legacyConflict, "\(legacyConflict.detail) \(legacyConflict.remedy)")
        }
        guard let store, let identity else {
            throw HostOperationError(.notReady, detail ?? "the Control host is still starting")
        }
        return (store, identity)
    }

    /// A one-use pairing bound to the verified route. There is no invitation
    /// without a verified route: the phone would pin an unreachable origin.
    public func mintPairingInvitation() async throws -> ControlHostInvitation {
        let (store, identity) = try administeredStore()
        guard route.state == .verified, let routeURL = route.url else {
            throw HostOperationError(.routeUnavailable, route.detail ?? "Verify this Mac's Tailscale route before pairing.")
        }
        let minted = try await store.createPairing(principal: .admin(accountID: identity.accountID))
        let invitation = try PairingInvitation(
            origin: identity.origin, route: try OriginRoute(routeURL),
            pairingID: minted.pairingID, pairingSecret: minted.secret, expiresAt: minted.expiresAt
        )
        return ControlHostInvitation(
            link: try invitation.link().absoluteString,
            originFingerprint: identity.origin.fingerprint,
            route: routeURL,
            expiresAt: minted.expiresAt.date
        )
    }

    public func listDevices() async throws -> [ControlHostDevice] {
        let (store, _) = try administeredStore()
        guard case .object(let members) = await store.deviceSummary(), case .array(let items)? = members["devices"] else {
            return []
        }
        var devices: [ControlHostDevice] = []
        for item in items {
            guard var reader = try? JSONReader(item),
                  let id = try? reader.id("device_id") else { continue }
            let grants: Set<DeviceGrant>
            if case .device(_, _, let current)? = try? await store.authenticateDevice(id) {
                grants = current
            } else {
                grants = []
            }
            devices.append(ControlHostDevice(
                deviceID: id.rawValue,
                platform: (try? reader.string("platform", maxLength: 16)) ?? "",
                label: (try? reader.string("label", maxLength: 120)) ?? "",
                keyFingerprint: (try? reader.string("key_fingerprint", maxLength: 128)) ?? "",
                gatewayDeviceID: (try? reader.optionalID("gateway_device_id"))??.rawValue,
                agentGrants: !grants.isDisjoint(with: DeviceGrant.agent)
            ))
        }
        return devices
    }

    public func listPendingPairings() async throws -> [ControlHostPendingPairing] {
        let (store, _) = try administeredStore()
        guard case .object(let members) = try await store.pendingDeviceAuthorizations(),
              case .array(let items)? = members["pending"] else { return [] }
        return items.compactMap { item in
            guard var reader = try? JSONReader(item), let code = try? reader.string("user_code", maxLength: 16) else { return nil }
            return ControlHostPendingPairing(
                userCode: code,
                platform: (try? reader.string("platform", maxLength: 16)) ?? "",
                label: (try? reader.string("label", maxLength: 120)) ?? "",
                keyFingerprint: (try? reader.string("key_fingerprint", maxLength: 128)) ?? "",
                gateway: try? reader.optionalString("gateway", maxLength: 120)
            )
        }
    }

    /// Mac-local confirmation of a claimed pairing or Watch reviewer, after
    /// the UI showed its label and key fingerprint.
    public func confirmPairing(userCode: String, approve: Bool) async throws {
        let (store, identity) = try administeredStore()
        guard !userCode.isEmpty, userCode.count <= 16 else {
            throw HostOperationError(.invalidArgument, "user_code must be 1...16 characters")
        }
        if approve {
            try await store.approveDeviceAuthorization(userCode: userCode, principal: .admin(accountID: identity.accountID))
        } else {
            try await store.denyDeviceAuthorization(userCode: userCode)
        }
    }

    public func revokeDevice(_ deviceID: String) async throws {
        let (store, identity) = try administeredStore()
        guard let id = ControlID(deviceID) else { throw HostOperationError(.invalidArgument, "device_id must be a lowercase UUID") }
        try await store.revoke(deviceID: id, principal: .admin(accountID: identity.accountID))
    }

    /// Agent grants are separately revocable and never a pairing default
    /// (spec 17.1).
    public func setAgentGrants(_ deviceID: String, enabled: Bool) async throws {
        let (store, identity) = try administeredStore()
        guard let id = ControlID(deviceID) else { throw HostOperationError(.invalidArgument, "device_id must be a lowercase UUID") }
        _ = try await store.setAgentGrants(deviceID: id, enabled: enabled, principal: .admin(accountID: identity.accountID))
    }
}

public struct HostOperationError: Error, Sendable, CustomStringConvertible {
    public let code: ControlHostErrorCode
    public let message: String
    public init(_ code: ControlHostErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
    public var description: String { "\(code.rawValue): \(message)" }
}

/// Records nothing and sends nothing: the bundled host has no push mode yet,
/// and an in-memory recorder would grow for the life of the process.
struct DiscardingPushSender: PushSender {
    func send(_ entry: OutboxEntry) async throws {}
}
