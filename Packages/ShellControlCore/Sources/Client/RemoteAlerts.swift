import Foundation
import Synchronization
import ShellControlProtocol

// Remote Control alerts on the iPhone: an explicit, local, per-origin and
// per-device choice, separate from review readiness
// (docs/specs/control-setup.md section 7).
//
// "Off" (no-relay mode) is not a transport and not offline operation: review
// continues through foreground refresh. A build-configured relay URL is
// availability, never consent to register.

extension ControlAPIClient {
    /// `GET /v1/devices/me/notification-preference`. An older broker without
    /// the endpoint answers 404, reported as ``NotificationPreferenceUnsupported``.
    public func notificationPreference() async throws -> NotificationPreference {
        do {
            return try NotificationPreference(json: try await get(NotificationPreference.path))
        } catch let error as ControlError where error.code == .notFound {
            throw NotificationPreferenceUnsupported()
        }
    }

    /// `PUT /v1/devices/me/notification-preference`, a compare-and-set on
    /// `expected_version`: a stale write is refused with HTTP 409.
    public func setNotificationPreference(_ update: NotificationPreferenceUpdate) async throws -> NotificationPreference {
        do {
            return try NotificationPreference(json: try await send(method: "PUT", path: NotificationPreference.path, body: update.json))
        } catch let error as ControlError where error.code == .notFound {
            throw NotificationPreferenceUnsupported()
        }
    }
}

/// The host predates the notification-preference API. Disabling cannot be
/// reported complete: the host must be updated to finish.
public struct NotificationPreferenceUnsupported: Error, Sendable, Equatable, CustomStringConvertible {
    public init() {}
    public var description: String { "the Mac does not support per-device alert preferences; update the host tools" }
}

/// What the Mac-side preference calls look like to the policy coordinator.
public protocol NotificationPreferenceService: Sendable {
    func notificationPreference() async throws -> NotificationPreference
    func setNotificationPreference(_ update: NotificationPreferenceUpdate) async throws -> NotificationPreference
}

extension ControlAPIClient: NotificationPreferenceService {}

/// The authenticated Mac endpoint that stores a relay delivery capability.
public protocol PushCapabilityRegistrationService: Sendable {
    func registerPushCapability(_ capability: String) async throws
}

extension ControlAPIClient: PushCapabilityRegistrationService {}

// MARK: - Local policy

/// The user's choice on this iPhone for one paired origin.
public enum RemoteAlertChoice: String, Sendable, Hashable, Codable {
    case off
    case configured
}

/// Whether the Mac has acknowledged the latest local choice.
public enum HostAlertAcknowledgement: String, Sendable, Hashable, Codable {
    /// Not yet confirmed by the Mac (offline, timed out, or not tried).
    case pending
    case acknowledged
    /// The Mac answered but lacks the preference API.
    case unsupported
}

/// A bounded, sanitized registration outcome. Unknown causes stay unknown.
public enum RemoteAlertFailure: String, Sendable, Hashable, Codable, CaseIterable {
    case permissionDenied = "permission_denied"
    case tokenUnavailable = "token_unavailable"
    case relayRejected = "relay_rejected"
    case networkFailure = "network_failure"
    case capabilityExpired = "capability_expired"
    case macRegistrationPending = "mac_registration_pending"
    case relayUnavailable = "relay_unavailable"
    case unknown
}

/// Everything a cached registration is bound to. Any change — relay
/// endpoint, app topic, APNs environment, origin, device record, token, or
/// expiry — means the cache no longer describes what the Mac holds.
public struct RemoteAlertRegistration: Sendable, Hashable, Codable {
    public var relayEndpoint: String
    public var topic: String
    public var environment: String
    public var originID: String
    public var deviceID: String
    /// A digest of the APNs token, never the token.
    public var tokenFingerprint: String
    public var expiresAt: Date

    public init(relayEndpoint: String, topic: String, environment: String, originID: String,
                deviceID: String, tokenFingerprint: String, expiresAt: Date) {
        self.relayEndpoint = relayEndpoint; self.topic = topic; self.environment = environment
        self.originID = originID; self.deviceID = deviceID; self.tokenFingerprint = tokenFingerprint
        self.expiresAt = expiresAt
    }

