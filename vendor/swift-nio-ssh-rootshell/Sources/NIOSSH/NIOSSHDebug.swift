//===----------------------------------------------------------------------===//
//
// Debug metrics bridge for NIOSSH internals.
// Consumers set handlers to receive counters and timestamped events
// from the SSH multiplexer and child channels.
//
//===----------------------------------------------------------------------===//

import Dispatch
import NIOConcurrencyHelpers
import NIOCore

/// Provides visibility into NIOSSH internal operations for debugging.
/// Set handlers once at startup; all methods are thread-safe.
///
/// Performance: when no handlers are wired (the production default), every
/// `increment`/`set`/`event`/`tsLog` call is a single lock-free atomic load
/// + branch and returns immediately. The protocol tracing helpers in
/// `NIOSSHTrace` honor the same flag, so per-message string formatting is
/// also skipped. Wiring up handlers via `setHandlers(...)` flips the flag
/// and the full lock-protected handler invocation kicks in.
public final class NIOSSHDebug: @unchecked Sendable {
    public static let shared = NIOSSHDebug()

    private let lock = NIOLock()
    private var _increment: (@Sendable (String, Int64) -> Void)?
    private var _set: (@Sendable (String, Int64) -> Void)?
    private var _event: (@Sendable (String) -> Void)?
    private var _tsLog: (@Sendable (String) -> Void)?

    /// Lock-free fast-path flag. True when any handler has been wired via
    /// `setHandlers(...)`. Read by every `increment`/`set`/`event`/`tsLog`
    /// call site to short-circuit before any work is done.
    private let _isEnabled = NIOLockedValueBox<Bool>(false)

    private init() {}

    /// Wire up handlers to receive metrics. Call once before SSH connections start.
    public func setHandlers(
        increment: @escaping @Sendable (String, Int64) -> Void,
        set: @escaping @Sendable (String, Int64) -> Void,
        event: @escaping @Sendable (String) -> Void,
        tsLog: @escaping @Sendable (String) -> Void
    ) {
        lock.lock()
        _increment = increment
        _set = set
        _event = event
        _tsLog = tsLog
        lock.unlock()
        _isEnabled.withLockedValue { $0 = true }
    }

    /// True when handlers are wired. Use as a fast-path before computing
    /// expensive trace strings:
    ///
    ///     guard NIOSSHDebug.shared.isEventEnabled else { return }
    ///     NIOSSHDebug.shared.event("…big string…")
    public var isEventEnabled: Bool {
        _isEnabled.withLockedValue { $0 }
    }

    func increment(_ key: String, by value: Int64 = 1) {
        guard isEventEnabled else { return }
        lock.lock()
        let handler = _increment
        lock.unlock()
        handler?(key, value)
    }

    func set(_ key: String, value: Int64) {
        guard isEventEnabled else { return }
        lock.lock()
        let handler = _set
        lock.unlock()
        handler?(key, value)
    }

    func event(_ text: String) {
        guard isEventEnabled else { return }
        lock.lock()
        let handler = _event
        lock.unlock()
        handler?(text)
    }

    /// Time-series log entry — written to file for export.
    func tsLog(_ text: String) {
        guard isEventEnabled else { return }
        lock.lock()
        let handler = _tsLog
        lock.unlock()
        handler?(text)
    }

    /// Current time in microseconds for duration measurements.
    static func nowUs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1000)
    }
}
