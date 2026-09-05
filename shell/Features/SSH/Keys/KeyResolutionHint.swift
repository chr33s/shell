//
//  KeyResolutionHint.swift
//  shell
//
//  Metadata hints stored alongside key UUIDs in synced profiles/history
//  to enable cross-device key resolution when the UUID doesn't exist locally.
//

import Foundation

/// Metadata captured from an SSH key at save time, stored in synced profiles and history
/// entries so other devices can resolve the key through alternative identifiers.
struct KeyResolutionHint: Codable, Hashable, Sendable {
    /// SHA256 fingerprint (hex) — matches the same key anywhere
    var fingerprint: String?

    /// Display name for UI fallback when key can't be resolved
    var keyName: String?

    /// Algorithm type for filtering compatible keys
    var keyType: SSHKey.KeyType?

    /// Creates a resolution hint from an existing SSH key's metadata
    @MainActor
    static func from(key: SSHKey) -> KeyResolutionHint {
        var hint = KeyResolutionHint()
        hint.fingerprint = key.fingerprint
        hint.keyName = key.name
        hint.keyType = key.keyType

        return hint
    }

    /// Creates a hint dict for a single key UUID
    @MainActor
    static func hintsDict(forKeyID keyID: UUID) -> [String: KeyResolutionHint] {
        guard let key = SSHKeyManager.shared.findKey(id: keyID) else { return [:] }
        return [keyID.uuidString: from(key: key)]
    }

    /// Creates a hint dict for multiple key UUIDs (target + jump host keys)
    @MainActor
    static func hintsDict(forKeyIDs keyIDs: [UUID]) -> [String: KeyResolutionHint] {
        let keyManager = SSHKeyManager.shared
        var hints: [String: KeyResolutionHint] = [:]
        for keyID in keyIDs {
            if let key = keyManager.findKey(id: keyID) {
                hints[keyID.uuidString] = from(key: key)
            }
        }
        return hints
    }

    /// Builds hints for an SSHConfig's key references (target + jump host)
    @MainActor
    static func hints(for config: SSHConfig) -> [String: KeyResolutionHint]? {
        var keyIDs: [UUID] = []

        if let keyID = config.authMethod.keyID {
            keyIDs.append(keyID)
        }

        if let jumpKeyID = config.jumpHost?.authMethod.keyID {
            keyIDs.append(jumpKeyID)
        }

        let result = hintsDict(forKeyIDs: keyIDs)
        return result.isEmpty ? nil : result
    }
}
