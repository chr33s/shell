//
//  SSHKeyGenerator.swift
//  shell
//
//  Generates SSH key pairs in-app (Ed25519, ML-DSA-44+Ed25519 hybrid,
//  ECDSA P-256/P-384/P-521, RSA 2048/3072/4096). Keys are emitted as
//  unencrypted OpenSSH PEM so they flow through the existing
//  SSHKeyParser → SSHKeyManager import path with no algorithm-specific
//  branching downstream. The emitted PEM must round-trip through
//  SSHKeyParser to the byte-identical public key material the parser
//  fingerprints (Ed25519: the raw public key; ECDSA: the raw x963
//  point; RSA: the mpint payloads of e ‖ n) — import re-derives the
//  fingerprint that key dedup compares, so a malformed blob would
//  silently break dedup.
//

import Foundation
import Crypto
import Citadel
import NIOSSH
import NIOCore
import NIOFoundationCompat
import CCryptoBoringSSL

/// Errors thrown by the on-device key generator. Only the BoringSSL-backed
/// RSA path can fail; Ed25519 and ECDSA use infallible CryptoKit constructors.
enum SSHKeyGenerationError: LocalizedError {
    case rsaAllocationFailed
    case rsaGenerationFailed(bits: Int)

    var errorDescription: String? {
        switch self {
        case .rsaAllocationFailed:
            return String(localized: "Failed to allocate RSA key context. Please try again.", comment: "SSH key generation error: allocation failure")
        case .rsaGenerationFailed(let bits):
            return String(localized: "Failed to generate a \(bits)-bit RSA key. Please try again.", comment: "SSH key generation error: keygen failure")
        }
    }
}

/// Result of SSH key generation
struct GeneratedSSHKey: Sendable {
    /// Private key in OpenSSH PEM format (for storage)
    let privateKeyPEM: String
}

/// User-selectable key types for on-device generation.
///
/// Nonisolated so the generator can read `rsaBits` from a detached task
/// without hopping back to MainActor (the project default isolation).
nonisolated enum GenerateKeyType: String, CaseIterable, Hashable, Sendable {
    case ed25519
    case ecdsaP256
    case ecdsaP384
    case ecdsaP521
    case rsa2048
    case rsa3072
    case rsa4096

    /// Every generatable type in this fork works on every supported OS.
    var isExperimental: Bool { false }
    var isAvailable: Bool { true }

    var displayName: String {
        switch self {
        case .ed25519:   return String(localized: "Ed25519 (recommended)", comment: "SSH key generation: type Ed25519 with recommended tag")
        case .ecdsaP256: return String(localized: "ECDSA P-256", comment: "SSH key generation: type ECDSA P-256")
        case .ecdsaP384: return String(localized: "ECDSA P-384", comment: "SSH key generation: type ECDSA P-384")
        case .ecdsaP521: return String(localized: "ECDSA P-521", comment: "SSH key generation: type ECDSA P-521")
        case .rsa2048:   return String(localized: "RSA 2048", comment: "SSH key generation: type RSA 2048-bit")
        case .rsa3072:   return String(localized: "RSA 3072", comment: "SSH key generation: type RSA 3072-bit")
        case .rsa4096:   return String(localized: "RSA 4096", comment: "SSH key generation: type RSA 4096-bit")
        }
    }

    /// Compact label used on the picker trigger row where horizontal space is tight.
    /// Drops the "(recommended)" tag; the pushed selection list uses the full `displayName`.
    var shortDisplayName: String {
        switch self {
        case .ed25519:   return String(localized: "Ed25519", comment: "SSH key generation: short label for Ed25519")
        case .ecdsaP256: return String(localized: "ECDSA P-256", comment: "SSH key generation: short label for ECDSA P-256")
        case .ecdsaP384: return String(localized: "ECDSA P-384", comment: "SSH key generation: short label for ECDSA P-384")
        case .ecdsaP521: return String(localized: "ECDSA P-521", comment: "SSH key generation: short label for ECDSA P-521")
        case .rsa2048:   return String(localized: "RSA 2048", comment: "SSH key generation: short label for RSA 2048")
        case .rsa3072:   return String(localized: "RSA 3072", comment: "SSH key generation: short label for RSA 3072")
        case .rsa4096:   return String(localized: "RSA 4096", comment: "SSH key generation: short label for RSA 4096")
        }
    }

    var sshKeyType: SSHKey.KeyType {
        switch self {
        case .ed25519:   return .ed25519
        case .ecdsaP256: return .ecdsaP256
        case .ecdsaP384: return .ecdsaP384
        case .ecdsaP521: return .ecdsaP521
        case .rsa2048, .rsa3072, .rsa4096: return .rsa
        }
    }

    var footerDescription: String {
        switch self {
        case .ed25519:
            return String(localized: "Modern elliptic-curve key. Fast, compact, and supported by OpenSSH 6.5+ (2014) and every current SSH server.", comment: "SSH key generation: Ed25519 footer")
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            return String(localized: "NIST elliptic-curve key. Required by some compliance regimes (e.g. FIPS); widely supported by modern SSH servers.", comment: "SSH key generation: ECDSA footer")
        case .rsa2048, .rsa3072, .rsa4096:
            return String(localized: "Classic RSA key. Slowest to generate (especially at 4096 bits) but works with the broadest range of servers, including very old ones.", comment: "SSH key generation: RSA footer")
        }
    }

    /// RSA modulus size in bits. Nil for non-RSA types.
    fileprivate var rsaBits: Int? {
        switch self {
        case .rsa2048: return 2048
        case .rsa3072: return 3072
        case .rsa4096: return 4096
        default: return nil
        }
    }
}

