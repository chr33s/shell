import Foundation
import NIOCore
import NIOSSH
import Crypto
import CMLDSA44

/// Hybrid post-quantum user/host key algorithm: ssh-mldsa44-ed25519
///
/// Implements the composite ML-DSA-44 + Ed25519 signature scheme added in
/// OpenSSH 10.4 (draft-miller-sshm-mldsa44-ed25519-composite-sigs-00, built on
/// draft-ietf-lamps-pq-composite-sigs). Both halves sign a derived message
/// M' = domain || label || len(ctx) || ctx || SHA-512(message); the ML-DSA half
/// additionally uses the label as its FIPS 204 context string. A signature is
/// valid only if BOTH halves verify.
///
/// Wire format (NIOSSH handles the algorithm name prefix wrapping):
/// - Public key: one SSH string, mldsaPK(1312) || ed25519PK(32) = 1344 bytes
/// - Signature: one SSH string, mldsaSig(2420) || ed25519Sig(64) = 2484 bytes
///
/// The private key is two independent 32-byte seeds (ML-DSA-44 ξ and RFC 8032
/// Ed25519 seed); the expanded ML-DSA key is re-derived on every signing
/// operation, matching OpenSSH. ML-DSA-44 comes from the BoringSSL vendored in
/// swift-crypto — no OS availability gate needed.
/// Canonical OpenSSH hybrid format. Existing vendored keys must retain their
/// original wire identity; use `LegacyMLDSA44Ed25519SSH` to read/use those keys.
public typealias MLDSA44Ed25519SSH = MLDSA44Ed25519Algorithm<MLDSA44Ed25519Format>
public typealias LegacyMLDSA44Ed25519SSH = MLDSA44Ed25519Algorithm<LegacyMLDSA44Ed25519Format>

public protocol MLDSA44Ed25519WireFormat {
    static var algorithmName: String { get }
    static var certifiedAlgorithmName: String { get }
    static var advertisedByDefault: Bool { get }
}

public enum MLDSA44Ed25519Format: MLDSA44Ed25519WireFormat {
    public static let algorithmName = "ssh-mldsa44-ed25519"
    public static let certifiedAlgorithmName = "ssh-mldsa44-ed25519-cert"
    public static let advertisedByDefault = true
}

public enum LegacyMLDSA44Ed25519Format: MLDSA44Ed25519WireFormat {
    public static let algorithmName = "ssh-mldsa44-ed25519@openssh.com"
    public static let certifiedAlgorithmName = "ssh-mldsa44-ed25519-cert-v01@openssh.com"
    public static let advertisedByDefault = false
}

public enum MLDSA44Ed25519Algorithm<Format: MLDSA44Ed25519WireFormat> {

    public static var algorithmName: String { Format.algorithmName }
    public static var certifiedAlgorithmName: String { Format.certifiedAlgorithmName }

    static var mldsaPublicKeyLength: Int { 1312 }
    static var mldsaSignatureLength: Int { 2420 }
    static var mldsaSeedLength: Int { 32 }
    static var ed25519PublicKeyLength: Int { 32 }
    static var ed25519SignatureLength: Int { 64 }
    static var ed25519SeedLength: Int { 32 }
    static var publicKeyLength: Int { mldsaPublicKeyLength + ed25519PublicKeyLength } // 1344
    static var signatureLength: Int { mldsaSignatureLength + ed25519SignatureLength } // 2484
    static var seedRepresentationLength: Int { mldsaSeedLength + ed25519SeedLength } // 64

    /// Fixed 32-byte domain separator prepended to every composite message.
    static var compositeDomain: Data { Data("CompositeAlgorithmSignatures2025".utf8) }
    /// Algorithm label: second component of M' and the FIPS 204 context for the
    /// ML-DSA half.
    static var compositeLabel: Data { Data("COMPSIG-MLDSA44-Ed25519-SHA512".utf8) }

