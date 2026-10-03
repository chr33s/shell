//
//  ShellSSHAgentDelegate.swift
//  shell
//
//  Signing facade the local SSH agent serves (ssh-agent-bridge-spec.md §11,
//  ssh-agent-bridge-v2-delta.md). It never holds key material of its own:
//  identities come from `SSHKeyManager` metadata filtered by the device-local
//  agent grant list, and each signature loads the key through the async,
//  authentication-aware `SSHKeyManager.loadPrivateKey(id:purpose:)` with the
//  `.localAgent` purpose, so Keychain ACLs, `.perSession` / `.perUse`,
//  deduplicated prompts, legacy-key migration and Secure Enclave
//  reconstruction stay where they are while agent sessions stay separate
//  from native SSH sessions.
//

import Foundation
import Combine
import NIOCore
import NIOFoundationCompat
import Citadel
import os

/// Where the agent gets identities and keys. Production is
/// ``SSHKeyManagerAgentKeySource``; tests substitute an in-memory source.
nonisolated protocol LocalSSHAgentKeySource: Sendable {
    /// The identities to advertise — and accept for signing — right now.
    func identityIndex() async -> SSHAgentIdentityIndex
    /// Loads the private key for `id` for local-agent use, enforcing its
    /// authentication requirement under the `.localAgent` purpose.
    func loadPrivateKey(id: UUID) async throws -> SSHPrivateKeyVariant
}

nonisolated struct ShellSSHAgentDelegate: SSHAgentDelegate {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "LocalSSHAgent")

    let source: any LocalSSHAgentKeySource
    let throttle: LocalSSHAgentAuthThrottle

    init(source: any LocalSSHAgentKeySource, throttle: LocalSSHAgentAuthThrottle = .shared) {
        self.source = source
        self.throttle = throttle
    }

    func listIdentities() async throws -> [SSHAgentIdentity] {
        await source.identityIndex().identities
    }

    /// Returns `nil` (→ `SSH_AGENT_FAILURE`) for a blob that is not an
    /// allowed identity — membership is checked here, not only at
    /// enumeration, and again once the key has loaded, so a revoke applies to
    /// connected clients and to a prompt already on screen — and for a key
    /// still in its post-cancel cooldown. A key that disappeared since
    /// enumeration, a cancelled prompt or a locked device throw from the
    /// loader and fail the request the same way.
    func sign(publicKeyBlob: ByteBuffer, data: ByteBuffer, flags: UInt32) async throws -> ByteBuffer? {
        let blob = Data(buffer: publicKeyBlob)
        guard let entry = await source.identityIndex().entry(forBlob: blob) else {
            Self.logger.info("Agent sign: no allowed identity matches the requested blob")
            return nil
        }
        guard throttle.allows(keyID: entry.keyID) else {
            Self.logger.info("Agent sign: key \(entry.keyID.uuidString, privacy: .private) in authentication cooldown")
            return nil
        }

        let key: SSHPrivateKeyVariant
        do {
            key = try await source.loadPrivateKey(id: entry.keyID)
        } catch {
            if Self.isAuthenticationFailure(error) {
                throttle.recordFailure(keyID: entry.keyID)
            }
            Self.logger.info("Agent sign: key \(entry.keyID.uuidString, privacy: .private) unavailable: \(String(describing: type(of: error)), privacy: .public)")
            throw error
        }
        throttle.recordSuccess(keyID: entry.keyID)

        // The load may have waited on Face ID / passcode; the grant may have
        // been revoked (or the agent disabled) while the prompt was up.
        guard await source.identityIndex().entry(forBlob: blob)?.keyID == entry.keyID else {
            Self.logger.info("Agent sign: key \(entry.keyID.uuidString, privacy: .private) revoked during authentication")
            return nil
        }

        let signature = try SSHPrivateKeySigner.signAgentPayload(
            key: key,
            keyType: entry.keyType,
            data: data,
            flags: SSHAgentSignatureFlags(rawValue: flags)
        )
        Self.logger.info("Agent sign: signed with key \(entry.keyID.uuidString, privacy: .private)\(entry.isCertificate ? " (certificate)" : "", privacy: .public)")
        return signature
    }

    /// A biometric/passcode prompt was cancelled or failed — the errors that
    /// start the per-key cooldown. Missing keys or a locked device do not.
    static func isAuthenticationFailure(_ error: any Error) -> Bool {
        switch error {
        case SSHKeyManager.LoadError.authenticationCancelled,
             SSHKeyManager.LoadError.authenticationFailed:
            return true
        default:
            return false
        }
    }
}

