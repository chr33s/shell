//
//  LocalSSHAgentV2SecurityTests.swift
//  ShellTests
//
//  The V2 security delta for the local SSH agent
//  (ssh-agent-bridge-v2-delta.md §11): explicit per-key grants, Off-by-default
//  settings, purpose-scoped authorization, the post-cancel cooldown, resource
//  bounds, and structural separation from remote agent forwarding.
//

import Foundation
import Testing
import UIKit
import NIOCore
import NIOFoundationCompat
import Citadel

@testable import Shell

// MARK: - Permission model (§11.1)

@Suite
struct LocalSSHAgentPermissionTests {

    private func index(_ policy: LocalSSHAgentPolicy, _ keys: [SSHKey]) -> SSHAgentIdentityIndex {
        SSHAgentIdentityIndex(policy: policy, keys: keys, locallyUsable: Set(keys.map(\.id)))
    }

    @Test
    func testDefaultKeyWithoutGrantIsNotAdvertised() throws {
        // `defaultKeyIDs` plays no part: membership is the allowlist alone.
        let defaultKey = try AgentTestKey.make(.ed25519, name: "default").key
        let policy = LocalSSHAgentPolicy(enabled: true, allowedKeyIDs: [])
        #expect(index(policy, [defaultKey]).entries.isEmpty)
    }

    @Test
    func testGrantedNonDefaultKeyIsAdvertised() throws {
        let key = try AgentTestKey.make(.ed25519).key
        let policy = LocalSSHAgentPolicy(enabled: true, allowedKeyIDs: [key.id])
        #expect(index(policy, [key]).entries.map(\.keyID) == [key.id])
    }

    @Test
    func testDisabledAgentAdvertisesNothingEvenWithGrants() throws {
        let key = try AgentTestKey.make(.ed25519).key
        let policy = LocalSSHAgentPolicy(enabled: false, allowedKeyIDs: [key.id])
        #expect(index(policy, [key]).entries.isEmpty)
    }

    @Test
    func testOrderingFollowsTheAllowlist() throws {
        let a = try AgentTestKey.make(.ed25519, name: "a").key
        let b = try AgentTestKey.make(.ed25519, name: "b").key
        var policy = LocalSSHAgentPolicy(enabled: true, allowedKeyIDs: [])
        policy.setAllowed(true, keyID: b.id)
        policy.setAllowed(true, keyID: a.id)
        policy.setAllowed(true, keyID: b.id)  // re-grant keeps its place
        #expect(index(policy, [a, b]).entries.map(\.keyID) == [b.id, a.id])
    }

    @Test
    func testCertificateFollowsItsKeysGrant() throws {
        var key = try AgentTestKey.make(.ed25519).key
        key.userCertificate = agentTestCertificate(blob: Data("cert".utf8))
        let allowed = LocalSSHAgentPolicy(enabled: true, allowedKeyIDs: [key.id])
        let notAllowed = LocalSSHAgentPolicy(enabled: true, allowedKeyIDs: [])
        #expect(index(allowed, [key]).entries.map(\.isCertificate) == [true, false])
        #expect(index(notAllowed, [key]).entries.isEmpty)
    }

    @Test
    func testSyncedIdentityDoesNotInheritAGrant() throws {
        // Grants are not part of `SSHKey`: a key arriving through iCloud
        // carries metadata only, so nothing in it can grant agent access.
        let key = try AgentTestKey.make(.ed25519).key
        let roundTripped = try JSONDecoder().decode(SSHKey.self, from: JSONEncoder().encode(key))
        let json = try #require(String(data: JSONEncoder().encode(key), encoding: .utf8))
        #expect(!json.localizedCaseInsensitiveContains("agent"))
        #expect(index(.initial, [roundTripped]).entries.isEmpty)
    }

