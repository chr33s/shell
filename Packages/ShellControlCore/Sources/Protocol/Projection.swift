import Foundation

/// Whether a user decision has been recorded. A non-pending resolution is
/// immutable (spec.watch.md section 12).
public enum Resolution: String, Sendable, Hashable, CaseIterable {
    case pending
    case approved
    case rejected
    case cancelled
    case expired

    public var isTerminal: Bool { self != .pending }

    public func canTransition(to next: Resolution) -> Bool {
        self == .pending && next != .pending
    }
}

/// Whether the decision reached the exact waiting permission gate.
///
/// `applied` never means the resulting command succeeded, and `unknown` is what
/// an origin reports when it cannot safely tell (spec.watch.md section 12).
public enum Dispatch: String, Sendable, Hashable, CaseIterable {
    case none
    case awaitingOrigin = "awaiting_origin"
    case claimed
    case applied
    case notApplied = "not_applied"
    case unknown

    public var isTerminal: Bool {
        switch self {
        case .applied, .notApplied, .unknown: return true
        case .none, .awaitingOrigin, .claimed: return false
        }
    }

    public func canTransition(to next: Dispatch) -> Bool {
        switch (self, next) {
        case (.none, .awaitingOrigin):
            return true
        case (.awaitingOrigin, .claimed):
            return true
        // A verified rejection receipt applies without a claim, and an
        // unconsumed approval that expires or is withdrawn is not applied.
        case (.awaitingOrigin, .applied), (.awaitingOrigin, .notApplied):
            return true
        case (.claimed, .applied), (.claimed, .notApplied), (.claimed, .unknown):
            return true
        // An `unknown` outcome may later be reconciled with positive adapter
        // evidence, but never back to pending.
        case (.unknown, .applied), (.unknown, .notApplied):
            return true
        default:
            return false
        }
    }
}

/// Liveness of the run that is actually blocked on the request. Presence is a
/// hint, never proof that an operation may execute (spec.watch.md section 15).
public struct SourcePresence: Sendable, Hashable {
    public let lastSeenAt: ControlTimestamp?
    public let isWaiting: Bool

    public init(lastSeenAt: ControlTimestamp?, isWaiting: Bool) {
        self.lastSeenAt = lastSeenAt
        self.isWaiting = isWaiting
    }

    public static let absent = SourcePresence(lastSeenAt: nil, isWaiting: false)

    public func isFresh(at now: ControlTimestamp, staleAfter: TimeInterval = ApprovalPolicy.presenceStaleAfter) -> Bool {
        guard isWaiting, let lastSeenAt else { return false }
        let age = now.date.timeIntervalSince(lastSeenAt.date)
        return age >= -1 && age <= staleAfter
    }
}

/// The mutable server projection over an immutable spec.
public struct ApprovalProjection: Sendable, Hashable {
    public var stateVersion: Int64
    public var policyVersion: Int64
    public var resolution: Resolution
    public var dispatch: Dispatch
    public var decisionID: ControlID?
    public var decidedByDeviceID: ControlID?
    public var decidedAt: ControlTimestamp?
    public var presence: SourcePresence
    public var watchReviewAllowed: Bool

    public init(
        stateVersion: Int64 = 1,
        policyVersion: Int64 = 1,
        resolution: Resolution = .pending,
        dispatch: Dispatch = .none,
        decisionID: ControlID? = nil,
        decidedByDeviceID: ControlID? = nil,
        decidedAt: ControlTimestamp? = nil,
        presence: SourcePresence = .absent,
        watchReviewAllowed: Bool = true
    ) {
        self.stateVersion = stateVersion
        self.policyVersion = policyVersion
        self.resolution = resolution
        self.dispatch = dispatch
        self.decisionID = decisionID
        self.decidedByDeviceID = decidedByDeviceID
        self.decidedAt = decidedAt
        self.presence = presence
        self.watchReviewAllowed = watchReviewAllowed
    }

