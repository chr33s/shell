import Foundation
import NIOCore
import NIOSSH
import XCTest
@testable import Citadel

#if os(macOS)
/// Optional live tests. Set OPENSSH_INTEROP_PORT to a loopback sshd configured
/// with TestData/mldsa44_ed25519_canonical as host/authorized key, its host
/// certificate, and canonical-ca.pub as TrustedUserCAKeys. No external hosts.
final class OpenSSHHybridInteropTests: XCTestCase {
    private var legacy: Bool { ProcessInfo.processInfo.environment["OPENSSH_INTEROP_LEGACY"] == "1" }

    private func fixture(_ suffix: String = "") throws -> String {
        if let directory = ProcessInfo.processInfo.environment["OPENSSH_INTEROP_FIXTURES"] {
            return try String(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("key" + suffix), encoding: .utf8)
        }
        return try MLDSA44Ed25519Tests.loadTestData("mldsa44_ed25519_canonical" + suffix)
    }

    private func privateKey() throws -> NIOSSHPrivateKey {
        let pem = try fixture()
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        var envelope = ByteBuffer(data: try XCTUnwrap(Data(base64Encoded: base64)))
        XCTAssertEqual(envelope.readString(length: 15), "openssh-key-v1\0")
        let cipher = try XCTUnwrap(envelope.readSSHBuffer())
        XCTAssertEqual(String(decoding: cipher.readableBytesView, as: UTF8.self), "none")
        _ = envelope.readSSHBuffer() // KDF name
        _ = envelope.readSSHBuffer() // KDF options
        XCTAssertEqual(envelope.readInteger(as: UInt32.self), 1)
        _ = envelope.readSSHBuffer() // public key
        var secret = try XCTUnwrap(envelope.readSSHBuffer())
        XCTAssertEqual(secret.readInteger(as: UInt32.self), secret.readInteger(as: UInt32.self))
        _ = secret.readSSHBuffer() // algorithm
        _ = secret.readSSHBuffer() // public key
        let seeds = try XCTUnwrap(secret.readSSHBuffer())
        if legacy {
            return NIOSSHPrivateKey(custom: try LegacyMLDSA44Ed25519SSH.PrivateKey(seedRepresentation: Data(seeds.readableBytesView)))
        }
        return NIOSSHPrivateKey(custom: try MLDSA44Ed25519SSH.PrivateKey(seedRepresentation: Data(seeds.readableBytesView)))
    }

    private struct HostCertificateValidator: NIOSSHClientServerAuthenticationDelegate {
        let ca: NIOSSHPublicKey
        func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
            do {
                let cert = try XCTUnwrap(NIOSSHCertifiedPublicKey(hostKey))
                _ = try cert.validate(principal: "localhost", type: .host, allowedAuthoritySigningKeys: [ca])
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }

    private func connect(certificate: Bool) async throws {
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["OPENSSH_INTEROP_PORT"]
            .flatMap(Int.init), "Set OPENSSH_INTEROP_PORT to enable live interoperability tests")
        SSHAlgorithms.all.registerPublicKeyAlgorithms()
        let key = try privateKey()
        let username = ProcessInfo.processInfo.environment["OPENSSH_INTEROP_USERNAME"] ?? NSUserName()
        let auth: SSHAuthenticationMethod
        let validator: SSHHostKeyValidator
        if certificate {
            let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: fixture("-user-cert.pub"))
            auth = .certificate(username: username, privateKey: key, certifiedKey: cert)
            validator = .custom(HostCertificateValidator(ca: try NIOSSHPublicKey(openSSHPublicKey: fixture("-ca.pub"))))
        } else {
            auth = SSHAuthenticationMethod(username: username, offer: .privateKey(.init(privateKey: key)))
            validator = .trustedKeys([key.publicKey])
        }
        var algorithms = SSHAlgorithms.all
        if legacy {
            algorithms.preferredPublicKeyAlgorithms = [
                (LegacyMLDSA44Ed25519SSH.PublicKey.self, LegacyMLDSA44Ed25519SSH.Signature.self),
            ]
        }
        let client = try await SSHClient.connect(
            host: "127.0.0.1", port: port, authenticationMethod: auth,
            hostKeyValidator: validator, reconnect: .never, algorithms: algorithms,
            protocolOptions: certificate ? [.advertiseHostCertificateAlgorithms] : [],
            connectTimeout: .seconds(5), loginTimeout: .seconds(10))
        do {
            // Exercise packet boundaries in both directions after authentication.
            for size in [1, 11, 12, 15, 16, 17, 31, 32, 33, 256, 4096] {
                let expected = String(repeating: "x", count: size)
                let output = try await client.executeCommand("printf '%s' '\(expected)'")
                XCTAssertEqual(String(decoding: output.readableBytesView, as: UTF8.self), expected)
            }
            // Multiple channel-data packets and server-initiated rekeying (the
            // runner uses RekeyLimit 16K), then a command using the new keys.
            let chunk = String(repeating: "0123456789abcdef", count: 512)
            let output = try await client.executeCommand(
                "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do printf '%s' '\(chunk)'; done")
            XCTAssertEqual(String(decoding: output.readableBytesView, as: UTF8.self), String(repeating: chunk, count: 16))
            let final = try await client.executeCommand("printf '%s' 'after-rekey'")
            XCTAssertEqual(String(decoding: final.readableBytesView, as: UTF8.self), "after-rekey")
        } catch {
            try? await client.close()
            throw error
        }
        try await client.close()
    }

    func testPlainUserAndHost() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENSSH_INTEROP_PORT"] != nil)
        try await connect(certificate: false)
    }

    func testCertifiedUserAndHost() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENSSH_INTEROP_PORT"] != nil)
        try await connect(certificate: true)
    }
}

#endif
