import Foundation
import ShellControlProtocol
import Synchronization

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
            "grants": JSONValue(strings: grants.map(\.rawValue).sorted())
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
    /// A Watch reviewer reads only through its bound iPhone gateway; it holds
    /// no standalone network credential (spec.iphone-gateway.md section 10.4).
    case requestsReadViaGateway = "requests.read-via-gateway"
    case notificationsReadViaGateway = "notifications.read-via-gateway"
    /// `shell-agent/1` grants, each separately revocable and never part of a
    /// default set (spec.agent-relay.md section 17.1).
    case agentSessionsRead = "agent.sessions.read"
    case agentInputsRead = "agent.inputs.read"
    case agentInputsRespond = "agent.inputs.respond"
    /// A Watch reviewer reads agent inputs only through its gateway iPhone.
    case agentInputsReadViaGateway = "agent.inputs.read-via-gateway"
    /// Reserved for later managed-session profiles; nothing accepts them yet.
    case agentMessagesSend = "agent.messages.send"
    case agentTurnsCancel = "agent.turns.cancel"

    /// Device enrollment and policy changes require account administration, not
    /// ordinary decision credentials, so they have no device grant at all.
    public static let watchDefault: Set<DeviceGrant> = [
        .requestsRead, .approvalsDecide, .notificationsRead, .notificationsAck
    ]

    /// What a Watch enrolled behind a gateway iPhone is granted by default.
    public static let watchReviewerDefault: Set<DeviceGrant> = [
        .requestsReadViaGateway, .approvalsDecide, .notificationsReadViaGateway, .notificationsAck
    ]

    /// What `shell-control agent grant` adds to an iPhone, and to a Watch
    /// reviewer (spec.agent-relay.md section 17.1).
    public static let agentPhone: Set<DeviceGrant> = [.agentSessionsRead, .agentInputsRead, .agentInputsRespond]
    public static let agentWatchReviewer: Set<DeviceGrant> = [.agentInputsReadViaGateway, .agentInputsRespond]
    /// Every agent grant, for revocation.
    public static let agent: Set<DeviceGrant> = agentPhone.union(agentWatchReviewer).union([.agentMessagesSend, .agentTurnsCancel])
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
public final class InMemoryCredentialStore: DeviceCredentialStore, Sendable {
    private struct Contents {
        var key: InMemoryDeviceKey?
        var session: DeviceSession?
    }

    private let contents = Mutex(Contents())

    public init() {}

    public func loadSigningKey() throws -> (any DeviceSigningKey)? {
        contents.withLock { $0.key }
    }

    public func storeSigningKey(_ key: InMemoryDeviceKey) throws {
        contents.withLock { $0.key = key }
    }

    public func loadSession() throws -> DeviceSession? {
        contents.withLock { $0.session }
    }

    public func storeSession(_ session: DeviceSession) throws {
        contents.withLock { $0.session = session }
    }

    public func removeAll() throws {
        contents.withLock { $0 = Contents() }
    }
}
