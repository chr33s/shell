//
//  RecoveryCoordinator.swift
//  shell
//
//  The single recovery owner for one logical connection
//  (spec.connectivity.md §4 CON-01, §6, §7).
//
//  This type is the whole point of the specification: one coordinator per
//  logical connection, one active attempt at a time, honest accounting of
//  what was actually dialled, and no state transition that claims more than
//  was proved. Projected tmux panes do not get their own — they share their
//  gateway's.
//
//  It deliberately depends on nothing but Foundation. The clock, the jitter
//  source, the sleeper, and the attempt itself are all injected, so the
//  deterministic regression suite (AC-01 … AC-24) exercises real policy
//  without a network, a terminal, or a real sleep.
//

import Foundation
import os

// MARK: - Sleeper

/// Suspends for a duration. Injected so tests never wait on wall time.
protocol RecoverySleeper: Sendable {
    /// Throws `CancellationError` when the surrounding task is cancelled.
    func sleep(seconds: TimeInterval) async throws
}

struct SystemRecoverySleeper: RecoverySleeper {
    nonisolated init() {}
    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Coordinator

@MainActor
final class RecoveryCoordinator {

    private nonisolated static let logger = Logger(
        subsystem: "dev.chr33s.shell", category: "Recovery")

    // MARK: Dependencies

    private let clock: RecoveryClock
    private let jitter: RecoveryJitterSource
    private let sleeper: RecoverySleeper
    private let scheduler: RecoveryGlobalScheduler

    // MARK: State

    private(set) var context: RecoveryContext
    private(set) var state: RecoveryState = .live
    private(set) var lastOutcome: RecoveryOutcome?
    private(set) var diagnostics: RecoveryDiagnosticRing

    /// Master gate (`autoReconnectEnabled`). Turning it off cancels recovery
    /// but never closes an otherwise healthy connection (§14).
    var isAutomaticRecoveryEnabled: Bool = true {
        didSet {
            guard oldValue != isAutomaticRecoveryEnabled, !isAutomaticRecoveryEnabled else { return }
            if state.isActiveRecovery {
                cancelLoop()
                transition(to: .awaitingUser(reason: .autoReconnectDisabled))
            }
        }
    }

    /// Whether this connection backs a visible gateway. Only affects global
    /// scheduling priority.
    var isVisibleGateway: Bool = false

    /// Whether the app is foreground-active. Cooldown attempts run only while
    /// foreground-active and path-eligible (§7.2).
    private(set) var isForegroundActive: Bool = true

    // MARK: Injected behavior

    /// Performs one connection attempt for `generation`, returning what it
    /// actually proved. Throwing is the failure path; the error is classified
    /// by `classifyFailure`.
    var performAttempt: ((UInt64) async throws -> RecoveryReadiness)?

    /// Destination-relevant path evidence. A generic global `satisfied` is a
    /// hint, not a licence to dial repeatedly (§7.2).
    var pathEligibilityProvider: (() -> RecoveryPathEligibility)?

    /// Maps a thrown error onto the typed domain/hop vocabulary. Callers
    /// supply this because only they know which hop threw.
    var classifyFailure: ((Error) -> RecoveryFailure)?

    var onStateChange: ((RecoveryState) -> Void)?
    var onOutcome: ((RecoveryOutcome) -> Void)?
    var onReadiness: ((RecoveryReadiness) -> Void)?

    // MARK: Private

    private var loopTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?
    private var pathWaiters: [CheckedContinuation<Void, Never>] = []
    private var readySince: MonotonicInstant?
    private var pendingCoalesce: Task<Void, Never>?
    private var coalesceFirstEventAt: MonotonicInstant?

    // MARK: - Init

    init(
        context: RecoveryContext,
        clock: RecoveryClock = SystemRecoveryClock(),
        jitter: RecoveryJitterSource = SystemRecoveryJitter(),
        sleeper: RecoverySleeper = SystemRecoverySleeper(),
        scheduler: RecoveryGlobalScheduler? = nil
    ) {
        self.context = context
        self.clock = clock
        self.jitter = jitter
        self.sleeper = sleeper
        self.scheduler = scheduler ?? RecoveryGlobalScheduler.shared
        self.diagnostics = RecoveryDiagnosticRing(capacity: context.recoveryPreference.diagnosticRingDepth)
    }

