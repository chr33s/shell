import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// The Watch's only way out: an immediate WatchConnectivity round trip to its
/// paired iPhone. There is no URL, no Tailscale session, and no bearer token
/// on this side (spec.iphone-gateway.md sections 4.6 and 11.1).
public protocol WatchGatewayLink: Sendable {
    /// `WCSession.isReachable`, checked before any decision is enabled.
    func isReachable() async -> Bool
    /// `sendMessageData(_:replyHandler:errorHandler:)`.
    func send(_ data: Data) async throws -> Data
}

/// Watch-side client for `shell-watch-gateway/1`. It conforms to
/// ``ControlDecisionService`` so the same review → challenge → sign → submit
/// logic the iPhone uses runs unchanged over the gateway, signed by the Watch's
/// own key.
public actor WatchGatewayClient: ControlDecisionService {
    private let link: any WatchGatewayLink
    private var watchDeviceID: ControlID?

    public init(link: any WatchGatewayLink, watchDeviceID: ControlID? = nil) {
        self.link = link
        self.watchDeviceID = watchDeviceID
    }

    public func setWatchDeviceID(_ id: ControlID?) { watchDeviceID = id }

    public func isReachable() async -> Bool { await link.isReachable() }

    // MARK: Enrollment

    public func requestEnrollment(_ request: WatchEnrollmentRequest) async throws -> WatchReviewerStatus {
        let status = try WatchReviewerStatus(json: try await call(.enrollmentRequest, body: request.json, identity: nil))
        guard try await verifyEnrollment(status, publicJWK: request.publicJWK) else {
            throw WatchGatewayError.responseMismatch
        }
        watchDeviceID = status.watchDeviceID
        return status
    }

    public func enrollmentStatus() async throws -> WatchReviewerStatus {
        try WatchReviewerStatus(json: try await call(.enrollmentStatus, body: .object([:])))
    }

    private func verifyEnrollment(_ status: WatchReviewerStatus, publicJWK: DeviceJWK) async throws -> Bool {
        // The Mac reports the fingerprint of the key it recorded; it must be
        // this Watch's key, or the iPhone enrolled something else.
        status.fingerprint == (try publicJWK.displayFingerprint())
    }

    // MARK: Reads

    public func snapshot(pageToken: String? = nil, limit: Int = 8) async throws -> SnapshotPage {
        var body: [String: JSONValue] = ["limit": .number(.int(Int64(limit)))]
        if let pageToken { body["page_token"] = .string(pageToken) }
        return try SnapshotPage(json: try await call(.snapshotFetch, body: .object(body)))
    }

    public func changes(after cursor: ChangeCursor, limit: Int = 8) async throws -> ChangePage {
        try ChangePage(json: try await call(.changesFetch, body: .object([
            "cursor": .string(cursor.rawValue),
            "limit": .number(.int(Int64(limit)))
        ])))
    }

    // MARK: ControlDecisionService

    public func approval(_ requestID: ControlID) async throws -> ApprovalRecord {
        // `ApprovalRecord(json:)` recomputes the request hash from the complete
        // immutable spec; an advertised hash is never trusted.
        try ApprovalRecord(json: try await call(.approvalFetch, body: .object(["request_id": JSONValue(requestID)])))
    }

    public func reviewChallenge(_ request: ReviewChallengeRequest) async throws -> ReviewChallenge {
        let challenge = try ReviewChallenge(json: try await call(.reviewChallenge, body: .object(["request": request.json])))
        guard challenge.deviceID == watchDeviceID else { throw WatchGatewayError.responseMismatch }
        return challenge
    }

    public func submit(signedCommand: String, commandID: ControlID) async throws -> CommandResult {
        try CommandResult(json: try await call(.commandSubmit, body: .object([
            "command_id": JSONValue(commandID),
            "signed_command": .string(signedCommand)
        ])))
    }

    public func commandResult(_ commandID: ControlID) async throws -> CommandResult {
        try CommandResult(json: try await call(.commandQuery, body: .object(["command_id": JSONValue(commandID)])))
    }

    // MARK: Plumbing

    private func call(_ type: WatchGatewayMessageType, body: JSONValue) async throws -> JSONValue {
        guard let watchDeviceID else { throw WatchGatewayError.notEnrolled }
        return try await call(type, body: body, identity: watchDeviceID)
    }

    private func call(_ type: WatchGatewayMessageType, body: JSONValue, identity: ControlID?) async throws -> JSONValue {
        // Interactive only: an unreachable iPhone fails closed now rather than
        // queueing the request for a later, unobserved delivery.
        guard await link.isReachable() else { throw WatchGatewayError.iPhoneUnreachable }
        let request = try WatchGatewayRequest(type: type, watchDeviceID: identity, body: body)
        let reply = try await link.send(try request.encoded())
        let response = try WatchGatewayResponse(data: reply)
        guard response.messageID == request.messageID else { throw WatchGatewayError.responseMismatch }
        switch response.result {
        case .success(let value): return value
        case .failure(let error): throw error
        case .gatewayUnavailable(let reason): throw WatchGatewayError.gatewayUnavailable(reason)
        }
    }
}