    /// M' = domain || label || uint8(ctxlen) || ctx || SHA-512(message).
    /// SSH always signs with an empty application context (M' = 127 bytes);
    /// the parameter exists for the draft's test vectors.
    static func compositeMessage<D: DataProtocol>(for data: D, context: Data = Data()) -> Data {
        precondition(context.count <= 255, "composite context must fit in one byte")
        var hasher = SHA512()
        hasher.update(data: data)
        let digest = hasher.finalize()

        var mPrime = Data(capacity: compositeDomain.count + compositeLabel.count + 1 + context.count + SHA512.byteCount)
        mPrime.append(compositeDomain)
        mPrime.append(compositeLabel)
        mPrime.append(UInt8(context.count))
        mPrime.append(context)
        mPrime.append(contentsOf: digest)
        return mPrime
    }

    // MARK: - Public key

    public struct PublicKey: NIOSSHPublicKeyProtocol, Sendable {
        public static var publicKeyPrefix: String { MLDSA44Ed25519Algorithm<Format>.algorithmName }
        public static var certifiedKeyPrefix: String? { MLDSA44Ed25519Algorithm<Format>.certifiedAlgorithmName }

        public static var defaultHostKeyAlgorithms: [String]? {
            Format.advertisedByDefault ? [Format.algorithmName] : []
        }
        public static var supportsHostCertificates: Bool { true }

        /// mldsaPK(1312) || ed25519PK(32)
        public let rawRepresentation: Data

        public init(rawRepresentation: Data) throws {
            guard rawRepresentation.count == MLDSA44Ed25519Algorithm<Format>.publicKeyLength else {
                throw MLDSAError(message: "Invalid ML-DSA-44+Ed25519 public key length \(rawRepresentation.count)")
            }
            self.rawRepresentation = Data(rawRepresentation)
        }

        public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
            guard let signature = signature as? Signature else {
                return false
            }
            return isValidCompositeSignature(signature.rawRepresentation, for: data, context: Data())
        }

        /// Context-capable core used by the public path (empty context) and the
        /// draft's KAT vectors (non-empty context).
        func isValidCompositeSignature<D: DataProtocol>(_ signature: Data, for data: D, context: Data) -> Bool {
            guard signature.count == MLDSA44Ed25519Algorithm<Format>.signatureLength else {
                return false
            }
            let mPrime = MLDSA44Ed25519Algorithm<Format>.compositeMessage(for: data, context: context)

            let sig = Data(signature)
            let mldsaSig = sig.subdata(in: 0..<MLDSA44Ed25519Algorithm<Format>.mldsaSignatureLength)
            let ed25519Sig = sig.subdata(in: MLDSA44Ed25519Algorithm<Format>.mldsaSignatureLength..<MLDSA44Ed25519Algorithm<Format>.signatureLength)
            let mldsaPub = rawRepresentation.subdata(in: 0..<MLDSA44Ed25519Algorithm<Format>.mldsaPublicKeyLength)
            let ed25519Pub = rawRepresentation.subdata(in: MLDSA44Ed25519Algorithm<Format>.mldsaPublicKeyLength..<MLDSA44Ed25519Algorithm<Format>.publicKeyLength)

            // Both halves must verify: ML-DSA with the label as FIPS 204
            // context, Ed25519 plain over M'.
            guard MLDSA44Boring.verify(
                mldsaSig,
                message: mPrime,
                publicKey: mldsaPub,
                context: MLDSA44Ed25519Algorithm<Format>.compositeLabel
            ) else {
                return false
            }
            guard let edKey = try? Curve25519.Signing.PublicKey(rawRepresentation: ed25519Pub) else {
                return false
            }
            return edKey.isValidSignature(ed25519Sig, for: mPrime)
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeSSHString(rawRepresentation)
        }

