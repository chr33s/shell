import Foundation
import Observation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// The Watch's single owner of protocol state: its signing key, reviewer
/// identity, cache, refreshes, and submissions — all through the paired
/// iPhone gateway. Only the published projection is main-actor state
/// (docs/specs/control-protocol.md sections 2.5, 10.1, and 11.5).
@MainActor
@Observable
final class ControlSession {
    enum Phase: Equatable {
        case loading
        case needsEnrollment
        /// The iPhone asked the Mac; the Mac has not confirmed yet.
        case awaitingConfirmation(WatchReviewerStatus)
        case ready
    }

    private(set) var phase: Phase = .loading
    private(set) var inbox = InboxState()
    /// Live WatchConnectivity reachability of the iPhone. Every decision needs
    /// it; cached content remains readable without it, marked stale.
    private(set) var isGatewayReachable = false
    /// Why the last live round trip failed: the iPhone, or its Mac route.
    private(set) var gatewayProblem: String?
    private(set) var lastError: String?
    private(set) var pendingCommands: [PendingCommand] = []
    private(set) var submissions: [ControlID: SubmissionState] = [:]
    /// Why the last decision on a request was not sent, when the cause is the
    /// request or the Watch rather than connectivity. Shown on review.
    private(set) var decisionProblems: [ControlID: String] = [:]
    private(set) var reviewer: WatchReviewerStatus?
    private(set) var enrollmentMessage: String?

    /// Whether the iPhone and Mac offer `shell-agent/1` to this Watch. An old
    /// iPhone or Mac is `unsupported`, never an error loop
    /// (docs/specs/agent-relay.md section 14.5).
    enum AgentAvailability: Equatable {
        case unknown
        case unsupported
        /// This Watch was not granted agent reads through its iPhone.
        case notEnabled
        case available
    }

    private(set) var agentAvailability: AgentAvailability = .unknown
    /// Typed questions as last seen through the iPhone. Kept in memory only:
    /// readable, marked stale, when the iPhone drops away; never a basis for
    /// an answer, which always refetches first.
    private(set) var agentInputs: [ControlID: InputRecord] = [:]
    private(set) var agentLastRefreshedAt: ControlTimestamp?
    private(set) var agentSubmissions: [ControlID: AgentSubmissionState] = [:]
    /// Why the last answer to a question was not sent.
    private(set) var agentProblems: [ControlID: String] = [:]

    private let client: WatchGatewayClient
    /// The agent extension over the same WatchConnectivity link, strictly
    /// separate from the base protocol.
    private let agentClient: WatchAgentGatewayClient
    private var agentCursor: ChangeCursor?
    private var agentLastAttempt: Date?
    private var agentLastProbe: Date?
    private var agentLastGrantCheck: Date?
    private let link: any WatchGatewayLink
    private let keys: any DeviceCredentialStore
    private let reviewerStore: any WatchReviewerStore
    private let cache: any InboxCacheStore
    private let journal: CommandJournal
    private let now: @Sendable () -> Date
    private(set) var pollTask: Task<Void, Never>?
    /// Identifies the current poll loop, so a cancelled loop that finishes
    /// late cannot clear the task that replaced it.
    private var pollGeneration = 0
    private var sceneActive = true
    private var screenNeedsData = false
    private var inFlightRefresh: Task<Void, Never>?
    private var queuedRefresh = false
    private var consecutiveFailures = 0
    private static let backoffSchedule: [TimeInterval] = [10, 20, 40, 60]

    /// Test/inspection: polling runs only while the scene is active and a
    /// relevant screen needs data.
    var isPolling: Bool { pollTask != nil }

    init(
        link: any WatchGatewayLink,
        keys: any DeviceCredentialStore,
        reviewerStore: any WatchReviewerStore,
        cache: any InboxCacheStore,
        journalStore: any CommandJournalStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.link = link
        self.client = WatchGatewayClient(link: link)
        self.agentClient = WatchAgentGatewayClient(link: link)
        self.keys = keys
        self.reviewerStore = reviewerStore
        self.cache = cache
        // The journal judges its own retention window, so it has to share this
        // session's clock rather than reading the wall clock behind its back.
        self.journal = CommandJournal(store: journalStore, now: now)
        self.now = now
    }

