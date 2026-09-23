import Foundation
import NIOCore
import NIOSSH
import XCTest
@testable import Citadel

#if os(macOS)
/// Live interoperability tests against a real sshd. Set OPENSSH_INTEROP_BINARIES to a built
/// openssh-portable directory to enable them; they skip otherwise. Each test launches its own
/// loopback server via `OpenSSHTestServer`, so no external host is ever contacted.
final class OpenSSHHybridInteropTests: XCTestCase {
    private var server: OpenSSHTestServer!

    override func setUpWithError() throws {
        try XCTSkipIf(OpenSSHTestServer.binaries == nil,
                      "Set OPENSSH_INTEROP_BINARIES to a built openssh-portable directory")
    }

    override func tearDown() {
        server?.stop()
        server = nil
    }

    private func startServer(_ configuration: OpenSSHTestServer.Configuration = .init()) throws {
        server = try OpenSSHTestServer.start(configuration)
    }

    private var legacy: Bool { server.usesLegacyHybridNames }

    private func privateKey() throws -> NIOSSHPrivateKey {
        let pem = try server.fixture()
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

    private func algorithms() throws -> SSHAlgorithms {
        SSHAlgorithms.all.registerPublicKeyAlgorithms()
        var algorithms = SSHAlgorithms.all
        if legacy {
            algorithms.preferredPublicKeyAlgorithms = [
                (LegacyMLDSA44Ed25519SSH.PublicKey.self, LegacyMLDSA44Ed25519SSH.Signature.self),
            ]
        }
        return algorithms
    }

    private func connectClient(port: Int? = nil) async throws -> SSHClient {
        let key = try privateKey()
        return try await SSHClient.connect(
            host: "127.0.0.1", port: port ?? server.port,
            authenticationMethod: SSHAuthenticationMethod(username: NSUserName(), offer: .privateKey(.init(privateKey: key))),
            hostKeyValidator: .trustedKeys([key.publicKey]), reconnect: .never, algorithms: try algorithms(),
            connectTimeout: .seconds(5), loginTimeout: .seconds(10))
    }

    /// sshd logs this at DEBUG3 once both sides advertise kex-strict-*-v00@openssh.com.
    private func assertStrictKeyExchange(file: StaticString = #filePath, line: UInt = #line) {
        let diagnostics = server.diagnostics
        XCTAssertTrue(diagnostics.contains("will use strict KEX ordering"),
                      "sshd did not negotiate strict KEX", file: file, line: line)
        XCTAssertFalse(diagnostics.contains("strict KEX violation"),
                       "sshd reported a strict KEX violation", file: file, line: line)
    }

    private func assertNegotiated(cipher: String, mac: String, file: StaticString = #filePath, line: UInt = #line) {
        let diagnostics = server.diagnostics
        let expectedMAC = cipher.contains("gcm") ? "<implicit>" : mac
        for direction in ["client->server", "server->client"] {
            XCTAssertTrue(diagnostics.contains("\(direction) cipher: \(cipher) MAC: \(expectedMAC)"),
                          "sshd did not negotiate \(cipher)/\(expectedMAC) \(direction)", file: file, line: line)
        }
    }

    // MARK: Tests

    func testPlainUserAndHost() async throws {
        try startServer()
        try await exerciseSession(certificate: false)
        assertStrictKeyExchange()
    }

    func testCertifiedUserAndHost() async throws {
        try startServer()
        try await exerciseSession(certificate: true)
        assertStrictKeyExchange()
    }

    func testAESCTRWithSHA256ETM() async throws {
        let configuration = OpenSSHTestServer.Configuration(cipher: "aes256-ctr", mac: "hmac-sha2-256-etm@openssh.com")
        try startServer(configuration)
        try await exerciseSession(certificate: false)
        assertNegotiated(cipher: configuration.cipher, mac: configuration.mac)
        assertStrictKeyExchange()
    }

    /// A 64-byte MAC key derived from a 32-byte exchange hash needs the RFC 4253 §7.2 expansion.
    /// Truncating instead fails the very first MAC, so this pairing is the regression for it.
    func testAESCTRWithSHA512ETMOverCurve25519() async throws {
        let configuration = OpenSSHTestServer.Configuration(
            cipher: "aes256-ctr", mac: "hmac-sha2-512-etm@openssh.com", kex: "curve25519-sha256")
        try startServer(configuration)
        try await exerciseSession(certificate: false)
        assertNegotiated(cipher: configuration.cipher, mac: configuration.mac)
        assertStrictKeyExchange()
    }

    /// RFC 4253 §4.2: text lines before the server's version line are ignored, and in particular
    /// must stay out of the exchange hash, or the host key signature fails.
    func testPreBannerLinesAreIgnored() async throws {
        try startServer()
        let proxy = try PreBannerProxy(forwardingTo: server.port)
        defer { proxy.shutdown() }

        let client = try await connectClient(port: proxy.port)
        do {
            let output = try await client.executeCommand("printf '%s' 'after-banner'")
            XCTAssertEqual(String(decoding: output.readableBytesView, as: UTF8.self), "after-banner")
        } catch {
            try? await client.close()
            throw error
        }
        try await client.close()
    }

    /// The server rekeys every 16 KiB, so a 256 KiB upload crosses many server-initiated rekeys
    /// while the client is writing. Every write must be queued and delivered, not dropped.
    func testSFTPUploadThroughServerRekeys() async throws {
        try startServer()
        let path = server.path("upload.bin")
        let payload = ByteBuffer(bytes: (0 ..< 256 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })

        let client = try await connectClient()
        do {
            let sftp = try await client.openSFTP()
            try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                try await file.write(payload)
            }
            let readBack = try await sftp.withFile(filePath: path, flags: .read) { file in
                try await file.readAll()
            }
            XCTAssertEqual(readBack, payload)
            try await sftp.close()
        } catch {
            try? await client.close()
            throw error
        }
        try await client.close()
        assertStrictKeyExchange()
    }

