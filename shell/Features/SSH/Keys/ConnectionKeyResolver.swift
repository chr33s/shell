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
    ///   - connectionIdentity: Optional connection identity string (for QuickConnect overrides)
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

        // Look up device override
        let deviceOverride: DeviceKeyOverride?
        if let profileID {
            deviceOverride = overrideManager.override(forProfile: profileID)
        } else if let connectionIdentity {
            deviceOverride = overrideManager.override(forConnectionIdentity: connectionIdentity)
        } else {
            deviceOverride = nil
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
                let hint = config.keyResolutionHints?[keyID.uuidString]
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
                let hint = config.keyResolutionHints?[jumpKeyID.uuidString]
                    ?? jumpConfig.keyResolutionHints?[jumpKeyID.uuidString]
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
                let hint = config.keyResolutionHints?[keyID.uuidString]
                if keyManager.resolveKey(id: keyID, hint: hint) == nil { return false }
            }
        }

        // Check jump host key
        if let jumpConfig = config.jumpHost, case .key(let jumpKeyID) = jumpConfig.authMethod {
            let override = profileID.flatMap { overrideManager.override(forProfile: $0) }
            if let overrideKeyID = override?.jumpHostKeyID {
                if keyManager.findKey(id: overrideKeyID) == nil { return false }
            } else {
                let hint = config.keyResolutionHints?[jumpKeyID.uuidString]
                    ?? jumpConfig.keyResolutionHints?[jumpKeyID.uuidString]
                if keyManager.resolveKey(id: jumpKeyID, hint: hint) == nil { return false }
            }
        }

        return true
    }

    // MARK: - Private

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
        let hint = config.keyResolutionHints?[keyID.uuidString]
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

        // Hint-based resolution (check both config-level and jump-level hints)
        let hint = config.keyResolutionHints?[keyID.uuidString]
            ?? jumpConfig.keyResolutionHints?[keyID.uuidString]
        if let key = keyManager.resolveKey(id: keyID, hint: hint) {
            return key
        }

        return nil
    }
}
