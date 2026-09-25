import Foundation
import ShellControlProtocol
import ShellControlSecurity
import Synchronization

/// Which Watch this iPhone gateways for. Changing it is an explicit re-binding
/// (docs/specs/control-protocol.md section 5.4).
public protocol WatchBindingStore: Sendable {
    func loadBoundWatch() throws -> WatchReviewerStatus?
    func storeBoundWatch(_ status: WatchReviewerStatus?) throws
}

public final class InMemoryWatchBindingStore: WatchBindingStore, Sendable {
    private let status: Mutex<WatchReviewerStatus?>

    public init(_ status: WatchReviewerStatus? = nil) { self.status = Mutex(status) }

    public func loadBoundWatch() throws -> WatchReviewerStatus? {
        status.withLock { $0 }
    }

    public func storeBoundWatch(_ status: WatchReviewerStatus?) throws {
        self.status.withLock { $0 = status }
    }
}

/// The iPhone half of `shell-watch-gateway/1`.
///
/// It relays live Watch requests to the Mac over the iPhone's own
/// authenticated Tailscale session. It never manufactures a Watch JWS, never
/// rewrites one, and never holds a Watch command for later: anything that
/// arrives outside the interactive channel is refused
/// (docs/specs/control-protocol.md sections 10.1 and 10.4).
public actor WatchGatewayRouter {
    /// Returns an authenticated client whose route has been verified against
    /// the pinned origin key.
    public typealias ClientProvider = @Sendable () async throws -> ControlAPIClient
    /// Lets the iPhone reinterpret an upstream error against its own session
    /// before it is relayed, e.g. a rejected token that means pair again.
    public typealias ErrorRecovery = @Sendable (any Error) async -> any Error

    private let client: ClientProvider
    private let recover: ErrorRecovery
    private let binding: any WatchBindingStore
    private let now: @Sendable () -> Date
    /// Gateway-level idempotency: a retried message ID gets the same answer
    /// without a second upstream call.
    private var recent: [ControlID: (requestDigest: String, response: Data, at: Date)] = [:]
    /// Messages still waiting on the Mac. A retry that arrives meanwhile
    /// joins the first attempt rather than making a second upstream call.
    private var inFlight: [ControlID: (requestDigest: String, response: Task<Data, Never>)] = [:]
    private static let recentLimit = 128
    private static let recentLifetime: TimeInterval = 300
    /// A snapshot page shrinks until its reply fits in one message.
    static let defaultPageLimit = 8

    public init(
        client: @escaping ClientProvider,
        binding: any WatchBindingStore,
        recover: @escaping ErrorRecovery = { $0 },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.recover = recover
        self.binding = binding
        self.now = now
    }

    public var boundWatch: WatchReviewerStatus? { try? binding.loadBoundWatch() }

    /// Handles one `sendMessageData` payload and returns the reply payload.
    public func handle(_ data: Data) async -> Data {
        // The agent extension is routed by its explicit protocol
        // discriminator to its own strict decoder (docs/specs/agent-relay.md 14.5).
        let messageID: ControlID
        let perform: @Sendable (isolated WatchGatewayRouter) async throws -> JSONValue
        do {
            if WatchAgentGatewayRequest.claims(data) {
                let request = try WatchAgentGatewayRequest(data: data)
                messageID = request.messageID
                perform = { router in try await router.dispatchAgentBound(request) }
            } else {
                let request = try WatchGatewayRequest(data: data)
                messageID = request.messageID
                perform = { router in try await router.dispatch(request) }
            }
        } catch {
            // Without a parseable message ID there is nothing to correlate a
            // reply with; answer with a nil-ID error the Watch will reject.
            return Self.encodeFallback(error)
        }
        let digest = ContentDigest.digest(of: data)
        pruneRecent()
        if let cached = recent[messageID] {
            guard cached.requestDigest == digest else { return reusedMessageID(messageID) }
            return cached.response
        }
        // Responding awaits the Mac, so a retry can arrive before the first
        // attempt is recorded in `recent`; it must not go upstream a second time.
        if let pending = inFlight[messageID] {
            guard pending.requestDigest == digest else { return reusedMessageID(messageID) }
            return await pending.response.value
        }
        let work = Task { await respondAndRecord(messageID, digest: digest, perform: perform) }
        inFlight[messageID] = (digest, work)
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private func respondAndRecord(
        _ messageID: ControlID,
        digest: String,
        perform: @Sendable (isolated WatchGatewayRouter) async throws -> JSONValue
    ) async -> Data {
        defer { inFlight[messageID] = nil }
        let response = await respond(to: messageID, perform: perform)
        let encoded = encode(response)
        if case .gatewayUnavailable = response.result {
            // Not recorded: a retry after connectivity returns must go upstream.
        } else {
            recent[messageID] = (digest, encoded, now())
        }
        return encoded
    }

    /// Agent messages must name the Watch this iPhone is bound to.
    private func dispatchAgentBound(_ request: WatchAgentGatewayRequest) async throws -> JSONValue {
        guard let bound = try binding.loadBoundWatch(), bound.watchDeviceID == request.watchDeviceID else {
            throw WatchGatewayError.watchNotBound
        }
        return try await dispatchAgent(request, upstream: try await client())
    }

    private func reusedMessageID(_ messageID: ControlID) -> Data {
        encode(WatchGatewayResponse(
            messageID: messageID,
            serverTime: ControlTimestamp(now()),
            result: .failure(ControlError(code: .idempotencyConflict, message: "message id reused with a different body"))
        ))
    }

    /// WatchConnectivity background delivery (`transferUserInfo`, file
    /// transfer, application context) never carries authority. Whatever
    /// arrives that way is ignored, including a decision-like object.
    public nonisolated func handleBackground(_ payload: [String: Any]) -> Bool { Self.refusesBackground(payload) }

    /// Always `false`: nothing delivered outside the interactive channel is
    /// acted on.
    public static func refusesBackground(_ payload: [String: Any]) -> Bool { false }

    private func respond(
        to messageID: ControlID,
        perform: @Sendable (isolated WatchGatewayRouter) async throws -> JSONValue
    ) async -> WatchGatewayResponse {
        let stamp = ControlTimestamp(now())
        do {
            do {
                let body = try await perform(self)
                return WatchGatewayResponse(messageID: messageID, serverTime: stamp, result: .success(body))
            } catch {
                throw await recover(error)
            }
        } catch let error as ControlError {
            return WatchGatewayResponse(messageID: messageID, serverTime: stamp, result: .failure(error))
        } catch let error as WatchGatewayError {
            return WatchGatewayResponse(
                messageID: messageID,
                serverTime: stamp,
                result: .failure(ControlError(code: error == .watchNotBound ? .reviewerNotBound : .invalidPayload, message: error.description))
            )
        } catch let error as JSONReader.ReadError {
            return WatchGatewayResponse(
                messageID: messageID,
                serverTime: stamp,
                result: .failure(ControlError(code: .invalidPayload, message: "\(error)"))
            )
        } catch let error as ValidationError {
            return WatchGatewayResponse(
                messageID: messageID,
                serverTime: stamp,
                result: .failure(ControlError(code: .invalidPayload, message: error.description))
            )
        } catch let error as any ControlErrorConvertible {
            return WatchGatewayResponse(messageID: messageID, serverTime: stamp, result: .failure(error.controlError))
        } catch {
            // Only transport failures remain: the Mac is unreachable.
            return WatchGatewayResponse(messageID: messageID, serverTime: stamp, result: .gatewayUnavailable(String(describing: error)))
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
    func fitting(limit: Int, dropping members: [String], _ fetch: (Int) async throws -> JSONValue) async throws -> JSONValue {
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

    static let tooLarge = ControlError(code: .unsupportedOperation, message: "too large for the Watch; review on iPhone")

    static func fits(_ body: JSONValue) -> Bool {
        // Leave room for the envelope around the body.
        ((try? JSONCanonicalization.canonicalize(body))?.count ?? .max) <= WatchGatewayProtocol.maximumMessageBytes - 512
    }

    static func checkFits(_ body: JSONValue) throws -> JSONValue {
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
