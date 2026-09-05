//
//  UnfairLock.swift
//  shell
//
//  A Sendable wrapper around os_unfair_lock for Swift 6 concurrency compliance.
//  Provides exception-safe locking via withLock closure pattern.
//

import os

/// A thread-safe lock wrapper for use in `@Sendable` closures.
///
/// This wrapper avoids Swift 6 concurrency warnings about mutating captured
/// `os_unfair_lock` variables in concurrent code by encapsulating the lock
/// in a reference type with manual synchronization.
nonisolated final class UnfairLock: @unchecked Sendable {
    private var lock = os_unfair_lock()

    init() {}

    /// Execute the closure while holding the lock.
    /// The lock is guaranteed to be released even if the closure throws.
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return try body()
    }
}
