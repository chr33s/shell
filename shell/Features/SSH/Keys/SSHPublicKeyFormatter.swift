//
//  SSHPublicKeyFormatter.swift
//  shell
//
//  Formats SSH public keys as authorized_keys lines.
//  Shared by SSHCopyID and SSHKeyDetailView.
//

import Foundation
import os.log

/// Formats SSH keys as authorized_keys lines for installation on remote servers.
@MainActor
enum SSHPublicKeyFormatter {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHPublicKeyFormatter")

    /// Format an SSHKey as an authorized_keys line: "type base64 comment"
    ///
    /// Uses cached publicKeyBlob when available (no keychain access required),
    /// falls back to loading the private key and extracting the public key.
    ///
    /// - Parameters:
    ///   - key: The SSH key to format
    ///   - comment: Optional comment override (defaults to key name)
    /// - Returns: The formatted authorized_keys line
    /// - Throws: If the key cannot be loaded
    static func authorizedKeysLine(for key: SSHKey, comment: String? = nil) throws -> String {
        let keyComment = comment ?? key.name

        // Fast path: use cached public key blob (no keychain/biometric access)
        if let publicKeyBlob = key.publicKeyBlob {
            let base64Key = publicKeyBlob.base64EncodedString()
            let keyTypeString = key.effectiveSSHKeyTypeString
            return "\(keyTypeString) \(base64Key) \(keyComment)"
        }

        // Slow path: load from private key (may require biometric auth)
        let keyVariant = try SSHKeyManager.shared.loadPrivateKey(id: key.id)
        return SSHKeyGenerator.formatPublicKey(
            from: keyVariant,
            keyType: key.keyType,
            comment: keyComment
        )
    }

    /// Format multiple keys as authorized_keys content.
    ///
    /// - Parameter keys: The SSH keys to format
    /// - Returns: Array of (key, formatted line) tuples for each successfully formatted key
    static func authorizedKeysContent(for keys: [SSHKey]) -> [(key: SSHKey, line: String)] {
        var results: [(key: SSHKey, line: String)] = []

        for key in keys {
            do {
                let line = try authorizedKeysLine(for: key)
                results.append((key: key, line: line))
            } catch {
                logger.warning("Failed to format public key for '\(key.name)': \(error.localizedDescription)")
            }
        }

        return results
    }
}
