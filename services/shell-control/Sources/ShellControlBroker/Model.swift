import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// An enrolled control device. Every device has a separate identity and
/// revocable grants (spec.watch.md section 4).
struct DeviceRecord: Sendable {
    let deviceID: ControlID
    let accountID: ControlID
    let publicJWK: DeviceJWK
    let platform: PushRegistration.Platform
    let label: String
    var grants: Set<DeviceGrant>
    var revokedAt: ControlTimestamp?
    var push: PushRegistration?

    var isRevoked: Bool { revokedAt != nil }
}

/// An enrolled origin. Its credential is stored only as a verifier, is
/// rotatable, and is never distributed to watchOS clients
/// (spec.watch.md section 10).
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
        try! ApprovalRecord(spec: spec, projection: projection)
    }
}

/// A one-use review challenge bound to a device, target, action, and versions
/// (spec.watch.md section 11).
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
/// command_id)` with a canonical payload hash (spec.watch.md section 11).
struct IdempotencyRecord: Sendable {
    let accountID: ControlID
    let deviceID: ControlID
    let commandID: ControlID
    let payloadHash: String
    let result: CommandResult
    let recordedAt: ControlTimestamp
}

/// An origin mutation's idempotency record, keyed by its mutation ID.
struct OriginMutationRecord: Sendable {
    let originID: ControlID
    let mutationID: ControlID
    let bodyHash: String
    let result: JSONValue
}

/// A queued alert. The push is a hint; the ledger is the change stream
/// (spec.watch.md section 14).
public struct OutboxEntry: Sendable {
    public let payload: Data
    public let headers: APNsRequestHeaders
    public let token: String
    public let platform: PushRegistration.Platform
    public let environment: PushRegistration.Environment
}

/// A compact tombstone kept after detailed content is purged, so a mutation or
/// request ID cannot be reused (spec.watch.md section 15).
struct Tombstone: Sendable {
    let requestID: ControlID
    let requestHash: String
    let resolution: Resolution
    let consumedBy: ControlID?
}