        public static func read(from buffer: inout ByteBuffer) throws -> PublicKey {
            guard let keyBuffer = buffer.readSSHBuffer(),
                  let keyData = keyBuffer.getData(at: 0, length: keyBuffer.readableBytes) else {
                throw MLDSAError(message: "Invalid ML-DSA-44+Ed25519 public key format")
            }
            return try PublicKey(rawRepresentation: keyData)
        }
    }

    // MARK: - Signature

    public struct Signature: NIOSSHSignatureProtocol, Sendable {
        public static var signaturePrefix: String { MLDSA44Ed25519Algorithm<Format>.algorithmName }

        /// mldsaSig(2420) || ed25519Sig(64)
        public let rawRepresentation: Data

        public init(rawRepresentation: Data) throws {
            guard rawRepresentation.count == MLDSA44Ed25519Algorithm<Format>.signatureLength else {
                throw MLDSAError(message: "Invalid ML-DSA-44+Ed25519 signature length \(rawRepresentation.count)")
            }
            self.rawRepresentation = Data(rawRepresentation)
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeSSHString(rawRepresentation)
        }

        public static func read(from buffer: inout ByteBuffer) throws -> Signature {
            guard let sigBuffer = buffer.readSSHBuffer(),
                  let sigData = sigBuffer.getData(at: 0, length: sigBuffer.readableBytes) else {
                throw MLDSAError(message: "Invalid ML-DSA-44+Ed25519 signature format")
            }
            return try Signature(rawRepresentation: sigData)
        }
    }

    // MARK: - Private key

    public struct PrivateKey: NIOSSHPrivateKeyProtocol, Sendable {
        public static var keyPrefix: String { MLDSA44Ed25519Algorithm<Format>.algorithmName }

        /// 32-byte FIPS 204 keygen seed ξ.
        public let mldsaSeed: Data
        /// 32-byte RFC 8032 Ed25519 seed.
        public let ed25519Seed: Data
        /// Derived at init so `publicKey` and serialization never re-expand.
        public let compositePublicKey: PublicKey

        public var publicKey: NIOSSHPublicKeyProtocol { compositePublicKey }

        /// The 64-byte `sk` field of the OpenSSH private key format:
        /// mldsaSeed(32) || ed25519Seed(32).
        public var seedRepresentation: Data { mldsaSeed + ed25519Seed }

        /// Generate a new key pair from two fresh random seeds.
        public init() throws {
            let (mldsaPublicKey, mldsaSeed) = try MLDSA44Boring.generateKeyPair()
            let ed25519Key = Curve25519.Signing.PrivateKey()
            self.mldsaSeed = mldsaSeed
            self.ed25519Seed = ed25519Key.rawRepresentation
            self.compositePublicKey = try PublicKey(
                rawRepresentation: mldsaPublicKey + ed25519Key.publicKey.rawRepresentation
            )
        }

        /// Rebuild a key pair from the serialized 64-byte seed pair.
        public init(seedRepresentation: Data) throws {
            guard seedRepresentation.count == MLDSA44Ed25519Algorithm<Format>.seedRepresentationLength else {
                throw MLDSAError(message: "Invalid ML-DSA-44+Ed25519 private key length \(seedRepresentation.count)")
            }
            let seeds = Data(seedRepresentation)
            let mldsaSeed = seeds.subdata(in: 0..<MLDSA44Ed25519Algorithm<Format>.mldsaSeedLength)
            let ed25519Seed = seeds.subdata(in: MLDSA44Ed25519Algorithm<Format>.mldsaSeedLength..<MLDSA44Ed25519Algorithm<Format>.seedRepresentationLength)

            let mldsaPublicKey = try MLDSA44Boring.publicKeyFromSeed(mldsaSeed)
            let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: ed25519Seed)

            self.mldsaSeed = mldsaSeed
            self.ed25519Seed = ed25519Seed
            self.compositePublicKey = try PublicKey(
                rawRepresentation: mldsaPublicKey + ed25519Key.publicKey.rawRepresentation
            )
        }

        public func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            try Signature(rawRepresentation: compositeSignature(for: data, context: Data()))
        }

        /// Context-capable core; SSH always signs with an empty context.
        func compositeSignature<D: DataProtocol>(for data: D, context: Data) throws -> Data {
            let mPrime = MLDSA44Ed25519Algorithm<Format>.compositeMessage(for: data, context: context)
            let mldsaSig = try MLDSA44Boring.sign(
                mPrime,
                seed: mldsaSeed,
                context: MLDSA44Ed25519Algorithm<Format>.compositeLabel
            )
            let ed25519Sig = try Curve25519.Signing.PrivateKey(rawRepresentation: ed25519Seed)
                .signature(for: mPrime)
            return mldsaSig + ed25519Sig
        }
    }
}

