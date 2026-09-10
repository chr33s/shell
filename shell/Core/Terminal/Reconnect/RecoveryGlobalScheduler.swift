//
//  RecoveryGlobalScheduler.swift
//  shell
//
//  App-wide admission control for automatic recovery attempts
//  (spec.connectivity.md §7.2).
//
//  Without this, twenty tmux panes and three SSH tabs coming back from a
//  tunnel outage dial the same host twenty-three times at once. The limits
//  are two concurrent automatic attempts app-wide and one per equivalent
//  endpoint/credential route; the visible gateway is admitted first and the
//  rest are served fairly in arrival order.
//

import Foundation
import os

/// A granted slot. Releasing is idempotent, and the slot releases itself if
/// its owner is deallocated mid-attempt so a crashed attempt cannot wedge the
/// queue (CON-08).
@MainActor
final class RecoveryAttemptSlot {
    private weak var scheduler: RecoveryGlobalScheduler?
    let routeKey: String
    private var released = false

    fileprivate init(scheduler: RecoveryGlobalScheduler, routeKey: String) {
        self.scheduler = scheduler
        self.routeKey = routeKey
    }

    func release() {
        guard !released else { return }
        released = true
        scheduler?.release(routeKey: routeKey)
    }

    deinit {
        // `deinit` on a @MainActor class already runs on the main actor, but
        // the isolation is not statically known here, so hop explicitly.
        guard !released else { return }
        let scheduler = self.scheduler
        let routeKey = self.routeKey
        Task { @MainActor in scheduler?.release(routeKey: routeKey) }
    }
}

@MainActor
final class RecoveryGlobalScheduler {

    private nonisolated static let logger = Logger(
        subsystem: "dev.chr33s.shell", category: "RecoveryScheduler")

    static let shared = RecoveryGlobalScheduler()

    private var policy: RecoveryPolicy
    private var activeTotal = 0
    private var activePerRoute: [String: Int] = [:]

    /// FIFO of waiters. `isVisibleGateway` waiters are admitted before the
    /// rest, which is the only priority rule: everything else is arrival order
    /// so a background pane cannot be starved indefinitely.
    private struct Waiter {
        let id: UInt64
        let routeKey: String
        let isVisibleGateway: Bool
        let resume: (RecoveryAttemptSlot?) -> Void
    }
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    init(policy: RecoveryPolicy = .default) {
        self.policy = policy
    }

    func updatePolicy(_ policy: RecoveryPolicy) {
        self.policy = policy
        drain()
    }

    /// Await a slot for an automatic attempt. Returns `nil` if the awaiting
    /// task is cancelled before admission.
    func acquire(routeKey: String, isVisibleGateway: Bool) async -> RecoveryAttemptSlot? {
        if canAdmit(routeKey: routeKey) {
            return admit(routeKey: routeKey)
        }

        // Identify this waiter, so cancelling it wakes only it. Cancelling by
        // route key would resume every other connection queued for the same
        // host: each would re-enter its loop, recompute the same backoff from
        // scratch, and pay an extra delay it never earned.
        nextWaiterID &+= 1
        let waiterID = nextWaiterID

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RecoveryAttemptSlot?, Never>) in
                // Re-check under the same main-actor turn: a slot may have
                // freed between the fast path above and here.
                if canAdmit(routeKey: routeKey) {
                    continuation.resume(returning: admit(routeKey: routeKey))
                    return
                }
                let waiter = Waiter(
                    id: waiterID,
                    routeKey: routeKey,
                    isVisibleGateway: isVisibleGateway,
                    resume: { continuation.resume(returning: $0) })
                if isVisibleGateway,
                   let firstBackground = waiters.firstIndex(where: { !$0.isVisibleGateway }) {
                    waiters.insert(waiter, at: firstBackground)
                } else {
                    waiters.append(waiter)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id: waiterID) }
        }
    }

    /// Non-blocking variant for callers that would rather re-evaluate than
    /// queue (used by the fast-path bypass, which must not jump the queue).
    func tryAcquire(routeKey: String) -> RecoveryAttemptSlot? {
        guard canAdmit(routeKey: routeKey) else { return nil }
        return admit(routeKey: routeKey)
    }

    // MARK: - Private

    private func canAdmit(routeKey: String) -> Bool {
        activeTotal < policy.globalConcurrentAttempts
            && (activePerRoute[routeKey] ?? 0) < policy.perRouteConcurrentAttempts
    }

    private func admit(routeKey: String) -> RecoveryAttemptSlot {
        activeTotal += 1
        activePerRoute[routeKey, default: 0] += 1
        return RecoveryAttemptSlot(scheduler: self, routeKey: routeKey)
    }

    fileprivate func release(routeKey: String) {
        activeTotal = max(0, activeTotal - 1)
        if let count = activePerRoute[routeKey] {
            if count <= 1 { activePerRoute.removeValue(forKey: routeKey) }
            else { activePerRoute[routeKey] = count - 1 }
        }
        drain()
    }

    private func drain() {
        var index = 0
        while index < waiters.count, activeTotal < policy.globalConcurrentAttempts {
            let waiter = waiters[index]
            if canAdmit(routeKey: waiter.routeKey) {
                waiters.remove(at: index)
                waiter.resume(admit(routeKey: waiter.routeKey))
            } else {
                // Route-limited: leave it queued and try the next waiter so a
                // busy route cannot block a different one behind it.
                index += 1
            }
        }
    }

    /// A cancelled waiter must still be resumed exactly once, or its awaiting
    /// task leaks forever. It is resumed with `nil` — no slot was ever
    /// counted as active for it, so there is nothing to release.
    private func cancelWaiter(id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.resume(nil)
    }

    // MARK: - Test support

    /// Snapshot for the deterministic suite.
    var activeAttemptCount: Int { activeTotal }
    var queuedWaiterCount: Int { waiters.count }
}
