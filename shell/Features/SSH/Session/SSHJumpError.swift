//
//  SSHJumpError.swift
//  shell
//
//  Error types for SSH jump host connections
//

import Foundation

/// Errors specific to SSH jump host connections
enum SSHJumpError: LocalizedError {
    /// Authentication failed (either jump or target)
    case authenticationFailed(host: String, isJumpHost: Bool)

    /// Host key rejected by user
    case hostKeyRejected(host: String, isJumpHost: Bool)

    var errorDescription: String? {
        switch self {
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
        }
    }

    /// Whether this error is related to the jump host (vs target)
    var isJumpHostError: Bool {
        switch self {
        case .authenticationFailed(_, let isJumpHost):
            return isJumpHost
        case .hostKeyRejected(_, let isJumpHost):
            return isJumpHost
        }
    }
}