    @Test
    func testRevokeFailsLaterSignsFromAnAlreadyConnectedClient() async throws {
        let key = try AgentTestKey.make(.ed25519)
        let source = FakeAgentKeySource(keys: [key])
        let delegate = ShellSSHAgentDelegate(source: source, throttle: LocalSSHAgentAuthThrottle())

        let before = try await delegate.sign(publicKeyBlob: ByteBuffer(data: key.blob), data: ByteBuffer(), flags: 0)
        #expect(before != nil)

        source.setAllowed(false, keyID: key.key.id)
        let after = try await delegate.sign(publicKeyBlob: ByteBuffer(data: key.blob), data: ByteBuffer(), flags: 0)
        #expect(after == nil)
        #expect(source.loads == [key.key.id])  // the revoked request never loaded the key
    }

    @Test
    func testRevokeWhileAPromptIsUpPreventsTheSignature() async throws {
        let key = try AgentTestKey.make(.ed25519)
        let source = FakeAgentKeySource(keys: [key])
        source.loadDelay = .milliseconds(200)  // the prompt on screen
        let delegate = ShellSSHAgentDelegate(source: source, throttle: LocalSSHAgentAuthThrottle())

        async let signature = delegate.sign(publicKeyBlob: ByteBuffer(data: key.blob), data: ByteBuffer(), flags: 0)
        while source.loads.isEmpty { await Task.yield() }
        source.setAllowed(false, keyID: key.key.id)

        #expect(try await signature == nil)
        #expect(source.loads == [key.key.id])
    }

    @Test
    func testAllowlistWireFormatRoundTripsAndDropsJunk() {
        let a = UUID(), b = UUID()
        let data = LocalSSHAgentPolicy.encodeAllowedKeyIDs([a, b])
        #expect(LocalSSHAgentPolicy.decodeAllowedKeyIDs(data) == [a, b])
        #expect(LocalSSHAgentPolicy.encodeAllowedKeyIDs([]) == nil)
        let junk = try? JSONEncoder().encode([a.uuidString, "nope", a.uuidString, b.uuidString])
        #expect(LocalSSHAgentPolicy.decodeAllowedKeyIDs(junk) == [a, b])
        #expect(LocalSSHAgentPolicy.decodeAllowedKeyIDs(Data("garbage".utf8)) == [])
    }
}

// MARK: - Global setting (§11.2)

@MainActor
@Suite(.serialized)
struct LocalSSHAgentSettingTests {

    @Test
    func testNewInstallDefaultsAreOffAndEmpty() {
        #expect(Settings.Connections.localSSHAgent.defaultValue == false)
        #expect(Settings.Connections.localSSHAgentAllowedKeyIDs.defaultValue == nil)
        #expect(LocalSSHAgentPolicy.initial == LocalSSHAgentPolicy(enabled: false, allowedKeyIDs: []))
    }

    @Test
    func testV1SettingIsNotCarriedIntoV2() {
        // V1 persisted "localSSHAgentEnabled" (default On) and derived
        // membership from defaultKeyIDs. V2 reads neither.
        #expect(Settings.Connections.localSSHAgent.name != "localSSHAgentEnabled")
        #expect(Settings.Connections.localSSHAgentAllowedKeyIDs.name != Settings.Connections.defaultKeyIDs.name)
    }

    @Test
    func testEnablingDoesNotPopulateTheAllowlist() {
        let store = SettingsStore.shared
        let previousEnabled = store.value(Settings.Connections.localSSHAgent)
        let previousAllowed = store.value(Settings.Connections.localSSHAgentAllowedKeyIDs)
        defer {
            store.set(Settings.Connections.localSSHAgent, previousEnabled)
            store.set(Settings.Connections.localSSHAgentAllowedKeyIDs, previousAllowed)
        }

        store.set(Settings.Connections.localSSHAgentAllowedKeyIDs, nil)
        store.set(Settings.Connections.localSSHAgent, true)
        #expect(LocalSSHAgentPolicy.current == LocalSSHAgentPolicy(enabled: true, allowedKeyIDs: []))
    }

