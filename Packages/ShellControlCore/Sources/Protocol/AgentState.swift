import Foundation

/// Input request resolution. A non-pending resolution is immutable
/// (docs/specs/agent-relay.md section 8.2).
public enum InputResolution: String, Sendable, Hashable, CaseIterable {
    case pending
    case answered
    case declined
    case expired
    case withdrawn

    public var isTerminal: Bool { self != .pending }
}

/// Response dispatch, the detailed `agent.delivery.v1` dimension. It is never
/// serialized into the legacy `dispatch` field without negotiation
/// (docs/specs/agent-relay.md section 8.2).
///
/// `native_response_written` proves only that bytes reached the local
/// transport; `accepted` needs correlated native evidence.
public enum AgentDispatch: String, Sendable, Hashable, CaseIterable {
    case none
    case awaitingOrigin = "awaiting_origin"
    case claimed
    case dispatchStarted = "dispatch_started"
    case nativeResponseWritten = "native_response_written"
    case accepted
    case notApplied = "not_applied"
    case unknown

    public var isTerminal: Bool {
        switch self {
        case .accepted, .notApplied, .unknown: return true
        default: return false
        }
    }

    /// Forward-only. A rejected approval is never claimed, so dispatch may
    /// start straight from `awaiting_origin`. `unknown` can later be
    /// reconciled only with positive evidence.
    public func canTransition(to next: AgentDispatch) -> Bool {
        switch (self, next) {
        case (.none, .awaitingOrigin),
             (.awaitingOrigin, .claimed), (.awaitingOrigin, .dispatchStarted),
             (.awaitingOrigin, .notApplied), (.awaitingOrigin, .unknown),
             (.claimed, .dispatchStarted), (.claimed, .notApplied), (.claimed, .unknown),
             (.dispatchStarted, .nativeResponseWritten), (.dispatchStarted, .accepted),
             (.dispatchStarted, .notApplied), (.dispatchStarted, .unknown),
             (.nativeResponseWritten, .accepted), (.nativeResponseWritten, .notApplied),
             (.nativeResponseWritten, .unknown),
             (.unknown, .accepted), (.unknown, .notApplied):
            return true
        default:
            return false
        }
    }

    /// The legacy receipt result this detailed state justifies, if any:
    /// `applied` only with acceptance evidence, `not_applied` only with
    /// positive evidence, otherwise `unknown` (docs/specs/agent-relay.md 8.2).
    public var legacyReceiptResult: ReceiptResult? {
        switch self {
        case .accepted: return .applied
        case .notApplied: return .notApplied
        case .nativeResponseWritten, .unknown: return .unknown
        case .none, .awaitingOrigin, .claimed, .dispatchStarted: return nil
        }
    }
}

/// The agent operation itself, independent of the response that unblocked it.
public enum AgentOperationState: String, Sendable, Hashable, CaseIterable {
    case notObserved = "not_observed"
    case running
    case completed
    case failed
    case cancelled
    case unknown
}

/// The mutable projection over an immutable input spec.
public struct InputProjection: Sendable, Hashable {
    public var stateVersion: Int64
    public var policyVersion: Int64
    public var resolution: InputResolution
    public var dispatch: AgentDispatch
    public var operation: AgentOperationState
    public var responseID: ControlID?
    public var commandID: ControlID?
    public var respondedByDeviceID: ControlID?
    public var respondedAt: ControlTimestamp?
    public var presence: SourcePresence
    public var watchReviewAllowed: Bool

    public init(
        stateVersion: Int64 = 1,
        policyVersion: Int64 = 1,
        resolution: InputResolution = .pending,
        dispatch: AgentDispatch = .none,
        operation: AgentOperationState = .notObserved,
        responseID: ControlID? = nil,
        commandID: ControlID? = nil,
        respondedByDeviceID: ControlID? = nil,
        respondedAt: ControlTimestamp? = nil,
        presence: SourcePresence = .absent,
        watchReviewAllowed: Bool = true
    ) {
        self.stateVersion = stateVersion
        self.policyVersion = policyVersion
        self.resolution = resolution
        self.dispatch = dispatch
        self.operation = operation
        self.responseID = responseID
        self.commandID = commandID
        self.respondedByDeviceID = respondedByDeviceID
        self.respondedAt = respondedAt
        self.presence = presence
        self.watchReviewAllowed = watchReviewAllowed
    }

