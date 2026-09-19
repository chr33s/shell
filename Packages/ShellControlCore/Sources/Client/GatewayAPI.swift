import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// What a pairing claim returns: the ordinary enrollment challenge plus the
/// device grant the Mac confirms locally (spec.iphone-gateway.md section 9).
public struct PairingClaim: Sendable {
    public let enrollmentID: ControlID
    public let challenge: String
    public let expiresAt: ControlTimestamp
    public let authorization: DeviceAuthorization
    public let fingerprint: String

    public init(json: JSONValue, now: ControlTimestamp) throws {
        var reader = try JSONReader(json)
        enrollmentID = try reader.id("enrollment_id")
        challenge = try reader.string("challenge", maxLength: 256)
        expiresAt = try reader.timestamp("expires_at")
        authorization = try DeviceAuthorization(json: try reader.value("device_authorization"), now: now)
        fingerprint = try reader.string("key_fingerprint", maxLength: 128)
        try reader.rejectUnknownMembers()
    }
}

extension ControlAPIClient {
    // MARK: Origin identity

    /// `GET /v1/origin/proof`: the endpoint signs our nonce with the origin key.
    /// Reachability alone proves nothing; this does
    /// (spec.iphone-gateway.md sections 7.4 and 24).
    public func originProof(nonce: String) async throws -> OriginProof {
        try OriginProof(unverified: try await get("/v1/origin/proof", query: [("nonce", nonce)], timeout: 8))
    }

    /// Verifies that this client's base URL is served by `origin`.
    public func verifyOrigin(_ origin: OriginIdentity) async throws {
        let nonce = OriginProof.freshNonce()
        try await originProof(nonce: nonce).verify(expected: origin, nonce: nonce)
    }

    // MARK: Pairing

    /// `POST /v1/pairings/{pairing_id}/claim`: proves knowledge of the one-use
    /// pairing secret without sending it, and possession of the new device key.
    public func claimPairing(
        _ invitation: PairingInvitation,
        key: InMemoryDeviceKey,
        platform: PushRegistration.Platform,
        label: String,
        now: ControlTimestamp = ControlTimestamp(Date())
    ) async throws -> PairingClaim {
        let nonce = OriginProof.freshNonce()
        let binding = try PairingInvitation.claimBinding(pairingID: invitation.pairingID, publicJWK: key.publicJWK, nonce: nonce)
        guard let secret = Base64URL.decode(invitation.pairingSecret) else {
            throw ControlError(code: .invalidPayload, message: "pairing secret is malformed")
        }
        let proof = PairingProof.mac(secret: secret, binding: binding)
        let value = try await send(
            method: "POST",
            path: "/v1/pairings/\(invitation.pairingID.rawValue)/claim",
            body: .object([
                "public_jwk": key.publicJWK.json,
                "platform": .string(platform.rawValue),
                "label": .string(label),
                "nonce": .string(nonce),
                "proof": .string(Base64URL.encode(proof)),
                "key_signature": .string(Base64URL.encode(try key.signature(for: binding)))
            ])
        )
        return try PairingClaim(json: value, now: now)
    }

    // MARK: Push capability

    /// Hands the Mac the relay-signed push capability. It is a delivery
    /// address, never authentication (spec.iphone-gateway.md section 16.1).
    public func registerPushCapability(_ capability: String) async throws {
        _ = try await send(method: "PUT", path: "/v1/devices/me/push-capability", body: .object([
            "capability": .string(capability)
        ]))
    }

    // MARK: Gateway: Watch reviewers

    public func enrollWatchReviewer(_ request: WatchEnrollmentRequest) async throws -> WatchReviewerStatus {
        try WatchReviewerStatus(json: try await send(method: "POST", path: "/v1/gateways/me/watch-reviewers", body: request.json))
    }

    public func watchReviewer(_ watchID: ControlID) async throws -> WatchReviewerStatus {
        try WatchReviewerStatus(json: try await get(Self.reviewerPath(watchID)))
    }

    /// Proxied reads and mutations for a Watch bound to this gateway. The
    /// broker derives the gateway from this client's credential and checks
    /// the binding on every call (spec.iphone-gateway.md section 13).
    public func gatewaySnapshot(watch watchID: ControlID, pageToken: String? = nil, limit: Int) async throws -> JSONValue {
        var query = [("limit", String(max(1, min(limit, SnapshotPage.maximumItems))))]
        if let pageToken { query.append(("page", pageToken)) }
        return try await get("\(Self.reviewerPath(watchID))/snapshot", query: query)
    }

    public func gatewayChanges(watch watchID: ControlID, cursor: ChangeCursor, limit: Int) async throws -> JSONValue {
        try await get("\(Self.reviewerPath(watchID))/changes", query: [
            ("cursor", cursor.rawValue),
            ("limit", String(max(1, min(limit, ChangePage.maximumEvents))))
        ])
    }

    public func gatewayApproval(watch watchID: ControlID, requestID: ControlID) async throws -> JSONValue {
        try await get("\(Self.reviewerPath(watchID))/approvals/\(requestID.rawValue)")
    }

    public func gatewayReviewChallenge(watch watchID: ControlID, request: JSONValue) async throws -> JSONValue {
        try await send(method: "POST", path: "\(Self.reviewerPath(watchID))/review-challenges", body: request)
    }

    /// Forwards the Watch's JWS unchanged: the gateway cannot substitute its
    /// own signature for the Watch's.
    public func gatewaySubmit(watch watchID: ControlID, signedCommand: String, commandID: ControlID) async throws -> JSONValue {
        try await send(
            method: "POST",
            path: "\(Self.reviewerPath(watchID))/commands",
            body: .object(["signed_command": .string(signedCommand)]),
            headers: ["Idempotency-Key": commandID.rawValue]
        )
    }

    public func gatewayCommandResult(watch watchID: ControlID, commandID: ControlID) async throws -> JSONValue {
        try await get("\(Self.reviewerPath(watchID))/commands/\(commandID.rawValue)")
    }

    static func reviewerPath(_ watchID: ControlID) -> String {
        "/v1/gateways/me/watch-reviewers/\(watchID.rawValue)"
    }
}