    @Test
    func testGrantAndRevokeThroughTheStore() {
        let store = SettingsStore.shared
        let previousAllowed = store.value(Settings.Connections.localSSHAgentAllowedKeyIDs)
        defer { store.set(Settings.Connections.localSSHAgentAllowedKeyIDs, previousAllowed) }
        store.set(Settings.Connections.localSSHAgentAllowedKeyIDs, nil)

        let id = UUID()
        let auth = SSHKeyAuthManager.shared
        let key = SSHKey(id: id, name: "k", keyType: .ed25519, fingerprint: "f", authRequirement: .perSession)
        auth.recordAuthentication(for: id, purpose: .localAgent)
        auth.recordAuthentication(for: id, purpose: .nativeSSH)

        LocalSSHAgentPolicy.setAllowed(true, keyID: id)
        #expect(LocalSSHAgentPolicy.current.allowedKeyIDs == [id])

        // Revoking clears that key's agent session, not its native one.
        LocalSSHAgentPolicy.setAllowed(false, keyID: id)
        #expect(LocalSSHAgentPolicy.current.allowedKeyIDs == [])
        #expect(auth.needsAuthentication(for: key, purpose: .localAgent))
        #expect(!auth.needsAuthentication(for: key, purpose: .nativeSSH))
        auth.clearAuthentication(for: id)
    }
}

// MARK: - Authentication scope (§11.3)

@MainActor
@Suite(.serialized)
struct LocalSSHAgentAuthScopeTests {
    private let auth = SSHKeyAuthManager.shared

    private func key(_ requirement: KeyAuthRequirement) -> SSHKey {
        SSHKey(name: "scope", keyType: .ed25519, fingerprint: "x", authRequirement: requirement)
    }

    @Test
    func testNativeSessionDoesNotAuthorizeTheAgent() {
        let key = key(.perSession)
        auth.recordAuthentication(for: key.id, purpose: .nativeSSH)
        #expect(!auth.needsAuthentication(for: key, purpose: .nativeSSH))
        #expect(auth.needsAuthentication(for: key, purpose: .localAgent))
        auth.clearAuthentication(for: key.id)
    }

    @Test
    func testAgentSessionDoesNotAuthorizeNativeSSH() {
        let key = key(.perSession)
        auth.recordAuthentication(for: key.id, purpose: .localAgent)
        #expect(!auth.needsAuthentication(for: key, purpose: .localAgent))
        #expect(auth.needsAuthentication(for: key, purpose: .nativeSSH))
        #expect(auth.needsAuthentication(for: key))  // default purpose is native
        auth.clearAuthentication(for: key.id)
    }

    @Test
    func testPerUseNeverEstablishesAnAgentSession() {
        let key = key(.perUse)
        auth.recordAuthentication(for: key.id, purpose: .localAgent)
        #expect(auth.needsAuthentication(for: key, purpose: .localAgent))
        auth.clearAuthentication(for: key.id)
    }

    @Test
    func testEveryInvalidationAdvancesTheAuthorizationEpoch() {
        let start = LocalSSHAgent.authorizationEpoch
        LocalSSHAgent.invalidateAuthorization()
        LocalSSHAgent.invalidateAuthorization(keyID: UUID())
        LocalSSHAgent.invalidateAuthorization(resetCooldowns: true)
        #expect(LocalSSHAgent.authorizationEpoch == start + 3)
    }

    @Test
    func testRevokingOneKeyLeavesOtherAgentSessions() {
        let revoked = key(.perSession)
        let kept = key(.perSession)
        auth.recordAuthentication(for: revoked.id, purpose: .localAgent)
        auth.recordAuthentication(for: kept.id, purpose: .localAgent)
        LocalSSHAgent.invalidateAuthorization(keyID: revoked.id)
        #expect(auth.needsAuthentication(for: revoked, purpose: .localAgent))
        #expect(!auth.needsAuthentication(for: kept, purpose: .localAgent))
        auth.clearAuthentication(for: kept.id)
    }

    @Test
    func testInvalidationClearsOnlyAgentSessions() {
        let agentKey = key(.perSession)
        let nativeKey = key(.perSession)
        auth.recordAuthentication(for: agentKey.id, purpose: .localAgent)
        auth.recordAuthentication(for: nativeKey.id, purpose: .nativeSSH)

        LocalSSHAgent.invalidateAuthorization()
        #expect(auth.needsAuthentication(for: agentKey, purpose: .localAgent))
        #expect(!auth.needsAuthentication(for: nativeKey, purpose: .nativeSSH))
        auth.clearAuthentication(for: nativeKey.id)
    }

