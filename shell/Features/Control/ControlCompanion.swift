//
//  ControlCompanion.swift
//  shell
//
//  The phone's half of the iPhone-gateway profile: a full review client for
//  its Mac, reached privately over Tailscale, and the gateway its Watch
//  reaches that Mac through. Pairing pins the Mac's Shell origin key; the
//  Tailscale URL is only a route (spec.iphone-gateway.md sections 4.5 and 7).
//

import Foundation
import Observation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient
#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
    static let controlPairingReceived = Notification.Name("dev.chr33s.shell.control.pairingReceived")
}

@MainActor
@Observable
final class ControlCompanion {
    static let shared = ControlCompanion()

    enum Phase: Equatable {
        /// No Mac paired: scan the setup QR.
        case notConfigured
        /// A Mac is pinned but this iPhone has no Shell session with it.
        case needsEnrollment
        case ready
    }

    /// Reachability of the private Mac route. Never a reason to re-pair.
    enum RouteState: Equatable {
        case unknown
        case reachable(String)
        case unavailable(String)
    }

    private(set) var phase: Phase = .notConfigured
    private(set) var pending: [ApprovalRecord] = []
    private(set) var lastRefreshedAt: ControlTimestamp?
    private(set) var statusMessage: String?
    private(set) var routeState: RouteState = .unknown
    private(set) var pinnedOrigin: PinnedOrigin?
    private(set) var pairingProgress: ControlPairingProgress?
    private(set) var isPairing = false
    /// A scanned or linked setup QR waiting for the user's explicit yes.
    /// Nothing is contacted or trusted before that (spec.iphone-gateway.md
    /// sections 9.2 and 24).
    private(set) var pendingPairing: PendingPairing?

    struct PendingPairing: Equatable {
        let invitation: PairingInvitation
        let assessment: OriginTrust.Assessment
        /// Arrived as a `shell-control://` link rather than from Settings.
        let fromLink: Bool
    }

    @ObservationIgnored let gateway: ControlGatewaySession
    @ObservationIgnored private var journal: CommandJournal?

    /// The gateway must reach its own session while the phone is locked in a
    /// pocket, or the Watch it relays for is cut off.
    /// Items written as `WhenUnlocked` by earlier builds are migrated as soon
    /// as they can be read, even if this store was created while locked.
    nonisolated static func defaultCredentials() -> KeychainCredentialStore {
        let store = KeychainCredentialStore(service: "dev.chr33s.shell.control", accessibility: .afterFirstUnlock)
        store.migrateAccessibility()
        return store
    }

    init(
        credentials: any DeviceCredentialStore = ControlCompanion.defaultCredentials(),
        origins: any PinnedOriginStore = KeychainPinnedOriginStore(),
        transport: any ControlHTTPTransport = ControlTailnetTransport()
    ) {
        gateway = ControlGatewaySession(credentials: credentials, origins: origins, transport: transport)
        journal = try? CommandJournal()
    }

    var originFingerprint: String? { pinnedOrigin?.origin.fingerprint }
    var currentRoute: String? { pinnedOrigin?.routes.first?.url.absoluteString }

    func start() async {
        pinnedOrigin = await gateway.pinnedOrigin
        guard pinnedOrigin != nil else {
            phase = .notConfigured
            return
        }
        guard await gateway.deviceSession != nil else {
            phase = .needsEnrollment
            return
        }
        phase = .ready
        await refresh()
        ControlPushCapability.registerIfConfigured()
    }

    // MARK: Scanned payloads

    /// A setup QR is staged for confirmation; a route QR only moves routing
    /// and is verified against the pinned key. The two are labelled
    /// differently everywhere (spec.iphone-gateway.md section 24).
    @discardableResult
    func handleScanned(_ text: String, fromLink: Bool = false) async -> Bool {
        switch ControlScannedPayload(text) {
        case .pairing(let invitation):
            guard !isPairing else { return false }
            pendingPairing = PendingPairing(
                invitation: invitation,
                assessment: OriginTrust.assess(invitation, against: pinnedOrigin),
                fromLink: fromLink
            )
            statusMessage = nil
            return true
        case .routeUpdate(let update):
            return await applyRouteUpdate(update)
        case nil:
            statusMessage = String(localized: "That is not a Shell pairing or route QR.")
            return false
        }
    }

    /// The user's explicit yes to the staged invitation.
    func confirmPendingPairing() async {
        guard let pending = pendingPairing else { return }
        pendingPairing = nil
        await pair(with: pending.invitation)
    }

    func cancelPendingPairing() {
        pendingPairing = nil
    }

    private func pair(with invitation: PairingInvitation) async {
        guard !isPairing else { return }
        let assessment = OriginTrust.assess(invitation, against: pinnedOrigin)
        isPairing = true
        pairingProgress = nil
        statusMessage = nil
        defer { isPairing = false }
        let flow = ControlPairingFlow(gateway: gateway, platformLabel: Self.deviceLabel)
        do {
            try await flow.run(invitation, replacesOrigin: assessment == .differentOrigin) { progress in
                self.pairingProgress = progress
            }
            if assessment == .differentOrigin {
                // A new origin key is a new trust relationship: the Watch
                // bound through the old one must be enrolled again.
                ControlWatchGateway.shared.forgetWatch()
                ControlPushCapability.forget()
            }
            pairingProgress = nil
            statusMessage = String(localized: "Paired")
            await start()
        } catch {
            statusMessage = String(describing: error)
            pinnedOrigin = await gateway.pinnedOrigin
        }
    }

