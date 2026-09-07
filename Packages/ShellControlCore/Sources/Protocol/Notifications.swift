import Foundation

/// Informational event kinds in v1 (spec.watch.md section 14).
public enum NotificationKind: String, Sendable, Hashable, CaseIterable {
    case jobCompleted = "job.completed"
    case jobFailed = "job.failed"
    case attention
}

public enum NotificationSeverity: String, Sendable, Hashable, CaseIterable {
    case info
    case warning
    case error
}

/// An origin-authored informational event. It is never a permission request:
/// terminal OSC events observed in the phone client may drive the same local
/// UI, but never become signed host claims (spec.watch.md section 14).
public struct InformationalEvent: Sendable, Hashable {
    public let eventID: ControlID
    public let originID: ControlID
    public let jobID: ControlID?
    public let runID: ControlID?
    public let kind: NotificationKind
    public let severity: NotificationSeverity
    public let title: String
    public let body: String
    public let occurredAt: ControlTimestamp
    public var acknowledgedAt: ControlTimestamp?

    public init(
        eventID: ControlID,
        originID: ControlID,
        jobID: ControlID? = nil,
        runID: ControlID? = nil,
        kind: NotificationKind,
        severity: NotificationSeverity = .info,
        title: String,
        body: String,
        occurredAt: ControlTimestamp,
        acknowledgedAt: ControlTimestamp? = nil
    ) throws {
        guard !title.isEmpty, title.unicodeScalars.count <= 120 else {
            throw ValidationError.invalid("title", "must be 1...120 characters")
        }
        guard body.unicodeScalars.count <= 1000 else {
            throw ValidationError.invalid("body", "must be at most 1000 characters")
        }
        self.eventID = eventID
        self.originID = originID
        self.jobID = jobID
        self.runID = runID
        self.kind = kind
        self.severity = severity
        self.title = title
        self.body = body
        self.occurredAt = occurredAt
        self.acknowledgedAt = acknowledgedAt
    }

