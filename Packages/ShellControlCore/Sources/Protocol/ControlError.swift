import Foundation

/// The protocol's error codes and the client action each implies
/// (docs/specs/control-protocol.md section 14).
public enum ControlErrorCode: String, Sendable, Hashable, CaseIterable {
    case invalidPayload = "invalid_payload"
    case unsupportedCommand = "unsupported_command"
    case invalidToken = "invalid_token"
    case deviceRevoked = "device_revoked"
    case notAuthorized = "not_authorized"
    case fullReviewRequired = "full_review_required"
    case notFound = "not_found"
    case alreadyResolved = "already_resolved"
    case idempotencyConflict = "idempotency_conflict"
    case alreadyClaimed = "already_claimed"
    case requestExpired = "request_expired"
    case challengeExpired = "challenge_expired"
    case cursorExpired = "cursor_expired"
    case staleVersion = "stale_version"
    case hashMismatch = "hash_mismatch"
    case policyChanged = "policy_changed"
    case unsupportedOperation = "unsupported_operation"
    case originUnavailable = "origin_unavailable"
    case rateLimited = "rate_limited"
    case temporarilyUnavailable = "temporarily_unavailable"
    /// A Watch reviewer is not bound to the iPhone gateway that carried the
    /// request: set the Watch up again through this iPhone, keeping its key,
    /// which the Mac confirms as a re-binding (docs/specs/control-protocol.md 5.4).
    case reviewerNotBound = "reviewer_not_bound"

    // `shell-agent/1` failures (docs/specs/agent-relay.md section 17). They are
    // emitted only by extension endpoints and local IPC, never on a base
    // endpoint an older client decodes.
    case unsupportedProviderVersion = "unsupported_provider_version"
    case unsupportedInputSchema = "unsupported_input_schema"
    case hookNotTrusted = "hook_not_trusted"
    case nativeWaitGone = "native_wait_gone"
    case nativeContextChanged = "native_context_changed"
    case requestResolved = "request_resolved"
    case reviewRequired = "review_required"
    case gatewayUnavailable = "gateway_unavailable"
    case responseInvalid = "response_invalid"
    case limitExceeded = "limit_exceeded"
    case outcomeUnknown = "outcome_unknown"

    public var httpStatus: Int {
        switch self {
        case .invalidPayload, .unsupportedCommand: return 400
        case .invalidToken, .deviceRevoked: return 401
        case .notAuthorized, .fullReviewRequired, .reviewerNotBound: return 403
        case .notFound: return 404
        case .alreadyResolved, .idempotencyConflict, .alreadyClaimed: return 409
        case .requestExpired, .challengeExpired, .cursorExpired: return 410
        case .staleVersion, .hashMismatch, .policyChanged: return 412
        case .unsupportedOperation: return 422
        case .originUnavailable: return 423
        case .rateLimited: return 429
        case .temporarilyUnavailable: return 503
        case .unsupportedProviderVersion, .unsupportedInputSchema, .hookNotTrusted: return 422
        case .nativeWaitGone, .nativeContextChanged: return 410
        case .requestResolved: return 409
        case .reviewRequired: return 403
        case .gatewayUnavailable: return 503
        case .responseInvalid: return 400
        case .limitExceeded: return 429
        case .outcomeUnknown: return 409
        }
    }

