import Foundation
import ShellControlProtocol
import ShellControlSecurity
import Synchronization

/// The Watch's only way out: an immediate WatchConnectivity round trip to its
/// paired iPhone. There is no URL, no Tailscale session, and no bearer token
/// on this side (docs/specs/control-protocol.md sections 2.5 and 10.1).
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
    /// How long one round trip may take before it is reported as an
    /// unreachable iPhone.
    ///
    /// `sendMessageData` promises exactly one of its two handlers, but a
    /// session torn down mid-flight can deliver neither, and there is no other
    /// transport to fall back to: without a deadline the review would sit
    /// waiting forever with no way out but killing the app.
    public static let roundTripTimeout: Duration = .seconds(20)

    private let link: any WatchGatewayLink
    private let timeout: Duration
    private var watchDeviceID: ControlID?

    public init(
        link: any WatchGatewayLink,
        watchDeviceID: ControlID? = nil,
        timeout: Duration = WatchGatewayClient.roundTripTimeout
    ) {
        self.link = link
        self.timeout = timeout
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
        let reply = try await send(try request.encoded())
        let response = try WatchGatewayResponse(data: reply)
        guard response.messageID == request.messageID else { throw WatchGatewayError.responseMismatch }
        switch response.result {
        case .success(let value): return value
        case .failure(let error): throw error
        case .gatewayUnavailable(let reason): throw WatchGatewayError.gatewayUnavailable(reason)
        }
    }

    /// One round trip, bounded by ``roundTripTimeout``.
    ///
    /// Two unstructured tasks race through a single-resume continuation rather
    /// than a task group. A group awaits every child when its body returns, and
    /// the child here is a `sendMessageData` continuation that a torn-down
    /// `WCSession` may never resume and cannot be cancelled out of — so a group
    /// would hang on exactly the case this deadline exists for. The losing task
    /// keeps running; the caller has already returned.
    private func send(_ payload: Data) async throws -> Data {
        try await Self.boundedSend(payload, link: link, timeout: timeout)
    }

    /// One round trip over `link`, bounded by `timeout`; shared with the
    /// agent extension client.
    static func boundedSend(_ payload: Data, link: any WatchGatewayLink, timeout: Duration) async throws -> Data {
        let claim = FirstToFinish()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let work = Task<Void, Never> {
                do {
                    let reply = try await link.send(payload)
                    if claim.take() { continuation.resume(returning: reply) }
                } catch {
                    if claim.take() { continuation.resume(throwing: error) }
                }
            }
            Task<Void, Never> {
                try? await Task.sleep(for: timeout)
                if claim.take() {
                    work.cancel()
                    continuation.resume(throwing: WatchGatewayError.iPhoneUnreachable)
                }
            }
        }
    }
}

/// Lets exactly one of two racing tasks resume a continuation; a second resume
/// would trap.
private final class FirstToFinish: Sendable {
    private let finished = Atomic(false)

    func take() -> Bool {
        !finished.exchange(true, ordering: .acquiringAndReleasing)
    }
}
