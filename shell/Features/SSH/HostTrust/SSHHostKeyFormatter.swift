//
//  SSHHostKeyFormatter.swift
//  shell
//
//  Shared helpers for deriving display/storage forms from a NIOSSHPublicKey.
//  Used by both the host-key validation delegate and the host-CA manager so
//  fingerprints and key blobs are computed identically everywhere (the cert
//  fallback path compares against stored KnownHost fingerprints, so they must
//  match byte-for-byte).
//

import Foundation
import Crypto
import NIOSSH

/// Error thrown when host key serialization fails
struct HostKeySerializationError: Error, LocalizedError {
    var errorDescription: String? {
        "Failed to serialize host key"
    }
}

enum SSHHostKeyFormatter {
    /// SHA256 fingerprint in colon-separated hex, prefixed with "SHA256:".
    /// Matches the format stored in `KnownHost.fingerprint`.
    nonisolated static func fingerprint(for key: NIOSSHPublicKey) -> String {
        let openSSHString = String(openSSHPublicKey: key)
        let components = openSSHString.split(separator: " ", maxSplits: 1)

        let data: Data
        if components.count >= 2, let keyData = Data(base64Encoded: String(components[1])) {
            data = keyData
        } else {
            // Fallback: hash the entire string.
            data = openSSHString.data(using: .utf8) ?? Data()
        }

        let hash = SHA256.hash(data: data)
        let fingerprint = hash.compactMap { String(format: "%02x", $0) }.joined(separator: ":")
        return "SHA256:\(fingerprint)"
    }

    /// Algorithm identifier (e.g. "ssh-ed25519", "ecdsa-sha2-nistp256").
    static func keyType(for key: NIOSSHPublicKey) -> String {
        let openSSHString = String(openSSHPublicKey: key)
        let components = openSSHString.split(separator: " ")
        return components.first.map(String.init) ?? "unknown"
    }

    /// Base64 wire blob (the portion after the algorithm id) for storage.
    nonisolated static func base64Blob(for key: NIOSSHPublicKey) throws -> String {
        let openSSHString = String(openSSHPublicKey: key)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2 else {
            throw HostKeySerializationError()
        }
        return String(components[1])
    }
}