    deinit {
        loopTask?.cancel()
        waitTask?.cancel()
        pendingCoalesce?.cancel()
        escalationTask?.cancel()
        synchronizationTask?.cancel()
    }

    var policy: RecoveryPolicy { context.recoveryPreference }

    /// Adopt a new settings snapshot. Configuration changes take effect at an
    /// explicit boundary, never mid-recovery (§5).
    func adoptPolicy(_ policy: RecoveryPolicy) {
        guard !state.isActiveRecovery else {
            Self.logger.debug("Policy change staged; recovery in progress")
            stagedPolicy = policy
            return
        }
        context.recoveryPreference = policy
    }
    private var stagedPolicy: RecoveryPolicy?

    /// Adopt the connection's identity and intent.
    ///
    /// A synced profile edit must not silently redirect an in-progress
    /// recovery at a different host, port, or credential — that would be the
    /// silent target substitution CON-05 forbids. Changes are staged and
    /// applied at the next explicitly adopted intent.
    func updateTarget(
        _ identity: RecoveryTargetIdentity,
        intent: RecoveryIntent,
        verifiesTmuxContinuity: Bool = false
    ) {
        guard !state.isActiveRecovery else {
            stagedTarget = (identity, intent, verifiesTmuxContinuity)
            return
        }
        applyTarget(identity, intent: intent, verifiesTmuxContinuity: verifiesTmuxContinuity)
    }
    private var stagedTarget: (RecoveryTargetIdentity, RecoveryIntent, Bool)?

    private func applyTarget(
        _ identity: RecoveryTargetIdentity,
        intent: RecoveryIntent,
        verifiesTmuxContinuity: Bool
    ) {
        let changed = context.targetIdentity != identity || context.intent != intent
        context.targetIdentity = identity
        context.intent = intent
        context.verifiesTmuxContinuity = verifiesTmuxContinuity
        // A changed intent retires the old generation: anything still in
        // flight for the previous target must not land on the new one.
        if changed { context.advanceGeneration() }
    }

    /// Record verified tmux continuity evidence for the attached session.
    func updateTmuxIdentity(_ evidence: TmuxContinuityEvidence?) {
        context.tmuxIdentity = evidence
    }

    // MARK: - Inbound events

    /// The connection proved itself live with real evidence.
    ///
    /// `readiness` must carry the generation that produced it. A superseded
    /// generation's late success is discarded rather than adopted (CON-02).
    func noteReady(_ readiness: RecoveryReadiness) {
        guard context.isCurrent(readiness.generation) else {
            Self.logger.info("Discarding readiness from retired generation \(readiness.generation)")
            record(.stateChange, failure: RecoveryFailure(domain: .cancelled, hop: .local))
            return
        }

        // CON-03: transport establishment alone never reports a restored
        // session. Only terminal- or tmux-level evidence promotes to `live`.
        guard readiness.kind != .transportEstablished else {
            transition(to: .recovering(stage: .attaching))
            return
        }

        // A verifiable tmux intent is only satisfied by tmux evidence:
        // publishing `live` on `terminalReady` here would be exactly the
        // invented success CON-03 forbids. PTY readiness after an attach-only
        // exec proves the attach was accepted; it says nothing about whether
        // the panes have caught up.
        if context.intent == .attachExistingTmux,
           context.verifiesTmuxContinuity,
           readiness.kind != .tmuxSessionRestored {
            transition(to: .recovering(stage: .synchronizing))
            scheduleSynchronizationEscalation()
            return
        }
        cancelSuspicionEscalation()

        cancelLoop()
        readySince = clock.now
        context.attemptState.beginEpoch()
        context.freshness.lastTargetActivity = clock.now
        transition(to: .live)
        onReadiness?(readiness)

        // "New shell opened" would be affirmatively false for a tmux
        // reattachment: the exec is attach-only, so a success means the
        // session already existed and nothing was created. Regular mode
        // cannot prove it is the *same* session, which is why it never claims
        // control mode's pane-by-pane guarantee — but it did not open a new
        // shell either (§9.2).
        let reattachedExistingSession = readiness.kind == .tmuxSessionRestored
            || (context.intent == .attachExistingTmux && !context.verifiesTmuxContinuity)
        let outcome: RecoveryOutcome = reattachedExistingSession ? .sessionRestored : .newShellOpened
        lastOutcome = outcome
        onOutcome?(outcome)
        record(.attemptSucceeded)

        if let stagedPolicy {
            context.recoveryPreference = stagedPolicy
            self.stagedPolicy = nil
        }
        if let stagedTarget {
            applyTarget(stagedTarget.0, intent: stagedTarget.1,
                        verifiesTmuxContinuity: stagedTarget.2)
            self.stagedTarget = nil
        }
    }

