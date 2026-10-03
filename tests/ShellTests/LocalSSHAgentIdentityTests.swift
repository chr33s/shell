//
//  LocalSSHAgentIdentityTests.swift
//  ShellTests
//
//  Which identities the local SSH agent advertises, in what order, and how a
//  sign request's blob resolves back to a key (ssh-agent-bridge-spec.md §7,
//  §11.1, §18.2), under the V2 explicit-grant model
//  (ssh-agent-bridge-v2-delta.md §2, §4, §11.1).
//

import Foundation
import Testing
import NIOCore
import NIOFoundationCompat
import Citadel

@testable import Shell

@Suite
struct LocalSSHAgentIdentityTests {

    private func index(
        keys: [SSHKey],
        allowed: [UUID],
        usable: Set<UUID>? = nil,
        now: Date = Date()
    ) -> SSHAgentIdentityIndex {
        SSHAgentIdentityIndex(
            memberKeyIDs: allowed,
            keys: keys,
            locallyUsable: usable ?? Set(keys.map(\.id)),
            now: now
        )
    }

    @Test
    func testOnlyAllowedKeysAreAdvertisedInAllowlistOrder() throws {
        let a = try AgentTestKey.make(.ed25519, name: "a").key
        let b = try AgentTestKey.make(.ecdsaP256, name: "b").key
        let notAllowed = try AgentTestKey.make(.ed25519, name: "c").key

        let result = index(keys: [a, b, notAllowed], allowed: [b.id, a.id])
        #expect(result.entries.map(\.keyID) == [b.id, a.id])
        #expect(result.entries.map(\.comment) == ["Shell: b", "Shell: a"])
        #expect(result.identities.count == 2)
    }

    @Test
    func testEmptyAllowlistMeansNoIdentities() throws {
        let a = try AgentTestKey.make(.ed25519).key
        #expect(index(keys: [a], allowed: []).entries.isEmpty)
    }

    @Test
    func testStaleAllowlistEntriesAreHarmless() throws {
        let a = try AgentTestKey.make(.ed25519).key
        let result = index(keys: [a], allowed: [UUID(), a.id, UUID()])
        #expect(result.entries.map(\.keyID) == [a.id])
    }

    @Test
    func testDuplicateGrantIsAdvertisedOnce() throws {
        let a = try AgentTestKey.make(.ed25519).key
        #expect(index(keys: [a], allowed: [a.id, a.id]).entries.count == 1)
    }

    @Test
    func testKeyWithoutLocalMaterialIsSkipped() throws {
        // Covers metadata synced from another device (a Secure Enclave
        // identity, or an iCloud key whose secret has not arrived) and legacy
        // keys awaiting unlock: the key source leaves them out of `locallyUsable`.
        var remoteSE = try AgentTestKey.make(.ecdsaP256, name: "remote SE").key
        remoteSE.keyType = .secureEnclaveP256
        remoteSE.secureEnclaveInfo = SecureEnclaveKeyInfo(publicKeyX963: Data(), createdDate: Date())
        let local = try AgentTestKey.make(.ed25519, name: "local").key

        let result = index(keys: [remoteSE, local], allowed: [remoteSE.id, local.id], usable: [local.id])
        #expect(result.entries.map(\.keyID) == [local.id])
    }

    @Test
    func testKeyWithoutCachedBlobIsSkipped() throws {
        var key = try AgentTestKey.make(.ed25519).key
        key.publicKeyBlob = nil
        #expect(index(keys: [key], allowed: [key.id]).entries.isEmpty)
    }

    @Test
    func testTruncatedBlobIsSkipped() throws {
        var key = try AgentTestKey.make(.ed25519).key
        key.publicKeyBlob = key.publicKeyBlob!.prefix(15)
        #expect(index(keys: [key], allowed: [key.id]).entries.isEmpty)
    }

    @Test
    func testValidCertificateIsListedBeforeItsRawKey() throws {
        var key = try AgentTestKey.make(.ed25519, name: "work").key
        let certBlob = Data("certificate".utf8)
        key.userCertificate = agentTestCertificate(blob: certBlob)

        let result = index(keys: [key], allowed: [key.id])
        #expect(result.entries.map(\.blob) == [certBlob, key.publicKeyBlob!])
        #expect(result.entries.map(\.comment) == ["Shell: work (certificate)", "Shell: work"])
        #expect(result.entries.map(\.isCertificate) == [true, false])
    }

    @Test
    func testExpiredCertificateIsOmitted() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var key = try AgentTestKey.make(.ed25519).key
        key.userCertificate = agentTestCertificate(validAfter: 1, validBefore: 2_000_000_000)
        let result = index(keys: [key], allowed: [key.id], now: now)
        #expect(result.entries.map(\.isCertificate) == [false])
    }

    @Test
    func testNotYetValidCertificateIsOmitted() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var key = try AgentTestKey.make(.ed25519).key
        key.userCertificate = agentTestCertificate(validAfter: 1_001)
        let result = index(keys: [key], allowed: [key.id], now: now)
        #expect(result.entries.map(\.isCertificate) == [false])
    }

    @Test
    func testCertificateExpiryIsEvaluatedAtRequestTime() throws {
        var key = try AgentTestKey.make(.ed25519).key
        key.userCertificate = agentTestCertificate(validBefore: 1_000)
        #expect(index(keys: [key], allowed: [key.id], now: Date(timeIntervalSince1970: 999)).entries.count == 2)
        #expect(index(keys: [key], allowed: [key.id], now: Date(timeIntervalSince1970: 1_000)).entries.count == 1)
    }

    @Test
    func testRawAndCertificateBlobsResolveToTheSameKey() throws {
        var a = try AgentTestKey.make(.ed25519, name: "a").key
        let b = try AgentTestKey.make(.ecdsaP384, name: "b").key
        let certBlob = Data("certificate-a".utf8)
        a.userCertificate = agentTestCertificate(blob: certBlob)

        let result = index(keys: [a, b], allowed: [a.id, b.id])
        #expect(result.entry(forBlob: certBlob)?.keyID == a.id)
        #expect(result.entry(forBlob: a.publicKeyBlob!)?.keyID == a.id)
        #expect(result.entry(forBlob: b.publicKeyBlob!)?.keyID == b.id)
        #expect(result.entry(forBlob: b.publicKeyBlob!)?.keyType == .ecdsaP384)
    }

    @Test
    func testLookupIsExactBlobEqualityOnly() throws {
        let a = try AgentTestKey.make(.ed25519).key
        let result = index(keys: [a], allowed: [a.id])
        #expect(result.entry(forBlob: a.publicKeyBlob!.dropLast()) == nil)
        #expect(result.entry(forBlob: a.publicKeyBlob! + Data([0])) == nil)
        #expect(result.entry(forBlob: Data()) == nil)
    }

    @Test
    func testDelegateSeesCurrentStateOnEveryRequest() async throws {
        let a = try AgentTestKey.make(.ed25519)
        let b = try AgentTestKey.make(.ed25519)
        let source = FakeAgentKeySource(keys: [a, b])
        let delegate = ShellSSHAgentDelegate(source: source)

        #expect(try await delegate.listIdentities().count == 2)
        source.removeKey(id: a.key.id)
        let identities = try await delegate.listIdentities()
        #expect(identities.map { Data(buffer: $0.publicKeyBlob) } == [b.blob])
    }
}
