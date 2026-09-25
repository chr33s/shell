import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// The `shell-watch-gateway/1` transport profile: strict JSON envelopes of at
/// most 64 KiB carried by WatchConnectivity `sendMessageData`. It is transport
/// only, never the ledger (docs/specs/control-protocol.md sections 10.1 and 10.3).
public enum WatchGatewayProtocol {
    public static let name = "shell-watch-gateway/1"
    public static let maximumMessageBytes = 64 * 1024

    static let limits = JSONLimits(maxDocumentBytes: maximumMessageBytes)
}

/// Interactive operations. Every one needs a live iPhone round trip; none of
/// them may be queued for later delivery (docs/specs/control-protocol.md section 10.1).
public enum WatchGatewayMessageType: String, Sendable, Hashable, CaseIterable {
    case enrollmentRequest = "enrollment.request"
    case enrollmentStatus = "enrollment.status"
    case snapshotFetch = "snapshot.fetch"
    case changesFetch = "changes.fetch"
    case approvalFetch = "approval.fetch"
    case reviewChallenge = "review.challenge"
    case commandSubmit = "command.submit"
    case commandQuery = "command.query"

    /// Only enrollment is sent before the Watch has a reviewer identity.
    var requiresWatchIdentity: Bool { self != .enrollmentRequest }
}

public struct WatchGatewayRequest: Sendable, Hashable {
    public let messageID: ControlID
    public let type: WatchGatewayMessageType
    public let watchDeviceID: ControlID?
    public let body: JSONValue

    public init(messageID: ControlID = .random(), type: WatchGatewayMessageType, watchDeviceID: ControlID?, body: JSONValue = .object([:])) throws {
        if type.requiresWatchIdentity, watchDeviceID == nil {
            throw ValidationError.invalid("watch_device_id", "required for \(type.rawValue)")
        }
        self.messageID = messageID
        self.type = type
        self.watchDeviceID = watchDeviceID
        self.body = body
    }

    public var json: JSONValue {
        JSONWriter.object([
            "v": 1,
            "protocol": .string(WatchGatewayProtocol.name),
            "message_id": JSONValue(messageID),
            "type": .string(type.rawValue),
            "watch_device_id": watchDeviceID.map { JSONValue($0) },
            "body": body
        ])
    }

    public func encoded() throws -> Data {
        let data = try JSONCanonicalization.canonicalize(json)
        guard data.count <= WatchGatewayProtocol.maximumMessageBytes else {
            throw WatchGatewayError.messageTooLarge
        }
        return data
    }

    /// Strict decoding: oversize, duplicate keys, unknown members, unknown
    /// types, bad identifiers, and unsupported versions all fail closed.
    public init(data: Data) throws {
        guard data.count <= WatchGatewayProtocol.maximumMessageBytes else { throw WatchGatewayError.messageTooLarge }
        let value: JSONValue
        do { value = try JSONValue.parse(data, limits: WatchGatewayProtocol.limits) } catch {
            throw WatchGatewayError.malformed("\(error)")
        }
        do {
            var reader = try JSONReader(value)
            guard try reader.integer("v") == 1,
                  try reader.string("protocol", maxLength: 64) == WatchGatewayProtocol.name
            else { throw WatchGatewayError.unsupportedVersion }
            let messageID = try reader.id("message_id")
            let typeText = try reader.string("type", maxLength: 64)
            guard let type = WatchGatewayMessageType(rawValue: typeText) else {
                throw WatchGatewayError.unknownType(typeText)
            }
            let watchDeviceID = try reader.optionalID("watch_device_id")
            let body = reader.optionalValue("body") ?? .object([:])
            guard body.objectValue != nil else { throw WatchGatewayError.malformed("body must be an object") }
            try reader.rejectUnknownMembers()
            try self.init(messageID: messageID, type: type, watchDeviceID: watchDeviceID, body: body)
        } catch let error as WatchGatewayError {
            throw error
        } catch {
            throw WatchGatewayError.malformed("\(error)")
        }
    }
}

public struct WatchGatewayResponse: Sendable, Hashable {
    public let messageID: ControlID
    public let serverTime: ControlTimestamp
    public let result: Result

    public enum Result: Sendable, Hashable {
        case success(JSONValue)
        case failure(ControlError)
        /// The iPhone could not complete the round trip (Tailscale, Mac, or
        /// transport); nothing was decided on the Watch's behalf.
        case gatewayUnavailable(String)
    }

    public init(messageID: ControlID, serverTime: ControlTimestamp = ControlTimestamp(Date()), result: Result) {
        self.messageID = messageID
        self.serverTime = serverTime
        self.result = result
    }

    public var json: JSONValue {
        var members: [String: JSONValue] = [
            "v": 1,
            "message_id": JSONValue(messageID),
            "server_time": JSONValue(serverTime)
        ]
        switch result {
        case .success(let body):
            members["ok"] = true
            members["body"] = body
        case .failure(let error):
            members["ok"] = false
            members["error"] = error.json
        case .gatewayUnavailable(let reason):
            members["ok"] = false
            members["gateway_unavailable"] = .string(String(reason.prefix(200)))
        }
        return .object(members)
    }

    public func encoded() throws -> Data {
        let data = try JSONCanonicalization.canonicalize(json)
        guard data.count <= WatchGatewayProtocol.maximumMessageBytes else { throw WatchGatewayError.messageTooLarge }
        return data
    }

