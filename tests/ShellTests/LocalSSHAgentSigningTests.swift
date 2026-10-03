//
//  LocalSSHAgentSigningTests.swift
//  ShellTests
//
//  End-to-end agent signing per algorithm, each signature verified
//  independently with CryptoKit / Security (ssh-agent-bridge-spec.md §11.3,
//  §18.3), plus the authentication state the agent relies on (§12, §18.4).
//

import Foundation
import Testing
import Crypto
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Citadel

@testable import Shell

@Suite
struct LocalSSHAgentSigningTests {

    private static let payload = Data("session-id || SSH_MSG_USERAUTH_REQUEST".utf8)

    private func agentSign(_ key: AgentTestKey, flags: UInt32 = 0, blob: Data? = nil) async throws -> ByteBuffer {
        let delegate = ShellSSHAgentDelegate(source: FakeAgentKeySource(keys: [key]))
        return try #require(try await delegate.sign(
            publicKeyBlob: ByteBuffer(data: blob ?? key.blob),
            data: ByteBuffer(data: Self.payload),
            flags: flags
        ))
    }

    private func expectValid(_ signature: ByteBuffer, _ key: AgentTestKey, algorithm: String) throws {
        let result = try AgentSignatureVerifier.verify(signatureBlob: signature, publicKeyBlob: key.blob, data: Self.payload)
        #expect(result.algorithm == algorithm)
        #expect(result.valid)
        let tampered = try AgentSignatureVerifier.verify(signatureBlob: signature, publicKeyBlob: key.blob, data: Self.payload + Data([0]))
        #expect(!tampered.valid)
    }

    @Test
    func testEd25519() async throws {
        let key = try AgentTestKey.make(.ed25519)
        try expectValid(try await agentSign(key), key, algorithm: "ssh-ed25519")
    }

    @Test
    func testECDSAP256() async throws {
        let key = try AgentTestKey.make(.ecdsaP256)
        try expectValid(try await agentSign(key), key, algorithm: "ecdsa-sha2-nistp256")
    }

    @Test
    func testECDSAP384() async throws {
        let key = try AgentTestKey.make(.ecdsaP384)
        try expectValid(try await agentSign(key), key, algorithm: "ecdsa-sha2-nistp384")
    }

    @Test
    func testECDSAP521() async throws {
        let key = try AgentTestKey.make(.ecdsaP521)
        try expectValid(try await agentSign(key), key, algorithm: "ecdsa-sha2-nistp521")
    }

    @Test
    func testRSASHA256() async throws {
        let key = try AgentTestKey.make(.rsa2048)
        try expectValid(try await agentSign(key, flags: 2), key, algorithm: "rsa-sha2-256")
    }

    @Test
    func testRSASHA512() async throws {
        let key = try AgentTestKey.make(.rsa2048)
        try expectValid(try await agentSign(key, flags: 4), key, algorithm: "rsa-sha2-512")
        // Both flags: SHA-512 wins, as in OpenSSH's agent.
        try expectValid(try await agentSign(key, flags: 6), key, algorithm: "rsa-sha2-512")
    }

    @Test
    func testRSAWithoutFlagsIsRefusedRatherThanSignedWithSHA1() async throws {
        let key = try AgentTestKey.make(.rsa2048)
        await #expect(throws: SSHPrivateKeySigner.SignerError.legacyRSASHA1Refused) {
            _ = try await agentSign(key, flags: 0)
        }
        #expect(throws: SSHPrivateKeySigner.SignerError.legacyRSASHA1Refused) {
            _ = try SSHPrivateKeySigner.signAgentPayload(key: key.variant, keyType: .rsa, data: ByteBuffer(), flags: [])
        }
    }

    @Test
    func testCertificateIdentitySignsWithItsPrivateKey() async throws {
        var key = try AgentTestKey.make(.ed25519)
        let certBlob = Data("cert".utf8)
        var metadata = key.key
        metadata.userCertificate = agentTestCertificate(blob: certBlob)
        key = AgentTestKey(key: metadata, variant: key.variant)
        try expectValid(try await agentSign(key, blob: certBlob), key, algorithm: "ssh-ed25519")
    }

    @Test(.enabled(if: SecureEnclave.isAvailable, "Secure Enclave hardware required"))
    func testSecureEnclaveP256() async throws {
        let enclaveKey = try SecureEnclave.P256.Signing.PrivateKey()
        let variant = SSHPrivateKeyVariant.secureEnclaveP256(NIOSSHPrivateKey(secureEnclaveP256Key: enclaveKey))
        var metadata = SSHKey(name: "se", keyType: .secureEnclaveP256, fingerprint: "se")
        metadata.publicKeyBlob = SSHPublicKeyBlob.makeData(from: variant, keyType: .secureEnclaveP256)
        let key = AgentTestKey(key: metadata, variant: variant)
        try expectValid(try await agentSign(key), key, algorithm: "ecdsa-sha2-nistp256")
    }

    @Test
    func testVariantThatContradictsTheKeyTypeIsRefused() throws {
        let key = try AgentTestKey.make(.ed25519)
        #expect(throws: SSHPrivateKeySigner.SignerError.keyTypeMismatch) {
            _ = try SSHPrivateKeySigner.signAgentPayload(
                key: key.variant, keyType: .rsa, data: ByteBuffer(), flags: []
            )
        }
    }

    // MARK: - Failure paths

    @Test
    func testCancelledAuthenticationFailsTheRequest() async throws {
        let key = try AgentTestKey.make(.ed25519)
        let source = FakeAgentKeySource(keys: [key])
        source.loadError = SSHKeyManager.LoadError.authenticationCancelled
        let responder = LocalSSHAgentResponder(delegate: ShellSSHAgentDelegate(source: source))

        let reply = await responder.response(to: ByteBuffer(bytes: AgentWire.signRequest(blob: key.blob, data: [1], flags: 0)))
        guard case .failure = reply else {
            Issue.record("expected SSH_AGENT_FAILURE, got \(reply)")
            return
        }
        #expect(source.loads == [key.key.id])
    }

    @Test
    func testKeyDeletedAfterEnumerationFails() async throws {
        let key = try AgentTestKey.make(.ed25519)
        let source = FakeAgentKeySource(keys: [key])
        let delegate = ShellSSHAgentDelegate(source: source)
        #expect(try await delegate.listIdentities().count == 1)

        source.removeKey(id: key.key.id)
        let signature = try await delegate.sign(publicKeyBlob: ByteBuffer(data: key.blob), data: ByteBuffer(), flags: 0)
        #expect(signature == nil)
    }
}

