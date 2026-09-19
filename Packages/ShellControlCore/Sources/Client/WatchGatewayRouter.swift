import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// Which Watch this iPhone gateways for. Changing it is an explicit re-binding
/// (spec.iphone-gateway.md section 10.5).
public protocol WatchBindingStore: Sendable {
    func loadBoundWatch() throws -> WatchReviewerStatus?
    func storeBoundWatch(_ status: WatchReviewerStatus?) throws
}

public final class InMemoryWatchBindingStore: WatchBindingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var status: WatchReviewerStatus?

    public init(_ status: WatchReviewerStatus? = nil) { self.status = status }

    public func loadBoundWatch() throws -> WatchReviewerStatus? {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    public func storeBoundWatch(_ status: WatchReviewerStatus?) throws {
        lock.lock(); defer { lock.unlock() }
        self.status = status
    }
}

/// The iPhone half of `shell-watch-gateway/1`.
///
/// It relays live Watch requests to the Mac over the iPhone's own
/// authenticated Tailscale session. It never manufactures a Watch JWS, never
/// rewrites one, and never holds a Watch command for later: anything that
/// arrives outside the interactive channel is refused
/// (spec.iphone-gateway.md sections 11 and 13).
public actor WatchGatewayRouter {
    /// Returns an authenticated client whose route has been verified against
    /// the pinned origin key.
    public typealias ClientProvider = @Sendable () async throws -> ControlAPIClient

    private let client: ClientProvider
    private let binding: any WatchBindingStore
    private let now: @Sendable () -> Date
    /// Gateway-level idempotency: a retried message ID gets the same answer
    /// without a second upstream call.
    private var recent: [ControlID: (requestDigest: String, response: Data, at: Date)] = [:]
    private static let recentLimit = 128
    private static let recentLifetime: TimeInterval = 300
    /// A snapshot page shrinks until its reply fits in one message.
    static let defaultPageLimit = 8

    public init(client: @escaping ClientProvider, binding: any WatchBindingStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.binding = binding
        self.now = now
    }

    public var boundWatch: WatchReviewerStatus? { try? binding.loadBoundWatch() }

    /// Handles one `sendMessageData` payload and returns the reply payload.
    public func handle(_ data: Data) async -> Data {
        let request: WatchGatewayRequest
        do {
            request = try WatchGatewayRequest(data: data)
        } catch {
            // Without a parseable message ID there is nothing to correlate a
            // reply with; answer with a nil-ID error the Watch will reject.
            return Self.encodeFallback(error)
        }
        let digest = ContentDigest.digest(of: data)
        pruneRecent()
        if let cached = recent[request.messageID] {
            guard cached.requestDigest == digest else {
                return encode(WatchGatewayResponse(
                    messageID: request.messageID,
                    serverTime: ControlTimestamp(now()),
                    result: .failure(ControlError(code: .idempotencyConflict, message: "message id reused with a different body"))
                ))
            }
            return cached.response
        }
        let response = await respond(to: request)
        let encoded = encode(response)
        if case .gatewayUnavailable = response.result {
            // Not recorded: a retry after connectivity returns must go upstream.
        } else {
            recent[request.messageID] = (digest, encoded, now())
        }
        return encoded
    }

    /// WatchConnectivity background delivery (`transferUserInfo`, file
    /// transfer, application context) never carries authority. Whatever
    /// arrives that way is ignored, including a decision-like object.
    public nonisolated func handleBackground(_ payload: [String: Any]) -> Bool { Self.refusesBackground(payload) }

    /// Always `false`: nothing delivered outside the interactive channel is
    /// acted on.
    public static func refusesBackground(_ payload: [String: Any]) -> Bool { false }

    private func respond(to request: WatchGatewayRequest) async -> WatchGatewayResponse {
        let stamp = ControlTimestamp(now())
        do {
            let body = try await dispatch(request)
            return WatchGatewayResponse(messageID: request.messageID, serverTime: stamp, result: .success(body))
        } catch let error as ControlError {
            return WatchGatewayResponse(messageID: request.messageID, serverTime: stamp, result: .failure(error))
        } catch let error as WatchGatewayError {
            return WatchGatewayResponse(
                messageID: request.messageID,
                serverTime: stamp,
                result: .failure(ControlError(code: error == .watchNotBound ? .reviewerNotBound : .invalidPayload, message: error.description))
            )
        } catch let error as JSONReader.ReadError {
            return WatchGatewayResponse(
                messageID: request.messageID,
                serverTime: stamp,
                result: .failure(ControlError(code: .invalidPayload, message: "\(error)"))
            )
        } catch {
            return WatchGatewayResponse(messageID: request.messageID, serverTime: stamp, result: .gatewayUnavailable(String(describing: error)))
        }
    }

    private func dispatch(_ request: WatchGatewayRequest) async throws -> JSONValue {
        if request.type == .enrollmentRequest {
            let enrollment = try WatchEnrollmentRequest(json: request.body)
            // Proof of possession is checked here as well as on the Mac, so a
            // malformed request never leaves the phone.
            try enrollment.verifySignature()
            let status = try await client().enrollWatchReviewer(enrollment)
            try binding.storeBoundWatch(status)
            return status.json
        }
        // Every other message must name the Watch this iPhone is bound to.
        guard let watchID = request.watchDeviceID,
              let bound = try binding.loadBoundWatch(), bound.watchDeviceID == watchID
        else { throw WatchGatewayError.watchNotBound }
        var body = try JSONReader(request.body)
        let upstream = try await client()
        switch request.type {
        case .enrollmentRequest:
            preconditionFailure("handled above")
        case .enrollmentStatus:
            try body.rejectUnknownMembers()
            let status = try await upstream.watchReviewer(watchID)
            try binding.storeBoundWatch(status)
            return status.json
        case .snapshotFetch:
            let pageToken = try body.optionalString("page_token", maxLength: 512)
            let limit = Int(try body.optionalInteger("limit") ?? Int64(Self.defaultPageLimit))
            try body.rejectUnknownMembers()
            return try await fitting(limit: limit, dropping: ["approvals", "notifications"]) { limit in
                try await upstream.gatewaySnapshot(watch: watchID, pageToken: pageToken, limit: limit)
            }
        case .changesFetch:
            let cursor = ChangeCursor(try body.string("cursor", maxLength: 512))
            let limit = Int(try body.optionalInteger("limit") ?? Int64(Self.defaultPageLimit))
            try body.rejectUnknownMembers()
            return try await fitting(limit: limit, dropping: ["events"]) { limit in
                try await upstream.gatewayChanges(watch: watchID, cursor: cursor, limit: limit)
            }
        case .approvalFetch:
            let requestID = try body.id("request_id")
            try body.rejectUnknownMembers()
            return try Self.checkFits(try await upstream.gatewayApproval(watch: watchID, requestID: requestID))
        case .reviewChallenge:
            let challenge = try ReviewChallengeRequest(json: try body.value("request"))
            try body.rejectUnknownMembers()
            return try await upstream.gatewayReviewChallenge(watch: watchID, request: challenge.json)
        case .commandSubmit:
            let commandID = try body.id("command_id")
            let signed = try body.string("signed_command", maxLength: 8192)
            try body.rejectUnknownMembers()
            // Forwarded byte for byte: the gateway cannot substitute its own
            // approval for the Watch's signature.
            return try await upstream.gatewaySubmit(watch: watchID, signedCommand: signed, commandID: commandID)
        case .commandQuery:
            let commandID = try body.id("command_id")
            try body.rejectUnknownMembers()
            return try await upstream.gatewayCommandResult(watch: watchID, commandID: commandID)
        }
    }

    /// Pages shrink until the reply fits in one WatchConnectivity message. A
    /// single item that still does not fit is left out of the Watch's page —
    /// its tokens and cursor still advance past it — so one oversized request
    /// cannot stall the Watch's whole sync. It stays reviewable on the iPhone,
    /// and fetching it from the Watch reports that handoff.
    private func fitting(limit: Int, dropping members: [String], _ fetch: (Int) async throws -> JSONValue) async throws -> JSONValue {
        var limit = max(1, min(limit, SnapshotPage.maximumItems))
        while true {
            let value = try await fetch(limit)
            if Self.fits(value) { return value }
            guard limit > 1 else {
                guard var object = value.objectValue else { throw Self.tooLarge }
                for member in members where object[member] != nil { object[member] = .array([]) }
                let trimmed = JSONValue.object(object)
                guard Self.fits(trimmed) else { throw Self.tooLarge }
                return trimmed
            }
            limit = max(1, limit / 2)
        }
    }

    private static let tooLarge = ControlError(code: .unsupportedOperation, message: "too large for the Watch; review on iPhone")

    private static func fits(_ body: JSONValue) -> Bool {
        // Leave room for the envelope around the body.
        ((try? JSONCanonicalization.canonicalize(body))?.count ?? .max) <= WatchGatewayProtocol.maximumMessageBytes - 512
    }

    private static func checkFits(_ body: JSONValue) throws -> JSONValue {
        guard fits(body) else { throw tooLarge }
        return body
    }

    private func encode(_ response: WatchGatewayResponse) -> Data {
        if let data = try? response.encoded() { return data }
        return (try? WatchGatewayResponse(
            messageID: response.messageID,
            serverTime: response.serverTime,
            result: .failure(Self.tooLarge)
        ).encoded()) ?? Data()
    }

    private static func encodeFallback(_ error: any Error) -> Data {
        let value: JSONValue = .object([
            "v": 1,
            "ok": false,
            "error": ControlError(code: .invalidPayload, message: String(describing: error).prefix(200).description).json
        ])
        return (try? JSONCanonicalization.canonicalize(value)) ?? Data()
    }

    private func pruneRecent() {
        let cutoff = now().addingTimeInterval(-Self.recentLifetime)
        recent = recent.filter { $0.value.at > cutoff }
        if recent.count > Self.recentLimit {
            for key in recent.sorted(by: { $0.value.at < $1.value.at }).prefix(recent.count - Self.recentLimit).map(\.key) {
                recent.removeValue(forKey: key)
            }
        }
    }
}