    @Test(arguments: [
        UIApplication.didEnterBackgroundNotification,
        UIApplication.protectedDataWillBecomeUnavailableNotification
    ])
    func testBackgroundAndLockClearAgentSessions(event: Notification.Name) async {
        LocalSSHAgent.activate()  // normally done at launch

        let key = key(.perSession)
        auth.recordAuthentication(for: key.id, purpose: .localAgent)
        auth.recordAuthentication(for: key.id, purpose: .nativeSSH)
        NotificationCenter.default.post(name: event, object: nil)

        #expect(auth.needsAuthentication(for: key, purpose: .localAgent))
        #expect(!auth.needsAuthentication(for: key, purpose: .nativeSSH))
        auth.clearAuthentication(for: key.id)
    }

    @Test
    func testDifferentPurposesDoNotShareADeduplicatedPrompt() async throws {
        let keyID = UUID()
        let count = LockedCounter()
        let release = AsyncGate()
        let loader: @Sendable () async throws -> Data = {
            count.increment()
            await release.wait()
            return Data()
        }
        async let native = auth.loadWithDeduplication(keyID: keyID, purpose: .nativeSSH, loader: loader)
        async let agent = auth.loadWithDeduplication(keyID: keyID, purpose: .localAgent, loader: loader)
        while count.value < 2 { await Task.yield() }
        await release.open()
        _ = try await (native, agent)
        #expect(count.value == 2)
    }
}

// MARK: - Prompt abuse and resource bounds (§11.4)

@Suite
struct LocalSSHAgentAbuseControlTests {

