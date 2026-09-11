import Foundation
import Crypto
import NIOCore
@testable import NIOSSH
import XCTest
@testable import Citadel

/// Tests for the ssh-mldsa44-ed25519@openssh.com composite scheme against the
/// official vectors shipped with OpenSSH 10.4:
/// - draft-ietf-lamps-pq-composite-sigs.json (composite KAT; seed layout,
///   M' construction, both signature halves)
/// - mldsa44_ed25519_1{,.pub,-cert.pub} (SSH-level key files)
///
/// Signing is randomized (hedged), so produced signatures can only be
/// round-trip verified, never byte-compared against the KAT.
final class MLDSA44Ed25519Tests: XCTestCase {

    struct CompositeKAT: Decodable {
        let m: String
        let ctx: String
        let pk: String
        let sk: String
        let s: String
        let sWithContext: String
    }

    static func loadKAT() throws -> (m: Data, ctx: Data, pk: Data, sk: Data, s: Data, sWithContext: Data) {
        let url = Bundle.module.url(
            forResource: "draft-ietf-lamps-pq-composite-sigs",
            withExtension: "json",
            subdirectory: "TestData"
        )!
        let kat = try JSONDecoder().decode(CompositeKAT.self, from: Data(contentsOf: url))
        func b64(_ s: String) -> Data { Data(base64Encoded: s)! }
        return (b64(kat.m), b64(kat.ctx), b64(kat.pk), b64(kat.sk), b64(kat.s), b64(kat.sWithContext))
    }

