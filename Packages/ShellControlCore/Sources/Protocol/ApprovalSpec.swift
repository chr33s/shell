import Foundation

/// How much review a request demands before a decision may be recorded.
public enum MinimumReview: String, Sendable, Hashable, CaseIterable {
    /// Reviewable on a Watch-sized surface.
    case watch
    /// Needs an enrolled full-review client; the Watch shows "Review on another
    /// device" and never mints an approval (spec.watch.md section 6).
    case full
}

public enum ControlDecision: String, Sendable, Hashable, CaseIterable {
    case approve
    case reject
}

/// Feature tokens a client must understand before it may decide.
public enum ControlFeature {
    public static let exec = "exec.v1"
    public static let consume = "consume.v1"
    public static let jobCancel = "job.cancel.v1"
    public static let notificationAck = "notification.ack.v1"
    public static let handoff = "handoff.v1"

    /// What this build of ShellControlCore actually implements.
    public static let supported: Set<String> = [exec, consume, jobCancel, notificationAck, handoff]
}

/// The immutable permission question.
///
/// Changing arguments, targets, policy-sensitive context, the review
/// requirement, or the expiry requires cancellation and a new request ID; a
/// spec is never updated behind an already-visible approval button
/// (spec.watch.md section 9).
public struct ApprovalSpec: Sendable, Hashable {
    public static let type = "approval.request"

    public let version: Int
    public let requestID: ControlID
    public let originID: ControlID
    public let jobID: ControlID
    public let runID: ControlID
    public let createdAt: ControlTimestamp
    public let expiresAt: ControlTimestamp
    public let summary: String
    public let operation: ControlOperation
    public let minimumReview: MinimumReview
    public let allowedDecisions: [ControlDecision]
    public let requiredFeatures: [String]

    public init(
        version: Int = 1,
        requestID: ControlID,
        originID: ControlID,
        jobID: ControlID,
        runID: ControlID,
        createdAt: ControlTimestamp,
        expiresAt: ControlTimestamp,
        summary: String,
        operation: ControlOperation,
        minimumReview: MinimumReview,
        allowedDecisions: [ControlDecision] = [.approve, .reject],
        requiredFeatures: [String]
    ) throws {
        guard version == 1 else { throw ValidationError.unsupported("spec version \(version)") }
        guard expiresAt > createdAt else {
            throw ValidationError.invalid("expires_at", "must be after created_at")
        }
        let lifetime = expiresAt.date.timeIntervalSince(createdAt.date)
        guard lifetime <= ApprovalPolicy.maximumLifetime else {
            throw ValidationError.invalid("expires_at", "exceeds the \(Int(ApprovalPolicy.maximumLifetime))s cap")
        }
        guard !summary.isEmpty, summary.unicodeScalars.count <= 200 else {
            throw ValidationError.invalid("summary", "must be 1...200 characters")
        }
        guard !allowedDecisions.isEmpty else {
            throw ValidationError.invalid("allowed_decisions", "must be nonempty")
        }
        guard Set(allowedDecisions).count == allowedDecisions.count else {
            throw ValidationError.invalid("allowed_decisions", "must not repeat a decision")
        }
        guard Set(requiredFeatures).count == requiredFeatures.count else {
            throw ValidationError.invalid("required_features", "must not repeat a feature")
        }
        self.version = version
        self.requestID = requestID
        self.originID = originID
        self.jobID = jobID
        self.runID = runID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.summary = summary
        self.operation = operation
        self.minimumReview = minimumReview
        self.allowedDecisions = allowedDecisions
        self.requiredFeatures = requiredFeatures
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let version = try Int(reader.integer("v"))
        let type = try reader.string("type", maxLength: 64)
        guard type == ApprovalSpec.type else { throw ValidationError.unsupported("spec type \(type)") }
        let requestID = try reader.id("request_id")
        let originID = try reader.id("origin_id")
        let jobID = try reader.id("job_id")
        let runID = try reader.id("run_id")
        let createdAt = try reader.timestamp("created_at")
        let expiresAt = try reader.timestamp("expires_at")
        let summary = try reader.string("summary", maxLength: 200)
        let operation = try ControlOperation.decode(try reader.value("operation"))
        let reviewText = try reader.string("minimum_review", maxLength: 16)
        guard let minimumReview = MinimumReview(rawValue: reviewText) else {
            throw ValidationError.unsupported("minimum_review \(reviewText)")
        }
        let decisionTexts = try reader.stringArray("allowed_decisions", maxCount: 4, maxLength: 16)
        let decisions = try decisionTexts.map { text -> ControlDecision in
            guard let decision = ControlDecision(rawValue: text) else {
                throw ValidationError.unsupported("decision \(text)")
            }
            return decision
        }
        let requiredFeatures = try reader.stringArray("required_features", maxCount: 32, maxLength: 64)
        try reader.rejectUnknownMembers()
        try self.init(
            version: version,
            requestID: requestID,
            originID: originID,
            jobID: jobID,
            runID: runID,
            createdAt: createdAt,
            expiresAt: expiresAt,
            summary: summary,
            operation: operation,
            minimumReview: minimumReview,
            allowedDecisions: decisions,
            requiredFeatures: requiredFeatures
        )
    }

    public var json: JSONValue {
        .object([
            "v": .number(.int(Int64(version))),
            "type": .string(ApprovalSpec.type),
            "request_id": JSONValue(requestID),
            "origin_id": JSONValue(originID),
            "job_id": JSONValue(jobID),
            "run_id": JSONValue(runID),
            "created_at": JSONValue(createdAt),
            "expires_at": JSONValue(expiresAt),
            "summary": .string(summary),
            "operation": operation.json,
            "minimum_review": .string(minimumReview.rawValue),
            "allowed_decisions": JSONValue(strings: allowedDecisions.map(\.rawValue)),
            "required_features": JSONValue(strings: requiredFeatures),
        ])
    }

    /// `sha256:` digest over the JCS encoding of the full spec. Recomputed
    /// independently by the origin and the Watch (spec.watch.md section 9).
    public func requestHash() throws -> String {
        try ContentDigest.digest(ofCanonical: json)
    }

    public func isExpired(at now: ControlTimestamp) -> Bool { now >= expiresAt }
}

public enum ApprovalPolicy {
    /// Approval expiry defaults to five minutes, capped at 30
    /// (spec.watch.md section 15).
    public static let defaultLifetime: TimeInterval = 5 * 60
    public static let maximumLifetime: TimeInterval = 30 * 60
    /// Origin heartbeat every 15 seconds; presence stale after 45.
    public static let heartbeatInterval: TimeInterval = 15
    public static let presenceStaleAfter: TimeInterval = 45
    /// A review challenge lives at most 60 seconds and never past the deadline.
    public static let challengeLifetime: TimeInterval = 60
    /// A consume permit is initially valid for ten seconds.
    public static let permitLifetime: TimeInterval = 10
    /// Foreground polling floor while a relevant screen is visible.
    public static let minimumPollInterval: TimeInterval = 5
    /// Retention floors.
    public static let changeLogRetention: TimeInterval = 7 * 24 * 60 * 60
    public static let commandRetention: TimeInterval = 30 * 24 * 60 * 60
}
