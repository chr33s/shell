import Foundation

// The owned UI-to-host boundary of the bundled Control host
// (spec.agent-relay.md sections 3.1, 19.6, and 19.9).
//
// This one file is compiled into two binaries: the `ShellControlHostRuntime`
// library (the native macOS host) and, by file reference, the Mac Catalyst
// Shell app. It therefore imports Foundation only and declares every type
// `nonisolated`, so it builds under the app's main-actor default isolation as
// well as the package's Swift 6 defaults. Messages are Codable values carried
// by the Swift XPC session API; `NSXPCConnection(machServiceName:)` is
// unavailable to Mac Catalyst, `XPCSession(machService:)` is not.

/// Identities and limits both sides must agree on.
nonisolated public enum ControlHostWire {
    /// Bumped on any incompatible change to the messages below. A peer that
    /// reports another version is `incompatible_build`, never "ready".
    public static let protocolVersion = 1
    /// The shared, provisioned App Group both executables claim (spec 19.5).
    public static let appGroupIdentifier = "group.dev.chr33s.shell.control"
    /// The launchd-published Mach service, inside the App Group namespace so
    /// no global Mach exception is needed (spec 19.6).
    public static let machServiceName = "group.dev.chr33s.shell.control.host"
    public static let launchAgentLabel = "dev.chr33s.shell.control-host"
    public static let launchAgentPlistName = "dev.chr33s.shell.control-host.plist"
    public static let hostBundleIdentifier = "dev.chr33s.shell.control-host"
    public static let appBundleIdentifier = "dev.chr33s.shell"
    /// The adapter ingress socket's file name in the App Group container. A
    /// candidate mechanism until the distribution spike validates it
    /// (spec 19.6).
    public static let adapterSocketName = "control.sock"
    /// Loopback port of the in-host broker; the same default as the
    /// standalone profile, so the two can never both own it (spec 19.8).
    public static let defaultBrokerPort: UInt16 = 8443
    public static let maximumRouteLength = 253
}

/// One request from the UI. `operation` stays a string so a newer UI's
/// operation decodes and is rejected explicitly instead of failing opaquely.
nonisolated public struct ControlHostRequest: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable, CaseIterable {
        case status
        case mintPairing = "mint_pairing"
        case listDevices = "list_devices"
        case listPendingPairings = "list_pending_pairings"
        case confirmPairing = "confirm_pairing"
        case revokeDevice = "revoke_device"
        case setAgentGrants = "set_agent_grants"
        case setRoute = "set_route"
        case verifyRoute = "verify_route"
        case stopAcceptingWork = "stop_accepting_work"
        case resumeAcceptingWork = "resume_accepting_work"
    }

    public var version: Int
    public var operation: String
    public var deviceID: String?
    public var userCode: String?
    public var enabled: Bool?
    public var route: String?

    public init(
        _ operation: Operation,
        deviceID: String? = nil,
        userCode: String? = nil,
        enabled: Bool? = nil,
        route: String? = nil,
        version: Int = ControlHostWire.protocolVersion
    ) {
        self.version = version
        self.operation = operation.rawValue
        self.deviceID = deviceID
        self.userCode = userCode
        self.enabled = enabled
        self.route = route
    }

    enum CodingKeys: String, CodingKey {
        case version = "v", operation = "op", deviceID = "device_id", userCode = "user_code", enabled, route
    }
}

/// The host's answer. Exactly one payload member is set on success.
nonisolated public struct ControlHostReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var errorCode: String?
    public var errorMessage: String?
    public var status: ControlHostStatus?
    public var devices: [ControlHostDevice]?
    public var pending: [ControlHostPendingPairing]?
    public var invitation: ControlHostInvitation?
    public var route: ControlHostRouteStatus?

    public init(
        ok: Bool = true,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        status: ControlHostStatus? = nil,
        devices: [ControlHostDevice]? = nil,
        pending: [ControlHostPendingPairing]? = nil,
        invitation: ControlHostInvitation? = nil,
        route: ControlHostRouteStatus? = nil
    ) {
        self.ok = ok
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.status = status
        self.devices = devices
        self.pending = pending
        self.invitation = invitation
        self.route = route
    }

    public static func failure(_ code: ControlHostErrorCode, _ message: String) -> ControlHostReply {
        ControlHostReply(ok: false, errorCode: code.rawValue, errorMessage: message)
    }

    enum CodingKeys: String, CodingKey {
        case ok, errorCode = "error_code", errorMessage = "error_message", status, devices, pending, invitation, route
    }
}