// MARK: - Pure ML-DSA-44 (ssh-mldsa44)

/// Pure (non-hybrid) ML-DSA-44 user/host keys, matching the OQS OpenSSH /
/// draft-rpe-ssh-mldsa naming used by MLDSA65SSH/MLDSA87SSH. Signing is pure
/// FIPS 204 ML-DSA with an empty context. BoringSSL-backed via CMLDSA44, so
/// unlike the CryptoKit-backed 65/87 types there is no OS availability gate.
///
/// Wire format: public key = SSH string of the raw 1312-byte FIPS 204 key;
/// signature = SSH string of the raw 2420-byte signature. The private key is
/// the 32-byte seed.
public enum MLDSA44SSH {

    public static let algorithmName = "ssh-mldsa44"

    public struct PublicKey: NIOSSHPublicKeyProtocol, Sendable {
        public static let publicKeyPrefix = MLDSA44SSH.algorithmName
        public static var defaultHostKeyAlgorithms: [String]? { [] }

        public let rawRepresentation: Data

        public init(rawRepresentation: Data) throws {
            guard rawRepresentation.count == MLDSA44Ed25519SSH.mldsaPublicKeyLength else {
                throw MLDSAError(message: "Invalid ML-DSA-44 public key length \(rawRepresentation.count)")
            }
            self.rawRepresentation = Data(rawRepresentation)
        }

        public func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
            guard let signature = signature as? Signature else {
                return false
            }
            return MLDSA44Boring.verify(
                signature.rawRepresentation,
                message: Data(data),
                publicKey: rawRepresentation,
                context: Data()
            )
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeSSHString(rawRepresentation)
        }

        public static func read(from buffer: inout ByteBuffer) throws -> PublicKey {
            guard let keyBuffer = buffer.readSSHBuffer(),
                  let keyData = keyBuffer.getData(at: 0, length: keyBuffer.readableBytes) else {
                throw MLDSAError(message: "Invalid ML-DSA-44 public key format")
            }
            return try PublicKey(rawRepresentation: keyData)
        }
    }

    public struct Signature: NIOSSHSignatureProtocol, Sendable {
        public static let signaturePrefix = MLDSA44SSH.algorithmName

        public let rawRepresentation: Data

        public init(rawRepresentation: Data) throws {
            guard rawRepresentation.count == MLDSA44Ed25519SSH.mldsaSignatureLength else {
                throw MLDSAError(message: "Invalid ML-DSA-44 signature length \(rawRepresentation.count)")
            }
            self.rawRepresentation = Data(rawRepresentation)
        }

        public func write(to buffer: inout ByteBuffer) -> Int {
            buffer.writeSSHString(rawRepresentation)
        }

        public static func read(from buffer: inout ByteBuffer) throws -> Signature {
            guard let sigBuffer = buffer.readSSHBuffer(),
                  let sigData = sigBuffer.getData(at: 0, length: sigBuffer.readableBytes) else {
                throw MLDSAError(message: "Invalid ML-DSA-44 signature format")
            }
            return try Signature(rawRepresentation: sigData)
        }
    }

    public struct PrivateKey: NIOSSHPrivateKeyProtocol, Sendable {
        public static let keyPrefix = MLDSA44SSH.algorithmName

        /// 32-byte FIPS 204 keygen seed ξ — the durable representation.
        public let seedRepresentation: Data
        public let mldsaPublicKey: PublicKey

        public var publicKey: NIOSSHPublicKeyProtocol { mldsaPublicKey }

        public init() throws {
            let (publicKey, seed) = try MLDSA44Boring.generateKeyPair()
            self.seedRepresentation = seed
            self.mldsaPublicKey = try PublicKey(rawRepresentation: publicKey)
        }

        public init(seedRepresentation: Data) throws {
            guard seedRepresentation.count == MLDSA44Ed25519SSH.mldsaSeedLength else {
                throw MLDSAError(message: "Invalid ML-DSA-44 seed length \(seedRepresentation.count)")
            }
            self.seedRepresentation = Data(seedRepresentation)
            self.mldsaPublicKey = try PublicKey(rawRepresentation: MLDSA44Boring.publicKeyFromSeed(self.seedRepresentation))
        }

        public func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
            try Signature(rawRepresentation: MLDSA44Boring.sign(Data(data), seed: seedRepresentation, context: Data()))
        }
    }
}