    public var json: JSONValue {
        JSONWriter.object([
            "state_version": .number(.int(stateVersion)),
            "policy_version": .number(.int(policyVersion)),
            "resolution": .string(resolution.rawValue),
            "dispatch": .string(dispatch.rawValue),
            "decision_id": decisionID.map { JSONValue($0) },
            "decided_by_device_id": decidedByDeviceID.map { JSONValue($0) },
            "decided_at": decidedAt.map { JSONValue($0) },
            "watch_review_allowed": .bool(watchReviewAllowed),
            "source_presence": JSONWriter.object([
                "last_seen_at": presence.lastSeenAt.map { JSONValue($0) },
                "waiting": .bool(presence.isWaiting),
            ]),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        stateVersion = try reader.integer("state_version")
        policyVersion = try reader.integer("policy_version")
        let resolutionText = try reader.string("resolution", maxLength: 16)
        guard let resolution = Resolution(rawValue: resolutionText) else {
            throw ValidationError.unsupported("resolution \(resolutionText)")
        }
        self.resolution = resolution
        let dispatchText = try reader.string("dispatch", maxLength: 24)
        guard let dispatch = Dispatch(rawValue: dispatchText) else {
            throw ValidationError.unsupported("dispatch \(dispatchText)")
        }
        self.dispatch = dispatch
        decisionID = try reader.optionalID("decision_id")
        decidedByDeviceID = try reader.optionalID("decided_by_device_id")
        decidedAt = try reader.optionalTimestamp("decided_at")
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

/// A full approval as a client sees it: immutable spec, its digest, and the
/// current projection.
public struct ApprovalRecord: Sendable, Hashable {
    public let spec: ApprovalSpec
    public let requestHash: String
    public var projection: ApprovalProjection

    public init(spec: ApprovalSpec, projection: ApprovalProjection) throws {
        self.spec = spec
        self.requestHash = try spec.requestHash()
        self.projection = projection
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let spec = try ApprovalSpec(json: try reader.value("spec"))
        let advertisedHash = try reader.string("request_hash", maxLength: 80)
        let projection = try ApprovalProjection(json: try reader.value("projection"))
        try reader.rejectUnknownMembers()
        // The digest is always recomputed from the full spec; an advertised
        // hash is never substituted for the computation.
        let computed = try spec.requestHash()
        guard ContentDigest.matches(computed, advertisedHash) else {
            throw ValidationError.invalid("request_hash", "does not match the spec digest")
        }
        self.spec = spec
        self.requestHash = computed
        self.projection = projection
    }

    public var json: JSONValue {
        .object([
            "spec": spec.json,
            "request_hash": .string(requestHash),
            "projection": projection.json,
        ])
    }
}

/// Why a request cannot be decided on this device right now.
public enum WatchApprovability: Sendable, Hashable {
    case approvable
    case reviewElsewhere(reason: Reason)

    public enum Reason: String, Sendable, Hashable {
        case unknownOperationSchema
        case unsupportedRequiredFeature
        case policyRequiresFullReview
        case alreadyResolved
        case expired
        case sourceNotPresent
    }
}

extension ApprovalRecord {
    /// A request is Watch-approvable only when the device understands its
    /// operation schema and all required features, the effective policy permits
    /// Watch review, and the source run has a fresh presence lease
    /// (spec.watch.md section 6).
    public func watchApprovability(
        at now: ControlTimestamp,
        supportedFeatures: Set<String> = ControlFeature.supported
    ) -> WatchApprovability {
        if projection.resolution.isTerminal { return .reviewElsewhere(reason: .alreadyResolved) }
        if spec.isExpired(at: now) { return .reviewElsewhere(reason: .expired) }
        if !spec.operation.isRecognized { return .reviewElsewhere(reason: .unknownOperationSchema) }
        if !Set(spec.requiredFeatures).isSubset(of: supportedFeatures) {
            return .reviewElsewhere(reason: .unsupportedRequiredFeature)
        }
        if spec.minimumReview != .watch || !projection.watchReviewAllowed {
            return .reviewElsewhere(reason: .policyRequiresFullReview)
        }
        if !projection.presence.isFresh(at: now) { return .reviewElsewhere(reason: .sourceNotPresent) }
        return .approvable
    }

    /// Reject can be recorded while the origin is offline, as long as the
    /// request is still pending (spec.watch.md section 15).
    public func canReject(at now: ControlTimestamp) -> Bool {
        !projection.resolution.isTerminal && !spec.isExpired(at: now)
            && spec.allowedDecisions.contains(.reject)
    }

    public func canApprove(at now: ControlTimestamp, supportedFeatures: Set<String> = ControlFeature.supported) -> Bool {
        spec.allowedDecisions.contains(.approve)
            && watchApprovability(at: now, supportedFeatures: supportedFeatures) == .approvable
    }
}
