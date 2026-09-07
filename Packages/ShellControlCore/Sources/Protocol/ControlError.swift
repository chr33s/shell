import Foundation

/// The protocol's error codes and the client action each implies
/// (spec.watch.md section 16).
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

    public var httpStatus: Int {
        switch self {
        case .invalidPayload, .unsupportedCommand: return 400
        case .invalidToken, .deviceRevoked: return 401
        case .notAuthorized, .fullReviewRequired: return 403
        case .notFound: return 404
        case .alreadyResolved, .idempotencyConflict, .alreadyClaimed: return 409
        case .requestExpired, .challengeExpired, .cursorExpired: return 410
        case .staleVersion, .hashMismatch, .policyChanged: return 412
        case .unsupportedOperation: return 422
        case .originUnavailable: return 423
        case .rateLimited: return 429
        case .temporarilyUnavailable: return 503
        }
    }

    /// Only reads and same-ID mutation reconciliation may be retried; a client
    /// never creates a replacement command automatically.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .temporarilyUnavailable: return true
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

    public var clientAction: ClientAction {
        switch self {
        case .invalidPayload, .unsupportedCommand: return .stopAndFix
        case .invalidToken: return .refreshCredentialsOnce
        case .deviceRevoked: return .reenroll
        case .notAuthorized, .fullReviewRequired: return .showPolicyOutcome
        case .notFound: return .reconcile
        case .alreadyResolved, .idempotencyConflict, .alreadyClaimed: return .showRecordedState
        case .requestExpired, .challengeExpired, .cursorExpired: return .refreshReviewOrSnapshot
        case .staleVersion, .hashMismatch, .policyChanged: return .requireFreshReview
        case .unsupportedOperation: return .handoff
        case .originUnavailable: return .leavePending
        case .rateLimited, .temporarilyUnavailable: return .backoffAndRetry
        }
    }
}

public struct ControlError: Error, Sendable, Hashable {
    public let code: ControlErrorCode
    public let message: String
    public let retryable: Bool
    public let serverTime: ControlTimestamp?
    /// An authorized current projection may accompany an error; it never
    /// discloses another account's object (spec.watch.md section 16).
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

    public var json: JSONValue {
        JSONWriter.object([
            "error": .object([
                "code": .string(code.rawValue),
                "message": .string(message),
                "retryable": .bool(retryable),
            ]),
            "server_time": serverTime.map { JSONValue($0) } ?? JSONValue(ControlTimestamp(Date())),
            "current_projection": currentProjection,
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