    /// Whether this cache still covers `candidate` for at least `margin`.
    public func covers(_ candidate: RemoteAlertRegistration, at now: Date, margin: TimeInterval) -> Bool {
        relayEndpoint == candidate.relayEndpoint && topic == candidate.topic
            && environment == candidate.environment && originID == candidate.originID
            && deviceID == candidate.deviceID && tokenFingerprint == candidate.tokenFingerprint
            && expiresAt.timeIntervalSince(now) > margin
    }

    public static func fingerprint(token: String) -> String {
        String(ContentDigest.sha256Hex(Data(token.utf8)).prefix(16))
    }
}

/// The persisted policy for one origin and one iPhone device record.
public struct RemoteAlertPolicy: Sendable, Hashable, Codable {
    public var choice: RemoteAlertChoice
    /// Bumped by every choice change, re-pairing, and cache invalidation.
    /// Work started under an older generation cannot commit.
    public var generation: Int
    public var host: HostAlertAcknowledgement
    /// The Mac's preference version last observed.
    public var hostVersion: Int64?
    public var registration: RemoteAlertRegistration?
    public var lastFailure: RemoteAlertFailure?
    public var lastOutcomeAt: Date?
    /// A migrated installation whose prior use could not be established asks
    /// once; this records that the question is still owed.
    public var needsChoice: Bool

    public init(choice: RemoteAlertChoice, generation: Int = 1, host: HostAlertAcknowledgement = .pending,
                hostVersion: Int64? = nil, registration: RemoteAlertRegistration? = nil,
                lastFailure: RemoteAlertFailure? = nil, lastOutcomeAt: Date? = nil, needsChoice: Bool = false) {
        self.choice = choice; self.generation = generation; self.host = host; self.hostVersion = hostVersion
        self.registration = registration; self.lastFailure = lastFailure; self.lastOutcomeAt = lastOutcomeAt
        self.needsChoice = needsChoice
    }

    /// Fresh guided setup: remote alerts off.
    public static let freshDefault = RemoteAlertPolicy(choice: .off)

    /// Migration of an installation that predates this policy. Nothing is
    /// written to the Mac: prior use is preserved as-is, and without it the
    /// Mac holds no delivery material, so alerts are effectively off. When a
    /// relay could be used the user is asked once.
    public static func migrated(priorUseEstablished: Bool, relayAvailable: Bool) -> RemoteAlertPolicy {
        priorUseEstablished
            ? RemoteAlertPolicy(choice: .configured, host: .acknowledged, hostVersion: 0)
            : RemoteAlertPolicy(choice: .off, host: .acknowledged, hostVersion: 0, needsChoice: relayAvailable)
    }

    /// The state shown for remote alerts (docs/specs/control-setup.md 3).
    public var displayState: RemoteAlertDisplayState {
        switch choice {
        case .off:
            switch host {
            case .acknowledged: return .off
            case .pending: return .disablePending
            case .unsupported: return .disableNeedsHostUpdate
            }
        case .configured:
            if host == .unsupported { return lastFailure == nil ? .configured : .degraded(lastFailure!) }
            if host == .pending { return .degraded(.macRegistrationPending) }
            if let lastFailure { return .degraded(lastFailure) }
            return .configured
        }
    }

    /// Whether registration with the relay and the Mac may run at all.
    public var permitsRegistration: Bool {
        choice == .configured && host != .pending
    }
}

public enum RemoteAlertDisplayState: Sendable, Hashable {
    case off
    case configured
    case degraded(RemoteAlertFailure)
    /// Off on this iPhone; the Mac has not acknowledged suppression yet.
    case disablePending
    /// Off on this iPhone; the Mac must be updated to finish disabling.
    case disableNeedsHostUpdate

