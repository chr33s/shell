//
//  ControlHostLifecycle.swift
//  shell
//
//  Mac Catalyst only: the lifecycle of the bundled Control host — explicit
//  consent, SMAppService registration, persisted user intent, reconciliation
//  on foreground activation, and the authenticated XPC client
//  (spec.agent-relay.md sections 19.4, 19.6, and 19.9).
//
//  `.enabled` registration is eligibility to run, never health: the readiness
//  shown to the user combines intent, registration, and what the host itself
//  reports over XPC (ControlReadiness.evaluate). Registration happens only on
//  an explicit user action; nothing here re-registers silently.
//

#if targetEnvironment(macCatalyst)
import Foundation
import Observation
import ServiceManagement
import XPC

// MARK: - Registration

/// The registration surface, so the controller's decisions do not depend on a
/// live launchd.
protocol ControlHostServiceControlling {
    var registration: ControlHostRegistration { get }
    func register() throws
    func unregister() async throws
    func openSystemSettingsLoginItems()
}

/// `SMAppService.agent(plistName:)` for the bundle-relative LaunchAgent at
/// `Contents/Library/LaunchAgents/dev.chr33s.shell.control-host.plist`
/// (spec 19.3).
struct ControlHostAgentService: ControlHostServiceControlling {
    private var service: SMAppService { SMAppService.agent(plistName: ControlHostWire.launchAgentPlistName) }

