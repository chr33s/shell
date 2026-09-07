import Foundation
import ShellControlProtocol

/// The device-scoped session a completed enrollment returns.
///
/// Access tokens are short (10 minutes) and refresh tokens rotate with a 30-day
/// idle lifetime (spec.watch.md section 5).
public struct DeviceSession: Sendable, Hashable {
    public let deviceID: ControlID
    public let accountID: ControlID
    public var accessToken: String
    public var accessTokenExpiresAt: ControlTimestamp
    public var refreshToken: String
    public let grants: Set<DeviceGrant>

    public init(
        deviceID: ControlID,
        accountID: ControlID,
        accessToken: String,
        accessTokenExpiresAt: ControlTimestamp,
        refreshToken: String,
        grants: Set<DeviceGrant>
    ) {
        self.deviceID = deviceID
        self.accountID = accountID
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.grants = grants
    }

    /// The audience a command signed by this device must carry.
    public var audience: String { "shell-control:\(accountID.rawValue)" }

    public func isAccessTokenFresh(at now: ControlTimestamp, margin: TimeInterval = 30) -> Bool {
        now.date.addingTimeInterval(margin) < accessTokenExpiresAt.date
    }

    public var json: JSONValue {
        .object([
            "device_id": JSONValue(deviceID),
            "account_id": JSONValue(accountID),
            "access_token": .string(accessToken),
            "access_token_expires_at": JSONValue(accessTokenExpiresAt),
            "refresh_token": .string(refreshToken),
            "grants": JSONValue(strings: grants.map(\.rawValue).sorted()),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        deviceID = try reader.id("device_id")
        accountID = try reader.id("account_id")
        accessToken = try reader.string("access_token", maxLength: 4096)
        accessTokenExpiresAt = try reader.timestamp("access_token_expires_at")
        refreshToken = try reader.string("refresh_token", maxLength: 4096)
        let grantTexts = try reader.stringArray("grants", maxCount: 16, maxLength: 32)
        grants = Set(grantTexts.compactMap(DeviceGrant.init(rawValue:)))
        try reader.rejectUnknownMembers()
    }
}

/// Watch grants are scoped by origin and action (spec.watch.md section 4).
public enum DeviceGrant: String, Sendable, Hashable, CaseIterable {
    case requestsRead = "requests.read"
    case approvalsDecide = "approvals.decide"
    case notificationsRead = "notifications.read"
    case notificationsAck = "notifications.ack"
    /// Optional; job cancellation is capability-gated.
    case jobsCancel = "jobs.cancel"

    /// Device enrollment and policy changes require account administration, not
    /// ordinary decision credentials, so they have no device grant at all.
    public static let watchDefault: Set<DeviceGrant> = [
        .requestsRead, .approvalsDecide, .notificationsRead, .notificationsAck,
    ]
}

/// Where a device's private key and refresh credential live.
public protocol DeviceCredentialStore: Sendable {
    func loadSigningKey() throws -> (any DeviceSigningKey)?
    func storeSigningKey(_ key: InMemoryDeviceKey) throws
    func loadSession() throws -> DeviceSession?
    func storeSession(_ session: DeviceSession) throws
    /// Account logout revokes the device session and removes local credentials
    /// (spec.watch.md section 5).
    func removeAll() throws
}

/// A store for tests and for hosts without a Keychain.
public final class InMemoryCredentialStore: DeviceCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: InMemoryDeviceKey?
    private var session: DeviceSession?

    public init() {}

    public func loadSigningKey() throws -> (any DeviceSigningKey)? {
        lock.lock(); defer { lock.unlock() }
        return key
    }

    public func storeSigningKey(_ key: InMemoryDeviceKey) throws {
        lock.lock(); defer { lock.unlock() }
        self.key = key
    }

    public func loadSession() throws -> DeviceSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    public func storeSession(_ session: DeviceSession) throws {
        lock.lock(); defer { lock.unlock() }
        self.session = session
    }

    public func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        key = nil
        session = nil
    }
}