    var lastRefreshedAt: ControlTimestamp? { inbox.lastRefreshedAt }

    /// The clock the session judges freshness and expiry against.
    var currentDate: Date { now() }

    /// Whether the inbox on screen was confirmed live through the iPhone.
    var isShowingLiveState: Bool { GatewayCache.isLive(gatewayReachable: isGatewayReachable, lastRefreshedAt: lastRefreshedAt) }

    /// Restores cached state first so the inbox can render without the
    /// iPhone, then tries a live refresh.
    func start() async {
        if let cached = try? cache.load() { inbox = cached }
        pendingCommands = await journal.pending
        isGatewayReachable = await link.isReachable()
        guard let reviewer = reviewerStore.load(), (try? keys.loadSigningKey()) != nil else {
            phase = .needsEnrollment
            return
        }
        await adopt(reviewer)
        if phase == .ready {
            await refresh()
            await reconcilePendingCommands()
        } else if case .awaitingConfirmation = phase {
            await checkEnrollment()
        }
    }

    private func adopt(_ status: WatchReviewerStatus) async {
        reviewer = status
        await client.setWatchDeviceID(status.watchDeviceID)
        await agentClient.setWatchDeviceID(status.watchDeviceID)
        switch status.state {
        case .active: phase = .ready
        case .pending: phase = .awaitingConfirmation(status)
        case .denied, .expired, .revoked: phase = .needsEnrollment
        }
    }

    // MARK: Gateway state

    /// A reply arrived over the interactive channel, so the iPhone is
    /// reachable whatever it answered. WatchConnectivity only reports
    /// reachability changes, so a timeout it never saw must be undone here.
    private func noteGatewayAnswered() {
        isGatewayReachable = true
    }

    func gatewayReachabilityChanged(_ reachable: Bool) {
        isGatewayReachable = reachable
        if reachable {
            gatewayProblem = nil
            consecutiveFailures = 0
            Task { await refresh(); await reconcilePendingCommands() }
        }
    }

    /// Background context from the iPhone: display state and a refresh hint,
    /// never a command.
    func applyContext(_ context: WatchGatewayContext) {
        if context.refreshRequested, phase == .ready, sceneActive {
            Task { await refresh() }
        }
    }

    // MARK: Enrollment

    /// Generates this Watch's own key and asks the Mac, through the iPhone,
    /// to enroll it as a reviewer bound to that iPhone. The private key never
    /// leaves the Watch (docs/specs/control-protocol.md section 5.3).
    func enroll(label: String) async {
        enrollmentMessage = nil
        do {
            let key: InMemoryDeviceKey
            if let existing = try keys.loadSigningKey() as? InMemoryDeviceKey {
                key = existing
            } else {
                key = InMemoryDeviceKey()
                try keys.storeSigningKey(key)
            }
            let status = try await client.requestEnrollment(try WatchEnrollmentRequest.make(key: key, label: label))
            try reviewerStore.store(status)
            await adopt(status)
            if phase == .ready { await refresh() }
        } catch {
            enrollmentMessage = describe(error)
        }
    }

    /// Asks the Mac, through the iPhone, whether it confirmed this Watch.
    func checkEnrollment() async {
        guard reviewer != nil else { return }
        do {
            let status = try await client.enrollmentStatus()
            try reviewerStore.store(status)
            await adopt(status)
            switch status.state {
            case .active:
                enrollmentMessage = nil
                await refresh()
            case .denied: enrollmentMessage = String(localized: "Setup was declined on the Mac")
            case .expired: enrollmentMessage = String(localized: "The code expired — start again")
            case .revoked:
                signOut()
                enrollmentMessage = String(localized: "This Watch was revoked")
            case .pending: break
            }
        } catch let error as ControlError where error.code == .reviewerNotBound {
            unbind()
        } catch {
            enrollmentMessage = describe(error)
        }
    }