    /// Transport-level trouble that has not yet been proved fatal. Freezes the
    /// display and gates input while the existing transport is validated (§6).
    func noteSuspect() {
        guard state == .live else { return }
        context.presentationState.isStale = true
        transition(to: .suspect)
    }

    /// Inbound authenticated traffic ended a period of doubt.
    ///
    /// Deliberately separate from `noteSuspectResolved()`: that one records a
    /// confirmed round trip, and this one has not proved a round trip at all.
    /// It proves the destination is still sending us bytes, which is enough to
    /// stop freezing the display and gating input, and not enough to claim a
    /// fresh RTT (§8.1).
    func noteSuspectResolvedByInboundActivity() {
        guard state == .suspect else { return }
        cancelSuspicionEscalation()
        context.freshness.probeOutstanding = false
        context.presentationState.isStale = false
        transition(to: .live)
    }

    /// The existing transport proved healthy after all — no replacement needed.
    func noteSuspectResolved() {
        guard state == .suspect else { return }
        cancelSuspicionEscalation()
        context.presentationState.isStale = false
        context.freshness.lastConfirmedRoundTrip = clock.now
        transition(to: .live)
    }

    /// A verified normal remote exit. Terminal for this intent: a clean shell
    /// exit or intentional tmux detach must never trigger auto-recovery (§6).
    func noteRemoteExit() {
        cancelLoop()
        transition(to: .exited)
    }

    /// Explicit local stop (tab closed, user pressed Stop Recovery).
    func stop() {
        context.attemptState.isCancelled = true
        context.advanceGeneration()
        cancelLoop()
        transition(to: .stopped)
        record(.generationRetired)
    }

    /// The connection dropped. This is the entry point to recovery.
    func noteDisconnected(_ failure: RecoveryFailure) {
        guard !state.isTerminal else { return }

        // A retired generation's teardown must not restart recovery that the
        // user (or a newer intent) already ended.
        guard !context.attemptState.isCancelled else { return }

        context.presentationState.isStale = true
        context.advanceGeneration()
        record(.generationRetired, failure: failure)

        // CON-04: a one-shot command whose dispatch may already have happened
        // is never re-run. Missing exit status is not evidence of non-execution.
        if context.intent == .oneShotCommand {
            cancelLoop()
            lastOutcome = .commandOutcomeUnknown
            transition(to: .awaitingUser(reason: .commandOutcomeUnknown))
            onOutcome?(.commandOutcomeUnknown)
            return
        }

        if failure.domain == .remoteExit {
            cancelLoop()
            transition(to: .exited)
            return
        }

        if failure.domain == .cancelled {
            cancelLoop()
            transition(to: .stopped)
            return
        }

        guard isAutomaticRecoveryEnabled else {
            cancelLoop()
            transition(to: .awaitingUser(reason: .autoReconnectDisabled))
            return
        }

        guard failure.isAutomaticallyRetryable else {
            cancelLoop()
            transition(to: .awaitingUser(reason: failure.attentionReason ?? .unsupportedRecovery))
            return
        }

        // A connection that stayed ready long enough has earned a fresh
        // budget; a flapping one keeps its accumulated backoff (§7.2).
        if let readySince, clock.now.elapsed(since: readySince) >= policy.stableReadyPeriod {
            context.attemptState.beginEpoch()
        }
        readySince = nil

        transition(to: .suspect)
        startLoop()
    }

