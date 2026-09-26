//
//  SurfaceObservation.swift
//  shell
//
//  Main-actor replacement for Combine `$property` sinks on terminal state.
//  `Observations` emits the current value, then each later write, and ends
//  the loop when the task is cancelled.
//

import Foundation
import Observation

@MainActor
enum SurfaceObservation {
    /// Subscribe to `read`. Pass `droppingFirst: true` to ignore the value
    /// already stored at subscription time (Combine's `dropFirst()`).
    ///
    /// Like a Combine sink, the value at subscription time is snapshotted
    /// (and, unless dropped, delivered) synchronously. Writes that land
    /// before the observation task first runs are still delivered: a
    /// tracking flag records them so the task's first emission is only
    /// skipped when nothing changed since subscribing.
    static func task<Value: Sendable>(
        droppingFirst: Bool = false,
        _ read: @escaping @MainActor @Sendable () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never> {
        let changedSinceSubscribe = ChangeFlag()
        let initial = withObservationTracking {
            read()
        } onChange: {
            changedSinceSubscribe.set()
        }
        if !droppingFirst {
            onChange(initial)
        }
        return Task { @MainActor in
            var iterator = Observations(read).makeAsyncIterator()
            guard let first = await iterator.next() else { return }
            if Task.isCancelled { return }
            if changedSinceSubscribe.isSet {
                onChange(first)
            }
            while let value = await iterator.next() {
                if Task.isCancelled { return }
                onChange(value)
            }
        }
    }
}

/// Set from the `withObservationTracking` change handler, which is
/// `@Sendable` and may run off the main actor.
private nonisolated final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}

/// Associated-object box for an observation task. Releasing the box cancels
/// the task, matching `AnyCancellable`.
final class SurfaceObservationTask: NSObject {
    let task: Task<Void, Never>

    init(_ task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }

    deinit {
        task.cancel()
    }
}