/// Generates SSH key pairs in-app.
///
/// `nonisolated` so callers can hand off generation to a background task
/// (RSA-3072/4096 takes multiple seconds — running on the MainActor would
/// freeze the UI even when invoked from `Task.detached`, because the
/// project-wide default isolation would otherwise hop the static call
/// back to MainActor).
nonisolated enum SSHKeyGenerator {

    // MARK: - Key Generation

    /// Generate a new SSH key pair of the requested type.
    /// - Parameters:
    ///   - type: Algorithm + size to generate.
    ///   - comment: Optional comment embedded in the OpenSSH key blob (typically the key's user-facing name).
    /// - Throws: `SSHKeyGenerationError` only when BoringSSL fails to
    ///   allocate or generate an RSA key — the Ed25519 and ECDSA paths
    ///   never throw.
    static func generate(type: GenerateKeyType, comment: String = "") throws -> GeneratedSSHKey {
        switch type {
        case .ed25519:
            return generateEd25519(comment: comment)
        case .ecdsaP256:
            return generateECDSAP256(comment: comment)
        case .ecdsaP384:
            return generateECDSAP384(comment: comment)
        case .ecdsaP521:
            return generateECDSAP521(comment: comment)
        case .rsa2048, .rsa3072, .rsa4096:
            return try generateRSA(bits: type.rsaBits!, comment: comment)
        }
    }

    /// Generate a new Ed25519 SSH key pair
    /// - Parameter comment: Optional comment to include in the key (typically key name)
    /// - Returns: GeneratedSSHKey containing the private key PEM
    static func generateEd25519(comment: String = "") -> GeneratedSSHKey {
        let privateKey = Curve25519.Signing.PrivateKey()
        let privateKeyPEM = formatPrivateKeyOpenSSH(privateKey, comment: comment)
        return GeneratedSSHKey(privateKeyPEM: privateKeyPEM)
    }

    // MARK: - ECDSA generation

    static func generateECDSAP256(comment: String = "") -> GeneratedSSHKey {
        let privateKey = P256.Signing.PrivateKey()
        return formatECDSA(
            curveName: "nistp256",
            keyTypeString: "ecdsa-sha2-nistp256",
            publicPoint: Data(privateKey.publicKey.x963Representation),
            privateScalar: privateKey.rawRepresentation,
            comment: comment
        )
    }

    static func generateECDSAP384(comment: String = "") -> GeneratedSSHKey {
        let privateKey = P384.Signing.PrivateKey()
        return formatECDSA(
            curveName: "nistp384",
            keyTypeString: "ecdsa-sha2-nistp384",
            publicPoint: Data(privateKey.publicKey.x963Representation),
            privateScalar: privateKey.rawRepresentation,
            comment: comment
        )
    }

    static func generateECDSAP521(comment: String = "") -> GeneratedSSHKey {
        let privateKey = P521.Signing.PrivateKey()
        return formatECDSA(
            curveName: "nistp521",
            keyTypeString: "ecdsa-sha2-nistp521",
            publicPoint: Data(privateKey.publicKey.x963Representation),
            privateScalar: privateKey.rawRepresentation,
            comment: comment
        )
    }

    private static func formatECDSA(
        curveName: String,
        keyTypeString: String,
        publicPoint: Data,
        privateScalar: Data,
        comment: String
    ) -> GeneratedSSHKey {
        let publicKeyBlob = buildECDSAPublicKeyBlob(
            keyTypeString: keyTypeString,
            curveName: curveName,
            publicPoint: publicPoint
        )

        let privateSection = buildECDSAPrivateSection(
            keyTypeString: keyTypeString,
            curveName: curveName,
            publicPoint: publicPoint,
            privateScalar: privateScalar,
            comment: comment
        )

        let privateKeyPEM = wrapOpenSSHPrivateKey(
            publicKeyBlob: publicKeyBlob,
            privateSection: privateSection
        )

        return GeneratedSSHKey(privateKeyPEM: privateKeyPEM)
    }

    // MARK: - RSA generation

    static func generateRSA(bits: Int, comment: String = "") throws -> GeneratedSSHKey {
        let (n, e, d, p, q, iqmp) = try generateRSAKeyMaterial(bits: bits)

        let publicKeyBlob = buildRSAPublicKeyBlob(n: n, e: e)

        let privateSection = buildRSAPrivateSection(
            n: n, e: e, d: d, p: p, q: q, iqmp: iqmp,
            comment: comment
        )

        let privateKeyPEM = wrapOpenSSHPrivateKey(
            publicKeyBlob: publicKeyBlob,
            privateSection: privateSection
        )

        return GeneratedSSHKey(privateKeyPEM: privateKeyPEM)
    }

    /// Generate RSA key material directly with BoringSSL. Citadel's
    /// `Insecure.RSA.PrivateKey(bits:)` runs `g^x mod p` over the DH-14
    /// group, which is not a real RSA keypair — we bypass it.
    /// - Returns: (n, e, d, p, q, iqmp = q^-1 mod p) as big-endian byte data.
    /// - Throws: `SSHKeyGenerationError` if BoringSSL can't allocate or
    ///   generate the key — surfaced through the Generate Key UI rather
    ///   than crashing the app.
    private static func generateRSAKeyMaterial(bits: Int) throws -> (Data, Data, Data, Data, Data, Data) {
        guard let rsa = CCryptoBoringSSL_RSA_new() else {
            throw SSHKeyGenerationError.rsaAllocationFailed
        }
        defer { CCryptoBoringSSL_RSA_free(rsa) }

        guard let eBN = CCryptoBoringSSL_BN_new() else {
            throw SSHKeyGenerationError.rsaAllocationFailed
        }
        defer { CCryptoBoringSSL_BN_free(eBN) }
        CCryptoBoringSSL_BN_set_word(eBN, 65537)

        let ok = CCryptoBoringSSL_RSA_generate_key_ex(rsa, Int32(bits), eBN, nil)
        guard ok == 1 else {
            throw SSHKeyGenerationError.rsaGenerationFailed(bits: bits)
        }

        var nPtr: UnsafePointer<BIGNUM>?
        var ePtr: UnsafePointer<BIGNUM>?
        var dPtr: UnsafePointer<BIGNUM>?
        CCryptoBoringSSL_RSA_get0_key(rsa, &nPtr, &ePtr, &dPtr)

        var pPtr: UnsafePointer<BIGNUM>?
        var qPtr: UnsafePointer<BIGNUM>?
        CCryptoBoringSSL_RSA_get0_factors(rsa, &pPtr, &qPtr)

        var dmp1Ptr: UnsafePointer<BIGNUM>?
        var dmq1Ptr: UnsafePointer<BIGNUM>?
        var iqmpPtr: UnsafePointer<BIGNUM>?
        CCryptoBoringSSL_RSA_get0_crt_params(rsa, &dmp1Ptr, &dmq1Ptr, &iqmpPtr)

        return (
            bignumToData(nPtr),
            bignumToData(ePtr),
            bignumToData(dPtr),
            bignumToData(pPtr),
            bignumToData(qPtr),
            bignumToData(iqmpPtr)
        )
    }

    private static func bignumToData(_ bn: UnsafePointer<BIGNUM>?) -> Data {
        guard let bn = bn else { return Data() }
        let numBytes = (Int(CCryptoBoringSSL_BN_num_bits(bn)) + 7) / 8
        guard numBytes > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: numBytes)
        _ = CCryptoBoringSSL_BN_bn2bin(bn, &bytes)
        return Data(bytes)
    }

    // Deliberately no public-key formatter here. Export goes through
    // `SSHPublicKeyFormatter.authorizedKeysLine(for:comment:)`, which derives
    // the wire-format blob with `SSHPublicKeyBlob` and throws when it cannot.
    // The two functions that used to live here returned
    // "# Public key not available…" for every key they were handed, and the
    // caller pasted that comment line into a server's `authorized_keys`.

    // MARK: - Private Key Formatting (OpenSSH Format)

    /// Format Ed25519 private key in OpenSSH format (unencrypted)
    /// This produces the same format as `ssh-keygen -t ed25519`
    private static func formatPrivateKeyOpenSSH(_ privateKey: Curve25519.Signing.PrivateKey, comment: String) -> String {
        let publicKeyBlob = buildEd25519PublicKeyBlob(privateKey.publicKey)
        let privateSection = buildEd25519PrivateSection(privateKey, comment: comment)
        return wrapOpenSSHPrivateKey(publicKeyBlob: publicKeyBlob, privateSection: privateSection)
    }

    /// Wrap an SSH public-key blob + private section in the `openssh-key-v1`
    /// container and PEM armor. Shared with encrypted-key normalization via
    /// `OpenSSHContainer` so both paths emit byte-identical layout.
    private static func wrapOpenSSHPrivateKey(publicKeyBlob: ByteBuffer, privateSection: ByteBuffer) -> String {
        OpenSSHContainer.wrapUnencryptedPrivateKey(publicKeyBlob: publicKeyBlob, privateSection: privateSection)
    }

    // MARK: - Ed25519 blob/section builders

    private static func buildEd25519PublicKeyBlob(_ publicKey: Curve25519.Signing.PublicKey) -> ByteBuffer {
        var blob = ByteBuffer()
        blob.writeSSHString("ssh-ed25519")

        var pubKeyData = ByteBuffer()
        pubKeyData.writeBytes(publicKey.rawRepresentation)
        blob.writeSSHBuffer(pubKeyData)

        return blob
    }

    private static func buildEd25519PrivateSection(_ privateKey: Curve25519.Signing.PrivateKey, comment: String) -> ByteBuffer {
        var section = ByteBuffer()

        let checkBytes = UInt32.random(in: 0...UInt32.max)
        section.writeInteger(checkBytes)
        section.writeInteger(checkBytes)

        section.writeSSHString("ssh-ed25519")

        var pubKeyBuffer = ByteBuffer()
        pubKeyBuffer.writeBytes(privateKey.publicKey.rawRepresentation)
        section.writeSSHBuffer(pubKeyBuffer)

        // Ed25519 "expanded" private key: 32-byte seed || 32-byte pubkey
        var privKeyBuffer = ByteBuffer()
        privKeyBuffer.writeBytes(privateKey.rawRepresentation)
        privKeyBuffer.writeBytes(privateKey.publicKey.rawRepresentation)
        section.writeSSHBuffer(privKeyBuffer)

        section.writeSSHString(comment)
        return section
    }

    // MARK: - ECDSA blob/section builders

    private static func buildECDSAPublicKeyBlob(keyTypeString: String, curveName: String, publicPoint: Data) -> ByteBuffer {
        var blob = ByteBuffer()
        blob.writeSSHString(keyTypeString)
        blob.writeSSHString(curveName)

        var pointBuffer = ByteBuffer()
        pointBuffer.writeBytes(publicPoint)
        blob.writeSSHBuffer(pointBuffer)
        return blob
    }

    private static func buildECDSAPrivateSection(
        keyTypeString: String,
        curveName: String,
        publicPoint: Data,
        privateScalar: Data,
        comment: String
    ) -> ByteBuffer {
        var section = ByteBuffer()

        let checkBytes = UInt32.random(in: 0...UInt32.max)
        section.writeInteger(checkBytes)
        section.writeInteger(checkBytes)

        section.writeSSHString(keyTypeString)
        section.writeSSHString(curveName)

        var pointBuffer = ByteBuffer()
        pointBuffer.writeBytes(publicPoint)
        section.writeSSHBuffer(pointBuffer)

        // OpenSSH encodes the scalar as an mpint (signed-magnitude with
        // leading 0x00 when the high bit is set). Anything else gets
        // rejected by `ssh-keygen` and other OpenSSH-compliant parsers.
        section.writeSSHMPInt(privateScalar)

        section.writeSSHString(comment)
        return section
    }

    // MARK: - RSA blob/section builders

    private static func buildRSAPublicKeyBlob(n: Data, e: Data) -> ByteBuffer {
        var blob = ByteBuffer()
        blob.writeSSHString("ssh-rsa")
        blob.writeSSHMPInt(e)
        blob.writeSSHMPInt(n)
        return blob
    }

    private static func buildRSAPrivateSection(
        n: Data, e: Data, d: Data, p: Data, q: Data, iqmp: Data,
        comment: String
    ) -> ByteBuffer {
        var section = ByteBuffer()

        let checkBytes = UInt32.random(in: 0...UInt32.max)
        section.writeInteger(checkBytes)
        section.writeInteger(checkBytes)

        section.writeSSHString("ssh-rsa")
        // OpenSSH private-section field order for RSA: n, e, d, iqmp, p, q
        section.writeSSHMPInt(n)
        section.writeSSHMPInt(e)
        section.writeSSHMPInt(d)
        section.writeSSHMPInt(iqmp)
        section.writeSSHMPInt(p)
        section.writeSSHMPInt(q)

        section.writeSSHString(comment)
        return section
    }
}