    /// A user-initiated retry. Bypasses the pending wait but not the typed
    /// attention states: an unresolved host-key change still needs its flow.
    func retryNow() {
        // `.stopped` is terminal for its *intent*, and a person tapping Retry
        // is a new user action starting another one (§6). Only a verified
        // clean remote exit stays closed — there is nothing to reconnect to.
        guard state != .exited else { return }

        // "Retry" must never re-dispatch a command whose completion cannot be
        // established — not even when a person taps it, because the tap means
        // "try the connection again", not "run that command a second time".
        // Restarting a one-shot command is a separate, explicit action
        // (§9.4, AC-14, AC-15).
        guard context.intent.allowsAutomaticRedial else { return }

        context.attemptState.isCancelled = false
        cancelSuspicionEscalation()
        if case .awaitingUser(let reason) = state {
            switch reason {
            case .burstExhausted, .autoReconnectDisabled, .commandOutcomeUnknown,
                 .unsupportedRecovery, .roundTripUnverified:
                // A retry is exactly the right response to these: nothing
                // needs resolving first.
                break
            case .hostTrustRejected, .credentialUnavailable, .authenticationCancelled,
                 .tmuxSessionMissing, .tmuxIdentityAmbiguous, .protocolIncompatible:
                // These require their own explicit flow; the caller resolves
                // the condition and then calls `resumeAfterUserResolution()`.
                return
            }
        }
        context.attemptState.beginEpoch()
        waitTask?.cancel()
        if loopTask == nil { startLoop(userInitiated: true) }
    }

    /// The user resolved an attention condition (approved the new host key,
    /// picked a session, supplied a credential). Recovery may proceed.
    func resumeAfterUserResolution() {
        guard case .awaitingUser = state else { return }
        guard context.intent.allowsAutomaticRedial else { return }
        context.attemptState.beginEpoch()
        startLoop(userInitiated: true)
    }

    /// Restart a one-shot command whose outcome was uncertain.
    ///
    /// Separate from `retryNow()` on purpose, and it takes a confirmation
    /// token rather than a bare call, so that no generic "retry" path can
    /// reach it by accident. The caller is stating that a person read
    /// "Command outcome unknown" and chose to run it again anyway.
    func restartUncertainCommand(userConfirmedRerun: Bool) {
        guard userConfirmedRerun else { return }
        guard context.intent == .oneShotCommand else { return }
        guard case .awaitingUser(.commandOutcomeUnknown) = state else { return }
        context.attemptState.isCancelled = false
        context.attemptState.beginEpoch()
        lastOutcome = nil
        startLoop(userInitiated: true)
    }

    // MARK: - Path and lifecycle

    /// A path notification arrived. Events are coalesced with a trailing
    /// debounce and a hard maximum deferral so a burst of 100 duplicate
    /// notifications produces one evaluation, not 100 attempts (AC-03).
    func notePathEvent(meaningfulRestoration: Bool = false) {
        record(.pathEvent, pathEligibility: currentPathEligibility())

        let now = clock.now
        if coalesceFirstEventAt == nil { coalesceFirstEventAt = now }
        let deferredFor = now.elapsed(since: coalesceFirstEventAt ?? now)
        let remainingDeferral = max(0, policy.pathCoalesceMaxDeferral - deferredFor)
        let debounce = min(policy.pathCoalesceDebounce, remainingDeferral)

        pendingCoalesce?.cancel()
        pendingCoalesce = Task { @MainActor [weak self] in
            guard let self else { return }
            // A Task cancelled before it started still runs its body, so the
            // superseded debounce must bail here rather than arming a timer
            // nothing will ever cancel again (CON-08).
            guard !Task.isCancelled else { return }
            try? await self.sleeper.sleep(seconds: debounce)
            guard !Task.isCancelled else { return }
            self.coalesceFirstEventAt = nil
            self.pendingCoalesce = nil
            self.applyCoalescedPathEvent(meaningfulRestoration: meaningfulRestoration)
        }
    }

    private func applyCoalescedPathEvent(meaningfulRestoration: Bool) {
        // Wake anything parked in `waitingForConnectivity`.
        let waiters = pathWaiters
        pathWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        guard meaningfulRestoration else { return }
        guard case .waitingForRetry = state else { return }
        guard currentPathEligibility().permitsDialing else { return }

        // Fast-path bypass, rate-limited per logical connection. Repeated
        // equivalent path notifications must not reset backoff (§7.2).
        let now = clock.now
        if let last = context.attemptState.lastFastPathBypass,
           now.elapsed(since: last) < policy.fastPathBypassInterval {
            return
        }
        context.attemptState.lastFastPathBypass = now
        // Cancelling the wait consumes no attempt. The flag matters: without
        // it the loop re-evaluates and computes the *same* backoff again, so
        // "the network is back, try now" would just start the identical wait
        // over and the bypass would do nothing.
        bypassNextWait = true
        waitTask?.cancel()
    }

