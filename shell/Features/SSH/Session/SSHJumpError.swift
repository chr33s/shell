//
//  SSHJumpError.swift
//  shell
//
//  Error types for SSH jump host connections
//

import Foundation

/// Errors specific to SSH jump host connections
enum SSHJumpError: LocalizedError {
    /// Connection to jump host failed
    case jumpConnectionFailed(host: String, underlying: Error)

    /// Connection to target through jump host failed
    case targetConnectionFailed(host: String, underlying: Error)

    /// Authentication failed (either jump or target)
    case authenticationFailed(host: String, isJumpHost: Bool)

    /// Host key rejected by user
    case hostKeyRejected(host: String, isJumpHost: Bool)

    /// Tunnel creation failed
    case tunnelCreationFailed(targetHost: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .jumpConnectionFailed(let host, let underlying):
            return "Failed to connect to jump host \(host): \(underlying.localizedDescription)"

        case .targetConnectionFailed(let host, let underlying):
            return "Connected to jump host but failed to reach \(host): \(underlying.localizedDescription)"

        case .authenticationFailed(let host, let isJumpHost):
            if isJumpHost {
                return "Authentication failed for jump host \(host)"
            } else {
                return "Authentication failed for target \(host)"
            }

        case .hostKeyRejected(let host, let isJumpHost):
            if isJumpHost {
                return "Host key rejected for jump host \(host)"
            } else {
                return "Host key rejected for target \(host)"
            }

        case .tunnelCreationFailed(let targetHost, let reason):
            return "Failed to create tunnel to \(targetHost): \(reason)"
        }
    }

    /// Whether this error is related to the jump host (vs target)
    var isJumpHostError: Bool {
        switch self {
        case .jumpConnectionFailed:
            return true
        case .authenticationFailed(_, let isJumpHost):
            return isJumpHost
        case .hostKeyRejected(_, let isJumpHost):
            return isJumpHost
        case .targetConnectionFailed, .tunnelCreationFailed:
            return false
        }
    }
}
