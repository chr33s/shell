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
    /// This iPhone's device record on the Mac, for the setup-test command.
    private(set) var deviceID: ControlID?
    /// The remote-alert choice for this Mac and this iPhone, and whether the
    /// Mac has acknowledged it (spec.control-companion-setup.md section 10).
    private(set) var alertPolicy: RemoteAlertPolicy?
    private(set) var notificationsDenied = false
    /// The last explicit diagnostic pass from this iPhone's vantage.
    private(set) var diagnostics: DiagnosticReport?
    private(set) var isCheckingConnection = false
    /// When the private route was last proved by a refresh or check.
    private(set) var routeCheckedAt: Date?
    /// The most recent setup-test request this iPhone has seen.
    private(set) var latestSetupTest: ApprovalRecord?
    /// Recently decided agent approvals, newest first, for the agent view's
    /// outcomes (spec.agent-relay.md section 13.1).
    private(set) var agentApprovalOutcomes: [ApprovalRecord] = []
    /// The optional agent integration: questions, sessions, and detailed
    /// delivery, kept apart from the base inbox (spec.agent-relay.md 12.2).
    let agent = ControlAgentCenter()

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
    @ObservationIgnored private let alertStore: any RemoteAlertPolicyStore
    @ObservationIgnored private var alertCoordinator: RemoteAlertCoordinator?
    /// Set by a pairing made in this build: its policy starts as a fresh
    /// guided setup (alerts off), not as a migrated installation.
    @ObservationIgnored private var freshlyPaired = false
    @ObservationIgnored private let diagnosticPasses = DiagnosticPassCoordinator()

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
        journalStore: @escaping () throws -> any CommandJournalStore = { try FileCommandJournalStore() },
        alertStore: any RemoteAlertPolicyStore = DefaultsRemoteAlertPolicyStore()
    ) {
        gateway = ControlGatewaySession(credentials: credentials, origins: origins, transport: transport)
        makeJournalStore = journalStore
        self.alertStore = alertStore
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
        if let policy = alertPolicy { ControlPushCapability.requestRegistration(policy: policy) }
    }

    /// Reads the pinned origin and session from the Keychain. Both are
    /// after-first-unlock items, so this also works while the phone is locked.
    private func loadPhase() async -> Phase {
        pinnedOrigin = await gateway.pinnedOrigin
        deviceID = await gateway.deviceSession?.deviceID
        guard pinnedOrigin != nil else { return .notConfigured }
        guard deviceID != nil else { return .needsEnrollment }
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
                if let previous = pinnedOrigin?.origin.originID.rawValue { forgetAlerts(originID: previous) }
            }
            freshlyPaired = true
            alertCoordinator = nil
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
        let stillNotified = await disableAlertsBeforeLeaving()
        if let origin = pinnedOrigin?.origin.originID.rawValue, let device = deviceID?.rawValue {
            alertStore.remove(originID: origin, deviceID: device)
        }
        await gateway.signOut(forgetOrigin: false)
        clear()
        statusMessage = stillNotified
        phase = pinnedOrigin == nil ? .notConfigured : .needsEnrollment
    }

    /// Forgets the Mac entirely: origin, credentials, and Watch binding.
    func forgetMac() async {
        let stillNotified = await disableAlertsBeforeLeaving()
        if let origin = pinnedOrigin?.origin.originID.rawValue { forgetAlerts(originID: origin) }
        await gateway.signOut(forgetOrigin: true)
        ControlWatchGateway.shared.forgetWatch()
        clear()
        statusMessage = stillNotified
        pinnedOrigin = nil
        phase = .notConfigured
    }

    private func clear() {
        inbox = InboxReconciler()
        pending = []
        agentApprovalOutcomes = []
        agent.reset()
        lastRefreshedAt = nil
        statusMessage = nil
        routeState = .unknown
        routeCheckedAt = nil
        diagnostics = nil
        alertPolicy = nil
        alertCoordinator = nil
        latestSetupTest = nil
        deviceID = nil
    }

    private func forgetAlerts(originID: String) {
        alertStore.removeAll(originID: originID)
        alertCoordinator = nil
    }

    /// Leaving a Mac must not leave its record sending alerts to this
    /// iPhone: the credentials are about to go, so ask the Mac to suppress
    /// and forget this device's delivery material first. Returns a warning
    /// when the Mac could not confirm it.
    private func disableAlertsBeforeLeaving() async -> String? {
        guard phase == .ready, let alerts = await remoteAlerts() else { return nil }
        _ = await alerts.choose(.off)
        let acknowledged = await withProbeDeadline(.seconds(8)) { [gateway] () -> Bool in
            guard let client = try? await gateway.authenticatedClient() else { return false }
            return await alerts.reconcile(with: client).host == .acknowledged
        }
        guard acknowledged != true else { return nil }
        let id = deviceID?.rawValue ?? "<DEVICE-ID>"
        return String(localized: "The Mac could not confirm that alerts to this iPhone stopped. To stop them, run shell-control revoke \(id) on the Mac.")
    }

    // MARK: Review

    /// Returns whether the snapshot was fetched. `forceAgent` lets an
    /// explicit refresh or a just-sent answer skip the agent poll floor.
    @discardableResult
    func refresh(forceAgent: Bool = false) async -> Bool {
        guard phase == .ready else { return false }
        var fetched = false
        do {
            let client = try await gateway.authenticatedClient()
            let state = try await reconcileInbox(client: client)
            pending = state.pendingApprovals
            lastRefreshedAt = state.lastRefreshedAt
            latestSetupTest = state.approvals.values
                .filter { SetupTestFixture.isIPhoneTest($0.spec) }
                .max { $0.spec.createdAt < $1.spec.createdAt }
            agentApprovalOutcomes = Array(state.recentOutcomes.filter(\.isAgentApproval).prefix(20))
            routeState = .reachable(await gateway.currentRoute?.url.host ?? "")
            routeCheckedAt = Date()
            statusMessage = nil
            fetched = true
            await reconcileJournal(client: client)
            // Its own feed and cursor; a Mac without the extension or an
            // iPhone without the grant costs one throttled probe.
            await agent.refresh(using: client, grants: await gateway.deviceSession?.grants ?? [], force: forceAgent)
            // Foreground reconnection also finishes an unacknowledged alert
            // choice — only that settings intent, never approval commands.
            await syncRemoteAlerts(client: client)
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
    nonisolated static func notRecordedText(_ error: ControlError) -> String {
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
    /// replacement decision is never minted. Agent answers are asked about
    /// only through the agent endpoints (spec.agent-relay.md section 8.3).
    private func reconcileJournal(client: ControlAPIClient) async {
        guard let journal = commandJournal(), let material = await gateway.signingMaterial() else { return }
        let coordinator = DecisionCoordinator(
            service: client, journal: journal, key: material.key, signer: material.signer, review: Self.review
        )
        let answers = AgentInputCoordinator(
            service: client, journal: journal, key: material.key, signer: material.signer, review: Self.review
        )
        for command in await journal.pending {
            if command.isAgentCommand {
                // Session commands reconcile through the same command
                // endpoint, by their own command ID; their target is the
                // session, not a question.
                guard let state = try? await answers.reconcile(command) else { continue }
                switch command.agentType {
                case .agentMessage?, .turnCancel?:
                    agent.noteSessionCommand(state, commandID: command.commandID, sessionID: command.targetID)
                default:
                    agent.note(state, for: command.targetID)
                }
            } else {
                _ = try? await coordinator.reconcile(command)
            }
        }
    }

    // MARK: Agent questions

    /// Pending approvals for agent operations, shown in the agent view.
    var agentPending: [ApprovalRecord] { pending.filter(\.isAgentApproval) }
    /// Every other pending approval, shown under Requests.
    var basePending: [ApprovalRecord] { pending.filter { !$0.isAgentApproval } }

    /// A notification or link names a request without saying which kind: an
    /// approval is tried first and, only on `not_found`, a typed question
    /// (spec.agent-relay.md section 12.3). Always a live fetch.
    func lookup(_ requestID: ControlID) async throws -> ControlRequestLookup.Found {
        let client: ControlAPIClient
        do {
            client = try await gateway.authenticatedClient()
        } catch {
            await note(error)
            throw error
        }
        let mayReadInputs = await gateway.deviceSession?.grants.contains(.agentInputsRead) ?? false
        do {
            let found = try await ControlRequestLookup.resolve(
                approval: { try await client.approval(requestID) },
                input: mayReadInputs ? { try await client.input(requestID) } : nil
            )
            if case .input(let record) = found { agent.adopt(record) }
            return found
        } catch let error as ControlError where error.code == .notFound {
            throw error
        } catch {
            await note(error)
            throw error
        }
    }

    /// The exact question, refetched and its digest recomputed before review.
    func fetchInput(_ requestID: ControlID) async throws -> InputRecord {
        do {
            let record = try await gateway.authenticatedClient().input(requestID)
            agent.adopt(record)
            return record
        } catch {
            await note(error)
            throw error
        }
    }

    /// Signs and sends one typed answer or decline with this iPhone's key,
    /// through the same review → challenge → sign → journal → submit
    /// sequence as a decision (spec.agent-relay.md section 8.2).
    func respond(_ response: InputResponse, to record: InputRecord) async {
        let requestID = record.spec.requestID
        guard let journal = commandJournal() else {
            agent.noteNotSent(String(localized: "Answers are unavailable: this iPhone cannot store them right now."), for: requestID)
            return
        }
        guard let material = await gateway.signingMaterial() else { return }
        agent.noteSending(requestID)
        do {
            let client = try await gateway.authenticatedClient()
            let coordinator = AgentInputCoordinator(
                service: client, journal: journal, key: material.key, signer: material.signer, review: Self.review
            )
            agent.note(try await coordinator.respond(response, reviewed: record), for: requestID)
        } catch let error as ControlError where error.provesCommandNotRecorded
            && error.code != .deviceRevoked && error.code != .reviewerNotBound {
            agent.noteNotSent(Self.notRecordedText(error), for: requestID)
        } catch let error as AgentInputCoordinator.CoordinatorError {
            agent.noteNotSent(ControlAgentText.coordinatorError(error), for: requestID)
        } catch is CommandJournalUnavailable {
            agent.noteNotSent(String(localized: "Answers are unavailable until this iPhone is unlocked."), for: requestID)
        } catch {
            // Refused or unreachable before a recorded answer was confirmed.
            // Any journalled command is reconciled by its own ID; the refresh
            // below shows the question as it now stands.
            await note(error)
            agent.noteNotSent((error as? ControlError)?.message ?? statusMessage ?? String(describing: error), for: requestID)
        }
        await refresh(forceAgent: true)
    }

    // MARK: Managed sessions

    /// The session, refetched live so review shows its current turn state.
    func fetchAgentSession(_ sessionID: ControlID) async throws -> AgentSessionProjection {
        do {
            let session = try await gateway.authenticatedClient().agentSession(sessionID)
            agent.adopt(session)
            return session
        } catch {
            await note(error)
            throw error
        }
    }

    /// Signs and sends exactly the confirmed action, built from the session
    /// as reviewed. A moved session is reported and refetched for a fresh
    /// review; nothing is resent or retargeted (spec.agent-relay.md 16).
    func sendSessionCommand(_ proposal: AgentSessionProposal) async {
        let sessionID = proposal.action.agentSessionID
        guard let journal = commandJournal() else {
            agent.noteSessionNotSent(String(localized: "Messages are unavailable: this iPhone cannot store them right now."), sessionID: sessionID)
            return
        }
        guard let material = await gateway.signingMaterial() else { return }
        agent.noteSessionSending(sessionID)
        do {
            let client = try await gateway.authenticatedClient()
            let coordinator = AgentSessionCoordinator(service: client, journal: journal, key: material.key, signer: material.signer)
            switch try await AgentSessionSender.send(proposal, with: coordinator) {
            case .submitted(let state):
                if let commandID = AgentSessionSender.commandID(of: state) {
                    agent.noteSessionCommand(state, commandID: commandID, sessionID: sessionID, action: proposal.action)
                }
            case .refused(let failure):
                agent.noteSessionNotSent(failure.text, sessionID: sessionID)
            }
        } catch is CommandJournalUnavailable {
            agent.noteSessionNotSent(String(localized: "Messages are unavailable until this iPhone is unlocked."), sessionID: sessionID)
        } catch {
            await note(error)
            agent.noteSessionNotSent((error as? ControlError)?.message ?? statusMessage ?? String(describing: error), sessionID: sessionID)
        }
        await refresh(forceAgent: true)
        _ = try? await fetchAgentSession(sessionID)
    }

    /// Follows this session's unsettled commands by their command IDs.
    /// Callers pace this at or above the poll floor.
    func followSessionCommands(_ sessionID: ControlID) async {
        await refresh()
        guard let client = try? await gateway.authenticatedClient() else { return }
        // Only this iPhone's own commands are asked about directly; the
        // agent feed carries every other record.
        let pending = agent.pendingSessionCommands(sessionID).filter { agent.sessionCommands[$0] != nil }
        if !pending.isEmpty, let journal = commandJournal(), let material = await gateway.signingMaterial() {
            let coordinator = AgentSessionCoordinator(service: client, journal: journal, key: material.key, signer: material.signer)
            for commandID in pending {
                if let state = try? await coordinator.refresh(commandID) {
                    agent.noteSessionCommand(state, commandID: commandID, sessionID: sessionID)
                }
            }
        }
        if let session = try? await client.agentSession(sessionID) { agent.adopt(session) }
    }

    private func note(_ error: any Error) async {
        switch await gateway.recover(from: error) {
        case let unavailable as TailnetUnavailable:
            await gateway.invalidateRoute()
            routeState = .unavailable(unavailable.reason)
            routeCheckedAt = Date()
            statusMessage = unavailable.reason
        case let resolution as OriginRouteResolver.ResolutionError:
            await gateway.invalidateRoute()
            routeState = .unavailable(resolution.description)
            routeCheckedAt = Date()
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
        guard phase == .ready, let alerts = await remoteAlerts() else { return }
        await ControlPushCapability.publish(deviceToken: deviceToken, gateway: gateway, alerts: alerts)
        alertPolicy = await alerts.policy
    }

    /// APNs gave no token. Recorded only while alerts are wanted.
    func didFailToRegisterForRemoteNotifications() async {
        guard phase == .ready, let alerts = await remoteAlerts(), let generation = await alerts.beginRegistration() else { return }
        await alerts.recordFailure(.tokenUnavailable, generation: generation)
        alertPolicy = await alerts.policy
    }

    // MARK: Remote alerts

    /// The coordinator for this Mac and this iPhone's device record.
    private func remoteAlerts() async -> RemoteAlertCoordinator? {
        guard let origin = await gateway.pinnedOrigin?.origin.originID.rawValue,
              let device = await gateway.deviceSession?.deviceID.rawValue else { return nil }
        if let existing = alertCoordinator, existing.originID == origin, existing.deviceID == device { return existing }
        let fresh = freshlyPaired
        let coordinator = RemoteAlertCoordinator(
            originID: origin, deviceID: device, store: alertStore,
            initial: fresh ? .freshDefault : ControlPushCapability.migratedPolicy(deviceID: device)
        )
        freshlyPaired = false
        alertCoordinator = coordinator
        return coordinator
    }

    /// Reconciles an unacknowledged choice with the Mac, if connected.
    private func syncRemoteAlerts(client: ControlAPIClient) async {
        guard let alerts = await remoteAlerts() else { return }
        var policy = await alerts.policy
        if policy.host != .acknowledged, !policy.needsChoice {
            policy = await alerts.reconcile(with: client)
        }
        alertPolicy = policy
        notificationsDenied = policy.choice == .configured ? await ControlPushCapability.notificationsDenied() : false
    }

    /// The user's explicit choice. Local registration work stops before the
    /// Mac is contacted; with the Mac offline the choice shows as pending.
    func setRemoteAlerts(_ choice: RemoteAlertChoice) async {
        guard let alerts = await remoteAlerts() else { return }
        alertPolicy = await alerts.choose(choice)
        if let client = try? await gateway.authenticatedClient() {
            alertPolicy = await alerts.reconcile(with: client)
        }
        if choice == .configured, let policy = alertPolicy {
            notificationsDenied = await ControlPushCapability.notificationsDenied()
            ControlPushCapability.requestRegistration(policy: policy)
        }
    }

    // MARK: Diagnostics

    /// One explicit, bounded diagnostic pass from this iPhone's vantage. It
    /// never creates requests, enrolls devices, or sends notifications, and
    /// a green result authorizes nothing.
    func checkConnection() async {
        guard !isCheckingConnection else { return }
        isCheckingConnection = true
        defer { isCheckingConnection = false }
        phase = await loadPhase()
        let paired = phase == .ready
        let gateway = gateway
        // The pass itself touches no companion state, so one that outlives
        // its budget cannot change what is shown afterwards.
        let report = await diagnosticPasses.run({
            await Self.connectionPass(gateway: gateway, paired: paired)
        }, timedOut: {
            DiagnosticReport(generatedAt: ControlTimestamp(Date()), vantage: .iphone, checks: [
                DiagnosticCheck(id: "mac_route", code: .notChecked, state: .unknown, requiredFor: [.iphoneReview],
                                source: "authenticated_route_check", observedAt: nil,
                                summary: String(localized: "The check ran out of time. That alone does not show whether the Mac is asleep, on another tailnet, or revoked."),
                                action: .checkTailscaleOnIPhone)
            ])
        })
        let now = report.generatedAt
        let route = report.check("mac_route")
        let routeOK = route?.state == .pass && report.check("origin_identity")?.state == .pass
        if route?.state != .unknown {
            routeState = routeOK
                ? .reachable(await gateway.currentRoute?.url.host ?? "")
                : .unavailable(route?.summary ?? report.check("origin_identity")?.summary ?? "")
            routeCheckedAt = now.date
        }
        if report.check("reviewer")?.code == .reviewerRevoked { phase = .needsEnrollment }
        if routeOK {
            // Bounded like the probes: a stuck reconcile never holds the check.
            _ = await withProbeDeadline(.seconds(8)) { [gateway] in
                if let client = try? await gateway.authenticatedClient() { await self.syncRemoteAlerts(client: client) }
            }
        }
        diagnostics = DiagnosticReport(generatedAt: now, vantage: .iphone,
                                       checks: report.checks + [await watchCheck(routeOK: routeOK, now: now), alertCheck(now: now)])
    }

    /// Route, identity, and session evidence from this iPhone's vantage,
    /// each probe bounded well inside the pass budget.
    nonisolated private static func connectionPass(gateway: ControlGatewaySession, paired: Bool) async -> DiagnosticReport {
        let now = ControlTimestamp(Date())
        var checks: [DiagnosticCheck] = []
        guard paired else {
            checks.append(DiagnosticCheck(
                id: "pairing", code: .notPaired, state: .notConfigured, requiredFor: [.iphoneReview, .watchReview],
                source: "local_pairing_state", observedAt: now,
                summary: String(localized: "This iPhone is not paired with a Mac."), action: .pairIPhone))
            return DiagnosticReport(generatedAt: now, vantage: .iphone, checks: checks)
        }
        let probe: Duration = .seconds(8)

        // Route and identity: a fresh proof, not the cached route.
        await gateway.invalidateRoute()
        let routeResult = await withProbeDeadline(probe) { () -> Result<String, any Error> in
            do { return .success(try await gateway.verifiedRoute().route.url.host ?? "") } catch { return .failure(error) }
        }
        var routeOK = false
        switch routeResult {
        case .success?:
            routeOK = true
            checks.append(DiagnosticCheck(id: "mac_route", code: .routeReachable, state: .pass, requiredFor: [.iphoneReview],
                                          source: "authenticated_route_check", observedAt: now,
                                          summary: String(localized: "The Mac answered on its private route.")))
            checks.append(DiagnosticCheck(id: "origin_identity", code: .originVerified, state: .pass, requiredFor: [.iphoneReview, .watchReview],
                                          source: "authenticated_origin_proof", observedAt: now,
                                          summary: String(localized: "The Mac proved the pinned origin identity.")))
        case .failure(let error as OriginRouteResolver.ResolutionError)? where error == .originMismatch:
            checks.append(DiagnosticCheck(id: "mac_route", code: .routeReachable, state: .pass, requiredFor: [.iphoneReview],
                                          source: "authenticated_route_check", observedAt: now,
                                          summary: String(localized: "An endpoint answered at the Mac's route.")))
            checks.append(DiagnosticCheck(id: "origin_identity", code: .originKeyMismatch, state: .fail, requiredFor: [.iphoneReview, .watchReview],
                                          source: "authenticated_origin_proof", observedAt: now,
                                          summary: String(localized: "The endpoint did not prove the paired Mac's key. Review is blocked; trust was not changed."),
                                          action: .pairAgain))
        case .failure(let error)?:
            checks.append(DiagnosticCheck(id: "mac_route", code: .routeUnreachable, state: .fail, requiredFor: [.iphoneReview],
                                          source: "authenticated_route_check", observedAt: now,
                                          summary: String(localized: "The Mac did not answer: \(String(describing: error))"),
                                          action: .checkTailscaleOnIPhone))
            checks.append(DiagnosticCheck(id: "origin_identity", code: .notChecked, state: .unknown, requiredFor: [.iphoneReview, .watchReview],
                                          source: "authenticated_origin_proof", observedAt: nil,
                                          summary: String(localized: "Not checked: the Mac was not reached.")))
        case nil:
            checks.append(DiagnosticCheck(id: "mac_route", code: .notChecked, state: .unknown, requiredFor: [.iphoneReview],
                                          source: "authenticated_route_check", observedAt: nil,
                                          summary: String(localized: "No answer in time. A timeout alone does not show whether the Mac is asleep, on another tailnet, or revoked."),
                                          action: .checkTailscaleOnIPhone))
            checks.append(DiagnosticCheck(id: "origin_identity", code: .notChecked, state: .unknown, requiredFor: [.iphoneReview, .watchReview],
                                          source: "authenticated_origin_proof", observedAt: nil,
                                          summary: String(localized: "Not checked: the Mac was not reached.")))
        }

        // This iPhone's reviewer session: an authenticated read.
        if routeOK {
            let reviewer = await withProbeDeadline(probe) { () -> (any Error)? in
                do {
                    _ = try await gateway.authenticatedClient().snapshot(limit: 1)
                    return nil
                } catch {
                    return await gateway.recover(from: error)
                }
            }
            switch reviewer {
            case .some(nil):
                checks.append(DiagnosticCheck(id: "reviewer", code: .reviewerReady, state: .pass, requiredFor: [.iphoneReview],
                                              source: "authenticated_session", observedAt: now,
                                              summary: String(localized: "This iPhone's reviewer session is accepted by the Mac.")))
            case .some(let error?):
                if case ControlGatewaySession.SessionError.pairingRequired(let reason) = error {
                    checks.append(DiagnosticCheck(id: "reviewer", code: .reviewerRevoked, state: .fail, requiredFor: [.iphoneReview],
                                                  source: "authenticated_session", observedAt: now, summary: reason, action: .pairAgain))
                } else {
                    checks.append(DiagnosticCheck(id: "reviewer", code: .routeUnreachable, state: .fail, requiredFor: [.iphoneReview],
                                                  source: "authenticated_session", observedAt: now,
                                                  summary: String(localized: "The Mac refused this iPhone's read: \(String(describing: error))")))
                }
            case nil:
                checks.append(DiagnosticCheck(id: "reviewer", code: .notChecked, state: .unknown, requiredFor: [.iphoneReview],
                                              source: "authenticated_session", observedAt: nil,
                                              summary: String(localized: "The reviewer check did not finish in time.")))
            }
        } else {
            checks.append(DiagnosticCheck(id: "reviewer", code: .notChecked, state: .unknown, requiredFor: [.iphoneReview],
                                          source: "authenticated_session", observedAt: nil,
                                          summary: String(localized: "Not checked: the Mac was not reached.")))
        }

        // What this app cannot observe is labelled unknown, never guessed.
        checks.append(DiagnosticCheck(
            id: "tailscale_iphone", code: .notChecked, state: .unknown, source: "not_observable", observedAt: nil,
            summary: String(localized: "Shell cannot see Tailscale's state on this iPhone. If the Mac is unreachable, check that Tailscale is connected to the same tailnet; VPN On Demand can connect it for *.ts.net automatically."),
            action: .checkTailscaleOnIPhone))
        return DiagnosticReport(generatedAt: now, vantage: .iphone, checks: checks)
    }

    private func watchCheck(routeOK: Bool, now: ControlTimestamp) async -> DiagnosticCheck {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let session = ControlPairingSession.shared
        let watch = ControlWatchGateway.shared.boundWatch
        func make(_ code: DiagnosticCode, _ state: DiagnosticState, _ summary: String, _ action: DiagnosticAction? = nil) -> DiagnosticCheck {
            DiagnosticCheck(id: "watch", code: code, state: state, requiredFor: [.watchReview],
                            source: "watch_connectivity_and_binding", observedAt: now, summary: summary, action: action)
        }
        switch watch?.state {
        case .active?:
            if !session.isReachable {
                return make(.watchGatewayUnreachable, .warn, String(localized: "Enrolled through this iPhone, but the Watch app is not reachable right now. Open Shell on the Watch."), .openWatchApp)
            }
            return routeOK
                ? make(.watchReady, .pass, String(localized: "Enrolled through this iPhone and reachable. Each Watch decision still needs a live round trip."))
                : make(.watchGatewayUnreachable, .fail, String(localized: "The Watch is reachable, but this iPhone cannot reach the Mac, so Watch decisions are disabled."), .checkConnection)
        case .pending?:
            return make(.watchPending, .warn, String(localized: "Waiting for confirmation on the Mac."), .confirmEnrollment)
        case .revoked?:
            return make(.reviewerRevoked, .fail, String(localized: "The Mac revoked this Watch reviewer. Set it up again to use it."), .addWatch)
        default:
            return session.isWatchAppInstalled
                ? make(.watchNotConfigured, .notConfigured, String(localized: "No Apple Watch is set up. This is optional."), .addWatch)
                : make(.watchAppNotInstalled, .notConfigured, String(localized: "The Shell Watch app is not installed. This is optional."), .addWatch)
        }
        #else
        return DiagnosticCheck(id: "watch", code: .watchNotConfigured, state: .notConfigured, requiredFor: [.watchReview],
                               source: "watch_connectivity_and_binding", observedAt: now,
                               summary: String(localized: "Apple Watch is not available on this device."))
        #endif
    }

    private func alertCheck(now: ControlTimestamp) -> DiagnosticCheck {
        func make(_ code: DiagnosticCode, _ state: DiagnosticState, _ summary: String, _ action: DiagnosticAction? = nil) -> DiagnosticCheck {
            DiagnosticCheck(id: "remote_alerts", code: code, state: state, requiredFor: [.remoteAlerts],
                            source: "local_preference_and_host_acknowledgement", observedAt: now, summary: summary, action: action)
        }
        guard let policy = alertPolicy else {
            return make(.alertsDisabledByUser, .disabled, Self.alertsOffText)
        }
        switch policy.displayState {
        case .off:
            return make(.alertsDisabledByUser, .disabled, Self.alertsOffText)
        case .disablePending:
            return make(.notificationDisablePending, .warn, String(localized: "Off on this iPhone; Mac update pending. Alerts the Mac already had may still arrive until it confirms."), .retryAlertDisable)
        case .disableNeedsHostUpdate:
            return make(.notificationDisableNeedsHostUpdate, .warn, String(localized: "Update host to finish disabling alerts."), .updateHost)
        case .configured:
            return notificationsDenied
                ? make(.notificationPermissionDenied, .fail, String(localized: "Notifications are turned off for Shell in Settings."), .openNotificationSettings)
                : make(.alertsConfigured, .pass, String(localized: "Registered for remote alerts. Registration does not prove an alert will be shown."))
        case .degraded(let failure):
            switch failure {
            case .macRegistrationPending:
                return make(.notificationRegistrationPending, .warn, String(localized: "Waiting to register alerts with the Mac."))
            case .relayUnavailable:
                return make(.alertsRelayUnavailable, .warn, String(localized: "This build has no push relay, so remote alerts cannot be registered."))
            case .permissionDenied:
                return make(.notificationPermissionDenied, .fail, String(localized: "Notifications are turned off for Shell in Settings."), .openNotificationSettings)
            default:
                return make(.notificationRegistrationFailed, .fail, Self.describe(failure))
            }
        }
    }

    static let alertsOffText = String(localized: "Remote alerts are off. Open Control and refresh to check for requests. Live review still requires a connection to your Mac.")

    static func describe(_ failure: RemoteAlertFailure) -> String {
        switch failure {
        case .permissionDenied: String(localized: "Notifications are turned off for Shell in Settings.")
        case .tokenUnavailable: String(localized: "This iPhone did not get a notification token from Apple.")
        case .relayRejected: String(localized: "The push relay rejected the registration.")
        case .networkFailure: String(localized: "The push relay could not be reached.")
        case .capabilityExpired: String(localized: "The alert registration expired.")
        case .macRegistrationPending: String(localized: "Waiting to register alerts with the Mac.")
        case .relayUnavailable: String(localized: "This build has no push relay.")
        case .unknown: String(localized: "Alert registration failed for an unknown reason.")
        }
    }

    /// A redacted, allowlisted export of the last diagnostic pass. Nothing is
    /// uploaded; the user chooses where it goes.
    func diagnosticExport() -> Data? {
        guard let diagnostics else { return nil }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        #if canImport(UIKit)
        let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        return try? DiagnosticExport.data(reports: [diagnostics], applicationVersion: version, osVersion: os)
    }

    /// Whether the latest setup test was approved by this iPhone and the
    /// host recorded its no-operation receipt.
    var setupTestPassed: Bool {
        guard let test = latestSetupTest, let deviceID else { return false }
        return test.projection.resolution == .approved && test.projection.dispatch == .applied
            && test.projection.decidedByDeviceID == deviceID
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

extension ApprovalRecord {
    /// Whether this base approval asks about an `agent.tool.v1` operation.
    var isAgentApproval: Bool {
        if case .agentTool = spec.operation { return true }
        return false
    }
}
