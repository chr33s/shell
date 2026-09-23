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
    /// Signed decisions whose outcome is not yet known. File-backed, so an
    /// ambiguous submission survives a relaunch and is still reconciled by
    /// its original command ID rather than forgotten.
    @ObservationIgnored private var journal: CommandJournal?
    @ObservationIgnored private let makeJournalStore: () throws -> any CommandJournalStore
    /// The Mac's approvals as last reconciled, with the change cursor that
    /// lets the next refresh fetch only what changed.
    @ObservationIgnored private var inbox = InboxReconciler()

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
        transport: any ControlHTTPTransport = ControlTailnetTransport(),
        journalStore: @escaping () throws -> any CommandJournalStore = { try FileCommandJournalStore() }
    ) {
        gateway = ControlGatewaySession(credentials: credentials, origins: origins, transport: transport)
        makeJournalStore = journalStore
        journal = try? CommandJournal(store: journalStore())
    }

    /// The journal, reopened if its store could not be created earlier.
    /// Never replaced by an empty in-memory journal: that would drop the
    /// persisted entries. A store that exists but cannot be read yet (before
    /// first unlock) is retried by the journal itself.
    private func commandJournal() -> CommandJournal? {
        if let journal { return journal }
        journal = try? CommandJournal(store: makeJournalStore())
        return journal
    }

    var originFingerprint: String? { pinnedOrigin?.origin.fingerprint }
    var currentRoute: String? { pinnedOrigin?.routes.first?.url.absoluteString }

    func start() async {
        phase = await loadPhase()
        guard phase == .ready else { return }
        await refresh()
        ControlPushCapability.registerIfConfigured()
    }

    /// Reads the pinned origin and session from the Keychain. Both are
    /// after-first-unlock items, so this also works while the phone is locked.
    private func loadPhase() async -> Phase {
        pinnedOrigin = await gateway.pinnedOrigin
        guard pinnedOrigin != nil else { return .notConfigured }
        guard await gateway.deviceSession != nil else { return .needsEnrollment }
        return .ready
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
            // Read the store, not the cache: a link can arrive at cold
            // launch before start() has loaded the pinned origin.
            pinnedOrigin = await gateway.pinnedOrigin
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
        isPairing = true
        pinnedOrigin = await gateway.pinnedOrigin
        let assessment = OriginTrust.assess(invitation, against: pinnedOrigin)
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
        inbox = InboxReconciler()
        pending = []
        lastRefreshedAt = nil
        statusMessage = nil
        routeState = .unknown
    }

    // MARK: Review

    /// Returns whether the snapshot was fetched.
    @discardableResult
    func refresh() async -> Bool {
        guard phase == .ready else { return false }
        var fetched = false
        do {
            let client = try await gateway.authenticatedClient()
            let state = try await reconcileInbox(client: client)
            pending = state.pendingApprovals
            lastRefreshedAt = state.lastRefreshedAt
            routeState = .reachable(await gateway.currentRoute?.url.host ?? "")
            statusMessage = nil
            fetched = true
            await reconcileJournal(client: client)
        } catch {
            await note(error)
        }
        publishWatchContext(refreshRequested: false)
        return fetched
    }

    /// One full snapshot, then only the change log after its cursor: a
    /// refresh (every approval hint, every pull) costs the deltas since the
    /// last one rather than the whole approval history, 50 per page. A
    /// cursor the broker no longer honours falls back to a fresh snapshot.
    private func reconcileInbox(client: ControlAPIClient) async throws -> InboxState {
        var reconciler = inbox
        if let cursor = reconciler.state.cursor {
            do {
                var next = cursor
                for _ in 0..<Self.maxChangePagesPerRefresh {
                    let page = try await client.changes(after: next)
                    reconciler.apply(page)
                    next = page.cursor
                    if page.events.count < ChangePage.maximumEvents { break }
                }
            } catch let error as ControlError where error.code == .cursorExpired || error.code == .notFound {
                reconciler = InboxReconciler()
            }
        }
        if reconciler.state.cursor == nil {
            var page = try await client.snapshot()
            var accumulator = InboxReconciler.SnapshotAccumulator(firstPage: page)
            while let next = page.nextPageToken {
                page = try await client.snapshot(pageToken: next)
                try accumulator.append(page)
            }
            try reconciler.applyCompletedSnapshot(accumulator, at: page.serverTime)
        }
        inbox = Self.bounded(reconciler)
        return inbox.state
    }

    /// A long-idle phone catches up over several refreshes rather than one
    /// unbounded loop.
    private static let maxChangePagesPerRefresh = 10
    /// Decided requests kept in memory. Only pending ones are shown.
    private static let maxResolvedApprovals = 256

    /// The reconciler never drops resolved approvals; trim the oldest so a
    /// long-running app does not grow without bound.
    private static func bounded(_ reconciler: InboxReconciler) -> InboxReconciler {
        let resolved = reconciler.state.recentOutcomes
        guard resolved.count > maxResolvedApprovals else { return reconciler }
        var state = reconciler.state
        for record in resolved.dropFirst(maxResolvedApprovals) {
            state.approvals.removeValue(forKey: record.spec.requestID)
        }
        return InboxReconciler(state: state)
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
        guard let journal = commandJournal() else {
            // Never sign without somewhere durable to record the command.
            statusMessage = String(localized: "Decisions are unavailable: this iPhone cannot store them right now.")
            return
        }
        guard let material = await gateway.signingMaterial() else { return }
        let outcome: String?
        do {
            let client = try await gateway.authenticatedClient()
            let coordinator = DecisionCoordinator(
                service: client, journal: journal, key: material.key, signer: material.signer, review: Self.review
            )
            outcome = Self.describe(try await coordinator.decide(decision, reviewed: record))
        } catch let error as ControlError where error.provesCommandNotRecorded
            && error.code != .deviceRevoked && error.code != .reviewerNotBound {
            // A final refusal: nothing was recorded and nothing will be
            // retried. Say why; the review screen refetches the request so
            // the user reviews it afresh before deciding again.
            outcome = Self.notRecordedText(error)
        } catch let error as DecisionCoordinator.CoordinatorError {
            outcome = Self.describe(error)
        } catch is CommandJournalUnavailable {
            // Nothing was signed or sent: the journal could not be read, and
            // recording into it now would overwrite what it holds.
            outcome = String(localized: "Decisions are unavailable until this iPhone is unlocked.")
        } catch {
            await note(error)
            outcome = statusMessage
        }
        await refresh()
        // A successful refresh clears the status line; the decision's outcome
        // is what the user needs to see.
        if let outcome { statusMessage = outcome }
    }

    /// The phone is a full-review client: it may approve requests whose
    /// `minimum_review` is `full` (spec.watch.md section 6). The review
    /// screen gates its Approve button on the same level.
    nonisolated static let review: MinimumReview = .full

    /// A definitive broker refusal: the command was not recorded and was
    /// dropped from the journal, so nothing retries it. Says why, and what to
    /// do next.
    static func notRecordedText(_ error: ControlError) -> String {
        let reason = String(localized: "Not recorded: \(error.message)")
        switch error.code {
        case .staleVersion, .policyChanged, .hashMismatch, .challengeExpired:
            return reason + "\n" + String(localized: "The request changed. Review it again before deciding.")
        case .originUnavailable:
            return reason + "\n" + String(localized: "The Mac is not present right now.")
        case .requestExpired:
            return reason + "\n" + String(localized: "The request expired.")
        default:
            return reason
        }
    }

    static func describe(_ error: DecisionCoordinator.CoordinatorError) -> String {
        switch error {
        case .requestChangedDuringReview:
            return String(localized: "This request changed while you were reviewing it. Review it again.")
        case .notApprovableOnWatch(let reason):
            return reviewElsewhereText(reason)
        case .decisionNotAllowed:
            return String(localized: "That decision is not allowed for this request")
        case .missingGrant:
            return String(localized: "This iPhone is not allowed to do that")
        case .noSession:
            return String(localized: "Pair this iPhone with your Mac again")
        }
    }

    static func reviewElsewhereText(_ reason: WatchApprovability.Reason) -> String {
        switch reason {
        case .unknownOperationSchema, .unsupportedRequiredFeature:
            return String(localized: "This operation is not supported on this iPhone")
        case .policyRequiresFullReview:
            return String(localized: "Policy requires review on another device")
        case .alreadyResolved:
            return String(localized: "Already resolved")
        case .expired:
            return String(localized: "Expired")
        case .sourceNotPresent:
            return String(localized: "The host is not waiting right now")
        }
    }

    /// Ambiguous outcomes are reconciled by their original command ID; a
    /// replacement decision is never minted.
    private func reconcileJournal(client: ControlAPIClient) async {
        guard let journal = commandJournal(), let material = await gateway.signingMaterial() else { return }
        let coordinator = DecisionCoordinator(
            service: client, journal: journal, key: material.key, signer: material.signer, review: Self.review
        )
        for command in await journal.pending {
            _ = try? await coordinator.reconcile(command)
        }
    }

    private func note(_ error: any Error) async {
        switch await gateway.recover(from: error) {
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
        case ControlGatewaySession.SessionError.notPaired:
            pinnedOrigin = await gateway.pinnedOrigin
            phase = pinnedOrigin == nil ? .notConfigured : .needsEnrollment
            statusMessage = nil
        case let error:
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
    /// cache. Correctness never depends on this running. A hint can wake the
    /// app while locked, before start() has run, so the session is loaded
    /// here; a phase that is not ready is left for start() to report.
    /// Returns nil when there is no session to fetch with (not a failure),
    /// otherwise whether the fetch succeeded.
    func handleApprovalHint() async -> Bool? {
        if phase != .ready, await loadPhase() == .ready { phase = .ready }
        guard phase == .ready else { return nil }
        let fetched = await refresh()
        publishWatchContext(refreshRequested: true)
        return fetched
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