/// Production source over `SSHKeyManager`.
nonisolated struct SSHKeyManagerAgentKeySource: LocalSSHAgentKeySource {
    func identityIndex() async -> SSHAgentIdentityIndex {
        await SSHAgentKeyAvailability.shared.identityIndex()
    }

    func loadPrivateKey(id: UUID) async throws -> SSHPrivateKeyVariant {
        try await SSHAgentKeyAvailability.shared.loadPrivateKey(id: id)
    }
}

/// The agent refused a key whose authorization ended while it was loading.
nonisolated enum LocalSSHAgentError: Error, Equatable {
    case authorizationRevoked
}

/// Builds the advertised index from `SSHKeyManager` state, and loads keys for
/// the agent.
///
/// Whether an allowed key's private material exists on this device is checked
/// with an attribute-only Keychain query (never the secret), off the main
/// actor. Positive answers are cached until `keysDidChange`; negative ones for
/// a short interval, so a key whose secret arrives later through iCloud
/// Keychain becomes available without the agent polling, and a client that
/// loops on identity requests cannot drive repeated Keychain queries.
@MainActor
final class SSHAgentKeyAvailability {
    static let shared = SSHAgentKeyAvailability()

    static let absentRecheckInterval: Duration = .seconds(10)

    private var confirmedLocal: Set<UUID> = []
    private var confirmedAbsent: [UUID: ContinuousClock.Instant] = [:]
    private var keysChangedSubscription: AnyCancellable?

    private init() {
        keysChangedSubscription = SSHKeyManager.shared.keysDidChange.sink { [weak self] in
            self?.confirmedLocal.removeAll()
            self?.confirmedAbsent.removeAll()
        }
    }

    func identityIndex() async -> SSHAgentIdentityIndex {
        let policy = LocalSSHAgentPolicy.current
        guard policy.enabled, !policy.allowedKeyIDs.isEmpty else { return .empty }
        let manager = SSHKeyManager.shared
        let allowed = Set(policy.allowedKeyIDs)
        let now = ContinuousClock.now
        let probes = manager.savedKeys
            .filter { key in
                guard allowed.contains(key.id), !confirmedLocal.contains(key.id) else { return false }
                guard let absentAt = confirmedAbsent[key.id] else { return true }
                return now - absentAt >= Self.absentRecheckInterval
            }
            .map { LocalMaterialProbe(id: $0.id, isDeviceBound: $0.isDeviceBound) }
        if !probes.isEmpty {
            let present = await Self.locallyPresent(probes)
            confirmedLocal.formUnion(present)
            for probe in probes where !present.contains(probe.id) {
                confirmedAbsent[probe.id] = now
            }
        }

        // Re-read after the await: grants or keys may have changed meanwhile.
        return SSHAgentIdentityIndex(
            policy: LocalSSHAgentPolicy.current,
            keys: manager.savedKeys,
            locallyUsable: confirmedLocal.subtracting(manager.keysNeedingUnlock)
        )
    }

    /// Loads with the `.localAgent` purpose. If authorization ended while the
    /// load waited on a prompt (revoke, disable, background, device lock), the
    /// key is refused and the session that prompt just recorded is dropped,
    /// so it can neither sign nor leave silent authority behind.
    func loadPrivateKey(id: UUID) async throws -> SSHPrivateKeyVariant {
        let epoch = LocalSSHAgent.authorizationEpoch
        let key = try await SSHKeyManager.shared.loadPrivateKey(id: id, purpose: .localAgent)
        let policy = LocalSSHAgentPolicy.current
        guard epoch == LocalSSHAgent.authorizationEpoch, policy.enabled, policy.isAllowed(id) else {
            SSHKeyAuthManager.shared.clearAuthentication(for: id, purpose: .localAgent)
            throw LocalSSHAgentError.authorizationRevoked
        }
        return key
    }

    private nonisolated struct LocalMaterialProbe: Sendable {
        let id: UUID
        let isDeviceBound: Bool
    }

    /// A Secure Enclave reference is always a non-synchronizable item; one
    /// that only exists as metadata from another device has no such item here.
    @concurrent
    private nonisolated static func locallyPresent(_ probes: [LocalMaterialProbe]) async -> Set<UUID> {
        let keychain = KeychainManager.shared
        var present: Set<UUID> = []
        for probe in probes {
            if probe.isDeviceBound && !SSHKeyManager.isSecureEnclaveAvailable {
                continue
            }
            let exists = (try? keychain.sshPrivateKeyExists(
                identifier: probe.id.uuidString,
                synchronizable: probe.isDeviceBound ? false : nil
            )) ?? false
            if exists {
                present.insert(probe.id)
            }
        }
        return present
    }
}
