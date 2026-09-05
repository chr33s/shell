//
//  AsyncTimeout.swift
//  shell
//
//  Hard timeout wrapper for async work that may otherwise hang on
//  dead network/FDs (typical after iOS suspension). Returns control to
//  the caller after `seconds` even if the underlying operation is
//  parked in a syscall that never observes cancellation.
//

import Foundation
import os

struct TimeoutError: LocalizedError {
    let seconds: TimeInterval
    var errorDescription: String? { "Operation timed out after \(seconds)s" }
}

/// Run `operation` with a hard wall-clock timeout.
///
/// On timeout the operation Task is cancelled but **not awaited** — control
/// returns to the caller immediately. This matters: `withThrowingTaskGroup`
/// (the obvious implementation) suspends until every child Task finishes,
/// which means a NIO close future parked on a dead socket would still hang
/// the caller after `cancelAll()`. Many of our targets (Citadel/NIO close,
/// Go gomobile syscalls) don't propagate `Task.isCancelled` either, so
/// "cancel and wait" is effectively "wait forever."
///
/// We instead race two unstructured Tasks through a single-resume
/// continuation. Whichever finishes first wins; the loser keeps running but
/// the caller has already returned. The operation Task is `cancel()`'d on
/// timeout so anything that DOES observe cancellation can short-circuit;
/// we just don't depend on it.
///
/// Note: this does NOT propagate cancellation from the surrounding Task.
/// Callers that need that should add their own `withTaskCancellationHandler`.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    // Single-resume guard — exactly one of {operation, timeout} resumes the
    // continuation. Without this a fast operation racing the timeout would
    // double-resume and trap.
    let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
    @Sendable nonisolated func tryClaim() -> Bool {
        resumed.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }

    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let opTask = Task<Void, Never> {
            do {
                let result = try await operation()
                if tryClaim() { cont.resume(returning: result) }
            } catch {
                if tryClaim() { cont.resume(throwing: error) }
            }
        }
        Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if tryClaim() {
                opTask.cancel()
                cont.resume(throwing: TimeoutError(seconds: seconds))
            }
        }
    }
}