    /// Adopts an origin-signed route update. Existing Shell trust is kept.
    func applyRouteUpdate(_ update: OriginRouteUpdate) async -> Bool {
        do {
            pinnedOrigin = try await gateway.adopt(update)
            statusMessage = String(localized: "Route updated. Pairing is unchanged.")
            await refresh()
            return true
        } catch {
            statusMessage = String(localized: "Route update rejected: \(String(describing: error))")
            return false
        }
    }

    /// Forgets this iPhone's Shell credentials; the Mac stays pinned, so
    /// pairing again is not a new trust decision.
    func signOut() async {
        await gateway.signOut(forgetOrigin: false)
        clear()
        phase = pinnedOrigin == nil ? .notConfigured : .needsEnrollment
    }

    /// Forgets the Mac entirely: origin, credentials, and Watch binding.
    func forgetMac() async {
        await gateway.signOut(forgetOrigin: true)
        ControlWatchGateway.shared.forgetWatch()
        ControlPushCapability.forget()
        clear()
        pinnedOrigin = nil
        phase = .notConfigured
    }

    private func clear() {
        pending = []
        lastRefreshedAt = nil
        statusMessage = nil
        routeState = .unknown
    }

    // MARK: Review

    func refresh() async {
        guard phase == .ready else { return }
        do {
            let client = try await gateway.authenticatedClient()
            var page = try await client.snapshot()
            var approvals = page.approvals
            while let next = page.nextPageToken {
                page = try await client.snapshot(pageToken: next)
                approvals += page.approvals
            }
            pending = approvals.filter { $0.projection.resolution == .pending }
            lastRefreshedAt = page.serverTime
            routeState = .reachable(await gateway.currentRoute?.url.host ?? "")
            statusMessage = nil
            await reconcileJournal(client: client)
        } catch {
            await note(error)
        }
        publishWatchContext(refreshRequested: false)
    }

    /// Always re-fetches: the phone is a fuller review surface, not a cache the
    /// user decides from.
    func fetch(_ requestID: ControlID) async throws -> ApprovalRecord {
        do {
            return try await gateway.authenticatedClient().approval(requestID)
        } catch {
            await note(error)
            throw error
        }
    }

    func decide(_ decision: ControlDecision, on record: ApprovalRecord) async {
        guard let journal, let material = await gateway.signingMaterial() else { return }
        do {
            let client = try await gateway.authenticatedClient()
            let coordinator = DecisionCoordinator(service: client, journal: journal, key: material.key, signer: material.signer)
            statusMessage = Self.describe(try await coordinator.decide(decision, reviewed: record))
        } catch {
            await note(error)
        }
        await refresh()
    }

    /// Ambiguous outcomes are reconciled by their original command ID; a
    /// replacement decision is never minted.
    private func reconcileJournal(client: ControlAPIClient) async {
        guard let journal, let material = await gateway.signingMaterial() else { return }
        let coordinator = DecisionCoordinator(service: client, journal: journal, key: material.key, signer: material.signer)
        for command in await journal.pending {
            _ = try? await coordinator.reconcile(command)
        }
    }

    private func note(_ error: any Error) async {
        switch error {
        case let unavailable as TailnetUnavailable:
            await gateway.invalidateRoute()
            routeState = .unavailable(unavailable.reason)
            statusMessage = unavailable.reason
        case let resolution as OriginRouteResolver.ResolutionError:
            await gateway.invalidateRoute()
            routeState = .unavailable(resolution.description)
            statusMessage = resolution == .originMismatch
                ? String(localized: "The Mac at this route is not the paired Shell origin. Scan a route QR from shell-control route, or pair again.")
                : String(localized: "The private Mac route is unavailable. Check Tailscale on this iPhone.")
        case ControlGatewaySession.SessionError.pairingRequired(let reason):
            phase = .needsEnrollment
            statusMessage = reason
        default:
            statusMessage = String(describing: error)
        }
    }

    // MARK: Watch gateway and push

    func publishWatchContext(refreshRequested: Bool) {
        let reachable: Bool
        if case .reachable = routeState { reachable = true } else { reachable = false }
        ControlPairingSupport.publish(ControlWatchGateway.shared.context(
            pending: pending,
            refreshedAt: lastRefreshedAt,
            macReachable: reachable,
            refreshRequested: refreshRequested
        ))
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) async {
        guard phase == .ready else { return }
        await ControlPushCapability.publish(deviceToken: deviceToken, gateway: gateway)
    }

    /// An approval hint: opportunistically refresh and stage the Watch's
    /// cache. Correctness never depends on this running.
    func handleApprovalHint() async {
        await refresh()
        publishWatchContext(refreshRequested: true)
    }

    static func describe(_ state: SubmissionState) -> String {
        switch state {
        case .sending: return String(localized: "Sending")
        case .decisionRecorded: return String(localized: "Decision recorded")
        case .waitingForHost: return String(localized: "Waiting for host")
        case .hostAccepted: return String(localized: "Host accepted")
        case .notApplied: return String(localized: "Not applied")
        case .outcomeUnknown: return String(localized: "Outcome unknown")
        }
    }

    /// A handoff hint carries identity and expiry only. It cannot force a
    /// device to open, cannot authorize work, and no execution adapter accepts
    /// it (spec.watch.md section 13).
    func handoffHint(for record: ApprovalRecord) -> JSONValue {
        .object([
            "v": 1,
            "type": .string(ControlCommandType.handoffRequest.rawValue),
            "request_id": JSONValue(record.spec.requestID),
            "job_id": JSONValue(record.spec.jobID),
            "expires_at": JSONValue(record.spec.expiresAt)
        ])
    }

    static var deviceLabel: String {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #elseif os(visionOS)
        return "Vision"
        #elseif canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        return "iPhone"
        #endif
    }
}