    /// The spec's four-valued remote-alert dimension.
    public var dimension: String {
        switch self {
        case .off: "off"
        case .configured: "configured"
        case .degraded: "degraded"
        case .disablePending, .disableNeedsHostUpdate: "disable_pending"
        }
    }
}

/// Where the policy lives. Keyed by origin and device record, so another
/// Mac, a re-pairing, or another reviewer never shares it.
public protocol RemoteAlertPolicyStore: Sendable {
    func load(originID: String, deviceID: String) -> RemoteAlertPolicy?
    func save(_ policy: RemoteAlertPolicy, originID: String, deviceID: String)
    func remove(originID: String, deviceID: String)
    /// Forgets every policy for an origin: the Mac was forgotten or replaced.
    func removeAll(originID: String)
}

public final class InMemoryRemoteAlertPolicyStore: RemoteAlertPolicyStore {
    private let storage = Mutex<[String: RemoteAlertPolicy]>([:])
    public init() {}
    public func load(originID: String, deviceID: String) -> RemoteAlertPolicy? {
        storage.withLock { $0["\(originID)|\(deviceID)"] }
    }
    public func save(_ policy: RemoteAlertPolicy, originID: String, deviceID: String) {
        storage.withLock { $0["\(originID)|\(deviceID)"] = policy }
    }
    public func remove(originID: String, deviceID: String) {
        storage.withLock { $0["\(originID)|\(deviceID)"] = nil }
    }
    public func removeAll(originID: String) {
        storage.withLock { storage in storage = storage.filter { !$0.key.hasPrefix("\(originID)|") } }
    }
}

