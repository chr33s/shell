import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// `shell-watch-agent-gateway/1`: the negotiated Watch transport extension for
/// agent inputs. It shares the WCSession with `shell-watch-gateway/1` but is
/// routed by its explicit protocol discriminator to a separate strict decoder
/// (docs/specs/agent-relay.md section 14.5).
public enum WatchAgentGatewayProtocol {
    public static let name = "shell-watch-agent-gateway/1"
}

/// The allowlist. There is no generic URL fetch, RPC pass-through, shell
/// command, or HTTP proxy operation.
public enum WatchAgentGatewayMessageType: String, Sendable, Hashable, CaseIterable {
    case capabilitiesFetch = "agent.capabilities.fetch"
    case snapshotFetch = "agent.snapshot.fetch"
    case changesFetch = "agent.changes.fetch"
    case inputFetch = "agent.input.fetch"
    case reviewChallenge = "agent.review.challenge"
    case commandSubmit = "agent.command.submit"
    case commandQuery = "agent.command.query"
}

public struct WatchAgentGatewayRequest: Sendable, Hashable {
    public let messageID: ControlID
    public let type: WatchAgentGatewayMessageType
    public let watchDeviceID: ControlID
    public let body: JSONValue

    public init(messageID: ControlID = .random(), type: WatchAgentGatewayMessageType, watchDeviceID: ControlID, body: JSONValue = .object([:])) {
        self.messageID = messageID
        self.type = type
        self.watchDeviceID = watchDeviceID
        self.body = body
    }

    public var json: JSONValue {
        .object([
            "protocol": .string(WatchAgentGatewayProtocol.name),
            "message_id": JSONValue(messageID),
            "watch_device_id": JSONValue(watchDeviceID),
            "type": .string(type.rawValue),
            "body": body
        ])
    }

    public func encoded() throws -> Data {
        let data = try JSONCanonicalization.canonicalize(json)
        guard data.count <= WatchGatewayProtocol.maximumMessageBytes else { throw WatchGatewayError.messageTooLarge }
        return data
    }

    /// Whether `data` claims this protocol. Only the discriminator is read;
    /// everything else is left to the strict decoder.
    public static func claims(_ data: Data) -> Bool {
        guard data.count <= WatchGatewayProtocol.maximumMessageBytes,
              let value = try? JSONValue.parse(data, limits: WatchGatewayProtocol.limits) else { return false }
        return value["protocol"]?.stringValue == WatchAgentGatewayProtocol.name
    }

    public init(data: Data) throws {
        guard data.count <= WatchGatewayProtocol.maximumMessageBytes else { throw WatchGatewayError.messageTooLarge }
        do {
            var reader = try JSONReader(try JSONValue.parse(data, limits: WatchGatewayProtocol.limits))
            guard try reader.string("protocol", maxLength: 64) == WatchAgentGatewayProtocol.name else {
                throw WatchGatewayError.unsupportedVersion
            }
            messageID = try reader.id("message_id")
            watchDeviceID = try reader.id("watch_device_id")
            let typeText = try reader.string("type", maxLength: 64)
            guard let type = WatchAgentGatewayMessageType(rawValue: typeText) else { throw WatchGatewayError.unknownType(typeText) }
            self.type = type
            body = try reader.value("body")
            guard body.objectValue != nil else { throw WatchGatewayError.malformed("body must be an object") }
            try reader.rejectUnknownMembers()
        } catch let error as WatchGatewayError {
            throw error
        } catch {
            throw WatchGatewayError.malformed("\(error)")
        }
    }
}

extension WatchGatewayRouter {
    /// iPhone half of the agent extension. It relays to the Mac over this
    /// iPhone's authenticated session and forwards the Watch's JWS byte for
    /// byte; it never signs a reply as the iPhone.
    func dispatchAgent(_ request: WatchAgentGatewayRequest, upstream: ControlAPIClient) async throws -> JSONValue {
        var body = try JSONReader(request.body)
        let watchID = request.watchDeviceID
        switch request.type {
        case .capabilitiesFetch:
            try body.rejectUnknownMembers()
            return try await upstream.gatewayAgentCapabilities(watch: watchID)
        case .snapshotFetch:
            let pageToken = try body.optionalString("page_token", maxLength: 512)
            let limit = Int(try body.optionalInteger("limit") ?? Int64(Self.defaultPageLimit))
            let pendingOnly = try body.optionalBool("pending_only") ?? false
            try body.rejectUnknownMembers()
            return try await fitting(limit: limit, dropping: ["sessions", "inputs", "approvals"]) { limit in
                try await upstream.gatewayAgentSnapshot(watch: watchID, pageToken: pageToken, limit: limit, pendingOnly: pendingOnly)
            }
        case .changesFetch:
            let cursor = ChangeCursor(try body.string("cursor", maxLength: 512))
            let limit = Int(try body.optionalInteger("limit") ?? Int64(Self.defaultPageLimit))
            try body.rejectUnknownMembers()
            return try await fitting(limit: limit, dropping: ["events"]) { limit in
                try await upstream.gatewayAgentChanges(watch: watchID, cursor: cursor, limit: limit)
            }
        case .inputFetch:
            let requestID = try body.id("request_id")
            try body.rejectUnknownMembers()
            return try Self.checkFits(try await upstream.gatewayInput(watch: watchID, requestID: requestID))
        case .reviewChallenge:
            let challenge = try AgentReviewChallengeRequest(json: try body.value("request"))
            try body.rejectUnknownMembers()
            return try await upstream.gatewayAgentReviewChallenge(watch: watchID, request: challenge.json)
        case .commandSubmit:
            let commandID = try body.id("command_id")
            let signed = try body.string("signed_command", maxLength: 16384)
            try body.rejectUnknownMembers()
            return try await upstream.gatewayAgentSubmit(watch: watchID, signedCommand: signed, commandID: commandID)
        case .commandQuery:
            let commandID = try body.id("command_id")
            try body.rejectUnknownMembers()
            return try await upstream.gatewayAgentCommandResult(watch: watchID, commandID: commandID)
        }
    }
}