    public var json: JSONValue {
        JSONWriter.object([
            "state_version": .number(.int(stateVersion)),
            "policy_version": .number(.int(policyVersion)),
            "resolution": .string(resolution.rawValue),
            "dispatch": .string(dispatch.rawValue),
            "operation": .string(operation.rawValue),
            "response_id": responseID.map { JSONValue($0) },
            "command_id": commandID.map { JSONValue($0) },
            "responded_by_device_id": respondedByDeviceID.map { JSONValue($0) },
            "responded_at": respondedAt.map { JSONValue($0) },
            "watch_review_allowed": .bool(watchReviewAllowed),
            "source_presence": JSONWriter.object([
                "last_seen_at": presence.lastSeenAt.map { JSONValue($0) },
                "waiting": .bool(presence.isWaiting)
            ])
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        stateVersion = try reader.integer("state_version")
        policyVersion = try reader.integer("policy_version")
        let resolutionText = try reader.string("resolution", maxLength: 16)
        guard let resolution = InputResolution(rawValue: resolutionText) else {
            throw ValidationError.unsupported("input resolution \(resolutionText)")
        }
        self.resolution = resolution
        let dispatchText = try reader.string("dispatch", maxLength: 32)
        guard let dispatch = AgentDispatch(rawValue: dispatchText) else {
            throw ValidationError.unsupported("agent dispatch \(dispatchText)")
        }
        self.dispatch = dispatch
        let operationText = try reader.string("operation", maxLength: 32)
        guard let operation = AgentOperationState(rawValue: operationText) else {
            throw ValidationError.unsupported("operation state \(operationText)")
        }
        self.operation = operation
        responseID = try reader.optionalID("response_id")
        commandID = try reader.optionalID("command_id")
        respondedByDeviceID = try reader.optionalID("responded_by_device_id")
        respondedAt = try reader.optionalTimestamp("responded_at")
        watchReviewAllowed = try reader.optionalBool("watch_review_allowed") ?? true
        if var presenceReader = try reader.optionalObject("source_presence") {
            let lastSeen = try presenceReader.optionalTimestamp("last_seen_at")
            let waiting = try presenceReader.optionalBool("waiting") ?? false
            try presenceReader.rejectUnknownMembers()
            presence = SourcePresence(lastSeenAt: lastSeen, isWaiting: waiting)
        } else {
            presence = .absent
        }
        try reader.rejectUnknownMembers()
    }
}

/// An input as a client sees it: the immutable spec, its independently
/// recomputed digest, and the current projection. The recorded response is
/// included once one exists.
public struct InputRecord: Sendable, Hashable {
    public let spec: InputSpec
    public let requestHash: String
    public var projection: InputProjection
    public var response: InputResponse?

    public init(spec: InputSpec, projection: InputProjection, response: InputResponse? = nil) throws {
        self.spec = spec
        self.requestHash = try spec.requestHash()
        self.projection = projection
        self.response = response
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let spec = try InputSpec(json: try reader.value("spec"))
        let advertised = try reader.string("request_hash", maxLength: 80)
        let projection = try InputProjection(json: try reader.value("projection"))
        let response = try reader.optionalValue("response").map(InputResponse.init(json:))
        try reader.rejectUnknownMembers()
        let computed = try spec.requestHash()
        guard ContentDigest.matches(computed, advertised) else {
            throw ValidationError.invalid("request_hash", "does not match the spec digest")
        }
        self.spec = spec
        self.requestHash = computed
        self.projection = projection
        self.response = response
    }

    public var json: JSONValue {
        JSONWriter.object([
            "spec": spec.json,
            "request_hash": .string(requestHash),
            "projection": projection.json,
            "response": response?.json
        ])
    }

    /// Why this device cannot answer right now, if it cannot. Everything but
    /// the review level applies to every client (docs/specs/agent-relay.md 7.2).
    public func answerability(
        at now: ControlTimestamp,
        review: MinimumReview,
        supportedFeatures: Set<String> = ControlFeature.supported
    ) -> WatchApprovability {
        if projection.resolution.isTerminal { return .reviewElsewhere(reason: .alreadyResolved) }
        if spec.isExpired(at: now) { return .reviewElsewhere(reason: .expired) }
        if !spec.isAnswerableEffect { return .reviewElsewhere(reason: .unknownOperationSchema) }
        if !Set(spec.requiredFeatures).isSubset(of: supportedFeatures) {
            return .reviewElsewhere(reason: .unsupportedRequiredFeature)
        }
        if review != .full, !spec.permitsWatchReview || !projection.watchReviewAllowed {
            return .reviewElsewhere(reason: .policyRequiresFullReview)
        }
        if !projection.presence.isFresh(at: now) { return .reviewElsewhere(reason: .sourceNotPresent) }
        return .approvable
    }
}
