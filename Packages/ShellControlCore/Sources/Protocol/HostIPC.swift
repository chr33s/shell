import Foundation

/// Length-prefixed IPC framing: a four-byte unsigned big-endian byte count
/// followed by one UTF-8 JSON document, maximum 64 KiB.
///
/// This avoids newline parsing of terminal data, and the PTY is never reused as
/// the control channel (spec.watch.md section 17).
public enum IPCFraming {
    public static let maxFrameBytes = JSONLimits.maxDocumentBytes

    public enum FramingError: Error, Equatable, Sendable {
        case frameTooLarge(Int)
        case truncated
    }

    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= maxFrameBytes else { throw FramingError.frameTooLarge(payload.count) }
        var header = UInt32(payload.count).bigEndian
        var out = Data(bytes: &header, count: 4)
        out.append(payload)
        return out
    }

    public static func frame(_ value: JSONValue) throws -> Data {
        try frame(JSONCanonicalization.canonicalize(value))
    }

    /// Reads one frame from the front of `buffer`, consuming it on success.
    /// Returns `nil` when the buffer does not yet hold a full frame.
    public static func decodeFrame(from buffer: inout Data) throws -> JSONValue? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(length) <= maxFrameBytes else { throw FramingError.frameTooLarge(Int(length)) }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let payload = buffer.dropFirst(4).prefix(Int(length))
        buffer.removeFirst(4 + Int(length))
        return try JSONValue.parse(Data(payload))
    }
}

/// The mandatory local IPC messages (spec.watch.md section 17).
public enum IPCMessageType: String, Sendable, Hashable, CaseIterable {
    case hello
    case notify
    case approvalRequest = "approval.request"
    case approvalWait = "approval.wait"
    case approvalWithdraw = "approval.withdraw"
    case receipt
}

/// Every IPC request carries a message ID and the per-run local capability;
/// retransmission uses the same ID and body hash (spec.watch.md section 17).
public struct IPCRequest: Sendable, Hashable {
    public let messageID: ControlID
    public let type: IPCMessageType
    public let runCapability: String?
    public let body: JSONValue

    public init(messageID: ControlID, type: IPCMessageType, runCapability: String?, body: JSONValue) {
        self.messageID = messageID
        self.type = type
        self.runCapability = runCapability
        self.body = body
    }

    public var json: JSONValue {
        JSONWriter.object([
            "message_id": JSONValue(messageID),
            "type": .string(type.rawValue),
            "run_capability": runCapability.map { .string($0) },
            "body": body,
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        messageID = try reader.id("message_id")
        let typeText = try reader.string("type", maxLength: 32)
        guard let type = IPCMessageType(rawValue: typeText) else {
            throw ValidationError.unsupported("ipc message \(typeText)")
        }
        self.type = type
        runCapability = try reader.optionalString("run_capability", maxLength: 128)
        body = try reader.value("body")
        try reader.rejectUnknownMembers()
    }

    /// Body hash for retransmission checks: the same message ID with a
    /// different body is a conflict.
    public func bodyHash() throws -> String { try ContentDigest.digest(ofCanonical: body) }
}

public struct IPCResponse: Sendable, Hashable {
    public let messageID: ControlID
    public let ok: Bool
    public let body: JSONValue
    public let errorCode: String?
    public let errorMessage: String?

    public init(messageID: ControlID, ok: Bool, body: JSONValue = .object([:]), errorCode: String? = nil, errorMessage: String? = nil) {
        self.messageID = messageID
        self.ok = ok
        self.body = body
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    public var json: JSONValue {
        JSONWriter.object([
            "message_id": JSONValue(messageID),
            "ok": .bool(ok),
            "body": body,
            "error_code": errorCode.map { .string($0) },
            "error_message": errorMessage.map { .string($0) },
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        messageID = try reader.id("message_id")
        ok = try reader.bool("ok")
        body = reader.optionalValue("body") ?? .object([:])
        errorCode = try reader.optionalString("error_code", maxLength: 64)
        errorMessage = try reader.optionalString("error_message", maxLength: 500)
        try reader.rejectUnknownMembers()
    }
}

/// The CLI exit convention (spec.watch.md section 17). A nonzero status never
/// authorizes, and the caller must still validate the structured result.
public enum ControlExitCode: Int32, Sendable, CaseIterable {
    case approved = 0
    case rejected = 10
    case expired = 11
    case cancelled = 12
    case unavailable = 13
}

/// The terminal outcome of waiting on a request, as the adapter sees it.
public enum ApprovalWaitOutcome: Sendable, Hashable {
    /// A permit the adapter may act on exactly once, before `apply_before`.
    case approved(ConsumePermit)
    case rejected(decisionID: ControlID)
    case expired
    case cancelled
    case unavailable(reason: String)

    public var exitCode: ControlExitCode {
        switch self {
        case .approved: return .approved
        case .rejected: return .rejected
        case .expired: return .expired
        case .cancelled: return .cancelled
        case .unavailable: return .unavailable
        }
    }

    public var json: JSONValue {
        switch self {
        case .approved(let permit):
            return .object(["outcome": "approved", "permit": permit.json])
        case .rejected(let decisionID):
            return .object(["outcome": "rejected", "decision_id": JSONValue(decisionID)])
        case .expired:
            return .object(["outcome": "expired"])
        case .cancelled:
            return .object(["outcome": "cancelled"])
        case .unavailable(let reason):
            return .object(["outcome": "unavailable", "reason": .string(reason)])
        }
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let outcome = try reader.string("outcome", maxLength: 24)
        switch outcome {
        case "approved":
            self = .approved(try ConsumePermit(json: try reader.value("permit")))
        case "rejected":
            self = .rejected(decisionID: try reader.id("decision_id"))
        case "expired":
            self = .expired
        case "cancelled":
            self = .cancelled
        case "unavailable":
            self = .unavailable(reason: try reader.optionalString("reason", maxLength: 200) ?? "unavailable")
        default:
            throw ValidationError.unsupported("wait outcome \(outcome)")
        }
    }
}
