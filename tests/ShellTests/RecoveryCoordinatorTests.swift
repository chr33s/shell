//
//  RecoveryCoordinatorTests.swift
//  ShellTests
//
//  The deterministic half of spec.connectivity.md §17.1. Test names carry
//  their acceptance-criterion id so a failure points straight at the clause
//  it violates.
//
//  Everything here runs on virtual time (`VirtualRecoveryScheduler`), a
//  seeded jitter source, a fake path source and a scripted transport. No test
//  in this file sleeps, touches the network, or builds a terminal.
//

import XCTest
@testable import Shell

@MainActor
final class RecoveryCoordinatorTests: XCTestCase {

    // MARK: - AC-01

    /// A ten-minute offline period with an existing tmux intent must produce
    /// no dial attempts while unavailability is established, and must recover
    /// on restoration without the user resetting anything.
    func testAC01_offlinePeriodDialsNothingAndRecoversOnRestoration() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.tmuxSessionRestored)])
        var eligibility = RecoveryPathEligibility.unavailable

        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .attachExistingTmux,
            scheduler: scheduler,
            transport: transport,
            eligibility: { eligibility })

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.settle()

        XCTAssertEqual(coordinator.state, .waitingForConnectivity)

        // Ten minutes of virtual time with no usable route.
        await scheduler.advance(by: 600)
        XCTAssertEqual(transport.attemptCount, 0, "dialled while unavailability was established")
        XCTAssertEqual(coordinator.context.attemptState.dialCount, 0)

        // Restoration alone must be enough — no manual reset.
        eligibility = .eligible
        coordinator.notePathEvent(meaningfulRestoration: true)
        await scheduler.advance(by: 1)
        await scheduler.settle()

        XCTAssertEqual(transport.attemptCount, 1)
        XCTAssertEqual(coordinator.state, .live)
        XCTAssertEqual(coordinator.lastOutcome, .sessionRestored)
    }

    // MARK: - AC-02

    /// Five actual rapid failures exhaust the burst. The intent must survive:
    /// exhaustion drops to the cooldown rate, it does not end recovery.
    func testAC02_burstExhaustionRetainsIntentAndEntersCooldown() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport(
            Array(repeating: .fail(RecoveryFailure(domain: .transportUnavailable)), count: 5))
        var policy = RecoveryPolicy.default
        policy.burstAttempts = 5

        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .attachExistingTmux,
            policy: policy,
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.settle()

        // Walk the burst. Attempt 1 is immediate; the rest wait out equal
        // jitter with `b = min(30, 2^(n-2))`, so the whole burst fits inside
        // 16 virtual seconds. Stop short of the 60s cooldown deliberately:
        // this test is about the burst, and the cooldown attempt that follows
        // is the subject of the next one.
        for _ in 0..<8 {
            await scheduler.advance(by: 2)
        }

        XCTAssertEqual(transport.attemptCount, 5, "burst dialled the wrong number of times")
        XCTAssertTrue(coordinator.context.attemptState.inCooldown)
        XCTAssertFalse(coordinator.state.isTerminal, "burst exhaustion must not be terminal")
        XCTAssertEqual(coordinator.context.intent, .attachExistingTmux, "intent must survive")
    }

    /// After the burst, attempts continue at the cooldown rate rather than
    /// stopping. The intent is retained, not abandoned.
    func testAC02_attemptsContinueAtTheCooldownRateAfterTheBurst() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([])  // every attempt fails
        var policy = RecoveryPolicy.default
        policy.burstAttempts = 2

        let coordinator = RecoveryTestFactory.makeCoordinator(
            policy: policy,
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        for _ in 0..<4 { await scheduler.advance(by: 2) }

        XCTAssertEqual(transport.attemptCount, 2, "the burst did not stop at its limit")
        XCTAssertTrue(coordinator.context.attemptState.inCooldown)

        // One cooldown period (60s ±20%) later, exactly one more attempt.
        await scheduler.advance(by: 75)
        XCTAssertEqual(transport.attemptCount, 3, "cooldown did not produce a further attempt")

        await scheduler.advance(by: 75)
        XCTAssertEqual(transport.attemptCount, 4, "cooldown attempts stopped")
    }

    /// Every delay the burst asked for must fall inside its equal-jitter band
    /// `[b/2, b]` with `b = min(30, 2^(n-2))`.
    func testAC02_burstDelaysStayInsideTheEqualJitterBand() {
        let policy = RecoveryPolicy.default
        let jitter = SeededRecoveryJitter(seed: 7)

        XCTAssertEqual(policy.burstDelay(forAttempt: 1, jitter: jitter), 0,
                       "the first attempt of an epoch is immediate")

        for attempt in 2...8 {
            let base = min(policy.maxBurstBackoff, pow(2, Double(attempt - 2)))
            let delay = policy.burstDelay(forAttempt: attempt, jitter: jitter)
            XCTAssertGreaterThanOrEqual(delay, base / 2, "attempt \(attempt) below the band")
            XCTAssertLessThanOrEqual(delay, base, "attempt \(attempt) above the band")
        }
    }

    // MARK: - AC-03

    /// 100 duplicate path notifications during a scheduled wait must coalesce
    /// into one evaluation, spend no attempts, and start no parallel attempt.
    func testAC03_duplicatePathNotificationsCoalesceAndSpendNoAttempts() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([
            .fail(RecoveryFailure(domain: .transportUnavailable)),
            .succeed(.terminalReady),
        ])

        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.settle()
        XCTAssertEqual(transport.attemptCount, 1, "the first attempt should be immediate")

        // Now parked in waitingForRetry. Shout at it.
        guard case .waitingForRetry = coordinator.state else {
            return XCTFail("expected a scheduled wait, got \(coordinator.state)")
        }

        for _ in 0..<100 {
            coordinator.notePathEvent(meaningfulRestoration: false)
        }
        await scheduler.settle()

        XCTAssertEqual(transport.attemptCount, 1, "path notifications spent attempts")
        XCTAssertEqual(coordinator.context.attemptState.dialCount, 1)

        // Exactly one debounce timer is outstanding for the whole burst of
        // notifications, alongside the retry wait itself.
        XCTAssertLessThanOrEqual(scheduler.pendingSleepCount, 2,
                                 "each notification armed its own timer")
    }

    /// Repeated equivalent path notifications must not reset backoff, and the
    /// fast-path bypass is rate-limited per logical connection.
    func testAC03_fastPathBypassIsRateLimited() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([
            .fail(RecoveryFailure(domain: .transportUnavailable)),
            .fail(RecoveryFailure(domain: .transportUnavailable)),
            .fail(RecoveryFailure(domain: .transportUnavailable)),
        ])

        // A short coalescing window keeps the debounce strictly shorter than
        // the shortest backoff (attempt 2 draws from [0.5s, 1s]). Without
        // that separation the test would be asserting on which of two timers
        // with the same deadline fires first, which is not the behavior under
        // test.
        var policy = RecoveryPolicy.default
        policy.pathCoalesceDebounce = 0.1

        let coordinator = RecoveryTestFactory.makeCoordinator(
            policy: policy,
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.settle()
        XCTAssertEqual(transport.attemptCount, 1)

        // First meaningful restoration bypasses the pending wait.
        coordinator.notePathEvent(meaningfulRestoration: true)
        await scheduler.advance(by: 0.2)
        XCTAssertEqual(transport.attemptCount, 2, "the first bypass should have dialled")

        // A second one inside the 5s rate limit must not.
        let before = transport.attemptCount
        coordinator.notePathEvent(meaningfulRestoration: true)
        await scheduler.advance(by: 0.2)
        XCTAssertEqual(transport.attemptCount, before,
                       "a second bypass inside the rate limit dialled anyway")
    }

    // MARK: - AC-05

    /// An unknown / VPN-on-demand path must still be allowed a bounded
    /// attempt. A generic monitor result is a hint, not an offline gate.
    func testAC05_unknownPathStillPermitsABoundedAttempt() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])

        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport,
            eligibility: { .unknown })

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.settle()

        XCTAssertEqual(transport.attemptCount, 1, "unknown path was treated as a hard offline gate")
        XCTAssertEqual(coordinator.state, .live)
    }

    // MARK: - AC-04

    /// A transport that proves healthy after a path change is validated, not
    /// replaced.
    func testAC04_healthyTransportIsValidatedRatherThanReplaced() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)

        coordinator.noteSuspect()
        XCTAssertEqual(coordinator.state, .suspect)

        coordinator.noteConfirmedRoundTrip(milliseconds: 42)
        await scheduler.settle()

        XCTAssertEqual(coordinator.state, .live)
        XCTAssertEqual(transport.attemptCount, 0, "a healthy transport was replaced")
    }

    // MARK: - AC-08

    /// Cancellation during an in-flight attempt must discard that attempt's
    /// late success — no reopened tab, no adopted success state.
    func testAC08_lateSuccessAfterCancellationIsDiscarded() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.hang])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.settle()
        XCTAssertEqual(transport.attemptCount, 1)

        coordinator.stop()
        await scheduler.settle()
        XCTAssertEqual(coordinator.state, .stopped)

        // The attempt was never actually abortable; it finishes anyway.
        transport.resolvePendingWithSuccess(.terminalReady)
        await scheduler.settle()

        XCTAssertEqual(coordinator.state, .stopped, "a cancelled attempt's success was adopted")
        XCTAssertNil(coordinator.lastOutcome)
    }

    // MARK: - AC-09

    /// Background/foreground cycling must spend no attempts and must produce
    /// exactly one recovery on resume — not a storm of overdue timers.
    func testAC09_suspensionSpendsNoAttemptsAndResumesOnce() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([
            .fail(RecoveryFailure(domain: .transportUnavailable)),
            .succeed(.terminalReady),
        ])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.settle()
        let attemptsBeforeSuspension = transport.attemptCount

        for _ in 0..<5 {
            coordinator.suspend()
            await scheduler.advance(by: 120)
            XCTAssertEqual(transport.attemptCount, attemptsBeforeSuspension,
                           "an attempt was spent while suspended")
            coordinator.resume()
            await scheduler.settle()
        }

        await scheduler.advance(by: 1)
        await scheduler.settle()

        XCTAssertEqual(coordinator.state, .live)
        XCTAssertEqual(transport.attemptCount, attemptsBeforeSuspension + 1,
                       "resume produced more than one recovery")
    }

    // MARK: - AC-10

    /// Transport establishment must never be published as a restored session,
    /// and a tmux intent must not be satisfied by terminal readiness alone.
    func testAC10_prematureReadinessIsNeverPublishedAsRestored() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .attachExistingTmux,
            scheduler: scheduler,
            transport: transport,
            verifiesTmuxContinuity: true)

        let generation = coordinator.context.connectionGeneration

        coordinator.noteReady(RecoveryReadiness(kind: .transportEstablished, generation: generation))
        XCTAssertNotEqual(coordinator.state, .live, "TCP + auth alone was reported as live")
        XCTAssertNil(coordinator.lastOutcome)

        coordinator.noteReady(RecoveryReadiness(kind: .terminalReady, generation: generation))
        XCTAssertEqual(coordinator.state, .recovering(stage: .synchronizing),
                       "a PTY alone satisfied a verifiable tmux intent")
        XCTAssertNil(coordinator.lastOutcome)

        coordinator.noteTmuxAttachmentVerified(.continuous, generation: generation)
        XCTAssertEqual(coordinator.state, .live)
        XCTAssertEqual(coordinator.lastOutcome, .sessionRestored)
    }

    /// A reattachment that lands on a *different* session must not be called
    /// restored; the user chooses instead (CON-05).
    func testAC12_verificationMismatchRequiresExplicitSelection() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .attachExistingTmux,
            scheduler: scheduler,
            transport: transport,
            verifiesTmuxContinuity: true)

        let generation = coordinator.context.connectionGeneration
        coordinator.noteReady(RecoveryReadiness(kind: .terminalReady, generation: generation))
        coordinator.noteTmuxAttachmentVerified(.differentSession, generation: generation)

        XCTAssertEqual(coordinator.state, .awaitingUser(reason: .tmuxSessionMissing))
        XCTAssertNil(coordinator.lastOutcome)
    }

    /// Synchronization that never completes must not hang the tab forever.
    func testAC10_synchronizationThatNeverCompletesAsksTheUser() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .attachExistingTmux,
            scheduler: scheduler,
            transport: transport,
            verifiesTmuxContinuity: true)

        coordinator.noteReady(RecoveryReadiness(
            kind: .terminalReady, generation: coordinator.context.connectionGeneration))
        XCTAssertEqual(coordinator.state, .recovering(stage: .synchronizing))

        await scheduler.advance(by: RecoveryPolicy.default.stageOverallDeadline + 1)
        XCTAssertEqual(coordinator.state, .awaitingUser(reason: .tmuxIdentityAmbiguous))
    }

    /// Regular tmux mode cannot verify continuity, so it must not wait for a
    /// verification that will never arrive — and its attach-only reconnect is
    /// not "a new shell", because nothing was created.
    func testRegularTmuxModeCompletesWithoutVerification() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .attachExistingTmux,
            scheduler: scheduler,
            transport: transport,
            verifiesTmuxContinuity: false)

        coordinator.noteReady(RecoveryReadiness(
            kind: .terminalReady, generation: coordinator.context.connectionGeneration))

        XCTAssertEqual(coordinator.state, .live)
        XCTAssertEqual(coordinator.lastOutcome, .sessionRestored)
    }

    /// Readiness from a retired generation must not promote the replacement.
    func testCON02_readinessFromRetiredGenerationIsDiscarded() {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)

        let stale = coordinator.context.connectionGeneration
        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))

        coordinator.noteReady(RecoveryReadiness(kind: .terminalReady, generation: stale))
        XCTAssertNotEqual(coordinator.state, .live, "a retired generation promoted the connection")
    }

    // MARK: - AC-15

    /// A one-shot command that loses its exit status is never dispatched a
    /// second time, and says so plainly.
    func testAC15_oneShotCommandIsNeverRedispatched() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .oneShotCommand,
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.advance(by: 300)

        XCTAssertEqual(transport.attemptCount, 0, "a one-shot command was re-dispatched")
        XCTAssertEqual(coordinator.state, .awaitingUser(reason: .commandOutcomeUnknown))
        XCTAssertEqual(coordinator.lastOutcome, .commandOutcomeUnknown)
    }

    /// Even an explicit Retry Now must not silently re-run the command.
    func testAC15_retryNowDoesNotRerunAnUncertainCommand() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .oneShotCommand,
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.settle()
        coordinator.retryNow()
        await scheduler.advance(by: 60)

        XCTAssertEqual(transport.attemptCount, 0)
    }

    // MARK: - AC-16

    /// A plain SSH reconnection is a new shell. It must never be reported as
    /// a restored session.
    func testAC16_plainSSHRecoveryReportsANewShellNotARestoredSession() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .interactiveShell,
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.settle()

        XCTAssertEqual(coordinator.state, .live)
        XCTAssertEqual(coordinator.lastOutcome, .newShellOpened)
        XCTAssertNotEqual(coordinator.lastOutcome, .sessionRestored)
    }

    // MARK: - AC-17

    /// A rejected host key, a missing credential, and a cancelled auth
    /// challenge each land in their own attention state and stop the retry
    /// loop — no retry-prompt loop, no fallback to a weaker method.
    func testAC17_trustAndCredentialFailuresRequireAttentionInsteadOfRetrying() async throws {
        let cases: [(RecoveryFailure, RecoveryAttentionReason)] = [
            (RecoveryFailure(domain: .hostTrustRejected), .hostTrustRejected),
            (RecoveryFailure(domain: .authenticationNeeded), .credentialUnavailable),
            (RecoveryFailure(domain: .authenticationRejected), .authenticationCancelled),
            (RecoveryFailure(domain: .sessionMissing), .tmuxSessionMissing),
        ]

        for (failure, expected) in cases {
            let scheduler = VirtualRecoveryScheduler()
            let transport = ScriptedTransport([.succeed(.terminalReady)])
            let coordinator = RecoveryTestFactory.makeCoordinator(
                scheduler: scheduler,
                transport: transport)

            coordinator.noteDisconnected(failure)
            await scheduler.advance(by: 300)

            XCTAssertEqual(coordinator.state, .awaitingUser(reason: expected),
                           "\(failure.domain) did not require attention")
            XCTAssertEqual(transport.attemptCount, 0,
                           "\(failure.domain) was retried automatically")
        }
    }

    /// Network restoration must not bypass an attention state.
    func testAC17_networkRestorationDoesNotBypassAwaitingUser() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .hostTrustRejected))
        await scheduler.settle()

        coordinator.notePathEvent(meaningfulRestoration: true)
        await scheduler.advance(by: 120)

        XCTAssertEqual(coordinator.state, .awaitingUser(reason: .hostTrustRejected))
        XCTAssertEqual(transport.attemptCount, 0)
    }

    // MARK: - AC-21

    /// With auto-reconnect disabled, no automatic replacement happens however
    /// many network events arrive. A clean remote exit is terminal.
    func testAC21_disabledAutoReconnectMakesNoAutomaticAttempts() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)
        coordinator.isAutomaticRecoveryEnabled = false

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        for _ in 0..<10 {
            coordinator.notePathEvent(meaningfulRestoration: true)
            await scheduler.advance(by: 30)
        }

        XCTAssertEqual(transport.attemptCount, 0)
        XCTAssertEqual(coordinator.state, .awaitingUser(reason: .autoReconnectDisabled))
    }

    func testAC21_cleanRemoteExitIsTerminalAndNeverAutoRecovers() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)

        coordinator.noteRemoteExit()
        coordinator.notePathEvent(meaningfulRestoration: true)
        await scheduler.advance(by: 300)

        XCTAssertEqual(coordinator.state, .exited)
        XCTAssertEqual(transport.attemptCount, 0)
    }

    // MARK: - AC-20

    /// The global scheduler admits at most two concurrent automatic attempts,
    /// and at most one per equivalent route.
    func testAC20_globalAndPerRouteConcurrencyLimits() async throws {
        let scheduler = RecoveryGlobalScheduler(policy: .default)

        let routeA1 = scheduler.tryAcquire(routeKey: "a")
        XCTAssertNotNil(routeA1)
        XCTAssertNil(scheduler.tryAcquire(routeKey: "a"), "two attempts admitted on one route")

        let routeB1 = scheduler.tryAcquire(routeKey: "b")
        XCTAssertNotNil(routeB1)
        XCTAssertEqual(scheduler.activeAttemptCount, 2)

        XCTAssertNil(scheduler.tryAcquire(routeKey: "c"), "global limit exceeded")

        routeA1?.release()
        XCTAssertNotNil(scheduler.tryAcquire(routeKey: "c"), "a released slot was not reusable")
        routeB1?.release()
    }

    // MARK: - Manual recovery must never be a dead end

    /// "Retry Now" is offered on the stopped strip, so it has to work. A
    /// person tapping it is a new user action starting another intent.
    func testRetryAfterStopStartsANewAttempt() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)

        coordinator.stop()
        XCTAssertEqual(coordinator.state, .stopped)

        coordinator.retryNow()
        await scheduler.advance(by: 1)

        XCTAssertEqual(transport.attemptCount, 1, "Retry Now was a no-op after Stop Recovery")
        XCTAssertEqual(coordinator.state, .live)
    }

    /// With Auto Reconnect off, an explicit retry must still connect — the
    /// setting gates *automatic* attempts. One attempt, then it stops rather
    /// than re-enabling the schedule the user turned off.
    func testManualRetryWorksWhileAutomaticRecoveryIsDisabled() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([
            .fail(RecoveryFailure(domain: .transportUnavailable)),
        ])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)
        coordinator.isAutomaticRecoveryEnabled = false

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.settle()
        XCTAssertEqual(coordinator.state, .awaitingUser(reason: .autoReconnectDisabled))

        coordinator.retryNow()
        await scheduler.advance(by: 1)
        XCTAssertEqual(transport.attemptCount, 1, "an explicit retry was blocked by the automatic gate")

        // …and it does not turn the automatic schedule back on.
        await scheduler.advance(by: 300)
        XCTAssertEqual(transport.attemptCount, 1, "a disabled automatic schedule resumed itself")
        XCTAssertEqual(coordinator.state, .awaitingUser(reason: .autoReconnectDisabled))
    }

    /// A clean remote exit stays closed even when a person taps Retry: there
    /// is nothing to reconnect to.
    func testRetryDoesNotReviveACleanRemoteExit() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            scheduler: scheduler,
            transport: transport)

        coordinator.noteRemoteExit()
        coordinator.retryNow()
        await scheduler.advance(by: 60)

        XCTAssertEqual(coordinator.state, .exited)
        XCTAssertEqual(transport.attemptCount, 0)
    }

    /// Cancelling one queued waiter must not wake the others: each spurious
    /// wake costs an unrelated connection a full extra backoff.
    func testCancellingOneQueuedWaiterLeavesTheOthersQueued() async throws {
        let scheduler = RecoveryGlobalScheduler(policy: .default)
        let held = scheduler.tryAcquire(routeKey: "route")
        XCTAssertNotNil(held)

        let first = Task { @MainActor in
            await scheduler.acquire(routeKey: "route", isVisibleGateway: false)
        }
        let second = Task { @MainActor in
            await scheduler.acquire(routeKey: "route", isVisibleGateway: false)
        }
        for _ in 0..<64 { await Task.yield() }
        XCTAssertEqual(scheduler.queuedWaiterCount, 2)

        first.cancel()
        _ = await first.value
        for _ in 0..<64 { await Task.yield() }

        XCTAssertEqual(scheduler.queuedWaiterCount, 1,
                       "cancelling one waiter woke every waiter on the route")

        second.cancel()
        _ = await second.value
        held?.release()
    }

    // MARK: - Suspicion must be bounded

    /// A tmux intent whose keepalive goes unanswered retires the transport
    /// and recovers, rather than sitting read-only forever. The user at a
    /// quiet prompt generates no inbound traffic to break the deadlock —
    /// precisely because input is gated while suspect (§8.3).
    func testProbeDeadlineEscalatesToRecoveryForATmuxIntent() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .attachExistingTmux,
            scheduler: scheduler,
            transport: transport)

        coordinator.noteProbeDeadlineExpired()
        XCTAssertEqual(coordinator.state, .suspect)
        XCTAssertEqual(transport.attemptCount, 0, "suspicion dialled before its deadline")

        await scheduler.advance(by: RecoveryPolicy.default.stageOverallDeadline + 1)

        XCTAssertEqual(transport.attemptCount, 1, "an unresolved suspicion never escalated")
        XCTAssertEqual(coordinator.state, .live)
    }

    /// A plain shell must NOT be replaced on an unverified round trip: that
    /// would destroy the user's apparent session to build a different one.
    /// It keeps its display and offers a choice.
    func testProbeDeadlineAsksAPlainShellRatherThanReplacingIt() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .interactiveShell,
            scheduler: scheduler,
            transport: transport)

        coordinator.noteProbeDeadlineExpired()
        await scheduler.advance(by: RecoveryPolicy.default.stageOverallDeadline + 1)

        XCTAssertEqual(coordinator.state, .awaitingUser(reason: .roundTripUnverified))
        XCTAssertEqual(transport.attemptCount, 0, "a plain shell was replaced automatically")

        let presentation = RecoveryStatusPresentation.make(
            for: coordinator.state, intent: .interactiveShell)
        XCTAssertEqual(presentation?.actions.contains(.openNewShell), true,
                       "no way out was offered")
    }

    /// Inbound traffic before the escalation resolves it without replacing
    /// anything.
    func testInboundActivityResolvesSuspicionBeforeEscalation() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([.succeed(.terminalReady)])
        let coordinator = RecoveryTestFactory.makeCoordinator(
            intent: .attachExistingTmux,
            scheduler: scheduler,
            transport: transport)

        coordinator.noteProbeDeadlineExpired()
        coordinator.noteSuspectResolvedByInboundActivity()
        XCTAssertEqual(coordinator.state, .live)

        await scheduler.advance(by: RecoveryPolicy.default.stageOverallDeadline + 5)
        XCTAssertEqual(transport.attemptCount, 0, "a resolved suspicion escalated anyway")
        XCTAssertEqual(coordinator.state, .live)
    }

    /// The suspect strip has to carry a way out, since input is gated.
    func testSuspectStripOffersAnAction() throws {
        let presentation = try XCTUnwrap(RecoveryStatusPresentation.make(
            for: .suspect, intent: .interactiveShell))
        XCTAssertFalse(presentation.actions.isEmpty,
                       "a buttonless suspect strip is a dead end while input is gated")
    }

    /// A retired loop must not clear the handle of the loop that replaced it,
    /// or a later disconnect starts a second loop dialling the same target.
    func testSuspendAndResumeDoesNotLeaveTwoLoopsRunning() async throws {
        let scheduler = VirtualRecoveryScheduler()
        let transport = ScriptedTransport([])  // every attempt fails
        var policy = RecoveryPolicy.default
        policy.burstAttempts = 8
        let coordinator = RecoveryTestFactory.makeCoordinator(
            policy: policy,
            scheduler: scheduler,
            transport: transport)

        coordinator.noteDisconnected(RecoveryFailure(domain: .transportUnavailable))
        await scheduler.advance(by: 1)
        let afterFirst = transport.attemptCount

        // Suspend mid-wait, resume, then let the schedule run. Two live loops
        // would roughly double the dial count over the same window.
        coordinator.suspend()
        await scheduler.settle()
        coordinator.resume()
        await scheduler.advance(by: 2)

        coordinator.stop()
        await scheduler.settle()
        let afterStop = transport.attemptCount
        await scheduler.advance(by: 120)

        XCTAssertEqual(transport.attemptCount, afterStop,
                       "an orphaned loop kept dialling after stop()")
        XCTAssertGreaterThanOrEqual(afterStop, afterFirst)
    }

    // MARK: - Diagnostics

    /// The diagnostic ring is bounded and holds no command text, terminal
    /// output, or credential material.
    func testDiagnosticRingIsBoundedAndRedacted() {
        var ring = RecoveryDiagnosticRing(capacity: 4)
        for index in 0..<10 {
            ring.record(RecoveryDiagnosticEvent(
                kind: .attemptBegan,
                state: .recovering(stage: .connecting),
                stage: .connecting,
                failure: RecoveryFailure(domain: .timeout, hop: .jumpHost, detail: "secret-banner"),
                generation: UInt64(index),
                attemptOrdinal: index,
                at: MonotonicInstant(seconds: Double(index)),
                elapsed: nil,
                pathEligibility: .eligible,
                byteCount: nil))
        }

        XCTAssertEqual(ring.count, 4, "the ring grew past its capacity")
        XCTAssertEqual(ring.events.map(\.generation), [6, 7, 8, 9], "oldest events were not evicted")

        let export = ring.redactedExport()
        XCTAssertFalse(export.contains("secret-banner"),
                       "the export leaked an untrusted server string")
        XCTAssertTrue(export.contains("fail=timeout@jumpHost"),
                      "the export dropped the typed reason code")
    }
}
