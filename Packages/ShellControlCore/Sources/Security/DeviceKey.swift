import Foundation
import CryptoKit
import ShellControlProtocol

/// A public EC P-256 key in JWK form, used at enrollment and by the broker's
/// key registry.
public struct DeviceJWK: Sendable, Hashable {
    public let x: Data
    public let y: Data

    public init(x: Data, y: Data) throws {
        guard x.count == 32, y.count == 32 else {
            throw ValidationError.invalid("jwk", "P-256 coordinates must be 32 bytes")
        }
        self.x = x
        self.y = y
    }

    public init(publicKey: P256.Signing.PublicKey) {
        let raw = publicKey.rawRepresentation
        self.x = raw.prefix(32)
        self.y = raw.suffix(32)
    }

    public var publicKey: P256.Signing.PublicKey? {
        try? P256.Signing.PublicKey(rawRepresentation: x + y)
    }

    public var json: JSONValue {
        .object([
            "kty": "EC",
            "crv": "P-256",
            "x": .string(Base64URL.encode(x)),
            "y": .string(Base64URL.encode(y)),
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let kty = try reader.string("kty", maxLength: 8)
        let crv = try reader.string("crv", maxLength: 16)
        guard kty == "EC", crv == "P-256" else {
            throw ValidationError.unsupported("key type \(kty)/\(crv)")
        }
        guard let x = Base64URL.decode(try reader.string("x", maxLength: 64)),
              let y = Base64URL.decode(try reader.string("y", maxLength: 64))
        else {
            throw ValidationError.invalid("jwk", "coordinates must be base64url")
        }
        // `use`/`alg`/`kid` are accepted but never widen what the key may do.
        try reader.rejectUnknownMembers(allowing: ["use", "alg", "kid"])
        try self.init(x: x, y: y)
    }

    /// RFC 7638 thumbprint, shown on the enrollment confirmation page as the
    /// key fingerprint (spec.watch.md section 5).
    public func thumbprint() throws -> String {
        let canonical = try JSONCanonicalization.canonicalize(.object([
            "crv": "P-256",
            "kty": "EC",
            "x": .string(Base64URL.encode(x)),
            "y": .string(Base64URL.encode(y)),
        ]))
        return Base64URL.encode(Data(SHA256.hash(data: canonical)))
    }

    /// A human-comparable rendering of the thumbprint for the Watch and the
    /// browser confirmation page to display side by side.
    public func displayFingerprint() throws -> String {
        let hex = ContentDigest.sha256Hex(try JSONCanonicalization.canonicalize(json))
        return stride(from: 0, to: 16, by: 4)
            .map { String(hex.dropFirst($0).prefix(4)).uppercased() }
            .joined(separator: "-")
    }
}

/// A device signing key. The private material never leaves its store, so the
/// protocol works with a device-local software key and a hardware-backed store
/// is a drop-in enhancement (spec.watch.md section 5).
public protocol DeviceSigningKey: Sendable {
    var publicJWK: DeviceJWK { get }
    /// Returns the 64-byte `R || S` ES256 signature over `data`.
    func signature(for data: Data) throws -> Data
}

public struct InMemoryDeviceKey: DeviceSigningKey {
    private let privateKey: P256.Signing.PrivateKey

    public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.privateKey = privateKey
    }

    public init(rawRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }
    public var publicJWK: DeviceJWK { DeviceJWK(publicKey: privateKey.publicKey) }

    public func signature(for data: Data) throws -> Data {
        try privateKey.signature(for: data).rawRepresentation
    }
}
