//
//  SSHConnectionInfo.swift
//  shell
//
//  Detailed SSH connection metadata including negotiated algorithms
//

import Foundation

/// Detailed information about an active SSH connection
struct SSHConnectionInfo: Sendable {
    let host: String
    let port: Int
    let username: String
    let resolvedIP: String?
    let connectedAt: Date
    let jumpHost: String?
    let jumpPort: Int?
    let keyExchangeAlgorithm: String?
    let hostKeyAlgorithm: String?
    let cipherAlgorithm: String?
    let macAlgorithm: String?

    /// Whether the negotiated key exchange uses a post-quantum KEM.
    /// This is what protects against "store now, decrypt later" attacks —
    /// a PQ host key alone can't help since it only affects authentication.
    var isPostQuantumKeyExchange: Bool {
        let kex = (keyExchangeAlgorithm ?? "").lowercased()
        return kex.contains("mlkem") || kex.contains("sntrup")
    }

    /// Whether the negotiated host-key algorithm is post-quantum.
    var isPostQuantumHostKey: Bool {
        let hk = (hostKeyAlgorithm ?? "").lowercased()
        return hk.contains("mldsa") || hk.contains("sntrup")
    }

    /// Whether any negotiated algorithm uses post-quantum cryptography.
    var isPostQuantum: Bool {
        isPostQuantumKeyExchange || isPostQuantumHostKey
    }
}
