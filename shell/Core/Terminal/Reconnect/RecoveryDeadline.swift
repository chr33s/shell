//
//  RecoveryDeadline.swift
//  shell
//
//  Owned operation deadlines for recovery stages and keepalive probes
//  (spec.connectivity.md §7.3, §8.3).
//
//  `withTimeout` in Core/Foundation solves half of this: it returns control
//  to the caller even when the underlying future ignores cancellation. What
//  it does not provide is the other half the spec requires — a *generation*
//  check, an inactivity deadline that valid progress can reset while the
//  overall deadline keeps running, and a cleanup hook that runs on the
//  timeout path so the abandoned request's resources are still released.
//
//  Replacing a task-group race with unstructured tasks alone is explicitly
//  not sufficient, which is why this file exists rather than a one-line
//  change to the existing helper.
//

import Foundation
import os

/// Why a staged operation ended.
enum RecoveryDeadlineOutcome<Value>: @unchecked Sendable where Value: Sendable {
    case completed(Value)
    /// The operation threw. A real outcome for the caller to classify — not
    /// a deadline expiry.
    case failed(Error)
    /// The inactivity (no-progress) deadline expired.
    case inactivityExpired
    /// The overall stage deadline expired. Progress never resets this.
    case overallExpired
    /// The generation was retired while the operation was in flight, or the
    /// surrounding task was cancelled. Its result must not be adopted.
    case superseded
}

/// A two-level deadline for one stage of recovery.
///
/// The inactivity deadline is reset by generation-matched progress; the
/// overall deadline is not. Both are measured on a monotonic clock, so a
/// wall-clock adjustment (or a device waking from sleep) cannot make a stage
/// appear to have taken negative time.
@MainActor
final class RecoveryStageDeadline {

    private nonisolated static let logger = Logger(
        subsystem: "dev.chr33s.shell", category: "RecoveryDeadline")

    private let clock: RecoveryClock
    private let inactivityBudget: TimeInterval
    private let overallBudget: TimeInterval
    private let startedAt: MonotonicInstant
    private var lastProgressAt: MonotonicInstant

    let generation: UInt64
    private(set) var isExpired = false

    init(
        generation: UInt64,
        inactivity: TimeInterval,
        overall: TimeInterval,
        clock: RecoveryClock = SystemRecoveryClock()
    ) {
        self.generation = generation
        self.inactivityBudget = inactivity
        self.overallBudget = overall
        self.clock = clock
        self.startedAt = clock.now
        self.lastProgressAt = startedAt
    }

    /// Record generation-matched progress. Progress from a retired generation
    /// is ignored: it must not keep a superseded stage alive.
    func noteProgress(generation: UInt64) {
        guard generation == self.generation else { return }
        lastProgressAt = clock.now
    }

    /// Remaining time before the *next* expiry of either budget.
    var remaining: TimeInterval {
        let now = clock.now
        let inactivityLeft = inactivityBudget - now.elapsed(since: lastProgressAt)
        let overallLeft = overallBudget - now.elapsed(since: startedAt)
        return max(0, min(inactivityLeft, overallLeft))
    }

    /// Which budget (if either) has run out right now.
    func expiredBudget() -> RecoveryDeadlineOutcome<Never>? {
        let now = clock.now
        if now.elapsed(since: startedAt) >= overallBudget { return .overallExpired }
        if now.elapsed(since: lastProgressAt) >= inactivityBudget { return .inactivityExpired }
        return nil
    }
}

// Single-resume box. Exactly one of {operation, deadline, cancellation}
// claims the continuation; the losers return without touching it. The
// continuation lives in the box rather than being captured directly so
// the cancellation handler — which runs outside the continuation body —
// can also resolve it instead of leaving the caller suspended forever.
private final class RecoveryDeadlineBox<Value: Sendable>: @unchecked Sendable {
    struct State {
        var continuation: CheckedContinuation<RecoveryDeadlineOutcome<Value>, Never>?
        var settled = false
        /// `onCancel` can fire before the continuation body runs when the
        /// surrounding task is already cancelled on entry. Without this,
        /// that resolve is a no-op and the caller suspends forever.
        var pendingOutcome: RecoveryDeadlineOutcome<Value>?
    }
    let lock = OSAllocatedUnfairLock<State>(initialState: State())

    func install(_ continuation: CheckedContinuation<RecoveryDeadlineOutcome<Value>, Never>) {
        let immediate = lock.withLock { state -> RecoveryDeadlineOutcome<Value>? in
            if let pending = state.pendingOutcome {
                state.settled = true
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
    }

    /// Resolve once. Returns true if this caller was the one that did it.
    @discardableResult
    func resolve(_ outcome: RecoveryDeadlineOutcome<Value>) -> Bool {
        let action = lock.withLock { state -> (CheckedContinuation<RecoveryDeadlineOutcome<Value>, Never>?, Bool) in
            if state.settled || state.pendingOutcome != nil { return (nil, false) }
            if let continuation = state.continuation {
                state.continuation = nil
                state.settled = true
                return (continuation, true)
            }
            state.pendingOutcome = outcome
            return (nil, true)
        }
        action.0?.resume(returning: outcome)
        return action.1
    }
}

/// Runs `operation` under a hard deadline that the caller observes even when
/// the operation itself never notices cancellation.
///
/// Differences from `withTimeout` that the spec requires:
///
///  * `isCurrent` is consulted before a *successful* result is adopted, so a
///    superseded generation's late success is reported as `.superseded`
///    instead of being handed back as if it were current (CON-02).
///  * `onAbandon` runs on the timeout path with the still-running operation
///    task, so the caller can close/abort the channel it owns rather than
///    leaking it. Returning from a timeout is not evidence that a file
///    descriptor was reclaimed (§8.3).
///  * Cancellation of the surrounding task propagates.
///
/// Exactly one of {operation, deadline, cancellation} resolves the call.
func withRecoveryDeadline<Value: Sendable>(
    seconds: TimeInterval,
    generation: UInt64,
    isCurrent: @escaping @Sendable (UInt64) -> Bool = { _ in true },
    onAbandon: (@Sendable () -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> Value
) async -> RecoveryDeadlineOutcome<Value> {
    let box = RecoveryDeadlineBox<Value>()

    return await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<RecoveryDeadlineOutcome<Value>, Never>) in
            box.install(continuation)

            // The timer is owned so the winner can cancel the loser. Leaving
            // it to expire on its own left a sleeping task behind every
            // keepalive and every completed stage — harmless individually,
            // and a steady drip over a long session.
            let timerBox = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

            let work = Task<Void, Never> {
                do {
                    let value = try await operation()
                    box.resolve(isCurrent(generation) ? .completed(value) : .superseded)
                } catch is CancellationError {
                    box.resolve(.superseded)
                } catch {
                    box.resolve(isCurrent(generation) ? .failed(error) : .superseded)
                }
                timerBox.withLock { $0 }?.cancel()
            }

            let timer = Task<Void, Never> {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                } catch {
                    return  // The operation finished first and cancelled us.
                }
                // Cancel first so anything that DOES observe cancellation can
                // short-circuit, then hand the caller its cleanup hook. We do
                // not await the operation task: that is the whole point.
                guard box.resolve(.overallExpired) else { return }
                work.cancel()
                onAbandon?()
            }
            timerBox.withLock { $0 = timer }
        }
    } onCancel: {
        if box.resolve(.superseded) { onAbandon?() }
    }
}
