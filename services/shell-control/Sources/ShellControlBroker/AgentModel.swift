import Foundation
import ShellControlProtocol

/// Everything the broker records for `shell-agent/1`. It lives beside the base
/// ledger, under the same single writer and commit, so an agent request and
/// its change event commit atomically; it is not a second authority
/// (docs/specs/agent-relay.md sections 11.2 and 14.1).
struct AgentLedger: Sendable {
    var sessions: [ControlID: AgentSessionEntry] = [:]
    var inputs: [ControlID: InputEntry] = [:]
    /// Agent attribution and detailed delivery for agent approvals. The
    /// approval itself stays in the base ledger.
    var approvals: [ControlID: AgentApprovalEntry] = [:]
    var changeLog: [AgentChangeEvent] = []
    var scopes: [ControlID: BrokerStore.EventScope] = [:]
    var itemSequences: [ControlID: UInt64] = [:]
    var nextSequence: UInt64 = 1
    var challenges: [String: AgentChallengeRecord] = [:]
    var idempotency: [String: AgentIdempotencyRecord] = [:]
    var mutations: [String: AgentMutationRecord] = [:]
    /// Purged or resolved input IDs with their hash, so an ID is never reused.
    var inputTombstones: [ControlID: String] = [:]
    /// Recorded managed-session commands, by command ID.
    var sessionCommands: [ControlID: SessionCommandEntry] = [:]

    var currentSequence: UInt64 { nextSequence - 1 }
    var earliestSequence: UInt64 { changeLog.first.map { $0.sequence.value } ?? nextSequence }
}

struct AgentSessionEntry: Sendable {
    let accountID: ControlID
    let originID: ControlID
    var projection: AgentSessionProjection
}

struct InputEntry: Sendable {
    let spec: InputSpec
    let requestHash: String
    let accountID: ControlID
    var projection: InputProjection
    var response: InputResponse?
    var responseHash: String?
    /// The winning device command, handed to the origin inside a permit.
    var commandJWS: String?
    var commandNotAfter: ControlTimestamp?
    var permit: InputConsumePermit?
    var withdrawnAt: ControlTimestamp?

    var record: InputRecord {
        do {
            return try InputRecord(spec: spec, projection: projection, response: response)
        } catch {
            preconditionFailure("Validated input record could not be reconstructed: \(error)")
        }
    }
}

/// A signed `agent.message` or `agent.turn.cancel`, recorded once and
/// claimed at most once by the session's origin (docs/specs/agent-relay.md 15).
struct SessionCommandEntry: Sendable {
    let accountID: ControlID
    let originID: ControlID
    var record: AgentSessionCommandRecord
    let commandJWS: String
    var permit: AgentSessionPermit?
}

struct AgentApprovalEntry: Sendable {
    let accountID: ControlID
    let originID: ControlID
    let runID: ControlID
    let nativeWaitID: ControlID
    var reference: AgentApprovalReference
}

struct AgentChallengeRecord: Sendable {
    let challengeID: String
    let accountID: ControlID
    let deviceID: ControlID
    let request: AgentReviewChallengeRequest
    let expiresAt: ControlTimestamp
    var consumedAt: ControlTimestamp?
}

struct AgentIdempotencyRecord: Sendable {
    let accountID: ControlID
    let deviceID: ControlID
    let commandID: ControlID
    let payloadHash: String
    let result: AgentCommandResult
    let recordedAt: ControlTimestamp

    static func key(account: ControlID, device: ControlID, command: ControlID) -> String {
        "agent|\(account.rawValue)|\(device.rawValue)|\(command.rawValue)"
    }
}

/// An origin mutation's idempotency record: withdraw, consume, event.
struct AgentMutationRecord: Sendable {
    enum Kind: String, Sendable {
        case inputWithdraw = "input_withdraw"
        case inputConsume = "input_consume"
        case sessionClaim = "session_claim"
        case event
    }

    let kind: Kind
    let originID: ControlID
    let mutationID: ControlID
    let bodyHash: String
    let result: JSONValue
    let recordedAt: ControlTimestamp

    var key: String { Self.key(kind, originID: originID, mutationID: mutationID) }

    static func key(_ kind: Kind, originID: ControlID, mutationID: ControlID) -> String {
        "\(kind.rawValue)|\(originID.rawValue)|\(mutationID.rawValue)"
    }
}
