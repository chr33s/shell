import Foundation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// The Watch's reviewer identity as the Mac reported it through the iPhone:
/// device ID, account audience, gateway binding, and grants. None of it is a
/// credential; the only secret is the signing key, kept in the Keychain
/// (spec.iphone-gateway.md sections 4.6 and 10).
protocol WatchReviewerStore: Sendable {
    func load() -> WatchReviewerStatus?
    func store(_ status: WatchReviewerStatus) throws
    func remove()
}

final class DefaultsWatchReviewerStore: WatchReviewerStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let key = "dev.chr33s.shell.control.watch-reviewer"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WatchReviewerStatus? {
        guard let text = defaults.string(forKey: Self.key), let value = try? JSONValue.parse(text) else { return nil }
        return try? WatchReviewerStatus(json: value)
    }

    func store(_ status: WatchReviewerStatus) throws {
        defaults.set(try JSONCanonicalization.canonicalString(status.json), forKey: Self.key)
    }

    func remove() {
        defaults.removeObject(forKey: Self.key)
    }
}

final class InMemoryWatchReviewerStore: WatchReviewerStore, @unchecked Sendable {
    private let lock = NSLock()
    private var status: WatchReviewerStatus?

    init(_ status: WatchReviewerStatus? = nil) { self.status = status }

    func load() -> WatchReviewerStatus? { lock.withLock { status } }
    func store(_ status: WatchReviewerStatus) throws { lock.withLock { self.status = status } }
    func remove() { lock.withLock { status = nil } }
}

/// The stale-tolerant inbox the Watch may show without its iPhone. Cached
/// material is always marked stale in the UI and never enables a decision
/// (spec.iphone-gateway.md section 11.4); the protected file is
/// ``ProtectedInboxCache``.
enum GatewayCache {
    /// Whether cached content may be shown as current.
    static func isLive(gatewayReachable: Bool, lastRefreshedAt: ControlTimestamp?) -> Bool {
        gatewayReachable && lastRefreshedAt != nil
    }
}
