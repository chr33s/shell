import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// An enrolled control device. Every device has a separate identity and
/// revocable grants (docs/specs/control-protocol.md section 3.1).
struct DeviceRecord: Sendable {
    let deviceID: ControlID
    let accountID: ControlID
    let publicJWK: DeviceJWK
    let platform: PushRegistration.Platform
    let label: String
    var grants: Set<DeviceGrant>
    var revokedAt: ControlTimestamp?
    var push: PushRegistration?
    /// Set for a Watch reviewer: the one iPhone gateway it may be reached
    /// through. Such a device has no standalone network credential
    /// (docs/specs/control-protocol.md section 5.3).
    var gatewayDeviceID: ControlID?
    /// A relay-signed push capability an iPhone handed over. It is a delivery
    /// address only (docs/specs/control-protocol.md section 12.2).
    var pushCapability: String?
    /// The iPhone's explicit remote-alert choice. Absent on records that
    /// predate it, which keep their legacy eligibility at version 0
    /// (docs/specs/control-setup.md section 7.3).
    var notificationPreference: NotificationPreference? = nil

    var isRevoked: Bool { revokedAt != nil }
    /// The preference as reported: an absent one is version 0, enabled.
    var effectiveNotificationPreference: NotificationPreference {
        notificationPreference ?? NotificationPreference(enabled: true, version: 0)
    }
    /// Explicitly turned off: no relay or direct-APNs send may target it.
    var alertsSuppressed: Bool { notificationPreference?.enabled == false }
    var isWatchReviewer: Bool { gatewayDeviceID != nil }
    /// The iPhone is a full-review client; a Watch, standalone or behind a
    /// gateway, is a glance-sized surface that never approves a request
    /// demanding fuller review (docs/specs/control-protocol.md section 2.4,
    /// docs/specs/control-protocol.md section 11.2).
    var isFullReviewClient: Bool { platform == .iOS && !isWatchReviewer }
}

/// A one-use, short-lived pairing the Mac minted for its setup QR. The secret
/// is bootstrap material, not an origin credential
/// (docs/specs/control-protocol.md section 5.2).
struct PairingRecord: Sendable {
    let pairingID: ControlID
    let accountID: ControlID
    /// The raw secret: the claim proof is an HMAC under it.
    let secret: Data
    let expiresAt: ControlTimestamp
    var claimedAt: ControlTimestamp?
}

/// A Watch reviewer enrollment an iPhone gateway requested, awaiting explicit
/// confirmation on the Mac (docs/specs/control-protocol.md section 5.3).
struct WatchReviewerRequestRecord: Sendable {
    let watchDeviceID: ControlID
    let accountID: ControlID
    let gatewayDeviceID: ControlID
    let publicJWK: DeviceJWK
    let label: String
    let userCode: String
    let grants: Set<DeviceGrant>
    let expiresAt: ControlTimestamp
    var approvedAt: ControlTimestamp?
    var deniedAt: ControlTimestamp?
}

/// A push the broker asks the stateless relay to deliver. It names the event
/// only; the relay builds the APNs payload itself
/// (docs/specs/control-protocol.md section 12.3).
public struct RelayPushEntry: Sendable, Hashable {
    public let capability: String
    public let event: String
    public let requestID: ControlID
    public let originID: ControlID
    public let collapseID: String
    public let presentationClass: String

    public var json: JSONValue {
        .object([
            "capability": .string(capability),
            "event": .string(event),
            "request_id": JSONValue(requestID),
            "origin_id": JSONValue(originID),
            "collapse_id": .string(collapseID),
            "presentation_class": .string(presentationClass)
        ])
    }
}

/// An enrolled origin. Its credential is stored only as a verifier, is
/// rotatable, and is never distributed to watchOS clients
/// (docs/specs/control-protocol.md section 8.1).
struct OriginRecord: Sendable {
    let originID: ControlID
    let accountID: ControlID
    let label: String
    var secretVerifier: String
    var revokedAt: ControlTimestamp?

    var isRevoked: Bool { revokedAt != nil }
}

/// One execution attempt, plus the presence lease its heartbeats refresh.
struct RunRecord: Sendable {
    let runID: ControlID
    let originID: ControlID
    let jobID: ControlID
    var registration: RunRegistration
    var lastSeenAt: ControlTimestamp?
    var waitingRequestIDs: Set<ControlID> = []
    var jobVersion: Int64 = 1
    var jobState: JobState = .running
    var cancellationRequestedAt: ControlTimestamp?
}

/// The immutable spec plus everything mutable the broker tracks about it.
struct ApprovalRecordEntry: Sendable {
    let spec: ApprovalSpec
    let requestHash: String
    let accountID: ControlID
    var projection: ApprovalProjection
    /// The device decision JWS, handed to the origin inside a permit so the
    /// host can verify the authority rather than trusting a summary.
    var decisionJWS: String?
    /// The single consume ID that claimed this approval, if any.
    var consumedBy: ControlID?
    var permit: ConsumePermit?
    var receiptID: ControlID?
    var withdrawnAt: ControlTimestamp?

    var record: ApprovalRecord {
        // Safe: the entry was built from a validated spec whose digest was
        // computed at creation time.
        do {
            return try ApprovalRecord(spec: spec, projection: projection)
        } catch {
            preconditionFailure("Validated approval record could not be reconstructed: \(error)")
        }
    }
}

/// A one-use review challenge bound to a device, target, action, and versions
/// (docs/specs/control-protocol.md section 9.2).
struct ChallengeRecord: Sendable {
    let challengeID: String
    let accountID: ControlID
    let deviceID: ControlID
    let action: ControlCommandType
    let request: ReviewChallengeRequest
    let expiresAt: ControlTimestamp
    var consumedAt: ControlTimestamp?
}

/// The recorded result of a command, keyed by `(account, device_id,
/// command_id)` with a canonical payload hash (docs/specs/control-protocol.md section 9.2).
struct IdempotencyRecord: Sendable {
    let accountID: ControlID
    let deviceID: ControlID
    let commandID: ControlID
    let payloadHash: String
    let result: CommandResult
    let recordedAt: ControlTimestamp
}

/// An origin mutation's idempotency record, keyed by its kind, origin, and
/// mutation ID.
struct OriginMutationRecord: Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case notify, withdraw
    }

    let kind: Kind
    let originID: ControlID
    let mutationID: ControlID
    let bodyHash: String
    let result: JSONValue

    var key: String { OriginMutationRecord.key(kind, originID: originID, mutationID: mutationID) }

    static func key(_ kind: Kind, originID: ControlID, mutationID: ControlID) -> String {
        "\(kind.rawValue)|\(originID.rawValue)|\(mutationID.rawValue)"
    }
}

/// A queued alert. The push is a hint; the ledger is the change stream
/// (docs/specs/control-protocol.md section 12).
public struct OutboxEntry: Sendable {
    public let payload: Data
    public let headers: APNsRequestHeaders
    public let token: String
    public let platform: PushRegistration.Platform
    public let environment: PushRegistration.Environment
}

/// A compact tombstone kept after detailed content is purged, so a mutation or
/// request ID cannot be reused (docs/specs/control-protocol.md section 13.1).
struct Tombstone: Sendable {
    let requestID: ControlID
    let requestHash: String
    let resolution: Resolution
    let consumedBy: ControlID?
}
