import Foundation

/// Runs blocking socket IO off the cooperative pool. A `recv` that waits out
/// a long `approval.wait` must not occupy a cooperative-pool thread, which the
/// rest of the process needs to make progress. Continuations resume exactly
/// once; callers suspend rather than joining a task with a semaphore.
///
/// A connection that does many reads and writes creates one instance and
/// calls ``perform(_:)``: every call hops to the same serial queue, so the
/// connection reuses one worker instead of spawning a thread per call. A
/// one-off exchange uses ``run(_:)``, which gets a thread of its own.
public struct BlockingIO: Sendable {
    private let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    public func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    public static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { continuation.resume(with: Result(catching: work)) }
        }
    }
}