nonisolated public enum ControlHostErrorCode: String, Codable, Sendable {
    case unauthorizedPeer = "unauthorized_peer"
    case unsupportedVersion = "unsupported_version"
    case unsupportedOperation = "unsupported_operation"
    case invalidArgument = "invalid_argument"
    case notReady = "not_ready"
    case legacyConflict = "legacy_conflict"
    case routeUnavailable = "route_unavailable"
    case notFound = "not_found"
    case failed
}

/// What the host observes about itself. The UI combines it with user intent
/// and the `SMAppService` status; none of it alone is "ready for approvals"
/// (spec 19.9).
nonisolated public struct ControlHostStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        /// Opening storage and the ledger.
        case starting
        /// Journal recovery has not finished; readiness is not advertised.
        case recovering
        /// Broker, adapter ingress, and recovery are up.
        case ready
        /// The user disabled Control: no new adapter work is accepted.
        case stopped
        /// A standalone installation owns the port or origin (spec 19.8).
        case legacyConflict = "legacy_conflict"
        /// Storage, key material, or a listener is unavailable.
        case degraded
    }

    public var protocolVersion: Int
    public var hostBuild: String
    public var phase: Phase
    public var detail: String?
    public var acceptingWork: Bool
    public var brokerPort: Int
    public var originID: String?
    public var originFingerprint: String?
    public var route: ControlHostRouteStatus
    public var daemonState: String?
    public var adapterSocketPath: String?
    public var enrolledDevices: Int
    public var pendingPairings: Int
    public var journalQuarantined: Bool

    public init(
        protocolVersion: Int = ControlHostWire.protocolVersion,
        hostBuild: String,
        phase: Phase,
        detail: String? = nil,
        acceptingWork: Bool,
        brokerPort: Int,
        originID: String? = nil,
        originFingerprint: String? = nil,
        route: ControlHostRouteStatus = ControlHostRouteStatus(),
        daemonState: String? = nil,
        adapterSocketPath: String? = nil,
        enrolledDevices: Int = 0,
        pendingPairings: Int = 0,
        journalQuarantined: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.hostBuild = hostBuild
        self.phase = phase
        self.detail = detail
        self.acceptingWork = acceptingWork
        self.brokerPort = brokerPort
        self.originID = originID
        self.originFingerprint = originFingerprint
        self.route = route
        self.daemonState = daemonState
        self.adapterSocketPath = adapterSocketPath
        self.enrolledDevices = enrolledDevices
        self.pendingPairings = pendingPairings
        self.journalQuarantined = journalQuarantined
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", hostBuild = "host_build", phase, detail
        case acceptingWork = "accepting_work", brokerPort = "broker_port", originID = "origin_id"
        case originFingerprint = "origin_fingerprint", route, daemonState = "daemon_state"
        case adapterSocketPath = "adapter_socket_path", enrolledDevices = "enrolled_devices"
        case pendingPairings = "pending_pairings", journalQuarantined = "journal_quarantined"
    }
}

/// The Tailscale route as the host last verified it. Registration never
/// implies a route (spec 19.7).
nonisolated public struct ControlHostRouteStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case notConfigured = "not_configured"
        case verified
        case unavailable
    }

    /// Why a route is unavailable, precise enough to act on (spec A48).
    public enum Reason: String, Codable, Sendable {
        case invalidName = "invalid_name"
        case unreachable
        case tlsFailure = "tls_failure"
        case httpStatus = "http_status"
        case notShellBroker = "not_shell_broker"
        case originMismatch = "origin_mismatch"
        case noOriginIdentity = "no_origin_identity"
    }

    public var state: State
    public var url: String?
    public var reason: Reason?
    public var detail: String?
    public var checkedAt: Date?

    public init(state: State = .notConfigured, url: String? = nil, reason: Reason? = nil, detail: String? = nil, checkedAt: Date? = nil) {
        self.state = state
        self.url = url
        self.reason = reason
        self.detail = detail
        self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey {
        case state, url, reason, detail, checkedAt = "checked_at"
    }
}

nonisolated public struct ControlHostDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { deviceID }
    public var deviceID: String
    public var platform: String
    public var label: String
    public var keyFingerprint: String
    public var gatewayDeviceID: String?
    public var agentGrants: Bool

    public init(deviceID: String, platform: String, label: String, keyFingerprint: String, gatewayDeviceID: String?, agentGrants: Bool) {
        self.deviceID = deviceID
        self.platform = platform
        self.label = label
        self.keyFingerprint = keyFingerprint
        self.gatewayDeviceID = gatewayDeviceID
        self.agentGrants = agentGrants
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", platform, label, keyFingerprint = "key_fingerprint"
        case gatewayDeviceID = "gateway_device_id", agentGrants = "agent_grants"
    }
}

