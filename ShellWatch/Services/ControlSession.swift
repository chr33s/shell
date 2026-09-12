import Foundation
import Observation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// The Watch's single owner of protocol state: credentials, cache, refreshes,
/// and submissions. Networking and signing happen off the main actor; only the
/// published projection is main-actor state (spec.watch.md section 18).
@MainActor
@Observable
final class ControlSession {
    enum Phase: Equatable {
        case loading
        case needsEnrollment
        case ready
    }

    private(set) var phase: Phase = .loading
    private(set) var inbox = InboxState()
    private(set) var isOffline = false
    private(set) var lastError: String?
    private(set) var pendingCommands: [PendingCommand] = []
    private(set) var submissions: [ControlID: SubmissionState] = [:]

    let brokerURL: URL
    private let credentials: any DeviceCredentialStore
    private let cache: any InboxCacheStore
    private let journal: CommandJournal
    private let defaults: UserDefaults
    /// Injectable so tests can drive the credential-renewal and offline paths
    /// without a network; production uses `URLSession`.
    private let transport: any ControlHTTPTransport
    private let now: @Sendable () -> Date
    private var client: ControlAPIClient?
    private var coordinator: DecisionCoordinator?
    private var session: DeviceSession?
    private var key: (any DeviceSigningKey)?
    private var pollTask: Task<Void, Never>?
    private var enrollment: EnrollmentCoordinator?
    private var sceneActive = true
    private var screenNeedsData = false
    private var inFlightRefresh: Task<Void, Never>?
    private var queuedRefresh = false
    private var renewTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private static let backoffSchedule: [TimeInterval] = [10, 20, 40, 60]

    /// Test/inspection: polling runs only while the scene is active and a
    /// relevant screen needs data.
    var isPolling: Bool { pollTask != nil }