    /// Only reads and same-ID mutation reconciliation may be retried; a client
    /// never creates a replacement command automatically.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .temporarilyUnavailable, .gatewayUnavailable: return true
        default: return false
        }
    }

    /// What the client should do next, expressed so UI code cannot invent a
    /// more permissive recovery than the table allows.
    public enum ClientAction: Sendable, Hashable {
        case stopAndFix
        case refreshCredentialsOnce
        case reenroll
        case showPolicyOutcome
        case reconcile
        case showRecordedState
        case refreshReviewOrSnapshot
        case requireFreshReview
        case handoff
        case leavePending
        case backoffAndRetry
    }

    /// A final rejection of a submitted command: the broker refused it, so
    /// nothing was recorded and resending the identical command cannot
    /// succeed. The command is not ambiguous and is not reconciled.
    ///
    /// Excluded, because they do not prove that: the recorded-state codes
    /// (409), `not_found` (reconcile), `invalid_token` (refresh, then the same
    /// command may be retried), the retryable codes, and `invalid_payload`,
    /// which clients and the iPhone gateway also synthesize locally when a
    /// response — possibly a success — could not be decoded.
    public var provesCommandNotRecorded: Bool {
        switch self {
        case .unsupportedCommand, .deviceRevoked, .reviewerNotBound,
             .notAuthorized, .fullReviewRequired,
             .requestExpired, .challengeExpired, .cursorExpired,
             .staleVersion, .hashMismatch, .policyChanged,
             .unsupportedOperation, .originUnavailable,
             .unsupportedProviderVersion, .unsupportedInputSchema, .hookNotTrusted,
             .nativeWaitGone, .nativeContextChanged, .reviewRequired, .responseInvalid,
             .limitExceeded:
            return true
        case .invalidPayload, .invalidToken, .notFound,
             .alreadyResolved, .idempotencyConflict, .alreadyClaimed,
             .rateLimited, .temporarilyUnavailable,
             .requestResolved, .gatewayUnavailable, .outcomeUnknown:
            return false
        }
    }

    public var clientAction: ClientAction {
        switch self {
        case .invalidPayload, .unsupportedCommand: return .stopAndFix
        case .invalidToken: return .refreshCredentialsOnce
        case .deviceRevoked, .reviewerNotBound: return .reenroll
        case .notAuthorized, .fullReviewRequired: return .showPolicyOutcome
        case .notFound: return .reconcile
        case .alreadyResolved, .idempotencyConflict, .alreadyClaimed: return .showRecordedState
        case .requestExpired, .challengeExpired, .cursorExpired: return .refreshReviewOrSnapshot
        case .staleVersion, .hashMismatch, .policyChanged: return .requireFreshReview
        case .unsupportedOperation: return .handoff
        case .originUnavailable: return .leavePending
        case .rateLimited, .temporarilyUnavailable: return .backoffAndRetry
        case .unsupportedProviderVersion, .unsupportedInputSchema, .hookNotTrusted: return .handoff
        case .nativeWaitGone, .nativeContextChanged: return .refreshReviewOrSnapshot
        case .requestResolved, .outcomeUnknown: return .showRecordedState
        case .reviewRequired: return .showPolicyOutcome
        case .gatewayUnavailable: return .backoffAndRetry
        case .responseInvalid: return .stopAndFix
        case .limitExceeded: return .leavePending
        }
    }
}

/// A local error with a protocol meaning, so a gateway can relay it as a
/// `ControlError` instead of reporting the route as unavailable.
public protocol ControlErrorConvertible: Error {
    var controlError: ControlError { get }
}

public struct ControlError: Error, Sendable, Hashable {
    public let code: ControlErrorCode
    public let message: String
    public let retryable: Bool
    public let serverTime: ControlTimestamp?
    /// An authorized current projection may accompany an error; it never
    /// discloses another account's object (docs/specs/control-protocol.md section 14).
    public let currentProjection: JSONValue?

    public init(
        code: ControlErrorCode,
        message: String,
        retryable: Bool? = nil,
        serverTime: ControlTimestamp? = nil,
        currentProjection: JSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable ?? code.isRetryable
        self.serverTime = serverTime
        self.currentProjection = currentProjection
    }

    /// A non-retryable final rejection of a submitted command; see
    /// ``ControlErrorCode/provesCommandNotRecorded``.
    public var provesCommandNotRecorded: Bool { !retryable && code.provesCommandNotRecorded }

    public var json: JSONValue {
        JSONWriter.object([
            "error": .object([
                "code": .string(code.rawValue),
                "message": .string(message),
                "retryable": .bool(retryable)
            ]),
            "server_time": serverTime.map { JSONValue($0) } ?? JSONValue(ControlTimestamp(Date())),
            "current_projection": currentProjection
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        var errorReader = try reader.object("error")
        let codeText = try errorReader.string("code", maxLength: 64)
        guard let code = ControlErrorCode(rawValue: codeText) else {
            throw ValidationError.unsupported("error code \(codeText)")
        }
        self.code = code
        message = try errorReader.string("message", maxLength: 500)
        retryable = try errorReader.optionalBool("retryable") ?? code.isRetryable
        try errorReader.rejectUnknownMembers()
        serverTime = try reader.optionalTimestamp("server_time")
        currentProjection = reader.optionalValue("current_projection")
        try reader.rejectUnknownMembers()
    }
}