    /// The iPhone this Watch was bound to is no longer its gateway (it was
    /// re-paired or replaced). The key stays, so setting up again through the
    /// current iPhone is a re-binding the Mac confirms, not a new identity.
    private func unbind() {
        stopPolling()
        reviewerStore.remove()
        try? cache.clear()
        inbox = InboxState()
        reviewer = nil
        submissions = [:]
        resetAgent()
        phase = .needsEnrollment
        enrollmentMessage = String(localized: "Set this Watch up again through its iPhone")
        Task {
            await client.setWatchDeviceID(nil)
            await agentClient.setWatchDeviceID(nil)
        }
    }

    // MARK: Refresh

    /// Full reconciliation through the gateway: snapshot pages, applied
    /// atomically, then deltas. Simultaneous triggers coalesce.
    func refresh() async {
        if let inFlightRefresh {
            queuedRefresh = true
            await inFlightRefresh.value
            return
        }
        repeat {
            queuedRefresh = false
            let task = Task { @MainActor in await self.refreshOnce() }
            inFlightRefresh = task
            defer { inFlightRefresh = nil }
            await task.value
        } while queuedRefresh && !Task.isCancelled
    }

    private func refreshOnce() async {
        guard phase == .ready else { return }
        do {
            var reconciler = InboxReconciler(state: inbox)
            if let cursor = inbox.cursor {
                let page = try await client.changes(after: cursor)
                _ = reconciler.apply(page)
            } else {
                var page = try await client.snapshot()
                var accumulator = InboxReconciler.SnapshotAccumulator(firstPage: page)
                while let next = page.nextPageToken {
                    page = try await client.snapshot(pageToken: next)
                    try accumulator.append(page)
                }
                try reconciler.applyCompletedSnapshot(accumulator, at: page.serverTime)
            }
            // Signing out or unbinding while the pages were in flight already
            // cleared the inbox and its cache; adopting them would restore both.
            guard phase == .ready else { return }
            // The reconciler never drops old approvals and trims seen event
            // IDs only past 5000; bound what is kept and cached.
            inbox = InboxBounds.bounded(reconciler.state)
            try? cache.commit(inbox)
            noteGatewayAnswered()
            gatewayProblem = nil
            lastError = nil
            consecutiveFailures = 0
            await refreshAgent()
        } catch let error as ControlError where error.code == .cursorExpired {
            // A cursor that outlived the log or a permissions change forces a
            // fresh snapshot so stale unauthorized objects are removed.
            inbox.cursor = nil
            await refreshOnce()
        } catch {
            note(error)
            consecutiveFailures += 1
        }
    }

    func noteSceneActive(_ active: Bool) {
        sceneActive = active
        if active {
            consecutiveFailures = 0
            Task { await refresh() }
            startPollingIfNeeded()
        } else {
            cancelPolling()
        }
    }

    /// Only while a relevant screen is visible does the Watch ask its iPhone
    /// for updates; otherwise it stays idle (docs/specs/control-protocol.md 11.5).
    func startPolling() {
        screenNeedsData = true
        startPollingIfNeeded()
    }

    func stopPolling() {
        screenNeedsData = false
        cancelPolling()
    }