/// Watch-side client for the agent extension. It conforms to
/// ``AgentInputService`` so the same coordinator runs over the gateway,
/// signed by the Watch's own key. An unreachable iPhone fails closed now; a
/// reply is never downgraded to terminal input or a phone-signed command.
public actor WatchAgentGatewayClient: AgentInputService {
    private let link: any WatchGatewayLink
    private let timeout: Duration
    private var watchDeviceID: ControlID?

    public init(link: any WatchGatewayLink, watchDeviceID: ControlID? = nil, timeout: Duration = WatchGatewayClient.roundTripTimeout) {
        self.link = link
        self.timeout = timeout
        self.watchDeviceID = watchDeviceID
    }

    public func setWatchDeviceID(_ id: ControlID?) { watchDeviceID = id }

    public func capabilities() async throws -> AgentCapabilities {
        try AgentCapabilities(json: try await call(.capabilitiesFetch, body: .object([:])))
    }

    public func snapshot(pageToken: String? = nil, limit: Int = 8, pendingOnly: Bool = false) async throws -> AgentSnapshotPage {
        var body: [String: JSONValue] = ["limit": .number(.int(Int64(limit)))]
        if let pageToken { body["page_token"] = .string(pageToken) }
        if pendingOnly { body["pending_only"] = .bool(true) }
        return try AgentSnapshotPage(json: try await call(.snapshotFetch, body: .object(body)))
    }

    public func changes(after cursor: ChangeCursor, limit: Int = 8) async throws -> AgentChangePage {
        try AgentChangePage(json: try await call(.changesFetch, body: .object([
            "cursor": .string(cursor.rawValue), "limit": .number(.int(Int64(limit)))
        ])))
    }

    public func input(_ requestID: ControlID) async throws -> InputRecord {
        try InputRecord(json: try await call(.inputFetch, body: .object(["request_id": JSONValue(requestID)])))
    }

    public func agentReviewChallenge(_ request: AgentReviewChallengeRequest) async throws -> AgentReviewChallenge {
        let challenge = try AgentReviewChallenge(json: try await call(.reviewChallenge, body: .object(["request": request.json])))
        guard challenge.deviceID == watchDeviceID else { throw WatchGatewayError.responseMismatch }
        return challenge
    }

    public func submitAgent(signedCommand: String, commandID: ControlID) async throws -> AgentCommandResult {
        try AgentCommandResult(json: try await call(.commandSubmit, body: .object([
            "command_id": JSONValue(commandID), "signed_command": .string(signedCommand)
        ])))
    }

    public func agentCommandResult(_ commandID: ControlID) async throws -> AgentCommandResult {
        try AgentCommandResult(json: try await call(.commandQuery, body: .object(["command_id": JSONValue(commandID)])))
    }

    private func call(_ type: WatchAgentGatewayMessageType, body: JSONValue) async throws -> JSONValue {
        guard let watchDeviceID else { throw WatchGatewayError.notEnrolled }
        guard await link.isReachable() else { throw WatchGatewayError.iPhoneUnreachable }
        let request = WatchAgentGatewayRequest(type: type, watchDeviceID: watchDeviceID, body: body)
        let reply = try await WatchGatewayClient.boundedSend(try request.encoded(), link: link, timeout: timeout)
        let response: WatchGatewayResponse
        do {
            response = try WatchGatewayResponse(data: reply)
        } catch {
            // An older iPhone answers an unknown protocol with an
            // uncorrelated error: the extension is unsupported there.
            throw WatchGatewayError.unsupportedVersion
        }
        guard response.messageID == request.messageID else { throw WatchGatewayError.responseMismatch }
        switch response.result {
        case .success(let value): return value
        case .failure(let error): throw error
        case .gatewayUnavailable(let reason): throw WatchGatewayError.gatewayUnavailable(reason)
        }
    }
}