    public var json: JSONValue {
        JSONWriter.object([
            "event_id": JSONValue(eventID),
            "origin_id": JSONValue(originID),
            "job_id": jobID.map { JSONValue($0) },
            "run_id": runID.map { JSONValue($0) },
            "kind": .string(kind.rawValue),
            "severity": .string(severity.rawValue),
            "title": .string(title),
            "body": .string(body),
            "occurred_at": JSONValue(occurredAt),
            "acknowledged_at": acknowledgedAt.map { JSONValue($0) },
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let eventID = try reader.id("event_id")
        let originID = try reader.id("origin_id")
        let jobID = try reader.optionalID("job_id")
        let runID = try reader.optionalID("run_id")
        let kindText = try reader.string("kind", maxLength: 32)
        guard let kind = NotificationKind(rawValue: kindText) else {
            throw ValidationError.unsupported("notification kind \(kindText)")
        }
        let severityText = try reader.optionalString("severity", maxLength: 16) ?? NotificationSeverity.info.rawValue
        guard let severity = NotificationSeverity(rawValue: severityText) else {
            throw ValidationError.unsupported("severity \(severityText)")
        }
        let title = try reader.string("title", maxLength: 120)
        let body = try reader.optionalString("body", maxLength: 1000) ?? ""
        let occurredAt = try reader.timestamp("occurred_at")
        let acknowledgedAt = try reader.optionalTimestamp("acknowledged_at")
        try reader.rejectUnknownMembers()
        try self.init(
            eventID: eventID,
            originID: originID,
            jobID: jobID,
            runID: runID,
            kind: kind,
            severity: severity,
            title: title,
            body: body,
            occurredAt: occurredAt,
            acknowledgedAt: acknowledgedAt
        )
    }

    /// Body-hash idempotency: the same event ID with a different body is a
    /// conflict, not an update (spec.watch.md section 10).
    public func bodyHash() throws -> String {
        try ContentDigest.digest(ofCanonical: .object([
            "kind": .string(kind.rawValue),
            "severity": .string(severity.rawValue),
            "title": .string(title),
            "body": .string(body),
            "occurred_at": JSONValue(occurredAt),
        ]))
    }
}

/// The APNs notification category both Watch and iPhone register.
public enum PushCategory {
    public static let approval = "SHELL_APPROVAL_V1"
    public static let informational = "SHELL_INFO_V1"
    public static let approvalThread = "shell-approvals"

    /// Actions in order. Review is first and `.foreground`, because Apple
    /// invokes the first nondestructive action for Double Tap and runs
    /// foreground actions on the device where they were selected
    /// (spec.watch.md section 6).
    public enum Action: String, Sendable, CaseIterable {
        case review = "SHELL_REVIEW"
        case approve = "SHELL_APPROVE_INTENT"
        case reject = "SHELL_REJECT_INTENT"
    }
}

/// Builds the alert payload. It carries identifiers and minimal display
/// metadata only: never a reusable credential, private key, callback URL, or a
/// command to execute (spec.watch.md section 14).
public struct ApprovalPushPayload: Sendable, Hashable {
    public static let maximumBytes = 4096

    public let eventID: ControlID
    public let requestID: ControlID
    public let title: String
    public let body: String

    public init(
        eventID: ControlID,
        requestID: ControlID,
        title: String = "Shell approval requested",
        body: String = "A command needs your review."
    ) {
        self.eventID = eventID
        self.requestID = requestID
        self.title = title
        self.body = body
    }

    public var json: JSONValue {
        .object([
            "aps": .object([
                "alert": .object([
                    "title": .string(title),
                    "body": .string(body),
                ]),
                "category": .string(PushCategory.approval),
                "thread-id": .string(PushCategory.approvalThread),
                "sound": "default",
            ]),
            "v": 1,
            "event_id": JSONValue(eventID),
            "request_id": JSONValue(requestID),
        ])
    }

    public func encoded() throws -> Data {
        let data = try JSONCanonicalization.canonicalize(json)
        guard data.count <= ApprovalPushPayload.maximumBytes else {
            throw ValidationError.invalid("payload", "exceeds the APNs 4 KiB limit")
        }
        return data
    }

    /// Request-scoped collapse identifier. Collapsing coalesces pushes; it does
    /// not implement the protocol's deduplication (spec.watch.md section 14).
    public var collapseID: String { "approval.\(requestID.rawValue)" }
}

/// Provider headers for one push. `apns-expiration` never outlives the request
/// deadline (spec.watch.md section 14).
public struct APNsRequestHeaders: Sendable, Hashable {
    public let topic: String
    public let pushType = "alert"
    public let priority = 10
    public let expiration: Int64
    public let collapseID: String

    public init(topic: String, expiresAt: ControlTimestamp, collapseID: String) {
        self.topic = topic
        self.expiration = Int64(expiresAt.date.timeIntervalSince1970)
        self.collapseID = collapseID
    }

    public var headerFields: [String: String] {
        [
            "apns-topic": topic,
            "apns-push-type": pushType,
            "apns-priority": String(priority),
            "apns-expiration": String(expiration),
            "apns-collapse-id": collapseID,
        ]
    }
}

/// A registered delivery address. A push token is not authentication
/// (spec.watch.md section 5).
public struct PushRegistration: Sendable, Hashable {
    public enum Platform: String, Sendable, Hashable, CaseIterable {
        case watchOS
        case iOS
    }

    public enum Environment: String, Sendable, Hashable, CaseIterable {
        case development
        case production
    }

    public let token: String
    public let platform: Platform
    public let environment: Environment
    public let topic: String

    public init(token: String, platform: Platform, environment: Environment, topic: String) throws {
        guard token.count >= 32, token.count <= 200, token.allSatisfy({ $0.isHexDigit }) else {
            throw ValidationError.invalid("token", "must be a hex APNs device token")
        }
        guard !topic.isEmpty, topic.count <= 200 else {
            throw ValidationError.invalid("topic", "must be 1...200 characters")
        }
        self.token = token.lowercased()
        self.platform = platform
        self.environment = environment
        self.topic = topic
    }

    public var json: JSONValue {
        .object([
            "token": .string(token),
            "platform": .string(platform.rawValue),
            "environment": .string(environment.rawValue),
            "topic": .string(topic),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let token = try reader.string("token", maxLength: 200)
        let platformText = try reader.string("platform", maxLength: 16)
        guard let platform = Platform(rawValue: platformText) else {
            throw ValidationError.unsupported("platform \(platformText)")
        }
        let environmentText = try reader.string("environment", maxLength: 16)
        guard let environment = Environment(rawValue: environmentText) else {
            throw ValidationError.unsupported("environment \(environmentText)")
        }
        let topic = try reader.string("topic", maxLength: 200)
        try reader.rejectUnknownMembers()
        try self.init(token: token, platform: platform, environment: environment, topic: topic)
    }
}