    public init(data: Data) throws {
        guard data.count <= WatchGatewayProtocol.maximumMessageBytes else { throw WatchGatewayError.messageTooLarge }
        do {
            var reader = try JSONReader(try JSONValue.parse(data, limits: WatchGatewayProtocol.limits))
            guard try reader.integer("v") == 1 else { throw WatchGatewayError.unsupportedVersion }
            messageID = try reader.id("message_id")
            serverTime = try reader.timestamp("server_time")
            if try reader.bool("ok") {
                result = .success(try reader.value("body"))
            } else if let reason = try reader.optionalString("gateway_unavailable", maxLength: 200) {
                result = .gatewayUnavailable(reason)
            } else {
                result = .failure(try ControlError(json: try reader.value("error")))
            }
            try reader.rejectUnknownMembers()
        } catch let error as WatchGatewayError {
            throw error
        } catch {
            throw WatchGatewayError.malformed("\(error)")
        }
    }
}

public enum WatchGatewayError: Error, Sendable, Hashable, CustomStringConvertible {
    /// `WCSession.isReachable` is false: decisions are disabled, not queued.
    case iPhoneUnreachable
    /// The iPhone answered but could not reach the Mac over Tailscale.
    case gatewayUnavailable(String)
    case messageTooLarge
    case malformed(String)
    case unknownType(String)
    case unsupportedVersion
    case watchNotBound
    case responseMismatch
    case notEnrolled

    public var description: String {
        switch self {
        case .iPhoneUnreachable: return "iPhone unavailable"
        case .gatewayUnavailable(let reason): return "private Mac route unavailable: \(reason)"
        case .messageTooLarge: return "message exceeds 64 KiB"
        case .malformed(let reason): return "malformed gateway message: \(reason)"
        case .unknownType(let type): return "unknown gateway message type \(type)"
        case .unsupportedVersion: return "unsupported gateway protocol version"
        case .watchNotBound: return "this Watch is not bound to this iPhone"
        case .responseMismatch: return "gateway reply does not match the request"
        case .notEnrolled: return "this Watch is not enrolled"
        }
    }
}

/// Stale-tolerant state the iPhone may deliver in the background through
/// `updateApplicationContext`. It can never carry an executable approval
/// command: its schema has no place for one, and unknown members are rejected
/// (docs/specs/control-protocol.md sections 10.1 and 10.2).
public struct WatchGatewayContext: Sendable, Hashable {
    public static let type = "gateway.context"
    public static let applicationContextKey = "shell-watch-gateway"

    public var pendingCount: Int
    public var requestIDs: [ControlID]
    public var refreshedAt: ControlTimestamp?
    public var refreshRequested: Bool
    /// Display-only: whether this iPhone can currently reach its Mac.
    public var macReachable: Bool
    /// Display-only: the reviewer state the iPhone last saw for this Watch.
    public var reviewer: WatchReviewerStatus?

    public init(
        pendingCount: Int = 0,
        requestIDs: [ControlID] = [],
        refreshedAt: ControlTimestamp? = nil,
        refreshRequested: Bool = false,
        macReachable: Bool = false,
        reviewer: WatchReviewerStatus? = nil
    ) {
        self.pendingCount = pendingCount
        self.requestIDs = Array(requestIDs.prefix(64))
        self.refreshedAt = refreshedAt
        self.refreshRequested = refreshRequested
        self.macReachable = macReachable
        self.reviewer = reviewer
    }

    public var json: JSONValue {
        JSONWriter.object([
            "v": 1,
            "protocol": .string(WatchGatewayProtocol.name),
            "type": .string(Self.type),
            "pending_count": .number(.int(Int64(pendingCount))),
            "request_ids": JSONValue(strings: requestIDs.map(\.rawValue)),
            "refreshed_at": refreshedAt.map { JSONValue($0) },
            "refresh_requested": .bool(refreshRequested),
            "mac_reachable": .bool(macReachable),
            "reviewer": reviewer?.json
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard try reader.integer("v") == 1,
              try reader.string("protocol", maxLength: 64) == WatchGatewayProtocol.name,
              try reader.string("type", maxLength: 32) == Self.type
        else { throw WatchGatewayError.unsupportedVersion }
        pendingCount = Int(try reader.integer("pending_count"))
        requestIDs = try reader.stringArray("request_ids", maxCount: 64, maxLength: 36).map {
            guard let id = ControlID($0) else { throw WatchGatewayError.malformed("request id") }
            return id
        }
        refreshedAt = try reader.optionalTimestamp("refreshed_at")
        refreshRequested = try reader.bool("refresh_requested")
        macReachable = try reader.bool("mac_reachable")
        reviewer = try reader.optionalValue("reviewer").map { try WatchReviewerStatus(json: $0) }
        try reader.rejectUnknownMembers()
    }

    public func applicationContext() throws -> [String: Any] {
        [Self.applicationContextKey: try JSONCanonicalization.canonicalString(json)]
    }

    /// Anything that does not parse as exactly this schema — including a
    /// decision-like object — is ignored.
    public init?(applicationContext: [String: Any]) {
        guard applicationContext.count == 1,
              let text = applicationContext[Self.applicationContextKey] as? String,
              text.utf8.count <= WatchGatewayProtocol.maximumMessageBytes,
              let value = try? JSONValue.parse(text, limits: WatchGatewayProtocol.limits),
              let parsed = try? WatchGatewayContext(json: value)
        else { return nil }
        self = parsed
    }
}
