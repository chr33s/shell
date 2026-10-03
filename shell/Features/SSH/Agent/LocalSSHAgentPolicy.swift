//
//  LocalSSHAgentPolicy.swift
//  shell
//
//  Device-local permission model for the local SSH agent
//  (ssh-agent-bridge-v2-delta.md §2, §3, §10). Agent membership is an
//  explicit, ordered grant list — never derived from `defaultKeyIDs`, key
//  import/generation, profile use, certificates or storage level — and lives
//  only in device-only settings, so another device's grant can never reach
//  this one through synced key metadata.
//

import Foundation

nonisolated struct LocalSSHAgentPolicy: Codable, Sendable, Equatable {
    var enabled: Bool
    /// Agent membership and advertisement order. Stale UUIDs are harmless:
    /// identities are resolved against current local keys on every request.
    var allowedKeyIDs: [UUID]

    /// New installs (and any V1 state): no delegated signing capability.
    static let initial = LocalSSHAgentPolicy(enabled: false, allowedKeyIDs: [])

    func isAllowed(_ keyID: UUID) -> Bool {
        allowedKeyIDs.contains(keyID)
    }

    /// Grants append (so earlier grants keep their order); revokes remove.
    mutating func setAllowed(_ allowed: Bool, keyID: UUID) {
        if allowed {
            if !allowedKeyIDs.contains(keyID) {
                allowedKeyIDs.append(keyID)
            }
        } else {
            allowedKeyIDs.removeAll { $0 == keyID }
        }
    }

    // MARK: - Allowlist wire format (device-only setting)

    static func decodeAllowedKeyIDs(_ data: Data?) -> [UUID] {
        guard let data, let strings = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        var seen: Set<UUID> = []
        return strings.compactMap(UUID.init(uuidString:)).filter { seen.insert($0).inserted }
    }

    static func encodeAllowedKeyIDs(_ ids: [UUID]) -> Data? {
        ids.isEmpty ? nil : try? JSONEncoder().encode(ids.map(\.uuidString))
    }
}

// MARK: - Settings-backed store

@MainActor
extension LocalSSHAgentPolicy {
    /// The policy as currently persisted on this device.
    static var current: LocalSSHAgentPolicy {
        let store = SettingsStore.shared
        return LocalSSHAgentPolicy(
            enabled: store.value(Settings.Connections.localSSHAgent),
            allowedKeyIDs: decodeAllowedKeyIDs(store.value(Settings.Connections.localSSHAgentAllowedKeyIDs))
        )
    }

    /// Grants or revokes one identity. A revoke takes effect at once for
    /// already-connected clients (the agent re-checks membership at sign
    /// time) and drops that key's local-agent session authorization.
    static func setAllowed(_ allowed: Bool, keyID: UUID) {
        var policy = current
        policy.setAllowed(allowed, keyID: keyID)
        SettingsStore.shared.set(
            Settings.Connections.localSSHAgentAllowedKeyIDs,
            encodeAllowedKeyIDs(policy.allowedKeyIDs)
        )
        if !allowed {
            LocalSSHAgent.invalidateAuthorization(keyID: keyID)
        }
    }

    /// Opportunistic cleanup when an identity is deleted.
    static func keyDeleted(_ keyID: UUID) {
        guard current.isAllowed(keyID) else { return }
        setAllowed(false, keyID: keyID)
    }
}
