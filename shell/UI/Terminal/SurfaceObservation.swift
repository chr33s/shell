//
//  SurfaceObservation.swift
//  shell
//
//  Main-actor replacement for Combine `$property` sinks on terminal state.
//  `Observations` emits the current value, then each later write, and ends
//  the loop when the task is cancelled.
//

import Observation

@MainActor
enum SurfaceObservation {
    /// Subscribe to `read`. Pass `droppingFirst: true` to ignore the value
    /// already stored at subscription time (Combine's `dropFirst()`).
    static func task<Value: Sendable>(
        droppingFirst: Bool = false,
        _ read: @escaping @MainActor @Sendable () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            var iterator = Observations(read).makeAsyncIterator()
            if droppingFirst {
                _ = await iterator.next()
            }
            while let value = await iterator.next() {
                if Task.isCancelled { return }
                onChange(value)
            }
        }
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