    /// A manually advanced monotonic clock.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { instant } }
        func advance(_ duration: Duration) { lock.withLock { instant = instant.advanced(by: duration) } }
    }

    private func signRequest(_ key: AgentTestKey) -> ByteBuffer {
        ByteBuffer(bytes: AgentWire.signRequest(blob: key.blob, data: [1], flags: 0))
    }

    @Test
    func testCancellationStartsACooldownThatSuppressesFurtherPrompts() async throws {
        let clock = TestClock()
        let throttle = LocalSSHAgentAuthThrottle(now: { clock.now })
        let key = try AgentTestKey.make(.ed25519)
        let source = FakeAgentKeySource(keys: [key])
        source.loadError = SSHKeyManager.LoadError.authenticationCancelled
        let delegate = ShellSSHAgentDelegate(source: source, throttle: throttle)
        let blob = ByteBuffer(data: key.blob)

        await #expect(throws: (any Error).self) {
            _ = try await delegate.sign(publicKeyBlob: blob, data: ByteBuffer(), flags: 0)
        }
        #expect(source.loads.count == 1)

        // Within the cooldown: fails without another load (no prompt).
        for _ in 0..<5 {
            #expect(try await delegate.sign(publicKeyBlob: blob, data: ByteBuffer(), flags: 0) == nil)
        }
        clock.advance(.seconds(4))
        #expect(try await delegate.sign(publicKeyBlob: blob, data: ByteBuffer(), flags: 0) == nil)
        #expect(source.loads.count == 1)

        // After the cooldown a later success clears the failure state.
        clock.advance(.seconds(1))
        source.loadError = nil
        #expect(try await delegate.sign(publicKeyBlob: blob, data: ByteBuffer(), flags: 0) != nil)
        #expect(throttle.allows(keyID: key.key.id))
        #expect(source.loads.count == 2)
    }

    @Test
    func testCooldownIsPerKey() async throws {
        let throttle = LocalSSHAgentAuthThrottle()
        let a = try AgentTestKey.make(.ed25519)
        let b = try AgentTestKey.make(.ed25519)
        throttle.recordFailure(keyID: a.key.id)

        let delegate = ShellSSHAgentDelegate(source: FakeAgentKeySource(keys: [a, b]), throttle: throttle)
        #expect(try await delegate.sign(publicKeyBlob: ByteBuffer(data: a.blob), data: ByteBuffer(), flags: 0) == nil)
        #expect(try await delegate.sign(publicKeyBlob: ByteBuffer(data: b.blob), data: ByteBuffer(), flags: 0) != nil)
    }

    @Test
    func testFailedAuthenticationAlsoStartsTheCooldown() {
        #expect(ShellSSHAgentDelegate.isAuthenticationFailure(SSHKeyManager.LoadError.authenticationFailed))
        #expect(ShellSSHAgentDelegate.isAuthenticationFailure(SSHKeyManager.LoadError.authenticationCancelled))
        #expect(!ShellSSHAgentDelegate.isAuthenticationFailure(SSHKeyManager.LoadError.keyNotFound))
    }

    @Test
    func testUnknownKeyAndMalformedTrafficNeverTouchTheCooldown() async throws {
        let throttle = LocalSSHAgentAuthThrottle()
        let key = try AgentTestKey.make(.ed25519)
        let source = FakeAgentKeySource(keys: [key])
        source.loadError = SSHKeyManager.LoadError.authenticationCancelled
        let responder = LocalSSHAgentResponder(delegate: ShellSSHAgentDelegate(source: source, throttle: throttle))

        let stranger = try AgentTestKey.make(.ed25519)
        _ = await responder.response(to: ByteBuffer(bytes: AgentWire.signRequest(blob: stranger.blob, data: [1], flags: 0)))
        _ = await responder.response(to: ByteBuffer(bytes: [13, 0, 0, 0, 9]))
        #expect(throttle.allows(keyID: key.key.id))
        #expect(source.loads.isEmpty)
    }

    @Test
    func testResetAllClearsCooldowns() {
        let throttle = LocalSSHAgentAuthThrottle()
        let id = UUID()
        throttle.recordFailure(keyID: id)
        #expect(!throttle.allows(keyID: id))
        throttle.resetAll()
        #expect(throttle.allows(keyID: id))
    }

    @Test
    func testGlobalInFlightSignLimitIsEnforced() async throws {
        let key = try AgentTestKey.make(.ed25519)
        let source = FakeAgentKeySource(keys: [key])
        source.loadDelay = .milliseconds(300)
        let limiter = LocalSSHAgentSignLimiter(limit: 1)
        let responder = LocalSSHAgentResponder(
            delegate: ShellSSHAgentDelegate(source: source, throttle: LocalSSHAgentAuthThrottle()),
            signLimiter: limiter
        )
        let request = signRequest(key)

        async let held = responder.response(to: request)
        while limiter.current == 0 { await Task.yield() }

        // Over the limit: refused at once, never reaches the key.
        guard case .failure = await responder.response(to: request) else {
            Issue.record("expected failure over the in-flight limit")
            return
        }
        guard case .signResponse = await held else {
            Issue.record("the in-flight request should still complete")
            return
        }
        #expect(limiter.current == 0)
        #expect(source.loads.count == 1)

        // Capacity is released afterwards.
        source.loadDelay = nil
        guard case .signResponse = await responder.response(to: request) else {
            Issue.record("expected a signature once capacity is free")
            return
        }
    }

    @Test
    func testSignLimiterAccounting() {
        let limiter = LocalSSHAgentSignLimiter(limit: 2)
        #expect(limiter.tryAcquire())
        #expect(limiter.tryAcquire())
        #expect(!limiter.tryAcquire())
        limiter.release()
        #expect(limiter.tryAcquire())
        #expect(LocalSSHAgentSignLimiter.defaultGlobalLimit == 16)
        #expect(LocalSSHAgentClientRegistry.defaultClientLimit == 8)
    }
}

// MARK: - Separation from remote forwarding (§9)

@Suite(.enabled(if: SourceTree.isAvailable, "App sources are not readable from this build"))
struct LocalSSHAgentForwardingSeparationTests {

    @Test
    func testNothingEnablesRemoteAgentForwarding() throws {
        try SourceTree.requireSources()
        let source = SourceTree.allAppSource()
        #expect(!source.contains("enableAgentForwarding("))
        #expect(!source.contains("AuthAgentRequest("))
        #expect(!source.contains("registerAgentHandler"))
        #expect(!source.contains("AgentChannelHandler("))
    }
}

// MARK: - Helpers

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

actor AsyncGate {
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