    private func startPollingIfNeeded() {
        guard sceneActive, screenNeedsData, pollTask == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.sceneActive, self.screenNeedsData else { break }
                await self.refresh()
                let interval = self.nextPollInterval()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            // Only this loop's own slot: after cancel-then-restart, a newer
            // loop already owns `pollTask`.
            if let self, self.pollGeneration == generation { self.pollTask = nil }
        }
    }

    private func cancelPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func nextPollInterval() -> TimeInterval {
        let minimum = ApprovalPolicy.minimumPollInterval
        guard consecutiveFailures > 0 else { return minimum }
        let index = min(consecutiveFailures, Self.backoffSchedule.count) - 1
        let backoff = Self.backoffSchedule[index]
        return max(minimum, backoff + Double.random(in: 0...(backoff * 0.1)))
    }

    // MARK: Review and decisions

    /// Always fetched live through the iPhone before review: a cached copy is
    /// not a decision basis (docs/specs/control-protocol.md section 10.5).
    func fetchForReview(_ requestID: ControlID) async throws -> ApprovalRecord {
        do {
            let record = try await client.approval(requestID)
            if phase == .ready {
                inbox.approvals[requestID] = record
                try? cache.commit(inbox)
            }
            noteGatewayAnswered()
            gatewayProblem = nil
            return record
        } catch {
            note(error)
            throw error
        }
    }

    // MARK: Agent questions

    var pendingAgentInputs: [InputRecord] {
        agentInputs.values
            .filter { $0.projection.resolution == .pending }
            .sorted { $0.spec.createdAt < $1.spec.createdAt }
    }

    /// A Mac without the extension, an old iPhone, or a Watch without the
    /// grant is asked again only this rarely.
    static let agentReprobeInterval: TimeInterval = 300
    /// Pages of one pending-only agent snapshot the Watch reads before it
    /// gives up on the cut and keeps what it had.
    static let agentMaxSnapshotPages = 32

    /// More pending agent questions than the Watch lists in one refresh.
    struct AgentSnapshotTooLarge: Error, Equatable {}

    /// Snapshot, then changes, of the agent projection through the iPhone,
    /// no faster than the poll floor unless `force`d after an answer.
    func refreshAgent(force: Bool = false) async {
        guard phase == .ready, isGatewayReachable else { return }
        let date = now()
        if !force, let agentLastAttempt, date.timeIntervalSince(agentLastAttempt) < ApprovalPolicy.minimumPollInterval { return }
        switch agentAvailability {
        case .unsupported, .notEnabled:
            if !force, let agentLastProbe, date.timeIntervalSince(agentLastProbe) < Self.agentReprobeInterval { return }
        case .unknown, .available:
            break
        }
        agentLastAttempt = date
        do {
            if agentAvailability != .available {
                agentLastProbe = date
                guard try await agentClient.capabilities().isCompatible else {
                    agentAvailability = .unsupported
                    return
                }
            }
            try await reconcileAgent()
            agentAvailability = .available
            await refreshReviewerGrantsIfNeeded()
        } catch WatchGatewayError.unsupportedVersion {
            // An iPhone without the extension: no downgrade to anything else.
            agentAvailability = .unsupported
            agentInputs = [:]
        } catch let error as ControlError where error.code == .notFound {
            agentAvailability = .unsupported
            agentInputs = [:]
        } catch let error as ControlError where error.code == .notAuthorized {
            agentAvailability = .notEnabled
            agentInputs = [:]
        } catch let error as ControlError where error.code == .cursorExpired {
            agentCursor = nil
        } catch {
            note(error)
        }
    }

    private func reconcileAgent() async throws {
        if let cursor = agentCursor {
            let page = try await agentClient.changes(after: cursor)
            for event in page.events {
                // Only questions matter here; agent approvals arrive through
                // the base inbox.
                guard let record = try? InputRecord(json: event.projection) else { continue }
                if let existing = agentInputs[record.spec.requestID],
                   existing.projection.stateVersion > record.projection.stateVersion { continue }
                agentInputs[record.spec.requestID] = record
            }
            agentCursor = page.cursor
            agentLastRefreshedAt = page.serverTime
        } else {
            // Only what can still be answered: resolved history is not
            // needed here and would crowd pending questions out.
            var page = try await agentClient.snapshot(pendingOnly: true)
            var inputs: [ControlID: InputRecord] = [:]
            var pages = 0
            while true {
                for case .supported(let record) in page.inputs { inputs[record.spec.requestID] = record }
                pages += 1
                guard let token = page.nextPageToken else { break }
                // A cut that does not end here is never adopted: its cursor
                // would skip everything after the last page read.
                guard pages < Self.agentMaxSnapshotPages else { throw AgentSnapshotTooLarge() }
                let next = try await agentClient.snapshot(pageToken: token, pendingOnly: true)
                guard next.snapshotToken == page.snapshotToken else {
                    throw ControlError(code: .cursorExpired, message: "agent snapshot cut moved")
                }
                page = next
            }
            // Signing out while the pages were in flight already cleared
            // this state; adopting them would restore it.
            guard phase == .ready else { return }
            agentInputs = inputs
            agentCursor = page.cursor
            agentLastRefreshedAt = page.serverTime
        }
        // Keep what is pending and the newest few outcomes.
        let resolved = agentInputs.values
            .filter { $0.projection.resolution.isTerminal }
            .sorted { $0.spec.createdAt > $1.spec.createdAt }
        for record in resolved.dropFirst(16) { agentInputs.removeValue(forKey: record.spec.requestID) }
    }

    /// Agent grants are added on the Mac after enrollment; the stored reviewer
    /// status is refreshed so the answer is signed with current grants.
    private func refreshReviewerGrantsIfNeeded() async {
        guard let reviewer, !reviewer.grants.contains(.agentInputsRespond) else { return }
        let date = now()
        if let agentLastGrantCheck, date.timeIntervalSince(agentLastGrantCheck) < Self.agentReprobeInterval { return }
        agentLastGrantCheck = date
        guard let status = try? await client.enrollmentStatus(),
              status.state == .active, status.watchDeviceID == reviewer.watchDeviceID else { return }
        try? reviewerStore.store(status)
        self.reviewer = status
    }

    /// Always fetched live through the iPhone before any answer is enabled.
    func fetchInputForReview(_ requestID: ControlID) async throws -> InputRecord {
        do {
            let record = try await agentClient.input(requestID)
            if phase == .ready { agentInputs[requestID] = record }
            noteGatewayAnswered()
            gatewayProblem = nil
            return record
        } catch {
            note(error)
            throw error
        }
    }

    /// Signs the answer the user confirmed on the final screen with this
    /// Watch's own key and sends it live through the iPhone. A draft that
    /// was never confirmed, or changed after confirmation, is not sent
    /// (docs/specs/agent-relay.md sections 7.1 and 12.2).
    func respond(with draft: WatchAnswerDraft, to record: InputRecord) async {
        guard let response = draft.confirmedResponse(for: record.spec) else {
            agentProblems[record.spec.requestID] = String(localized: "Confirm the exact answer before sending")
            return
        }
        await submit(response, to: record)
    }

    /// Declines, after its own explicit confirmation in the view.
    func decline(_ record: InputRecord) async {
        await submit(.decline, to: record)
    }

    private func submit(_ response: InputResponse, to record: InputRecord) async {
        let requestID = record.spec.requestID
        // Nothing is queued: an unreachable iPhone disables submission now.
        guard isGatewayReachable else {
            agentProblems[requestID] = String(localized: "iPhone unavailable — no answer is queued")
            return
        }
        guard let coordinator = makeAgentCoordinator() else { return }
        agentSubmissions[requestID] = .sending
        agentProblems[requestID] = nil
        do {
            agentSubmissions[requestID] = try await coordinator.respond(response, reviewed: record)
        } catch let error as ControlError {
            agentSubmissions[requestID] = nil
            lastError = "\(error.code.rawValue): \(error.message)"
            agentProblems[requestID] = error.provesCommandNotRecorded ? Self.notRecordedText(error) : describe(error)
            if error.code == .deviceRevoked || error.code == .reviewerNotBound { note(error) }
        } catch let error as WatchGatewayError {
            agentSubmissions[requestID] = nil
            note(error)
            agentProblems[requestID] = describe(error)
        } catch {
            // Refused before anything was sent: changed, not answerable here,
            // no grant, or a local failure. A failure after submission is
            // journalled under its command ID and reconciled later.
            agentSubmissions[requestID] = nil
            agentProblems[requestID] = describe(error)
        }
        pendingCommands = await journal.pending
        await refresh()
        await refreshAgent(force: true)
    }

    /// The answer coordinator is built with this Watch's signer and key and
    /// Watch-level review, so every answer is attributable to the Watch.
    private func makeAgentCoordinator() -> AgentInputCoordinator? {
        guard phase == .ready,
              let reviewer, let audience = reviewer.audience,
              let key = try? keys.loadSigningKey()
        else { return nil }
        return AgentInputCoordinator(
            service: agentClient,
            journal: journal,
            key: key,
            signer: SignerIdentity(deviceID: reviewer.watchDeviceID, audience: audience, grants: reviewer.grants),
            review: .watch,
            now: now
        )
    }

    private func resetAgent() {
        agentAvailability = .unknown
        agentInputs = [:]
        agentCursor = nil
        agentLastRefreshedAt = nil
        agentSubmissions = [:]
        agentProblems = [:]
        agentLastAttempt = nil
        agentLastProbe = nil
        agentLastGrantCheck = nil
    }

    func decide(_ decision: ControlDecision, on record: ApprovalRecord) async {
        guard let coordinator = await makeCoordinator() else { return }
        submissions[record.spec.requestID] = .sending
        decisionProblems[record.spec.requestID] = nil
        do {
            let state = try await coordinator.decide(decision, reviewed: record)
            submissions[record.spec.requestID] = state
        } catch let error as ControlError {
            submissions[record.spec.requestID] = nil
            lastError = "\(error.code.rawValue): \(error.message)"
            // A final refusal means nothing was recorded (and the journal
            // entry is gone): say why, and send the user back to a fresh
            // review — the view reloads the request after deciding.
            decisionProblems[record.spec.requestID] = error.provesCommandNotRecorded
                ? Self.notRecordedText(error)
                : describe(error)
            if error.code == .deviceRevoked || error.code == .reviewerNotBound { note(error) }
        } catch let error as WatchGatewayError {
            // Nothing was queued: an unreachable iPhone fails closed.
            submissions[record.spec.requestID] = nil
            note(error)
        } catch {
            // Anything else escaping the coordinator happened before the
            // command was sent: the request changed, the Watch may not decide
            // it, or a local signing or parsing failure. Nothing was
            // submitted; a failure after submission is journalled by the
            // coordinator under its real command ID and reconciled later.
            submissions[record.spec.requestID] = nil
            lastError = describe(error)
            decisionProblems[record.spec.requestID] = describe(error)
        }
        pendingCommands = await journal.pending
        await refresh()
    }

    func acknowledge(_ notification: InformationalEvent) async {
        guard let coordinator = await makeCoordinator() else { return }
        _ = try? await coordinator.acknowledge(notification: notification)
        await refresh()
    }

    /// On reconnection, ask about every command whose outcome is unresolved,
    /// by its original command ID. Agent answers are asked about only through
    /// the agent extension (docs/specs/agent-relay.md section 7.3).
    func reconcilePendingCommands() async {
        guard let coordinator = await makeCoordinator() else { return }
        let answers = makeAgentCoordinator()
        for command in await journal.pending {
            if command.isAgentCommand {
                if let answers, let state = try? await answers.reconcile(command) {
                    agentSubmissions[command.targetID] = state
                }
            } else if let state = try? await coordinator.reconcile(command) {
                submissions[command.targetID] = state
            }
        }
        pendingCommands = await journal.pending
    }

    private func makeCoordinator() async -> DecisionCoordinator? {
        guard phase == .ready,
              let reviewer, let audience = reviewer.audience,
              let key = try? keys.loadSigningKey()
        else { return nil }
        return DecisionCoordinator(
            service: client,
            journal: journal,
            key: key,
            signer: SignerIdentity(deviceID: reviewer.watchDeviceID, audience: audience, grants: reviewer.grants),
            now: now
        )
    }

    private func note(_ error: any Error) {
        switch error {
        case let error as WatchGatewayError:
            switch error {
            case .iPhoneUnreachable: isGatewayReachable = false
            case .gatewayUnavailable: noteGatewayAnswered()
            default: break
            }
            gatewayProblem = describe(error)
        case is ControlError where !isGatewayReachable:
            // The iPhone relayed the Mac's answer, so it is reachable.
            noteGatewayAnswered()
            note(error)
        case let error as ControlError where error.code == .deviceRevoked:
            signOut()
            enrollmentMessage = String(localized: "This Watch was revoked")
        case let error as ControlError where error.code == .reviewerNotBound:
            unbind()
        case let error as ControlError:
            lastError = "\(error.code.rawValue): \(error.message)"
        default:
            // Delivery failures arrive as `WatchGatewayError`; anything else
            // is not a connectivity problem.
            lastError = describe(error)
        }
    }

    /// A definitive broker refusal: nothing was recorded and the journal
    /// entry is gone, so nothing retries it. Says why, and what to do next.
    static func notRecordedText(_ error: ControlError) -> String {
        let reason = String(localized: "Not recorded: \(error.message)")
        switch error.code {
        case .staleVersion, .policyChanged, .hashMismatch, .challengeExpired:
            return reason + "\n" + String(localized: "The request changed. Review it again before deciding.")
        case .originUnavailable:
            return reason + "\n" + String(localized: "The Mac is not present right now.")
        case .requestExpired:
            return reason + "\n" + String(localized: "The request expired.")
        case .fullReviewRequired:
            return reason + "\n" + String(localized: "Review it on your iPhone or Mac.")
        default:
            return reason
        }
    }

    private func describe(_ error: any Error) -> String {
        switch error {
        case WatchGatewayError.iPhoneUnreachable: return String(localized: "iPhone unavailable")
        case WatchGatewayError.gatewayUnavailable: return String(localized: "The iPhone cannot reach the Mac right now")
        case let error as ControlError: return error.message
        case is CommandJournalUnavailable:
            return String(localized: "Decisions are unavailable until this Watch is unlocked")
        case DecisionCoordinator.CoordinatorError.requestChangedDuringReview:
            return String(localized: "This request changed while you were reviewing it. Review it again.")
        case DecisionCoordinator.CoordinatorError.notApprovableOnWatch:
            return String(localized: "Review this request on your iPhone or Mac")
        case DecisionCoordinator.CoordinatorError.decisionNotAllowed:
            return String(localized: "That decision is not allowed for this request")
        case DecisionCoordinator.CoordinatorError.missingGrant:
            return String(localized: "This Watch is not allowed to do that")
        case DecisionCoordinator.CoordinatorError.noSession:
            return String(localized: "Set this Watch up again through its iPhone")
        case is AgentSnapshotTooLarge:
            return String(localized: "Too many agent questions to list on this Watch. Review them on your iPhone.")
        case AgentInputCoordinator.CoordinatorError.requestChangedDuringReview:
            return String(localized: "This question changed while you were reviewing it. Review it again.")
        case AgentInputCoordinator.CoordinatorError.notAnswerableHere:
            return String(localized: "Answer this question on your iPhone or Mac")
        case AgentInputCoordinator.CoordinatorError.missingGrant:
            return String(localized: "This Watch is not allowed to answer agent questions")
        case AgentInputCoordinator.CoordinatorError.invalidResponse:
            return String(localized: "The answer does not fit the question")
        case WatchGatewayError.unsupportedVersion:
            return String(localized: "Update Shell on your iPhone to answer agent questions")
        default: return String(describing: error)
        }
    }

    /// Forgets this Watch's reviewer identity, key, cache, and journal
    /// together. The journal goes too: its entries are commands signed by the
    /// key being discarded here, so nothing can retry or reconcile them.
    func signOut() {
        stopPolling()
        try? keys.removeAll()
        reviewerStore.remove()
        try? cache.clear()
        inbox = InboxState()
        reviewer = nil
        submissions = [:]
        pendingCommands = []
        decisionProblems = [:]
        resetAgent()
        phase = .needsEnrollment
        Task {
            try? await journal.clear()
            await client.setWatchDeviceID(nil)
            await agentClient.setWatchDeviceID(nil)
        }
    }
}