/// Serializes every remote-alert change for one origin and device.
///
/// Local intent is persisted, and in-flight registration invalidated, before
/// the Mac is contacted. Only the latest persisted intent is ever reconciled
/// with the Mac, and a registration that finishes under an older generation
/// is discarded — so a late result can never restore delivery after the user
/// chose off (docs/specs/control-setup.md sections 7.3 and 7.4).
public actor RemoteAlertCoordinator {
    public nonisolated let originID: String
    public nonisolated let deviceID: String
    private let store: any RemoteAlertPolicyStore
    private let now: @Sendable () -> Date
    private var reconciling = false
    private var reconcileWaiters: [CheckedContinuation<Void, Never>] = []
    private var registrationTasks: [UUID: Task<Void, Error>] = [:]

    public init(originID: String, deviceID: String, store: any RemoteAlertPolicyStore,
                initial: RemoteAlertPolicy, now: @escaping @Sendable () -> Date = { Date() }) {
        self.originID = originID
        self.deviceID = deviceID
        self.store = store
        self.now = now
        if store.load(originID: originID, deviceID: deviceID) == nil {
            store.save(initial, originID: originID, deviceID: deviceID)
        }
    }

    public var policy: RemoteAlertPolicy {
        store.load(originID: originID, deviceID: deviceID) ?? .freshDefault
    }

    private func update(_ change: (inout RemoteAlertPolicy) -> Void) -> RemoteAlertPolicy {
        var current = policy
        change(&current)
        store.save(current, originID: originID, deviceID: deviceID)
        return current
    }

    /// Records the user's choice and invalidates in-flight registration work
    /// immediately, before anything is sent. Call ``reconcile(with:)`` next.
    @discardableResult
    public func choose(_ choice: RemoteAlertChoice) -> RemoteAlertPolicy {
        let chosen = update { policy in
            policy.choice = choice
            policy.generation += 1
            policy.host = .pending
            policy.needsChoice = false
            policy.lastFailure = nil
            if choice == .off { policy.registration = nil }
        }
        cancelRegistrations()
        return chosen
    }

    /// Brings the Mac in line with the latest persisted intent — only that
    /// intent, and only this settings change, never approval commands. Safe
    /// to call on every foreground reconnection.
    @discardableResult
    public func reconcile(with service: any NotificationPreferenceService) async -> RemoteAlertPolicy {
        // Actor methods may interleave at every await. Keep exactly one host
        // reconciliation active while choose() remains free to record intent.
        while reconciling {
            await withCheckedContinuation { reconcileWaiters.append($0) }
        }
        reconciling = true
        defer {
            reconciling = false
            if !reconcileWaiters.isEmpty { reconcileWaiters.removeFirst().resume() }
        }

        while true {
            let intent = policy
            guard intent.host != .acknowledged else { return intent }
            let wanted = intent.choice == .configured
            do {
                var current = try await service.notificationPreference()
                for _ in 0..<3 {
                    if policy.generation != intent.generation { break }
                    // A never-set record (version 0) is off only once
                    // explicitly written: its legacy value may be on.
                    let asIntended = wanted ? current.enabled : (!current.enabled && current.version > 0)
                    if asIntended { return acknowledge(current, generation: intent.generation) }
                    do {
                        let written = try await service.setNotificationPreference(
                            NotificationPreferenceUpdate(enabled: wanted, expectedVersion: current.version)
                        )
                        if policy.generation == intent.generation {
                            return acknowledge(written, generation: intent.generation)
                        }
                        break // A newer choice arrived during the host write.
                    } catch let error as ControlError where error.code == .idempotencyConflict {
                        current = try await service.notificationPreference()
                    }
                }
                if policy.generation != intent.generation { continue }
                return policy
            } catch is NotificationPreferenceUnsupported {
                if policy.generation != intent.generation { continue }
                return update { $0.host = .unsupported }
            } catch {
                // Offline or timed out: leave the latest intent pending.
                if policy.generation != intent.generation { continue }
                return policy
            }
        }
    }

    private func acknowledge(_ preference: NotificationPreference, generation: Int) -> RemoteAlertPolicy {
        update { policy in
            guard policy.generation == generation else { return }
            policy.host = .acknowledged
            policy.hostVersion = preference.version
        }
    }

    /// Starts registration work, returning the generation it runs under, or
    /// nil when the policy forbids registering (off, or the Mac has not yet
    /// accepted the opt-in).
    public func beginRegistration() -> Int? {
        let current = policy
        return current.permitsRegistration ? current.generation : nil
    }

    /// Checks consent before starting the upload and cancels outstanding work
    /// when the user turns alerts off. The host also suppresses delivery after
    /// an off preference reaches it, including a request already on the wire.
    public func registerCapability(_ capability: String, generation: Int,
                                   with service: any PushCapabilityRegistrationService) async throws -> Bool {
        guard beginRegistration() == generation else { return false }
        let id = UUID()
        let task = Task { try await service.registerPushCapability(capability) }
        registrationTasks[id] = task
        defer { registrationTasks[id] = nil }
        try await task.value
        return beginRegistration() == generation
    }

    private func cancelRegistrations() {
        for task in registrationTasks.values { task.cancel() }
        registrationTasks.removeAll()
    }

    /// Whether the cached registration still covers `candidate`.
    public func isCurrent(_ candidate: RemoteAlertRegistration, margin: TimeInterval) -> Bool {
        policy.registration?.covers(candidate, at: now(), margin: margin) ?? false
    }

    /// Commits a finished registration. A result from an older generation,
    /// or after the user chose off, is discarded and reported as stale.
    @discardableResult
    public func completeRegistration(_ registration: RemoteAlertRegistration, generation: Int) -> Bool {
        let current = policy
        guard current.generation == generation, current.permitsRegistration else { return false }
        _ = update { policy in
            policy.registration = registration
            policy.lastFailure = nil
            policy.lastOutcomeAt = now()
        }
        return true
    }

    /// Records a sanitized failure for the generation that produced it.
    public func recordFailure(_ failure: RemoteAlertFailure, generation: Int) {
        _ = update { policy in
            guard policy.generation == generation, policy.choice == .configured else { return }
            policy.lastFailure = failure
            policy.lastOutcomeAt = now()
        }
    }

    /// Drops the cached registration so the next opportunity re-registers:
    /// relay endpoint change, token change, or re-pairing.
    public func invalidateRegistration() {
        cancelRegistrations()
        _ = update { policy in
            policy.registration = nil
            policy.generation += 1
        }
    }
}
