import Foundation
import CryptoKit
import ShellControlProtocol

/// The Mac's long-lived Shell Control origin identity.
///
/// The origin key is identity; a Tailscale URL is only routing. Pairing pins
/// `origin_id` plus this public key, so a route change never becomes a trust
/// change (spec.iphone-gateway.md sections 7 and 35).
public struct OriginIdentity: Sendable, Hashable {
    public let originID: ControlID
    public let publicJWK: DeviceJWK

    public init(originID: ControlID, publicJWK: DeviceJWK) {
        self.originID = originID
        self.publicJWK = publicJWK
    }

    /// `SHA256:<hex>` over the canonical public JWK: what setup prints and the
    /// phone shows for side-by-side comparison.
    public var fingerprint: String {
        OriginIdentity.fingerprint(of: publicJWK)
    }

    public static func fingerprint(of jwk: DeviceJWK) -> String {
        let canonical = (try? JSONCanonicalization.canonicalize(jwk.json)) ?? Data()
        return "SHA256:\(ContentDigest.sha256Hex(canonical))"
    }
}

/// The origin's private signing key. It is stored only on the Mac.
public struct OriginSigningKey: DeviceSigningKey {
    private let privateKey: P256.Signing.PrivateKey

    public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.privateKey = privateKey
    }

    public init(pemRepresentation: String) throws {
        privateKey = try P256.Signing.PrivateKey(pemRepresentation: pemRepresentation)
    }

    public var pemRepresentation: String { privateKey.pemRepresentation }
    public var publicJWK: DeviceJWK { DeviceJWK(publicKey: privateKey.publicKey) }

    public func signature(for data: Data) throws -> Data {
        try privateKey.signature(for: data).rawRepresentation
    }
}

/// A flat JSON document signed by one key: the signature is ES256 (`R || S`,
/// base64url) over the RFC 8785 canonical form of every other member. The
/// document's `type` member is the domain separator, so a route update can
/// never be replayed as an origin proof and vice versa.
public enum SignedDocument {
    public enum SignatureError: Error, Equatable, Sendable {
        case missingSignature
        case badSignature
        case unexpectedType(String)
    }

    public static let signatureMember = "signature"

    public static func sign(_ members: [String: JSONValue], key: some DeviceSigningKey) throws -> JSONValue {
        var unsigned = members
        unsigned.removeValue(forKey: signatureMember)
        let bytes = try JSONCanonicalization.canonicalize(.object(unsigned))
        let signature = try key.signature(for: bytes)
        guard signature.count == 64 else { throw SignatureError.badSignature }
        unsigned[signatureMember] = .string(Base64URL.encode(signature))
        return .object(unsigned)
    }

    /// Verifies `document` under `publicKey` and requires its `type` member to
    /// equal `type`. Returns the members without the signature.
    @discardableResult
    public static func verify(_ document: JSONValue, type: String, publicKey: DeviceJWK) throws -> [String: JSONValue] {
        guard var members = document.objectValue else { throw JSONReader.ReadError.notAnObject }
        guard let encoded = members.removeValue(forKey: signatureMember)?.stringValue,
              let signature = Base64URL.decode(encoded), signature.count == 64
        else { throw SignatureError.missingSignature }
        guard let actual = members["type"]?.stringValue else { throw SignatureError.unexpectedType("") }
        guard actual == type else { throw SignatureError.unexpectedType(actual) }
        let bytes = try JSONCanonicalization.canonicalize(.object(members))
        guard let key = publicKey.publicKey,
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              key.isValidSignature(ecdsa, for: bytes)
        else { throw SignatureError.badSignature }
        return members
    }
}
