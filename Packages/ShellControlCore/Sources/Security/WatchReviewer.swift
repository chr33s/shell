import Foundation
import CryptoKit
import ShellControlProtocol

/// What the Watch hands its iPhone over WatchConnectivity to ask for reviewer
/// enrollment: public key, label, and a Watch-generated nonce, signed by the
/// Watch key. No private key ever leaves the Watch
/// (docs/specs/control-protocol.md sections 5.3 and 5.3).
public struct WatchEnrollmentRequest: Sendable, Hashable {
    public static let type = "shell-control.watch-enrollment"

    public let publicJWK: DeviceJWK
    public let label: String
    public let nonce: String
    public let signature: String

    public static func make(key: some DeviceSigningKey, label: String, nonce: String = OriginProof.freshNonce()) throws -> WatchEnrollmentRequest {
        let binding = try binding(publicJWK: key.publicJWK, label: label, nonce: nonce)
        return try WatchEnrollmentRequest(
            publicJWK: key.publicJWK,
            label: label,
            nonce: nonce,
            signature: Base64URL.encode(try key.signature(for: binding))
        )
    }

    public init(publicJWK: DeviceJWK, label: String, nonce: String, signature: String) throws {
        guard !label.isEmpty, label.unicodeScalars.count <= 64 else {
            throw ValidationError.invalid("label", "must be 1...64 characters")
        }
        guard !nonce.isEmpty, nonce.count <= 64 else { throw ValidationError.invalid("nonce", "must be 1...64 characters") }
        self.publicJWK = publicJWK
        self.label = label
        self.nonce = nonce
        self.signature = signature
    }

    static func binding(publicJWK: DeviceJWK, label: String, nonce: String) throws -> Data {
        try JSONCanonicalization.canonicalize(.object([
            "type": .string(type),
            "public_jwk": publicJWK.json,
            "label": .string(label),
            "nonce": .string(nonce)
        ]))
    }

    public var fingerprint: String { (try? publicJWK.displayFingerprint()) ?? "" }

    /// Proof that whoever submitted this holds the Watch private key.
    public func verifySignature() throws {
        let bytes = try Self.binding(publicJWK: publicJWK, label: label, nonce: nonce)
        guard let raw = Base64URL.decode(signature), raw.count == 64,
              let key = publicJWK.publicKey,
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              key.isValidSignature(ecdsa, for: bytes)
        else {
            throw ControlError(code: .notAuthorized, message: "watch enrollment is not signed by its key")
        }
    }

    public var json: JSONValue {
        .object([
            "public_jwk": publicJWK.json,
            "label": .string(label),
            "nonce": .string(nonce),
            "signature": .string(signature)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let jwk = try DeviceJWK(json: try reader.value("public_jwk"))
        let label = try reader.string("label", maxLength: 64)
        let nonce = try reader.string("nonce", maxLength: 64)
        let signature = try reader.string("signature", maxLength: 128)
        try reader.rejectUnknownMembers()
        try self.init(publicJWK: jwk, label: label, nonce: nonce, signature: signature)
    }
}

/// The Mac's view of one Watch reviewer, as its gateway iPhone may read it.
public struct WatchReviewerStatus: Sendable, Hashable {
    public enum State: String, Sendable, Hashable, CaseIterable {
        /// Waiting for explicit confirmation on the Mac.
        case pending
        case active
        case denied
        case expired
        case revoked
    }

    public let watchDeviceID: ControlID
    public let state: State
    public let gatewayDeviceID: ControlID
    public let fingerprint: String
    public let label: String
    /// The code the Mac shows next to the fingerprint while pending.
    public let userCode: String?
    /// Present once active: the audience a Watch-signed command commits to.
    public let accountID: ControlID?
    public let grants: Set<DeviceGrant>

    public init(
        watchDeviceID: ControlID,
        state: State,
        gatewayDeviceID: ControlID,
        fingerprint: String,
        label: String,
        userCode: String? = nil,
        accountID: ControlID? = nil,
        grants: Set<DeviceGrant> = []
    ) {
        self.watchDeviceID = watchDeviceID
        self.state = state
        self.gatewayDeviceID = gatewayDeviceID
        self.fingerprint = fingerprint
        self.label = label
        self.userCode = userCode
        self.accountID = accountID
        self.grants = grants
    }

    public var audience: String? { accountID.map { "shell-control:\($0.rawValue)" } }

    public var json: JSONValue {
        JSONWriter.object([
            "watch_device_id": JSONValue(watchDeviceID),
            "state": .string(state.rawValue),
            "gateway_device_id": JSONValue(gatewayDeviceID),
            "key_fingerprint": .string(fingerprint),
            "label": .string(label),
            "user_code": userCode.map { .string($0) },
            "account_id": accountID.map { JSONValue($0) },
            "grants": JSONValue(strings: grants.map(\.rawValue).sorted())
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        watchDeviceID = try reader.id("watch_device_id")
        let stateText = try reader.string("state", maxLength: 16)
        guard let state = State(rawValue: stateText) else { throw ValidationError.unsupported("reviewer state \(stateText)") }
        self.state = state
        gatewayDeviceID = try reader.id("gateway_device_id")
        fingerprint = try reader.string("key_fingerprint", maxLength: 128)
        label = try reader.string("label", maxLength: 64)
        userCode = try reader.optionalString("user_code", maxLength: 16)
        accountID = try reader.optionalID("account_id")
        grants = Set(try reader.stringArray("grants", maxCount: 16, maxLength: 48).compactMap(DeviceGrant.init(rawValue:)))
        try reader.rejectUnknownMembers()
    }
}