    static func loadTestData(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "TestData")!
        return try String(contentsOf: url, encoding: .utf8)
    }

    override class func setUp() {
        super.setUp()
        SSHAlgorithms.all.registerPublicKeyAlgorithms()
    }

    // MARK: - Composite KAT

    func testSeedRepresentationDerivesKATPublicKey() throws {
        let kat = try Self.loadKAT()
        let key = try MLDSA44Ed25519SSH.PrivateKey(seedRepresentation: kat.sk)
        XCTAssertEqual(key.compositePublicKey.rawRepresentation, kat.pk)
        XCTAssertEqual(key.seedRepresentation, kat.sk)
    }

    func testKATSignatureVerifies() throws {
        let kat = try Self.loadKAT()
        let publicKey = try MLDSA44Ed25519SSH.PublicKey(rawRepresentation: kat.pk)
        let signature = try MLDSA44Ed25519SSH.Signature(rawRepresentation: kat.s)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: kat.m))
    }

    func testKATSignatureWithContextVerifies() throws {
        let kat = try Self.loadKAT()
        let publicKey = try MLDSA44Ed25519SSH.PublicKey(rawRepresentation: kat.pk)
        XCTAssertTrue(publicKey.isValidCompositeSignature(kat.sWithContext, for: kat.m, context: kat.ctx))
        // Context mismatch must fail both ways
        XCTAssertFalse(publicKey.isValidCompositeSignature(kat.sWithContext, for: kat.m, context: Data()))
        XCTAssertFalse(publicKey.isValidCompositeSignature(kat.s, for: kat.m, context: kat.ctx))
    }

    func testKATSigningRoundTrip() throws {
        let kat = try Self.loadKAT()
        let key = try MLDSA44Ed25519SSH.PrivateKey(seedRepresentation: kat.sk)
        let publicKey = try MLDSA44Ed25519SSH.PublicKey(rawRepresentation: kat.pk)

        let signature = try key.signature(for: kat.m)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: kat.m))

        let withContext = try key.compositeSignature(for: kat.m, context: kat.ctx)
        XCTAssertTrue(publicKey.isValidCompositeSignature(withContext, for: kat.m, context: kat.ctx))
    }

    // MARK: - Fresh keys, negatives

    func testGeneratedKeySignAndVerify() throws {
        let key = try MLDSA44Ed25519SSH.PrivateKey()
        let message = Data("the quick brown fox".utf8)
        let signature = try key.signature(for: message) as! MLDSA44Ed25519SSH.Signature
        XCTAssertEqual(signature.rawRepresentation.count, 2484)
        XCTAssertTrue(key.compositePublicKey.isValidSignature(signature, for: message))

        // Round-trip through the 64-byte seed representation
        let restored = try MLDSA44Ed25519SSH.PrivateKey(seedRepresentation: key.seedRepresentation)
        XCTAssertEqual(restored.compositePublicKey.rawRepresentation, key.compositePublicKey.rawRepresentation)
        XCTAssertTrue(restored.compositePublicKey.isValidSignature(signature, for: message))
    }

    func testTamperedSignatureHalvesFail() throws {
        let key = try MLDSA44Ed25519SSH.PrivateKey()
        let message = Data("tamper test".utf8)
        let signature = try key.signature(for: message) as! MLDSA44Ed25519SSH.Signature
        let publicKey = key.compositePublicKey

        // Flip a byte in the ML-DSA half
        var mldsaTampered = signature.rawRepresentation
        mldsaTampered[100] ^= 0xff
        let badMLDSA = try MLDSA44Ed25519SSH.Signature(rawRepresentation: mldsaTampered)
        XCTAssertFalse(publicKey.isValidSignature(badMLDSA, for: message))

        // Flip a byte in the Ed25519 half — proves BOTH halves are checked
        var edTampered = signature.rawRepresentation
        edTampered[2450] ^= 0xff
        let badEd = try MLDSA44Ed25519SSH.Signature(rawRepresentation: edTampered)
        XCTAssertFalse(publicKey.isValidSignature(badEd, for: message))

        // Tampered message
        XCTAssertFalse(publicKey.isValidSignature(signature, for: Data("tamper test!".utf8)))
    }

    func testInvalidLengthsRejected() throws {
        XCTAssertThrowsError(try MLDSA44Ed25519SSH.PublicKey(rawRepresentation: Data(count: 1343)))
        XCTAssertThrowsError(try MLDSA44Ed25519SSH.Signature(rawRepresentation: Data(count: 2483)))
        XCTAssertThrowsError(try MLDSA44Ed25519SSH.PrivateKey(seedRepresentation: Data(count: 63)))
    }

    // MARK: - Pure ML-DSA types

    func testPureMLDSA44SeedRoundTripAndSignVerify() throws {
        let key = try MLDSA44SSH.PrivateKey()
        XCTAssertEqual(key.seedRepresentation.count, 32)
        XCTAssertEqual(key.mldsaPublicKey.rawRepresentation.count, 1312)

        let restored = try MLDSA44SSH.PrivateKey(seedRepresentation: key.seedRepresentation)
        XCTAssertEqual(restored.mldsaPublicKey.rawRepresentation, key.mldsaPublicKey.rawRepresentation)

        let message = Data("pure mldsa44".utf8)
        let signature = try key.signature(for: message) as! MLDSA44SSH.Signature
        XCTAssertEqual(signature.rawRepresentation.count, 2420)
        XCTAssertTrue(key.mldsaPublicKey.isValidSignature(signature, for: message))
        XCTAssertTrue(restored.mldsaPublicKey.isValidSignature(signature, for: message))

        var tampered = signature.rawRepresentation
        tampered[7] ^= 0xff
        let bad = try MLDSA44SSH.Signature(rawRepresentation: tampered)
        XCTAssertFalse(key.mldsaPublicKey.isValidSignature(bad, for: message))
        XCTAssertFalse(key.mldsaPublicKey.isValidSignature(signature, for: Data("pure mldsa44!".utf8)))

        XCTAssertThrowsError(try MLDSA44SSH.PrivateKey(seedRepresentation: Data(count: 31)))
        XCTAssertThrowsError(try MLDSA44SSH.PublicKey(rawRepresentation: Data(count: 1311)))
    }

    func testPureMLDSA65SeedRoundTripAndSignVerify() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("CryptoKit MLDSA requires macOS 26") }
        let key = try MLDSA65SSH.PrivateKey()
        XCTAssertEqual(key.seedRepresentation.count, 32)
        XCTAssertEqual(key.mldsaPublicKey.rawRepresentation.count, 1952)

        let restored = try MLDSA65SSH.PrivateKey(seedRepresentation: key.seedRepresentation)
        XCTAssertEqual(restored.mldsaPublicKey.rawRepresentation, key.mldsaPublicKey.rawRepresentation)

        let message = Data("pure mldsa65".utf8)
        let signature = try key.signature(for: message) as! MLDSA65SSH.Signature
        XCTAssertEqual(signature.rawRepresentation.count, 3309)
        XCTAssertTrue(key.mldsaPublicKey.isValidSignature(signature, for: message))
        XCTAssertFalse(key.mldsaPublicKey.isValidSignature(signature, for: Data("nope".utf8)))
    }

    func testPureMLDSA87SeedRoundTripAndSignVerify() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("CryptoKit MLDSA requires macOS 26") }
        let key = try MLDSA87SSH.PrivateKey()
        XCTAssertEqual(key.seedRepresentation.count, 32)
        XCTAssertEqual(key.mldsaPublicKey.rawRepresentation.count, 2592)

        let restored = try MLDSA87SSH.PrivateKey(seedRepresentation: key.seedRepresentation)
        XCTAssertEqual(restored.mldsaPublicKey.rawRepresentation, key.mldsaPublicKey.rawRepresentation)

        let message = Data("pure mldsa87".utf8)
        let signature = try key.signature(for: message) as! MLDSA87SSH.Signature
        XCTAssertEqual(signature.rawRepresentation.count, 4627)
        XCTAssertTrue(key.mldsaPublicKey.isValidSignature(signature, for: message))
        XCTAssertFalse(key.mldsaPublicKey.isValidSignature(signature, for: Data("nope".utf8)))
    }

    // MARK: - SSH-level files from openssh-portable

    func testParseOpenSSHPublicKeyFile() throws {
        let line = try Self.loadTestData("mldsa44_ed25519_1.pub")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ")
        XCTAssertEqual(String(parts[0]), LegacyMLDSA44Ed25519SSH.algorithmName)

        let blob = Data(base64Encoded: String(parts[1]))!
        var buffer = ByteBuffer(data: blob)
        let name = buffer.readSSHBuffer().map { String(decoding: $0.readableBytesView, as: UTF8.self) }
        XCTAssertEqual(name, LegacyMLDSA44Ed25519SSH.algorithmName)
        let publicKey = try LegacyMLDSA44Ed25519SSH.PublicKey.read(from: &buffer)
        XCTAssertEqual(publicKey.rawRepresentation.count, 1344)
        XCTAssertEqual(buffer.readableBytes, 0)

        // Full NIOSSH parse path (uses the registered custom algorithm)
        let nioKey = try NIOSSHPublicKey(openSSHPublicKey: line)
        XCTAssertEqual(String(openSSHPublicKey: nioKey).split(separator: " ")[1], parts[1])
    }

    func testParseOpenSSHCertificateFile() throws {
        let line = try Self.loadTestData("mldsa44_ed25519_1-cert.pub")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(line.hasPrefix(LegacyMLDSA44Ed25519SSH.certifiedAlgorithmName))

        let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: line)
        XCTAssertEqual(cert.keyID, "julius")
        // The embedded base key must round-trip as our composite type
        let base = String(openSSHPublicKey: cert.key)
        XCTAssertTrue(base.hasPrefix(LegacyMLDSA44Ed25519SSH.algorithmName))
    }
    func testCanonicalAndLegacyIdentitiesRemainDistinct() throws {
        let key = try MLDSA44Ed25519SSH.PrivateKey()
        let legacy = try LegacyMLDSA44Ed25519SSH.PrivateKey(seedRepresentation: key.seedRepresentation)
        XCTAssertEqual(key.compositePublicKey.rawRepresentation, legacy.compositePublicKey.rawRepresentation)
        let canonicalPublic = NIOSSHPrivateKey(custom: key).publicKey
        let legacyPublic = NIOSSHPrivateKey(custom: legacy).publicKey
        let canonicalLine = String(openSSHPublicKey: canonicalPublic)
        let legacyLine = String(openSSHPublicKey: legacyPublic)
        XCTAssertTrue(canonicalLine.hasPrefix("ssh-mldsa44-ed25519 "))
        XCTAssertTrue(legacyLine.hasPrefix("ssh-mldsa44-ed25519@openssh.com "))
        XCTAssertNotEqual(canonicalLine, legacyLine)
        XCTAssertEqual(String(openSSHPublicKey: try NIOSSHPublicKey(openSSHPublicKey: canonicalLine)), canonicalLine)
        XCTAssertEqual(String(openSSHPublicKey: try NIOSSHPublicKey(openSSHPublicKey: legacyLine)), legacyLine)
        let message = Data("SSH algorithm binding".utf8)
        XCTAssertFalse(key.compositePublicKey.isValidSignature(try legacy.signature(for: message), for: message))
        XCTAssertFalse(legacy.compositePublicKey.isValidSignature(try key.signature(for: message), for: message))
    }

    func testOpenSSHDefaultHostKeyOrderAndExplicitPQPreference() {
        NIOSSHAlgorithms.unregisterAlgorithms()
        defer {
            NIOSSHAlgorithms.unregisterAlgorithms()
            SSHAlgorithms.all.registerPublicKeyAlgorithms()
        }
        SSHAlgorithms.all.registerPublicKeyAlgorithms()
        XCTAssertEqual(SSHKeyExchangeStateMachine.supportedServerHostKeyAlgorithms, [
            "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
            "rsa-sha2-256", "ssh-mldsa44-ed25519",
        ])
        XCTAssertEqual(SSHKeyExchangeStateMachine.hostCertificateAlgorithms, [
            "ssh-ed25519-cert-v01@openssh.com", "ecdsa-sha2-nistp256-cert-v01@openssh.com",
            "ecdsa-sha2-nistp384-cert-v01@openssh.com", "ecdsa-sha2-nistp521-cert-v01@openssh.com",
            "ssh-mldsa44-ed25519-cert",
        ])
        NIOSSHAlgorithms.registerPreferred(publicKey: LegacyMLDSA44Ed25519SSH.PublicKey.self,
                                          signature: LegacyMLDSA44Ed25519SSH.Signature.self)
        XCTAssertEqual(SSHKeyExchangeStateMachine.supportedServerHostKeyAlgorithms.first,
                       "ssh-mldsa44-ed25519@openssh.com")
        XCTAssertEqual(SSHKeyExchangeStateMachine.hostCertificateAlgorithms, [
            "ssh-mldsa44-ed25519-cert-v01@openssh.com",
            "ssh-ed25519-cert-v01@openssh.com", "ecdsa-sha2-nistp256-cert-v01@openssh.com",
            "ecdsa-sha2-nistp384-cert-v01@openssh.com", "ecdsa-sha2-nistp521-cert-v01@openssh.com",
            "ssh-mldsa44-ed25519-cert",
        ])

        NIOSSHAlgorithms.unregisterAlgorithms()
        SSHAlgorithms.all.registerPublicKeyAlgorithms()
        NIOSSHAlgorithms.registerPreferred(publicKey: MLDSA44Ed25519SSH.PublicKey.self,
                                          signature: MLDSA44Ed25519SSH.Signature.self)
        XCTAssertEqual(SSHKeyExchangeStateMachine.supportedServerHostKeyAlgorithms.first,
                       "ssh-mldsa44-ed25519")
        // The canonical hybrid is also registered normally. It must appear only
        // once, ahead of Ed25519 certificates when explicitly preferred.
        XCTAssertEqual(SSHKeyExchangeStateMachine.hostCertificateAlgorithms, [
            "ssh-mldsa44-ed25519-cert",
            "ssh-ed25519-cert-v01@openssh.com", "ecdsa-sha2-nistp256-cert-v01@openssh.com",
            "ecdsa-sha2-nistp384-cert-v01@openssh.com", "ecdsa-sha2-nistp521-cert-v01@openssh.com",
        ])

        NIOSSHAlgorithms.registerPreferred(publicKey: LegacyMLDSA44Ed25519SSH.PublicKey.self,
                                          signature: LegacyMLDSA44Ed25519SSH.Signature.self)
        // Multiple preferred registrations retain their order before built-ins.
        XCTAssertEqual(SSHKeyExchangeStateMachine.hostCertificateAlgorithms, [
            "ssh-mldsa44-ed25519-cert", "ssh-mldsa44-ed25519-cert-v01@openssh.com",
            "ssh-ed25519-cert-v01@openssh.com", "ecdsa-sha2-nistp256-cert-v01@openssh.com",
            "ecdsa-sha2-nistp384-cert-v01@openssh.com", "ecdsa-sha2-nistp521-cert-v01@openssh.com",
        ])
    }

    func testCanonicalOpenSSHCertificatesValidateAndRoundTrip() throws {
        let ca = try NIOSSHPublicKey(openSSHPublicKey: Self.loadTestData("mldsa44_ed25519_canonical-ca.pub"))
        let publicKey = try NIOSSHPublicKey(openSSHPublicKey: Self.loadTestData("mldsa44_ed25519_canonical.pub"))
        for (kind, principal, type) in [("user", "kit", NIOSSHCertifiedPublicKey.CertificateType.user),
                                        ("host", "localhost", .host)] {
            let line = try Self.loadTestData("mldsa44_ed25519_canonical-" + kind + "-cert.pub")
            let key = try NIOSSHPublicKey(openSSHPublicKey: line)
            var cert = try XCTUnwrap(NIOSSHCertifiedPublicKey(key))
            XCTAssertEqual(cert.key, publicKey)
            XCTAssertEqual(String(openSSHPublicKey: key), line.split(separator: " ").prefix(2).joined(separator: " "))
            _ = try cert.validate(principal: principal, type: type, allowedAuthoritySigningKeys: [ca])
            XCTAssertThrowsError(try cert.validate(principal: "wrong", type: type, allowedAuthoritySigningKeys: [ca]))
            // Renaming a signed legacy/canonical certificate must never be treated as an alias.
            cert.keyID = "tampered"
            XCTAssertThrowsError(try cert.validate(principal: principal, type: type, allowedAuthoritySigningKeys: [ca]))
        }
    }

    func testCanonicalOpenSSHSignatureVerifies() throws {
        let armored = try Self.loadTestData("mldsa44_ed25519_canonical.sig")
        let base64 = armored.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        var envelope = ByteBuffer(data: try XCTUnwrap(Data(base64Encoded: base64)))
        XCTAssertEqual(envelope.readString(length: 6), "SSHSIG")
        XCTAssertEqual(envelope.readInteger(as: UInt32.self), 1)
        var publicBlob = try XCTUnwrap(envelope.readSSHBuffer())
        let publicKey = try XCTUnwrap(publicBlob.readSSHHostKey())
        let namespace = try XCTUnwrap(envelope.readSSHBuffer())
        let reserved = try XCTUnwrap(envelope.readSSHBuffer())
        let hashAlgorithm = try XCTUnwrap(envelope.readSSHBuffer())
        XCTAssertEqual(String(decoding: hashAlgorithm.readableBytesView, as: UTF8.self), "sha512")
        var signatureBlob = try XCTUnwrap(envelope.readSSHBuffer())
        let signature = try XCTUnwrap(signatureBlob.readSSHSignature())
        var signed = ByteBuffer()
        signed.writeString("SSHSIG")
        for field in [Data(namespace.readableBytesView), Data(reserved.readableBytesView),
                      Data(hashAlgorithm.readableBytesView),
                      Data(SHA512.hash(data: Data("rootshell OpenSSH hybrid interoperability\n".utf8)))] {
            signed.writeInteger(UInt32(field.count))
            signed.writeBytes(field)
        }
        XCTAssertTrue(publicKey.isValidSignature(signature, for: signed))
        signed.writeInteger(UInt8(0))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: signed))
    }

}