// MARK: - BoringSSL ML-DSA-44 wrapper

/// Thin wrapper over the CMLDSA44 shim, which bridges to the ML-DSA-44
/// implementation vendored in swift-crypto's BoringSSL. The expanded private
/// key only ever exists inside a single shim call — the durable representation
/// is always the 32-byte seed, matching OpenSSH.
private enum MLDSA44Boring {

    /// Generate a fresh key pair. Returns the encoded public key (1312 bytes)
    /// and the seed (32 bytes) it can be re-derived from.
    static func generateKeyPair() throws -> (publicKey: Data, seed: Data) {
        var publicKey = [UInt8](repeating: 0, count: MLDSA44Ed25519SSH.mldsaPublicKeyLength)
        var seed = [UInt8](repeating: 0, count: MLDSA44Ed25519SSH.mldsaSeedLength)
        guard cmldsa44_generate_key(&publicKey, &seed) == 1 else {
            throw MLDSAError(message: "ML-DSA-44 key generation failed")
        }
        defer { seed.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return (Data(publicKey), Data(seed))
    }

    /// Re-derive the encoded public key (1312 bytes) from a 32-byte seed.
    static func publicKeyFromSeed(_ seed: Data) throws -> Data {
        guard seed.count == MLDSA44Ed25519SSH.mldsaSeedLength else {
            throw MLDSAError(message: "Invalid ML-DSA-44 seed length \(seed.count)")
        }
        var publicKey = [UInt8](repeating: 0, count: MLDSA44Ed25519SSH.mldsaPublicKeyLength)
        let ok = seed.withUnsafeBytes { raw in
            cmldsa44_public_from_seed(&publicKey, raw.baseAddress?.assumingMemoryBound(to: UInt8.self))
        }
        guard ok == 1 else {
            throw MLDSAError(message: "ML-DSA-44 public key derivation failed")
        }
        return Data(publicKey)
    }

    /// FIPS 204 pure ML-DSA.Sign (hedged) over `message` with `context`.
    static func sign(_ message: Data, seed: Data, context: Data) throws -> Data {
        var signature = [UInt8](repeating: 0, count: MLDSA44Ed25519SSH.mldsaSignatureLength)
        let ok = seed.withUnsafeBytes { raw in
            message.withUnsafeBytes { msg in
                context.withUnsafeBytes { ctx in
                    cmldsa44_sign(
                        &signature,
                        raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        msg.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        msg.count,
                        ctx.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        ctx.count
                    )
                }
            }
        }
        guard ok == 1 else {
            throw MLDSAError(message: "ML-DSA-44 signing failed")
        }
        return Data(signature)
    }

    /// FIPS 204 pure ML-DSA.Verify over `message` with `context`.
    static func verify(_ signature: Data, message: Data, publicKey: Data, context: Data) -> Bool {
        guard signature.count == MLDSA44Ed25519SSH.mldsaSignatureLength,
              publicKey.count == MLDSA44Ed25519SSH.mldsaPublicKeyLength else {
            return false
        }
        return publicKey.withUnsafeBytes { pub in
            signature.withUnsafeBytes { sig in
                message.withUnsafeBytes { msg in
                    context.withUnsafeBytes { ctx in
                        cmldsa44_verify(
                            pub.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            sig.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            sig.count,
                            msg.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            msg.count,
                            ctx.baseAddress?.assumingMemoryBound(to: UInt8.self),
                            ctx.count
                        ) == 1
                    }
                }
            }
        }
    }
}