/// A claimed pairing or Watch reviewer waiting for confirmation on the Mac.
nonisolated public struct ControlHostPendingPairing: Codable, Sendable, Equatable, Identifiable {
    public var id: String { userCode }
    public var userCode: String
    public var platform: String
    public var label: String
    public var keyFingerprint: String
    public var gateway: String?

    public init(userCode: String, platform: String, label: String, keyFingerprint: String, gateway: String?) {
        self.userCode = userCode
        self.platform = platform
        self.label = label
        self.keyFingerprint = keyFingerprint
        self.gateway = gateway
    }

    enum CodingKeys: String, CodingKey {
        case userCode = "user_code", platform, label, keyFingerprint = "key_fingerprint", gateway
    }
}

/// A one-use, ten-minute pairing invitation: the same
/// `shell-control://pair?invite=` link `shell-control pair` prints.
nonisolated public struct ControlHostInvitation: Codable, Sendable, Equatable {
    public var link: String
    public var originFingerprint: String
    public var route: String
    public var expiresAt: Date

    public init(link: String, originFingerprint: String, route: String, expiresAt: Date) {
        self.link = link
        self.originFingerprint = originFingerprint
        self.route = route
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case link, originFingerprint = "origin_fingerprint", route, expiresAt = "expires_at"
    }
}

// MARK: - Readiness

/// The proposed UI states of spec 19.9, plus `legacy_conflict` (spec 19.8).
/// They are not aliases for `SMAppService.Status`.
nonisolated public enum ControlReadinessState: String, Codable, Sendable, CaseIterable {
    case notEnabled = "not_enabled"
    case approvalRequired = "approval_required"
    case registeredStarting = "registered_starting"
    case readyLocal = "ready_local"
    case routeUnavailable = "route_unavailable"
    case disabledByUser = "disabled_by_user"
    case incompatibleBuild = "incompatible_build"
    case degraded
    case legacyConflict = "legacy_conflict"
}

/// `SMAppService.Status`, mirrored so this file needs no ServiceManagement
/// import. `unknown` covers any value a later OS adds.
nonisolated public enum ControlHostRegistration: String, Codable, Sendable {
    case notRegistered = "not_registered"
    case enabled
    case requiresApproval = "requires_approval"
    case notFound = "not_found"
    case unknown
}

/// What the UI could learn from the host over XPC.
nonisolated public enum ControlHostObservation: Sendable, Equatable {
    case notQueried
    case unreachable(detail: String)
    case reachable(ControlHostStatus)
}

nonisolated public enum ControlReadiness {
    /// How long an unreachable but registered host counts as starting before
    /// it is reported degraded. launchd throttles restarts to about ten
    /// seconds, so a crash loop outlives this.
    public static let startupGrace: TimeInterval = 30

    /// Combines user intent, system registration, and host health. `.enabled`
    /// registration is eligibility to run, never health (spec 19.4).
    ///
    /// - Parameters:
    ///   - intentEnabled: the persisted user intent.
    ///   - registration: the current `SMAppService` status.
    ///   - everObservedEnabled: whether this registration was ever seen
    ///     `.enabled`; a later `.requiresApproval` then means the user turned
    ///     the background item off in System Settings.
    ///   - host: the XPC observation.
    ///   - unreachableFor: how long the host has been unreachable while
    ///     registered, if it is.
    public static func evaluate(
        intentEnabled: Bool,
        registration: ControlHostRegistration,
        everObservedEnabled: Bool,
        host: ControlHostObservation,
        unreachableFor: TimeInterval? = nil
    ) -> ControlReadinessState {
        guard intentEnabled else { return .notEnabled }
        switch registration {
        case .notRegistered:
            // Intent says enabled but nothing is registered: registration is
            // an explicit user action, never repeated silently (spec A42).
            return everObservedEnabled ? .disabledByUser : .notEnabled
        case .requiresApproval:
            return everObservedEnabled ? .disabledByUser : .approvalRequired
        case .notFound:
            // The bundle carries no such agent: a damaged or foreign build.
            return .incompatibleBuild
        case .unknown:
            return .degraded
        case .enabled:
            break
        }
        switch host {
        case .notQueried:
            return .registeredStarting
        case .unreachable:
            if let unreachableFor, unreachableFor > startupGrace { return .degraded }
            return .registeredStarting
        case .reachable(let status):
            guard status.protocolVersion == ControlHostWire.protocolVersion else { return .incompatibleBuild }
            switch status.phase {
            case .starting, .recovering: return .registeredStarting
            case .legacyConflict: return .legacyConflict
            case .degraded: return .degraded
            // Intent is enabled, so a stopped host is about to be resumed.
            case .stopped: return .registeredStarting
            case .ready:
                return status.route.state == .verified ? .readyLocal : .routeUnavailable
            }
        }
    }
}
