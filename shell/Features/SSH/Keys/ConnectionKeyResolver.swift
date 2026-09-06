//
//  ConnectionKeyResolver.swift
//  shell
//
//  Central orchestrator for cross-device SSH key resolution.
//  Combines resolution hints, device overrides, and SSHKeyManager
//  to resolve key UUIDs that may not exist on the current device.
//

import Foundation
import os.log

/// Result of attempting to resolve keys for a connection config
enum KeyResolutionResult: Sendable {
    /// All keys resolved successfully — config is ready to use
    case resolved(SSHConfig)
    /// One or more keys could not be resolved — needs user interaction
    case unresolved(SSHConfig, unresolvedKeys: [UnresolvedKeyInfo])
}

/// Information about a key that couldn't be resolved
struct UnresolvedKeyInfo: Sendable {
    /// The original UUID that couldn't be found
    let originalKeyID: UUID
    /// The hint associated with the key (if any)
    let hint: KeyResolutionHint?
    /// Whether this is for the jump host (vs target)
    let isJumpHost: Bool
}

@MainActor
enum ConnectionKeyResolver {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "KeyResolver")

    // MARK: - Full Resolution

    /// Resolves all key references in an SSH config, returning a config with locally-valid UUIDs.
    /// Checks device overrides first, then falls back to hint-based resolution.
    ///
    /// - Parameters:
    ///   - config: The SSH config with potentially unresolvable key UUIDs
    ///   - profileID: Optional profile UUID (for device override lookup)
    ///   - connectionIdentity: Connection identity string to look the device
    ///     override up under when there is no profile. Defaults to the config's
    ///     own `connectionIdentity`, so a QuickConnect caller that has nothing
    ///     but a config still finds the override the key-resolution sheet saved.
    /// - Returns: Resolution result with either a fully-resolved config or unresolved key info
    static func resolve(
        config: SSHConfig,
        profileID: UUID? = nil,
        connectionIdentity: String? = nil
    ) -> KeyResolutionResult {
        var resolvedConfig = config
        var unresolvedKeys: [UnresolvedKeyInfo] = []
        let overrideManager = DeviceKeyOverrideManager.shared
        let keyManager = SSHKeyManager.shared

        // Look up device override. A saved profile keys its override by UUID;
        // everything else — QuickConnect, deep links, history — has no UUID and
        // keys off the connection's own identity. Deriving that identity here
        // when the caller did not supply one is what makes "Always use on this
        // device" work for `ssh me@host`: the caller only ever has a config,
        // and the same `config.connectionIdentity` is what `KeyResolutionSheet`
        // wrote the override under.
        let deviceOverride: DeviceKeyOverride?
        if let profileID {
            deviceOverride = overrideManager.override(forProfile: profileID)
        } else {
            deviceOverride = overrideManager.override(
                forConnectionIdentity: connectionIdentity ?? config.connectionIdentity
            )
        }

        // Resolve target key
        if case .key(let keyID) = config.authMethod {
            let resolvedKey = resolveTargetKey(
                keyID: keyID,
                config: config,
                deviceOverride: deviceOverride,
                keyManager: keyManager
            )
            if let resolvedKey {
                resolvedConfig.authMethod = .key(resolvedKey.id)
            } else {
                let hint = resolutionHint(for: keyID, config: config)
                unresolvedKeys.append(UnresolvedKeyInfo(originalKeyID: keyID, hint: hint, isJumpHost: false))
            }
        }

        // Resolve jump host key
        if var jumpConfig = resolvedConfig.jumpHost, case .key(let jumpKeyID) = jumpConfig.authMethod {
            let resolvedKey = resolveJumpHostKey(
                keyID: jumpKeyID,
                config: config,
                jumpConfig: jumpConfig,
                deviceOverride: deviceOverride,
                keyManager: keyManager
            )
            if let resolvedKey {
                jumpConfig.authMethod = .key(resolvedKey.id)
                resolvedConfig.jumpHost = jumpConfig
            } else {
                let hint = resolutionHint(for: jumpKeyID, config: config, jumpConfig: jumpConfig)
                unresolvedKeys.append(UnresolvedKeyInfo(originalKeyID: jumpKeyID, hint: hint, isJumpHost: true))
            }
        }

        // Resolve fallback key IDs (filter to locally available keys)
        if let fallbackIDs = resolvedConfig.fallbackKeyIDs {
            resolvedConfig.fallbackKeyIDs = fallbackIDs.filter { keyManager.findKey(id: $0) != nil }
            if resolvedConfig.fallbackKeyIDs?.isEmpty == true {
                resolvedConfig.fallbackKeyIDs = nil
            }
        }

        if unresolvedKeys.isEmpty {
            return .resolved(resolvedConfig)
        } else {
            return .unresolved(resolvedConfig, unresolvedKeys: unresolvedKeys)
        }
    }

    // MARK: - Lightweight Availability Check

    /// Checks if a config's keys are resolvable without performing the full resolution.
    /// Used for profile list badges.
    static func isResolvable(config: SSHConfig, profileID: UUID? = nil) -> Bool {
        let keyManager = SSHKeyManager.shared
        let overrideManager = DeviceKeyOverrideManager.shared

        // Check target key
        if case .key(let keyID) = config.authMethod {
            let override = profileID.flatMap { overrideManager.override(forProfile: $0) }
            if let overrideKeyID = override?.targetKeyID {
                if keyManager.findKey(id: overrideKeyID) == nil { return false }
            } else {
                let hint = resolutionHint(for: keyID, config: config)
                if keyManager.resolveKey(id: keyID, hint: hint) == nil { return false }
            }
        }

        // Check jump host key
        if let jumpConfig = config.jumpHost, case .key(let jumpKeyID) = jumpConfig.authMethod {
            let override = profileID.flatMap { overrideManager.override(forProfile: $0) }
            if let overrideKeyID = override?.jumpHostKeyID {
                if keyManager.findKey(id: overrideKeyID) == nil { return false }
            } else {
                let hint = resolutionHint(for: jumpKeyID, config: config, jumpConfig: jumpConfig)
                if keyManager.resolveKey(id: jumpKeyID, hint: hint) == nil { return false }
            }
        }

        return true
    }

    // MARK: - Private

    /// The resolution hint recorded for `keyID`: config-level first, then the
    /// jump host's own dictionary, then — only for a profile that already
    /// carries explicit hints — the identity-metadata store.
    ///
    /// The metadata fallback fills a *gap* in a profile whose author already
    /// recorded hints for some of its keys: a profile written before jump-host
    /// hints were captured, or one whose target key was hinted while the jump
    /// key was not. It deliberately does not extend to profiles that carry no
    /// hints at all. The store now holds records pulled from CloudKit, and
    /// consulting it for every profile would silently widen the trust boundary
    /// from "the hints this profile carries" to "anything any device ever
    /// published to the account".
    ///
    /// Either way resolution stays fail-closed: a hint only ever matches a key
    /// that is already on this device, by exact SHA256 fingerprint — the same
    /// public key under a different UUID. A hint can therefore narrow
    /// resolution, never select a different credential and never downgrade to
    /// password auth.
    /// `metadataEntries` is a testability seam: it defaults to exactly the
    /// value the body read before (`SSHIdentityMetadataStore.shared.entries`),
    /// so every existing caller is unchanged. The store is a `private init()`
    /// singleton writing to a fixed on-disk path, and the gate below cannot be
    /// exercised at all without being able to state what the store holds.
    static func resolutionHint(
        for keyID: UUID,
        config: SSHConfig,
        jumpConfig: SSHConfig.JumpHostConfig? = nil,
        metadataEntries: [SSHIdentityMetadata]? = nil
    ) -> KeyResolutionHint? {
        let metadataEntries = metadataEntries ?? SSHIdentityMetadataStore.shared.entries
        if let recorded = config.keyResolutionHints?[keyID.uuidString] {
            return recorded
        }
        if let recorded = jumpConfig?.keyResolutionHints?[keyID.uuidString] {
            return recorded
        }
        guard carriesExplicitHints(config: config, jumpConfig: jumpConfig) else { return nil }
        guard let entry = metadataEntries.first(where: { $0.id == keyID }),
              // An empty fingerprint would match any local key whose own
              // fingerprint failed to compute, so it is never a usable hint.
              !entry.fingerprint.isEmpty else {
            return nil
        }
        var synthesized = KeyResolutionHint()
        synthesized.fingerprint = entry.fingerprint
        synthesized.keyName = entry.name
        synthesized.keyType = SSHKey.KeyType(rawValue: entry.keyType)
        return synthesized
    }

    /// Whether this profile recorded any key resolution hints of its own —
    /// the gate on the identity-metadata fallback above.
    private static func carriesExplicitHints(
        config: SSHConfig,
        jumpConfig: SSHConfig.JumpHostConfig?
    ) -> Bool {
        if let hints = config.keyResolutionHints, !hints.isEmpty { return true }
        if let hints = jumpConfig?.keyResolutionHints, !hints.isEmpty { return true }
        return false
    }

    private static func resolveTargetKey(
        keyID: UUID,
        config: SSHConfig,
        deviceOverride: DeviceKeyOverride?,
        keyManager: SSHKeyManager
    ) -> SSHKey? {
        // Device override takes priority
        if let overrideKeyID = deviceOverride?.targetKeyID,
           let key = keyManager.findKey(id: overrideKeyID) {
            logger.info("Resolved target key via device override: \(key.name)")
            return key
        }

        // Hint-based resolution
        let hint = resolutionHint(for: keyID, config: config)
        if let key = keyManager.resolveKey(id: keyID, hint: hint) {
            return key
        }

        return nil
    }

    private static func resolveJumpHostKey(
        keyID: UUID,
        config: SSHConfig,
        jumpConfig: SSHConfig.JumpHostConfig,
        deviceOverride: DeviceKeyOverride?,
        keyManager: SSHKeyManager
    ) -> SSHKey? {
        // Device override takes priority
        if let overrideKeyID = deviceOverride?.jumpHostKeyID,
           let key = keyManager.findKey(id: overrideKeyID) {
            logger.info("Resolved jump host key via device override: \(key.name)")
            return key
        }

        // Hint-based resolution (config-level, then jump-level, then metadata)
        let hint = resolutionHint(for: keyID, config: config, jumpConfig: jumpConfig)
        if let key = keyManager.resolveKey(id: keyID, hint: hint) {
            return key
        }

        return nil
    }
}