    /// App backgrounded / scene suspended. Not a failure, and it consumes no
    /// attempts (§6, §13).
    func suspend() {
        guard !state.isTerminal, state != .suspended(savedIntent: context.intent) else { return }
        isForegroundActive = false
        let savedIntent = context.intent
        cancelLoop()
        pendingCoalesce?.cancel()
        pendingCoalesce = nil
        coalesceFirstEventAt = nil
        record(.lifecycle)
        // A live connection stays live: suspension pauses recovery timers, it
        // does not invalidate a healthy transport.
        if state.isActiveRecovery {
            transition(to: .suspended(savedIntent: savedIntent))
        }
    }

    /// Foreground activation. Re-evaluates once against the *current* path,
    /// rather than firing every timer that came due while suspended (§7.3).
    func resume() {
        isForegroundActive = true
        record(.lifecycle)
        guard case .suspended = state else { return }
        guard isAutomaticRecoveryEnabled else {
            transition(to: .awaitingUser(reason: .autoReconnectDisabled))
            return
        }
        transition(to: .suspect)
        startLoop()
    }

    // MARK: - Liveness bookkeeping

    /// Authenticated inbound traffic from the destination (not the bastion).
    /// A local write never advances this (§8.2).
    func noteTargetActivity() {
        context.freshness.lastTargetActivity = clock.now
    }

    /// A completed request/reply round trip.
    func noteConfirmedRoundTrip(milliseconds: Double) {
        let now = clock.now
        context.freshness.lastConfirmedRoundTrip = now
        context.freshness.lastRoundTripMilliseconds = milliseconds
        context.freshness.probeOutstanding = false
        record(.probeResolved, elapsed: milliseconds / 1000)
        if state == .suspect { noteSuspectResolved() }
    }

    /// A keepalive deadline expired. This marks the round trip *unverified*,
    /// not the remote process dead (§8.3).
    ///
    /// Suspicion is bounded. The probe that timed out keeps its FIFO slot, so
    /// no replacement probe is coming, and a user sitting at a quiet prompt
    /// generates no inbound traffic either — precisely because input is gated
    /// while suspect. Without an escalation the terminal would stay read-only
    /// and buttonless for the life of the connection.
    func noteProbeDeadlineExpired() {
        context.freshness.probeOutstanding = true
        record(.probeDeadlineExpired, failure: RecoveryFailure(domain: .timeout))
        noteSuspect()
        scheduleSuspicionEscalation()
    }

    /// Escalate a suspicion that nothing has resolved.
    ///
    /// The two intents diverge here exactly as §8.3 requires: a tmux intent
    /// may retire the transport and recover, because reattaching restores the
    /// same session. A plain shell must not — destroying the user's apparent
    /// session to create a different one is not recovery — so it keeps its
    /// display and asks.
    private func scheduleSuspicionEscalation() {
        escalationTask?.cancel()
        let deadline = policy.stageOverallDeadline
        escalationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            do { try await self.sleeper.sleep(seconds: deadline) } catch { return }
            guard !Task.isCancelled, self.state == .suspect else { return }
            self.escalateSuspicion()
        }
    }

    private func escalateSuspicion() {
        record(.stateChange, failure: RecoveryFailure(domain: .timeout))
        if context.intent.promisesSessionContinuity {
            noteDisconnected(RecoveryFailure(domain: .timeout, hop: .destination))
        } else {
            transition(to: .awaitingUser(reason: .roundTripUnverified))
        }
    }

    private func cancelSuspicionEscalation() {
        escalationTask?.cancel()
        escalationTask = nil
    }

    private var escalationTask: Task<Void, Never>?

    /// The visible pane's state was confirmed synchronized.
    func notePaneSynchronized() {
        context.freshness.lastPaneSync = clock.now
        context.presentationState.isStale = false
    }

    /// The tmux layer reattached and verified it is the same session.
    ///
    /// This is the only thing that promotes a control-mode recovery to `live`
    /// with a `sessionRestored` outcome. `verdict` is what the server actually
    /// said: anything other than `continuous` means the session Shell was
    /// asked to restore is not the one on the other end, and that requires an
    /// explicit choice rather than a silent substitution (CON-05).
    func noteTmuxAttachmentVerified(_ verdict: TmuxContinuityVerdict, generation: UInt64) {
        guard context.isCurrent(generation) else { return }
        cancelSynchronizationEscalation()
        switch verdict {
        case .continuous:
            notePaneSynchronized()
            noteReady(RecoveryReadiness(kind: .tmuxSessionRestored, generation: generation))
        case .differentSession, .sessionMissing:
            transition(to: .awaitingUser(reason: .tmuxSessionMissing))
        case .insufficientEvidence:
            transition(to: .awaitingUser(reason: .tmuxIdentityAmbiguous))
        }
    }

