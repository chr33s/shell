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
/// `os_unfair_lock` variables in concurrent code. It is backed by
/// `OSAllocatedUnfairLock`, which gives the lock the stable heap address
/// `os_unfair_lock` requires (`&storedProperty` does not guarantee one).
nonisolated final class UnfairLock: Sendable {
    private let lock = OSAllocatedUnfairLock()

    init() {}

    /// Execute the closure while holding the lock.
    /// The lock is guaranteed to be released even if the closure throws.
    @inline(__always)
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        try lock.withLockUnchecked(body)
    }
}