/// The authentication state machine the agent inherits unchanged from
/// `SSHKeyAuthManager` (the agent adds no cache of its own).
@MainActor
@Suite(.serialized)
struct LocalSSHAgentAuthenticationTests {
    private let auth = SSHKeyAuthManager.shared

    private func key(_ requirement: KeyAuthRequirement) -> SSHKey {
        SSHKey(name: "auth", keyType: .ed25519, fingerprint: "x", authRequirement: requirement)
    }

    @Test
    func testNoneNeverNeedsAuthentication() {
        #expect(!auth.needsAuthentication(for: key(.none)))
    }

    @Test
    func testPerSessionIsRecordedOnlyAfterSuccessAndThenReused() {
        let key = key(.perSession)
        #expect(auth.needsAuthentication(for: key))
        auth.recordAuthentication(for: key.id)
        #expect(!auth.needsAuthentication(for: key))
        auth.clearAuthentication(for: key.id)
        #expect(auth.needsAuthentication(for: key))
    }

    @Test
    func testPerUseAlwaysNeedsFreshAuthentication() {
        let key = key(.perUse)
        auth.recordAuthentication(for: key.id)
        #expect(auth.needsAuthentication(for: key))
        #expect(auth.needsAuthentication(for: key))
        auth.clearAuthentication(for: key.id)
    }

    @Test
    func testConcurrentLoadsForOneKeyShareOnePrompt() async throws {
        let keyID = UUID()
        let counter = Counter()
        let gate = Gate()
        let loader: @Sendable () async throws -> Data = {
            await counter.increment()
            await gate.wait()
            return Data([1])
        }

        async let first = auth.loadWithDeduplication(keyID: keyID, loader: loader)
        async let second = auth.loadWithDeduplication(keyID: keyID, loader: loader)
        async let third = auth.loadWithDeduplication(keyID: keyID, loader: loader)
        // Let every caller register before the shared load completes.
        while await counter.value == 0 { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        await gate.open()

        let results = try await [first, second, third]
        #expect(results == [Data([1]), Data([1]), Data([1])])
        #expect(await counter.value == 1)
    }

    @Test
    func testCancellationPropagatesAndRecordsNothing() async {
        let key = key(.perSession)
        await #expect(throws: SSHKeyManager.LoadError.self) {
            _ = try await auth.loadWithDeduplication(keyID: key.id) {
                throw SSHKeyManager.LoadError.authenticationCancelled
            }
        }
        #expect(auth.needsAuthentication(for: key))
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }
}
