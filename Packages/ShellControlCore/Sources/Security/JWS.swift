import Foundation
import CryptoKit
import ShellControlProtocol

/// JWS Compact Serialization restricted to what the control protocol allows:
/// `alg=ES256`, `kid=<device_id>`, `typ=shell-control+jws`, and a JCS-encoded
/// payload (spec.watch.md section 11).
public enum ControlJWS {
    public static let type = "shell-control+jws"
    public static let algorithm = "ES256"

    public enum JWSError: Error, Equatable, Sendable {
        case malformed
        case unsupportedAlgorithm(String)
        case unsupportedType(String)
        case untrustedHeaderMember(String)
        case unknownCriticalHeader([String])
        case keyIdentifierMismatch
        case badSignature
        case payloadNotCanonical
    }

    /// Header members that would let a signer point at an attacker-controlled
    /// key. They are rejected outright rather than ignored.
    private static let forbiddenHeaderMembers: Set<String> = ["jku", "jwk", "x5u", "x5c", "x5t", "x5t#S256"]

    public struct Header: Sendable, Hashable {
        public let algorithm: String
        public let keyID: ControlID
        public let type: String

        public init(keyID: ControlID) {
            self.algorithm = ControlJWS.algorithm
            self.keyID = keyID
            self.type = ControlJWS.type
        }

        var json: JSONValue {
            .object([
                "alg": .string(algorithm),
                "kid": JSONValue(keyID),
                "typ": .string(type),
            ])
        }
    }

    /// Signs `payload` for `deviceID`.
    public static func sign(payload: JSONValue, deviceID: ControlID, key: some DeviceSigningKey) throws -> String {
        let headerBytes = try JSONCanonicalization.canonicalize(Header(keyID: deviceID).json)
        let payloadBytes = try JSONCanonicalization.canonicalize(payload)
        let signingInput = "\(Base64URL.encode(headerBytes)).\(Base64URL.encode(payloadBytes))"
        let signature = try key.signature(for: Data(signingInput.utf8))
        guard signature.count == 64 else { throw JWSError.badSignature }
        return "\(signingInput).\(Base64URL.encode(signature))"
    }

    public struct VerifiedCommand: Sendable, Hashable {
        public let deviceID: ControlID
        public let payload: JSONValue
        public let command: ControlCommand
        public let compactSerialization: String
        /// Canonical payload hash, so retries that differ only in signature
        /// bytes are still the same logical command (spec.watch.md section 11).
        public let payloadHash: String
    }

    /// Verifies a compact serialization against `resolveKey`, which maps the
    /// `kid` to a *registered* device key. Only the explicitly allowed
    /// algorithm is accepted.
    public static func verify(
        compactSerialization: String,
        resolveKey: (ControlID) throws -> DeviceJWK?
    ) throws -> VerifiedCommand {
        let segments = compactSerialization.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { throw JWSError.malformed }
        guard let headerBytes = Base64URL.decode(String(segments[0])),
              let payloadBytes = Base64URL.decode(String(segments[1])),
              let signature = Base64URL.decode(String(segments[2]))
        else { throw JWSError.malformed }
        guard signature.count == 64 else { throw JWSError.badSignature }

        let headerValue = try JSONValue.parse(headerBytes)
        var header = try JSONReader(headerValue)
        let algorithm = try header.string("alg", maxLength: 16)
        guard algorithm == ControlJWS.algorithm else { throw JWSError.unsupportedAlgorithm(algorithm) }
        let typ = try header.string("typ", maxLength: 64)
        guard typ == ControlJWS.type else { throw JWSError.unsupportedType(typ) }
        let keyID = try header.id("kid")
        if let critical = header.members["crit"] {
            let names = critical.arrayValue?.compactMap(\.stringValue) ?? []
            throw JWSError.unknownCriticalHeader(names)
        }
        for member in header.members.keys where forbiddenHeaderMembers.contains(member) {
            throw JWSError.untrustedHeaderMember(member)
        }
        try header.rejectUnknownMembers()

        guard let jwk = try resolveKey(keyID), let publicKey = jwk.publicKey else {
            throw JWSError.keyIdentifierMismatch
        }
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        guard publicKey.isValidSignature(ecdsa, for: signingInput) else { throw JWSError.badSignature }

        let payload = try JSONValue.parse(payloadBytes)
        // The payload must already be canonical, so the digest the broker
        // stores is the digest the device committed to.
        guard try JSONCanonicalization.canonicalize(payload) == payloadBytes else {
            throw JWSError.payloadNotCanonical
        }
        let command = try ControlCommand.decode(payload)
        guard command.envelope.deviceID == keyID else { throw JWSError.keyIdentifierMismatch }
        return VerifiedCommand(
            deviceID: keyID,
            payload: payload,
            command: command,
            compactSerialization: compactSerialization,
            payloadHash: ContentDigest.digest(of: payloadBytes)
        )
    }
}