    /// Streams 2 MiB into a PTY shell across roughly 128 rekeys, issuing writes back to back so
    /// many land inside a rekey window. The deterministic version is NIOSSH's EndToEndTests.
    @available(macOS 15.0, *)
    func testPTYStreamThroughServerRekeys() async throws {
        try startServer()
        let path = server.path("stream.txt")
        let line = String(repeating: "0123456789abcdef", count: 4) + "\n"
        let expected = String(repeating: line, count: 32_000)

        let client = try await connectClient()
        struct StreamStalled: Error {}
        do {
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: "xterm", terminalCharacterWidth: 500, terminalRowHeight: 24,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))
            // Lost writes leave head waiting forever, and NIO futures ignore task cancellation, so a
            // structured race would never return; a one-shot continuation abandons the session instead.
            final class OneShot: @unchecked Sendable {
                private let lock = NSLock()
                private var done = false
                func claim() -> Bool {
                    lock.lock(); defer { lock.unlock() }
                    if done { return false }
                    done = true
                    return true
                }
            }
            let oneShot = OneShot()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    if oneShot.claim() { continuation.resume(throwing: StreamStalled()) }
                }
                Task {
                    let result: Result<Void, Error>
                    do {
                        try await client.withPTY(request) { inbound, outbound in
                            // Markers are quoted in the command so the echoed command line cannot match them.
                            // Raw mode matters: the canonical input queue silently discards input past 1 KiB,
                            // so data only flows once the tty is raw and head is the reader.
                            var iterator = inbound.makeAsyncIterator()
                            func waitFor(_ marker: String) async throws {
                                var seen = ""
                                while let output = try await iterator.next() {
                                    guard case .stdout(let buffer) = output else { continue }
                                    seen += String(decoding: buffer.readableBytesView, as: UTF8.self)
                                    if seen.contains(marker) {
                                        return
                                    }
                                    seen = String(seen.suffix(64))
                                }
                                XCTFail("Channel closed before \(marker)")
                            }
                            try await outbound.write(ByteBuffer(string: "stty raw -echo; echo 'GO'-'NOW'; head -c \(expected.utf8.count) > '\(path)'; echo 'STREAM'-'COMPLETE'\n"))
                            try await waitFor("GO-NOW")
                            var remaining = Substring(expected)
                            while !remaining.isEmpty {
                                let chunk = remaining.prefix(4096)
                                remaining = remaining.dropFirst(chunk.count)
                                try await outbound.write(ByteBuffer(string: String(chunk)))
                            }
                            try await waitFor("STREAM-COMPLETE")
                        }
                        result = .success(())
                    } catch {
                        result = .failure(error)
                    }
                    if oneShot.claim() { continuation.resume(with: result) }
                }
            }
            let readBack = try await client.executeCommand("cat '\(path)'")
            XCTAssertEqual(readBack.readableBytes, expected.utf8.count)
            let actualBytes = Array(readBack.readableBytesView)
            let expectedBytes = Array(expected.utf8)
            if let mismatch = zip(actualBytes, expectedBytes).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                let window = max(0, mismatch - 32) ..< min(actualBytes.count, mismatch + 32)
                XCTFail("Stream differs at byte \(mismatch): got \(String(decoding: actualBytes[window], as: UTF8.self).debugDescription) expected \(String(decoding: expectedBytes[window], as: UTF8.self).debugDescription)")
            }
        } catch is StreamStalled {
            // The connection is wedged; do not wait on its close.
            Task { try? await client.close() }
            XCTFail("Stream stalled: writes issued during a rekey were not delivered")
            return
        } catch {
            try? await client.close()
            throw error
        }
        try await client.close()
        assertStrictKeyExchange()
    }

    // MARK: Shared session exercise

    private func exerciseSession(certificate: Bool) async throws {
        let key = try privateKey()
        let auth: SSHAuthenticationMethod
        let validator: SSHHostKeyValidator
        if certificate {
            let cert = try NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey: server.fixture("-user-cert.pub"))
            auth = .certificate(username: NSUserName(), privateKey: key, certifiedKey: cert)
            validator = .custom(HostCertificateValidator(ca: try NIOSSHPublicKey(openSSHPublicKey: server.fixture("-ca.pub"))))
        } else {
            auth = SSHAuthenticationMethod(username: NSUserName(), offer: .privateKey(.init(privateKey: key)))
            validator = .trustedKeys([key.publicKey])
        }

        let client = try await SSHClient.connect(
            host: "127.0.0.1", port: server.port, authenticationMethod: auth,
            hostKeyValidator: validator, reconnect: .never, algorithms: try algorithms(),
            protocolOptions: certificate ? [.advertiseHostCertificateAlgorithms] : [],
            connectTimeout: .seconds(5), loginTimeout: .seconds(10))
        do {
            // Exercise packet boundaries in both directions after authentication.
            for size in [1, 11, 12, 15, 16, 17, 31, 32, 33, 256, 4096] {
                let expected = String(repeating: "x", count: size)
                let output = try await client.executeCommand("printf '%s' '\(expected)'")
                XCTAssertEqual(String(decoding: output.readableBytesView, as: UTF8.self), expected)
            }
            // Multiple channel-data packets and server-initiated rekeying, then a command on the new keys.
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
}

#endif
