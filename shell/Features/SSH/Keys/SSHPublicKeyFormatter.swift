//
//  SSHPublicKeyFormatter.swift
//  shell
//
//  Formats SSH public keys as authorized_keys lines.
//  Shared by SSHKeyDetailView and SSHKeyGenerateView.
//

import Foundation

/// Why an `authorized_keys` line could not be produced.
///
/// This path must fail loudly. The value the user copies here is pasted
/// straight into a server's `authorized_keys`; a placeholder that merely
/// looks like a key installs a broken line and key auth then fails on that
/// host with nothing to diagnose it from.
enum SSHPublicKeyFormatterError: LocalizedError {
    /// The private key loaded, but no usable public key could be derived
    /// from it.
    case publicKeyUnavailable(keyName: String)

    var errorDescription: String? {
        switch self {
        case .publicKeyUnavailable(let keyName):
            return String(
                localized: "Could not read the public key for “\(keyName)”. The stored key may be damaged; re-import or regenerate it.",
                comment: "SSH public key export error: the public key could not be derived from the stored private key"
            )
        }
    }
}

/// Formats SSH keys as authorized_keys lines for installation on remote servers.
@MainActor
enum SSHPublicKeyFormatter {
    /// Format an SSHKey as an authorized_keys line: "type base64 comment"
    ///
    /// Uses cached publicKeyBlob when available (no keychain access required),
    /// falls back to loading the private key and deriving the public key blob
    /// from it.
    ///
    /// - Parameters:
    ///   - key: The SSH key to format
    ///   - comment: Optional comment override (defaults to key name)
    /// - Returns: The formatted authorized_keys line
    /// - Throws: `SSHPublicKeyFormatterError.publicKeyUnavailable` if no public
    ///   key can be derived, or whatever `SSHKeyManager.loadPrivateKey` throws.
    static func authorizedKeysLine(for key: SSHKey, comment: String? = nil) throws -> String {
        let keyComment = comment ?? key.name
        let keyTypeString = key.effectiveSSHKeyTypeString

        // Fast path: use cached public key blob (no keychain/biometric access)
        if let publicKeyBlob = key.publicKeyBlob,
           SSHPublicKeyBlob.isComplete(publicKeyBlob, keyType: key.keyType) {
            return "\(keyTypeString) \(publicKeyBlob.base64EncodedString()) \(keyComment)"
        }

        // Slow path: derive the blob from the stored private key (may require
        // biometric auth). Same wire format the fast path caches, so both
        // paths emit a byte-identical line for the same key.
        let keyVariant = try SSHKeyManager.shared.loadPrivateKey(id: key.id)
        guard let derived = SSHPublicKeyBlob.makeData(from: keyVariant, keyType: key.keyType),
              SSHPublicKeyBlob.isComplete(derived, keyType: key.keyType) else {
            throw SSHPublicKeyFormatterError.publicKeyUnavailable(keyName: key.name)
        }
        return "\(keyTypeString) \(derived.base64EncodedString()) \(keyComment)"
    }
}
