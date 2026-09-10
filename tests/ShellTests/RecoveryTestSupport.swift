//
//  RecoveryTestSupport.swift
//  ShellTests
//
//  Deterministic time for the recovery suite (spec.connectivity.md §17.1).
//
//  The acceptance criteria describe schedules measured in minutes. Sleeping
//  through them would make the suite unrunnable, and sleeping through a
//  *fraction* of them would make it flaky. So the coordinator's clock and its
//  sleeper are the same injected object: virtual time only moves when a test
//  moves it, and a sleeping task wakes exactly when its deadline is crossed.
//
//  This is what lets AC-01 assert "no dial attempts during a ten-minute
//  offline period" in microseconds, and what lets AC-03 hold a scheduled wait
//  open while 100 path notifications arrive.
//

import Foundation
@testable import Shell

/// A virtual clock that is also the sleeper the coordinator waits on.
final class VirtualRecoveryScheduler: RecoveryClock, RecoverySleeper, @unchecked Sendable {

    private let lock = NSLock()
    private var currentSeconds: TimeInterval = 1_000
    private var nextID = 0

    private struct Waiter {
        let id: Int
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    /// Every duration passed to `sleep`, in call order. Tests assert on the
    /// schedule itself, not just on its side effects.
    private(set) var requestedSleeps: [TimeInterval] = []

    var now: MonotonicInstant {
        lock.lock()
        defer { lock.unlock() }
        return MonotonicInstant(seconds: currentSeconds)
    }

    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        // A Task that was cancelled before its body ran still executes that
        // body. Without this check the debounce timers the coordinator
        // cancels would register waiters anyway and never be woken, which
        // reads exactly like a timer leak.
        try Task.checkCancellation()

        let id: Int = lock.withLock {
            nextID += 1
            requestedSleeps.append(seconds)
            return nextID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let deadline: TimeInterval = lock.withLock { currentSeconds + seconds }
                let shouldResumeNow: Bool = lock.withLock {
                    guard deadline > currentSeconds else { return true }
                    waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if shouldResumeNow { continuation.resume() }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    /// Move virtual time forward and wake everything whose deadline passed.
    ///
    /// Yields afterwards so the woken tasks actually run before the caller's
    /// next assertion — without this, a test would assert on state the
    /// coordinator has not reached yet.
    func advance(by seconds: TimeInterval, settleTurns: Int = 64) async {
        // Settle first: a task created but not yet started has not registered
        // its sleep, and advancing past a deadline that does not exist yet
        // parks it forever.
        await settle(turns: settleTurns)

        let due: [Waiter] = lock.withLock {
            currentSeconds += seconds
            let reached = waiters.filter { $0.deadline <= currentSeconds }
            waiters.removeAll { $0.deadline <= currentSeconds }
            return reached
        }
        for waiter in due { waiter.continuation.resume() }
        await settle(turns: settleTurns)
    }

    /// Let queued main-actor work run without moving time.
    ///
    /// One woken sleeper can cascade through several suspension points before
    /// the coordinator reaches its next observable state — cancel the wait,
    /// resume the loop, acquire a scheduling slot, run the attempt — and each
    /// of those costs a turn. The count is generous on purpose: yielding a few
    /// extra times is free, and starving the chain makes tests fail for
    /// reasons that have nothing to do with the behavior under test.
    func settle(turns: Int = 64) async {
        for _ in 0..<turns { await Task.yield() }
    }

    /// Number of tasks currently parked in `sleep`.
    var pendingSleepCount: Int {
        lock.withLock { waiters.count }
    }

    private func cancel(id: Int) {
        let cancelled: Waiter? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index)
        }
        cancelled?.continuation.resume(throwing: CancellationError())
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// A scripted transport: each attempt takes the next outcome in the list.
@MainActor
final class ScriptedTransport {
    enum Outcome {
        case succeed(RecoveryReadinessKind)
        case fail(RecoveryFailure)
        /// Never resolves until `resolvePending` is called. Models an attempt
        /// hanging on a blackholed socket.
        case hang
    }

    private var script: [Outcome]
    private(set) var attemptGenerations: [UInt64] = []
    private var pending: CheckedContinuation<RecoveryReadiness, Error>?
    private var pendingGeneration: UInt64 = 0

    init(_ script: [Outcome]) {
        self.script = script
    }

    var attemptCount: Int { attemptGenerations.count }

    func perform(generation: UInt64) async throws -> RecoveryReadiness {
        attemptGenerations.append(generation)
        let outcome = script.isEmpty
            ? Outcome.fail(RecoveryFailure(domain: .transportUnavailable))
            : script.removeFirst()

        switch outcome {
        case .succeed(let kind):
            return RecoveryReadiness(kind: kind, generation: generation)
        case .fail(let failure):
            throw ScriptedFailure(failure: failure)
        case .hang:
            pendingGeneration = generation
            return try await withCheckedThrowingContinuation { continuation in
                self.pending = continuation
            }
        }
    }

    /// Resolve a hanging attempt as a success — the "late success after
    /// cancellation" case.
    func resolvePendingWithSuccess(_ kind: RecoveryReadinessKind) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: RecoveryReadiness(kind: kind, generation: pendingGeneration))
    }
}

struct ScriptedFailure: Error {
    let failure: RecoveryFailure
}

@MainActor
enum RecoveryTestFactory {

    static func target(host: String = "example.test") -> RecoveryTargetIdentity {
        RecoveryTargetIdentity(host: host, port: 22, username: "user")
    }

    static func context(
        intent: RecoveryIntent,
        policy: RecoveryPolicy = .default,
        host: String = "example.test",
        verifiesTmuxContinuity: Bool = false
    ) -> RecoveryContext {
        var context = RecoveryContext(
            intent: intent, targetIdentity: target(host: host), policy: policy)
        context.verifiesTmuxContinuity = verifiesTmuxContinuity
        return context
    }

    /// A coordinator wired to virtual time, a seeded jitter source, a private
    /// global scheduler, and a scripted transport.
    static func makeCoordinator(
        intent: RecoveryIntent = .interactiveShell,
        policy: RecoveryPolicy = .default,
        scheduler: VirtualRecoveryScheduler,
        transport: ScriptedTransport,
        verifiesTmuxContinuity: Bool = false,
        eligibility: @escaping () -> RecoveryPathEligibility = { .eligible }
    ) -> RecoveryCoordinator {
        let coordinator = RecoveryCoordinator(
            context: context(intent: intent, policy: policy,
                             verifiesTmuxContinuity: verifiesTmuxContinuity),
            clock: scheduler,
            jitter: SeededRecoveryJitter(seed: 42),
            sleeper: scheduler,
            scheduler: RecoveryGlobalScheduler(policy: policy))

        coordinator.performAttempt = { generation in
            try await transport.perform(generation: generation)
        }
        coordinator.classifyFailure = { error in
            (error as? ScriptedFailure)?.failure ?? RecoveryFailure(domain: .unknown)
        }
        coordinator.pathEligibilityProvider = eligibility
        return coordinator
    }
}