    /// Synchronization cannot hang forever: without a bound, a gateway that
    /// never finishes reconciling leaves the tab in "Restoring terminal
    /// state…" with input gated and no way out.
    private func scheduleSynchronizationEscalation() {
        cancelSynchronizationEscalation()
        let deadline = policy.stageOverallDeadline
        synchronizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.sleeper.sleep(seconds: deadline) } catch { return }
            guard !Task.isCancelled,
                  self.state == .recovering(stage: .synchronizing) else { return }
            self.transition(to: .awaitingUser(reason: .tmuxIdentityAmbiguous))
        }
    }

    private func cancelSynchronizationEscalation() {
        synchronizationTask?.cancel()
        synchronizationTask = nil
    }

    private var synchronizationTask: Task<Void, Never>?

    // MARK: - Loop

    /// Start the recovery loop.
    ///
    /// `userInitiated` is what makes Retry Now work while Auto Reconnect is
    /// off. That setting gates *automatic* replacement attempts; blocking a
    /// person who explicitly asked to reconnect would leave the strip's only
    /// button doing nothing (§14). A user-initiated run makes exactly one
    /// attempt and then stops, rather than quietly re-enabling the automatic
    /// policy the user turned off.
    private func startLoop(userInitiated: Bool = false) {
        guard loopTask == nil else { return }
        guard isAutomaticRecoveryEnabled || userInitiated else { return }
        singleAttemptOnly = userInitiated && !isAutomaticRecoveryEnabled

        // The handle is cleared only if it is still *this* task's. A cancelled
        // loop can outlive `cancelLoop()` — it may be parked in `performWait`
        // — and unconditionally nilling on the way out would clear the handle
        // of the loop that replaced it, orphaning a running loop that nothing
        // can cancel and letting a later disconnect start a second one
        // dialling the same target (CON-01).
        final class TaskBox: @unchecked Sendable {
            var task: Task<Void, Never>?
        }
        let box = TaskBox()
        box.task = Task { @MainActor [weak self, box] in
            guard let self else { return }
            await self.runLoop()
            if self.loopTask == box.task { self.loopTask = nil }
        }
        loopTask = box.task
    }

    private func cancelLoop() {
        bypassNextWait = false
        cancelSuspicionEscalation()
        cancelSynchronizationEscalation()
        loopTask?.cancel()
        loopTask = nil
        waitTask?.cancel()
        waitTask = nil
        let waiters = pathWaiters
        pathWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard !context.attemptState.isCancelled else { return }

            // 1. Destination-relevant eligibility. `unknown` still gets a
            //    bounded try — a VPN-on-demand route reports nothing useful
            //    until something actually dials it.
            if !currentPathEligibility().permitsDialing {
                transition(to: .waitingForConnectivity)
                await awaitPathEvent()
                continue
            }

            // 2. Cooldown attempts only run while foreground-active.
            if context.attemptState.inCooldown && !isForegroundActive {
                transition(to: .waitingForConnectivity)
                await awaitPathEvent()
                continue
            }

            // 3. Wait out the scheduled backoff. Waiting consumes no attempt,
            //    and a cancelled wait (fast path, Retry now) just re-evaluates.
            let delay = nextDelay()
            if delay > 0 {
                let deadline = clock.now.advanced(by: delay)
                context.attemptState.backoffDeadline = deadline
                transition(to: .waitingForRetry(deadline: deadline))
                let completed = await performWait(delay)
                context.attemptState.backoffDeadline = nil
                if Task.isCancelled { return }
                if !completed { continue }
            }

            // 4. Admission control. Queuing consumes no attempt either.
            guard let slot = await scheduler.acquire(
                routeKey: context.targetIdentity.routeKey,
                isVisibleGateway: isVisibleGateway
            ) else {
                if Task.isCancelled { return }
                continue
            }
            defer { slot.release() }

            if Task.isCancelled || context.attemptState.isCancelled { return }

            // 5. One actual dial. THIS is where the attempt count moves.
            context.attemptState.dialCount += 1
            let generation = context.advanceGeneration()
            transition(to: .recovering(stage: .connecting))
            record(.attemptBegan)

            do {
                guard let performAttempt else { throw RecoveryCoordinatorError.noAttemptHandler }
                let readiness = try await performAttempt(generation)

                // CON-07: cancellation wins. A late success from a cancelled
                // or superseded attempt is discarded, never adopted.
                if Task.isCancelled || !context.isCurrent(generation) {
                    record(.attemptFailed, failure: RecoveryFailure(domain: .cancelled, hop: .local))
                    return
                }
                noteReady(readiness)
                return
            } catch {
                if Task.isCancelled { return }
                let failure = classifyFailure?(error) ?? RecoveryFailure(domain: .unknown)
                record(.attemptFailed, failure: failure)

                guard failure.isAutomaticallyRetryable else {
                    transition(to: .awaitingUser(reason: failure.attentionReason ?? .unsupportedRecovery))
                    return
                }

                if singleAttemptOnly {
                    // The user asked for one attempt while automatic recovery
                    // is off. It failed; do not start an automatic schedule
                    // they explicitly disabled.
                    transition(to: .awaitingUser(reason: .autoReconnectDisabled))
                    return
                }

                // Reaching the burst limit is not permanent failure: the
                // intent survives and the low-rate policy takes over (§7.2).
                // It deliberately does NOT become an `awaitingUser` state —
                // recovery is still running, and saying otherwise would put
                // the tab behind a failure overlay while attempts continue.
                // The change of pace reaches the user through the strip's
                // cooldown wording instead.
                context.attemptState.inCooldown =
                    context.attemptState.dialCount >= policy.burstAttempts
            }
        }
    }

    /// Set by a granted fast-path bypass; consumed by the next `nextDelay()`.
    private var bypassNextWait = false

    /// Set when the loop is running on a user's explicit request while
    /// automatic recovery is off: one attempt, then stop.
    private var singleAttemptOnly = false

    /// Delay before the next attempt. Attempt 1 of an epoch is immediate.
    private func nextDelay() -> TimeInterval {
        if bypassNextWait {
            bypassNextWait = false
            return 0
        }
        if context.attemptState.inCooldown {
            return policy.cooldownDelay(jitter: jitter)
        }
        return policy.burstDelay(forAttempt: context.attemptState.dialCount + 1, jitter: jitter)
    }

    /// Returns true if the wait ran to completion, false if it was bypassed.
    private func performWait(_ delay: TimeInterval) async -> Bool {
        let task = Task<Void, Never> { @MainActor [sleeper] in
            do { try await sleeper.sleep(seconds: delay) } catch { }
        }
        waitTask = task
        await task.value
        let bypassed = task.isCancelled
        waitTask = nil
        return !bypassed
    }

    private func awaitPathEvent() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                pathWaiters.append(continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let waiters = self.pathWaiters
                self.pathWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
    }

    private func currentPathEligibility() -> RecoveryPathEligibility {
        pathEligibilityProvider?() ?? .unknown
    }

    // MARK: - Transitions and diagnostics

    private func transition(to newState: RecoveryState) {
        guard state != newState else { return }
        Self.logger.debug(
            "Recovery \(String(describing: self.state)) -> \(String(describing: newState))")
        state = newState
        record(.stateChange)
        onStateChange?(newState)
    }

    private func record(
        _ kind: RecoveryDiagnosticEvent.Kind,
        failure: RecoveryFailure? = nil,
        elapsed: TimeInterval? = nil,
        pathEligibility: RecoveryPathEligibility? = nil,
        byteCount: Int? = nil
    ) {
        var stage: RecoveryStage?
        if case .recovering(let current) = state { stage = current }
        diagnostics.record(RecoveryDiagnosticEvent(
            kind: kind,
            state: state,
            stage: stage,
            failure: failure,
            generation: context.connectionGeneration,
            attemptOrdinal: context.attemptState.dialCount,
            at: clock.now,
            elapsed: elapsed,
            pathEligibility: pathEligibility,
            byteCount: byteCount))
    }
}

enum RecoveryCoordinatorError: LocalizedError {
    case noAttemptHandler

    var errorDescription: String? {
        switch self {
        case .noAttemptHandler:
            return "No recovery attempt handler configured"
        }
    }
}