    var registration: ControlHostRegistration {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: - XPC client

/// One request per session to the host's Mach service. The session requires
/// the peer to be the host signed by this app's team (spec 19.6); the host
/// applies the mirror-image check to us.
nonisolated struct ControlHostClient: Sendable {
    enum ClientError: Error, CustomStringConvertible {
        case timedOut
        case rejected(code: String, message: String)

        var description: String {
            switch self {
            case .timedOut: String(localized: "The Control host did not answer in time.")
            case .rejected(_, let message): message
            }
        }
    }

    var timeout: TimeInterval = 10

    func send(_ request: ControlHostRequest) async throws -> ControlHostReply {
        let reply = try await Self.exchange(request, timeout: timeout)
        guard reply.ok else {
            throw ClientError.rejected(code: reply.errorCode ?? "failed", message: reply.errorMessage ?? "rejected")
        }
        return reply
    }

    /// The first of reply, error, or timeout wins; the session is cancelled
    /// either way, so an unresponsive host never strands the caller.
    private static func exchange(_ request: ControlHostRequest, timeout: TimeInterval) async throws -> ControlHostReply {
        let session = try XPCSession(
            machService: ControlHostWire.machServiceName,
            requirement: .isFromSameTeam(andMatchesSigningIdentifier: ControlHostWire.hostBundleIdentifier)
        )
        let outcome = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            outcome.install(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                outcome.resume(.failure(ClientError.timedOut))
                session.cancel(reason: "timed out")
            }
            do {
                try session.send(request) { (result: Result<ControlHostReply, any Error>) in
                    outcome.resume(result)
                    session.cancel(reason: "request complete")
                }
            } catch {
                outcome.resume(.failure(error))
                session.cancel(reason: "send failed")
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ControlHostReply, any Error>?

        func install(_ continuation: CheckedContinuation<ControlHostReply, any Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(_ result: Result<ControlHostReply, any Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<ControlHostReply, any Error>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }
}

// MARK: - Lifecycle

@Observable
final class ControlHostLifecycle {
    static let shared = ControlHostLifecycle()

    private enum Keys {
        static let intent = "controlHost.intentEnabled"
        static let everObservedEnabled = "controlHost.everObservedEnabled"
    }

    /// The user's decision, persisted before any system call so a crash
    /// mid-change never leaves Control running against a "disabled" choice.
    private(set) var intentEnabled: Bool
    /// Whether this registration was ever seen `.enabled`; a later
    /// `.requiresApproval` then means the user turned it off in System
    /// Settings, which is respected, not undone (spec A42).
    private(set) var everObservedEnabled: Bool
    private(set) var registration: ControlHostRegistration = .notRegistered
    private(set) var observation: ControlHostObservation = .notQueried
    private(set) var readiness: ControlReadinessState = .notEnabled
    private(set) var devices: [ControlHostDevice] = []
    private(set) var pending: [ControlHostPendingPairing] = []
    private(set) var invitation: ControlHostInvitation?
    private(set) var lastError: String?
    private(set) var notice: String?
    private(set) var isWorking = false
    private var unreachableSince: Date?

    private let service: any ControlHostServiceControlling
    private let client: ControlHostClient
    private let defaults: UserDefaults

    init(
        service: any ControlHostServiceControlling = ControlHostAgentService(),
        client: ControlHostClient = ControlHostClient(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.client = client
        self.defaults = defaults
        intentEnabled = defaults.bool(forKey: Keys.intent)
        everObservedEnabled = defaults.bool(forKey: Keys.everObservedEnabled)
    }

    var hostStatus: ControlHostStatus? {
        if case .reachable(let status) = observation { return status }
        return nil
    }

    var hostIsServing: Bool { hostStatus.map { $0.phase == .ready || $0.phase == .stopped } ?? false }

    // MARK: Consent, enable, disable

    /// Registers only after the consent screen. Re-enabling after a System
    /// Settings disable is likewise an explicit action.
    func enable() async {
        await perform {
            setIntent(true)
            setEverObservedEnabled(false)
            do {
                try service.register()
            } catch {
                // `.requiresApproval` is reported by reconcile; anything else
                // is shown as it is.
                if service.registration != .requiresApproval {
                    lastError = String(localized: "Control could not be registered: \(error.localizedDescription)")
                }
            }
            await reconcileNow()
            if hostStatus?.phase == .stopped || hostStatus?.phase == .legacyConflict {
                _ = try? await client.send(ControlHostRequest(.resumeAcceptingWork))
                await reconcileNow()
            }
        }
    }

    /// Disable Control: persist stopped intent, tell the host to stop
    /// accepting work, unregister, and confirm the stopped state. A failure is
    /// reported, never presented as stopped (spec 19.4, A41).
    func disable() async {
        await perform {
            setIntent(false)
            var problems: [String] = []
            if registration == .enabled || hostStatus != nil {
                do {
                    _ = try await client.send(ControlHostRequest(.stopAcceptingWork))
                } catch {
                    problems.append(String(localized: "The host did not confirm it stopped accepting work: \(String(describing: error))"))
                }
            }
            do {
                try await service.unregister()
            } catch {
                await reconcileNow()
                lastError = String(localized: "Control could not be stopped: \(error.localizedDescription). It is still registered as a background item.")
                return
            }
            setEverObservedEnabled(false)
            invitation = nil
            // Confirm: unregistered, and the host no longer answers.
            var stillAnswering = true
            for _ in 0..<10 {
                if (try? await client.send(ControlHostRequest(.status))) == nil {
                    stillAnswering = false
                    break
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            await reconcileNow()
            if registration != .notRegistered {
                problems.append(String(localized: "The background item still reports \(registration.rawValue)."))
            }
            if stillAnswering {
                problems.append(String(localized: "The host is still running after unregistration."))
            }
            if problems.isEmpty {
                notice = String(localized: "Control is stopped. Pairings, keys, and history are kept.")
            } else {
                lastError = problems.joined(separator: " ")
            }
        }
    }

    func openLoginItems() {
        service.openSystemSettingsLoginItems()
    }

    // MARK: Reconciliation

    /// On appearance, on foreground activation, and after returning from
    /// System Settings. Observes; never registers.
    func reconcile() async {
        await perform { await reconcileNow() }
    }

    private func reconcileNow() async {
        registration = service.registration
        if registration == .enabled { setEverObservedEnabled(true) }
        if registration == .enabled || (!intentEnabled && hostStatus != nil) {
            do {
                let reply = try await client.send(ControlHostRequest(.status))
                observation = reply.status.map(ControlHostObservation.reachable) ?? .unreachable(detail: "empty status")
                unreachableSince = nil
            } catch {
                observation = .unreachable(detail: String(describing: error))
                if unreachableSince == nil { unreachableSince = Date() }
            }
        } else {
            observation = .notQueried
            unreachableSince = nil
        }
        // Intent is enabled and the user did not stop it: a host that is
        // stopped (a restart before a failed disable) resumes work.
        if intentEnabled, hostStatus?.phase == .stopped,
           let reply = try? await client.send(ControlHostRequest(.resumeAcceptingWork)), let status = reply.status {
            observation = .reachable(status)
        }
        if !intentEnabled, registration == .enabled {
            lastError = String(localized: "Control is still registered although it was disabled. Choose Disable Control again.")
        }
        readiness = ControlReadiness.evaluate(
            intentEnabled: intentEnabled,
            registration: registration,
            everObservedEnabled: everObservedEnabled,
            host: observation,
            unreachableFor: unreachableSince.map { Date().timeIntervalSince($0) }
        )
        if hostIsServing {
            await refreshListsNow()
        } else {
            devices = []
            pending = []
        }
    }

    /// Asks a host that could not start (a resolved legacy conflict, storage
    /// that is available again) to try once more.
    func retryHost() async {
        await perform {
            _ = try await client.send(ControlHostRequest(.resumeAcceptingWork))
            await reconcileNow()
        }
    }

    // MARK: Route (spec 19.7)

    func setRoute(_ text: String) async {
        await perform {
            _ = try await client.send(ControlHostRequest(.setRoute, route: text))
            await reconcileNow()
        }
    }

    func verifyRoute() async {
        await perform {
            _ = try await client.send(ControlHostRequest(.verifyRoute))
            await reconcileNow()
        }
    }

    // MARK: Pairing and devices

    func mintInvitation() async {
        await perform {
            invitation = try await client.send(ControlHostRequest(.mintPairing)).invitation
        }
    }

    func dismissInvitation() { invitation = nil }

    func refreshLists() async {
        await perform { await refreshListsNow() }
    }

    private func refreshListsNow() async {
        devices = (try? await client.send(ControlHostRequest(.listDevices)).devices) ?? devices
        pending = (try? await client.send(ControlHostRequest(.listPendingPairings)).pending) ?? pending
    }

    func confirm(_ item: ControlHostPendingPairing, approve: Bool) async {
        await perform {
            pending = try await client.send(ControlHostRequest(.confirmPairing, userCode: item.userCode, enabled: approve)).pending ?? []
            if approve { invitation = nil }
            devices = try await client.send(ControlHostRequest(.listDevices)).devices ?? devices
        }
    }

    func revoke(_ device: ControlHostDevice) async {
        await perform {
            devices = try await client.send(ControlHostRequest(.revokeDevice, deviceID: device.deviceID)).devices ?? []
        }
    }

    func setAgentGrants(_ device: ControlHostDevice, enabled: Bool) async {
        await perform {
            devices = try await client.send(ControlHostRequest(.setAgentGrants, deviceID: device.deviceID, enabled: enabled)).devices ?? devices
        }
    }

    // MARK: Plumbing

    private func perform(_ work: () async throws -> Void) async {
        isWorking = true
        lastError = nil
        notice = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            lastError = String(describing: error)
        }
    }

    private func setIntent(_ enabled: Bool) {
        intentEnabled = enabled
        defaults.set(enabled, forKey: Keys.intent)
    }

    private func setEverObservedEnabled(_ value: Bool) {
        everObservedEnabled = value
        defaults.set(value, forKey: Keys.everObservedEnabled)
    }
}
#endif
