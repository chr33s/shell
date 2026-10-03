//
//  LocalSSHAgentLimits.swift
//  shell
//
//  Prompt-abuse and resource bounds for the local SSH agent
//  (ssh-agent-bridge-v2-delta.md §7). Any program in the local shell can
//  reach `SSH_AUTH_SOCK`, so the agent must not become an unlimited
//  biometric-prompt or resource-exhaustion surface.
//

import Foundation
import NIOCore

/// Per-key cooldown after a cancelled or failed local-agent authentication.
/// During the cooldown, sign requests for that key fail at once without
/// presenting another prompt. Process-memory only, monotonic clock.
nonisolated final class LocalSSHAgentAuthThrottle: @unchecked Sendable {
    static let shared = LocalSSHAgentAuthThrottle()

    static let defaultCooldown: Duration = .seconds(5)

    private let lock = NSLock()
    private let cooldown: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private var failedAt: [UUID: ContinuousClock.Instant] = [:]

    init(
        cooldown: Duration = defaultCooldown,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.cooldown = cooldown
        self.now = now
    }

    /// Whether an authentication-triggering request for `keyID` may proceed.
    func allows(keyID: UUID) -> Bool {
        lock.withLock {
            guard let failure = failedAt[keyID] else { return true }
            if now() - failure >= cooldown {
                failedAt[keyID] = nil
                return true
            }
            return false
        }
    }

    func recordFailure(keyID: UUID) {
        lock.withLock { failedAt[keyID] = now() }
    }

    /// A successful authentication ends the failure state.
    func recordSuccess(keyID: UUID) {
        reset(keyID: keyID)
    }

    func reset(keyID: UUID) {
        lock.withLock { failedAt[keyID] = nil }
    }

    func resetAll() {
        lock.withLock { failedAt.removeAll() }
    }
}

/// Bounds global in-flight signing work. Per-client in-flight work is bounded
/// structurally: each connection answers its requests strictly one at a
/// time, so a client never has more than one sign request outstanding.
nonisolated final class LocalSSHAgentSignLimiter: @unchecked Sendable {
    static let defaultGlobalLimit = 16

    private let lock = NSLock()
    private let limit: Int
    private var inFlight = 0

    init(limit: Int = defaultGlobalLimit) {
        self.limit = limit
    }

    func tryAcquire() -> Bool {
        lock.withLock {
            guard inFlight < limit else { return false }
            inFlight += 1
            return true
        }
    }

    func release() {
        lock.withLock { inFlight = max(0, inFlight - 1) }
    }

    var current: Int {
        lock.withLock { inFlight }
    }
}

/// Admits a bounded number of simultaneous clients and remembers them so
/// disabling the agent can close every live connection immediately — even
/// one parked on a biometric prompt.
nonisolated final class LocalSSHAgentClientRegistry: @unchecked Sendable {
    static let defaultClientLimit = 8

    private let lock = NSLock()
    private let limit: Int
    private var clients: [ObjectIdentifier: any Channel] = [:]

    init(limit: Int = defaultClientLimit) {
        self.limit = limit
    }

    /// False when the client would exceed the limit; the caller closes it.
    func admit(_ channel: any Channel) -> Bool {
        lock.withLock {
            guard clients.count < limit else { return false }
            clients[ObjectIdentifier(channel)] = channel
            return true
        }
    }

    func remove(_ channel: any Channel) {
        lock.withLock { _ = clients.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    var count: Int {
        lock.withLock { clients.count }
    }

    func closeAll() {
        let live = lock.withLock {
            defer { clients.removeAll() }
            return Array(clients.values)
        }
        for channel in live {
            channel.close(promise: nil)
        }
    }
}
