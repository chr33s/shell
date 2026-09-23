import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Synchronization

public struct SignalCancellation: Error, Sendable { public let signal: Int32; public var exitCode: Int32 { 128 + signal } }

/// Process-wide signal fan-out. State and callback access are protected by the
/// mutex; callbacks run outside it.
public final class InvocationCancellation: Sendable {
    public static let shared = InvocationCancellation()
    private struct State {
        var callbacks: [UUID: @Sendable () -> Void] = [:]
        var caught: Int32?
    }
    private let state = Mutex(State())
    private let sources: [DispatchSourceSignal]

    private init() {
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            sources.append(source)
        }
        self.sources = sources
        for (number, source) in zip([SIGINT, SIGTERM, SIGHUP], sources) {
            source.setEventHandler { [weak self] in self?.cancel(signal: number) }
            source.resume()
        }
    }

    private func cancel(signal: Int32) {
        let values = state.withLock { state in
            if state.caught == nil { state.caught = signal }
            return Array(state.callbacks.values)
        }
        values.forEach { $0() }
    }

    private func register(_ callback: @escaping @Sendable () -> Void) -> (UUID, Int32?) {
        state.withLock { state in
            let id = UUID(); state.callbacks[id] = callback; return (id, state.caught)
        }
    }
    private func unregister(_ id: UUID) { state.withLock { $0.callbacks[id] = nil } }
    private func caughtSignal() -> Int32? { state.withLock { $0.caught } }

    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await operation() }
        let (id, signal) = register { task.cancel() }
        if signal != nil { task.cancel() }
        defer { unregister(id) }
        do { return try await task.value } catch {
            if let number = caughtSignal() { throw SignalCancellation(signal: number) }
            if task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

public enum TerminalPrompt {
    private final class Reader: Sendable {
        let fd: Int32
        private let cancelled = Atomic(false)
        init(fd: Int32) { self.fd = fd }
        func cancel() { cancelled.store(true, ordering: .releasing) }
        func isCancelled() -> Bool { cancelled.load(ordering: .acquiring) }
        deinit { close(fd) }
    }

    public static func ask(_ question: String) async throws -> String? {
        try FileHandle.standardError.write(contentsOf: Data(question.utf8))
        let reader = Reader(fd: dup(STDIN_FILENO)); guard reader.fd >= 0 else { throw ManagementError.unavailable("cannot read terminal") }
        guard fcntl(reader.fd, F_SETFL, fcntl(reader.fd, F_GETFL) | O_NONBLOCK) == 0 else {
            throw ManagementError.unavailable("cannot configure cancellable terminal input")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let queue = DispatchQueue(label: "dev.chr33s.shell.prompt")
                queue.async {
                    var result = Data(), byte: UInt8 = 0
                    while true {
                        if reader.isCancelled() { continuation.resume(throwing: CancellationError()); return }
                        let count = read(reader.fd, &byte, 1)
                        if count == 0 { continuation.resume(returning: result.isEmpty ? nil : String(decoding: result, as: UTF8.self)); return }
                        if count < 0 {
                            if errno == EAGAIN || errno == EWOULDBLOCK { usleep(20_000); continue }
                            if errno == EINTR { continue }
                            continuation.resume(throwing: ManagementError.unavailable("terminal input failed")); return
                        }
                        if byte == 10 || byte == 13 { continuation.resume(returning: String(decoding: result, as: UTF8.self)); return }
                        if result.count < 4096 { result.append(byte) }
                    }
                }
            }
        } onCancel: { reader.cancel() }
    }
}
