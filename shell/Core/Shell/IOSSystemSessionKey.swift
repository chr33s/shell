import Foundation

/// Stable, unique ios_system session keys.
///
/// ios_system identifies sessions by an opaque pointer. The previous scheme —
/// `UnsafeRawPointer(bitPattern: sessionID.hashValue)` — could produce nil
/// (hashValue == 0 makes every ios_setStreams/ios_settty call a silent no-op)
/// and could in principle collide between two live sessions, merging their
/// cwd/env/stream state. This registry hands out a heap-allocated one-byte
/// pointer per UUID instead: guaranteed non-nil, unique, and identical for
/// every caller that derives it from the same session UUID (LocalShellSession
/// and its ShellEnvironment must resolve to the same ios_system session).
nonisolated enum IOSSystemSessionKey {
    private static let lock = UnfairLock()
    private nonisolated(unsafe) static var keys: [UUID: UnsafeMutableRawPointer] = [:]

    /// Returns the stable key for a session, allocating on first use.
    static func key(for sessionID: UUID) -> UnsafeRawPointer {
        lock.withLock {
            if let existing = keys[sessionID] { return UnsafeRawPointer(existing) }
            let fresh = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
            keys[sessionID] = fresh
            return UnsafeRawPointer(fresh)
        }
    }

    /// Frees a session's key. Call only after `ios_closeSession` — ios_system
    /// must never see this pointer again.
    static func release(_ sessionID: UUID) {
        let pointer = lock.withLock { keys.removeValue(forKey: sessionID) }
        pointer?.deallocate()
    }
}