    init(
        brokerURL: URL,
        credentials: any DeviceCredentialStore,
        cache: any InboxCacheStore,
        journalStore: any CommandJournalStore,
        transport: any ControlHTTPTransport = URLSessionTransport(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.brokerURL = brokerURL
        self.credentials = credentials
        self.cache = cache
        self.journal = try CommandJournal(store: journalStore)
        self.transport = transport
        self.defaults = defaults
        self.now = now
    }

    var lastRefreshedAt: ControlTimestamp? { inbox.lastRefreshedAt }

    /// The clock the session judges freshness and expiry against.
    var currentDate: Date { now() }

    /// Restores cached state first so the inbox can render offline, then tries
    /// the network.
    func start() async {
        if ControlBrokerAddress.hasChanged(
            from: defaults.string(forKey: ControlBrokerAddress.defaultsKey),
            to: brokerURL,
            hasCredentials: (try? credentials.loadSession()) != nil
        ) {
            try? credentials.removeAll()
            try? cache.clear()
            inbox = InboxState()
        }
        defaults.set(brokerURL.absoluteString, forKey: ControlBrokerAddress.defaultsKey)
        if let cached = try? cache.load() { inbox = cached }
        pendingCommands = await journal.pending
        guard let session = try? credentials.loadSession(),
              let key = try? credentials.loadSigningKey()
        else {
            phase = .needsEnrollment
            return
        }
        install(session: session, key: key)
        phase = .ready
        await refresh()
        await reconcilePendingCommands()
    }

    func adopt(session: DeviceSession, key: any DeviceSigningKey) async {
        install(session: session, key: key)
        phase = .ready
        await refresh()
    }

    private func install(session: DeviceSession, key: any DeviceSigningKey) {
        self.session = session
        self.key = key
        let client = ControlAPIClient(baseURL: brokerURL, transport: transport, credential: .device(session.accessToken))
        self.client = client
        self.enrollment = EnrollmentCoordinator(baseURL: brokerURL, transport: transport)
        coordinator = DecisionCoordinator(client: client, journal: journal, key: key, session: session, now: now)
    }

    /// Access tokens last ten minutes, so every network path renews first
    /// rather than discovering the expiry as a 401 it cannot recover from
    /// (spec.watch.md sections 5 and 16). Concurrent callers share one renewal.
    private func ensureFreshCredentials() async {
        if let renewTask {
            await renewTask.value
            return
        }
        let task = Task { @MainActor in
            await self.renewCredentialsIfNeeded()
        }
        renewTask = task
        await task.value
        renewTask = nil
    }

    private func renewCredentialsIfNeeded() async {
        guard let session, let client, let enrollment, let key else { return }
        guard !session.isAccessTokenFresh(at: ControlTimestamp(now())) else { return }
        do {
            let renewed = try await enrollment.refresh(session: session)
            try? credentials.storeSession(renewed)
            self.session = renewed
            await client.updateCredential(.device(renewed.accessToken))
            coordinator = DecisionCoordinator(client: client, journal: journal, key: key, session: renewed, now: now)
        } catch let error as ControlError where error.code == .invalidToken || error.code == .deviceRevoked {
            // The refresh token is spent or the device was revoked: a new
            // identity is the only way back, and it needs the local cache gone.
            signOut()
        } catch {
            isOffline = true
        }
    }

    /// Full reconciliation: snapshot pages, applied atomically, then deltas.
    /// Simultaneous launch/foreground/notification/manual triggers coalesce.
    func refresh() async {
        if let inFlightRefresh {
            queuedRefresh = true
            await inFlightRefresh.value
            return
        }
        repeat {
            queuedRefresh = false
            let task = Task { @MainActor in
                await self.refreshOnce()
            }
            inFlightRefresh = task
            defer { inFlightRefresh = nil }
            await task.value
        } while queuedRefresh && !Task.isCancelled
    }

    private func refreshOnce() async {
        await ensureFreshCredentials()
        guard let client else { return }
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
            inbox = reconciler.state
            try? cache.commit(inbox)
            isOffline = false
            lastError = nil
            consecutiveFailures = 0
        } catch let error as ControlError where error.code == .cursorExpired {
            // A cursor that outlived the log or a permissions change forces a
            // fresh snapshot so stale unauthorized objects are removed.
            inbox.cursor = nil
            await refreshOnce()
        } catch is TransportError {
            isOffline = true
            consecutiveFailures += 1
        } catch {
            lastError = String(describing: error)
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

    /// While a relevant screen is visible, refreshes coalesce and never poll
    /// faster than every five seconds; polling pauses when not visible
    /// (spec.watch.md section 7).
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
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.sceneActive, self.screenNeedsData else { break }
                await self.refresh()
                let interval = self.nextPollInterval()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            self?.pollTask = nil
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
        let jitter = Double.random(in: 0...(backoff * 0.1))
        return max(minimum, backoff + jitter)
    }

    /// Always re-fetches before showing the review screen: a digest alone is not
    /// review material, and a cached copy is not a decision basis.
    func fetchForReview(_ requestID: ControlID) async throws -> ApprovalRecord {
        await ensureFreshCredentials()
        guard let client else { throw TransportError.offline }
        let record = try await client.approval(requestID)
        inbox.approvals[requestID] = record
        try? cache.commit(inbox)
        return record
    }

    func decide(_ decision: ControlDecision, on record: ApprovalRecord) async {
        await ensureFreshCredentials()
        guard let coordinator else { return }
        submissions[record.spec.requestID] = .sending
        do {
            let state = try await coordinator.decide(decision, reviewed: record)
            submissions[record.spec.requestID] = state
        } catch let error as ControlError {
            submissions[record.spec.requestID] = nil
            lastError = "\(error.code.rawValue): \(error.message)"
        } catch {
            submissions[record.spec.requestID] = .outcomeUnknown(commandID: .random(), reason: String(describing: error))
        }
        pendingCommands = await journal.pending
        await refresh()
    }

    func acknowledge(_ notification: InformationalEvent) async {
        await ensureFreshCredentials()
        guard let coordinator else { return }
        _ = try? await coordinator.acknowledge(notification: notification)
        await refresh()
    }

    func cancelJob(jobID: ControlID, runID: ControlID, jobVersion: Int64) async {
        await ensureFreshCredentials()
        guard let coordinator else { return }
        do {
            _ = try await coordinator.cancelJob(jobID: jobID, runID: runID, expectedJobVersion: jobVersion)
        } catch {
            lastError = String(describing: error)
        }
        await refresh()
    }

    /// On reconnection, ask about every command whose outcome is unresolved.
    func reconcilePendingCommands() async {
        await ensureFreshCredentials()
        guard let coordinator else { return }
        for command in await journal.pending {
            if let state = try? await coordinator.reconcile(command) {
                submissions[command.targetID] = state
            }
        }
        pendingCommands = await journal.pending
    }

    /// Registers this Watch's own APNs token. A push token is a delivery
    /// address, not authentication (spec.watch.md section 5).
    func registerPushToken(_ token: Data, topic: String, environment: PushRegistration.Environment) async {
        await ensureFreshCredentials()
        guard let client else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard let registration = try? PushRegistration(
            token: hex,
            platform: .watchOS,
            environment: environment,
            topic: topic
        ) else { return }
        try? await client.registerPush(registration)
    }

    /// Account logout: the local credentials and cache go away together.
    func signOut() {
        stopPolling()
        try? credentials.removeAll()
        try? cache.clear()
        inbox = InboxState()
        session = nil
        key = nil
        client = nil
        coordinator = nil
        enrollment = nil
        phase = .needsEnrollment
    }
}
