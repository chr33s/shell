//
//  ConnectionInfo.swift
//  shell
//
//  Unified connection info enum for the Connection Info sheet
//

import Foundation

/// Unified connection information across the session types this fork supports.
enum ConnectionInfo: Identifiable, Sendable {
    case local(shell: String, workingDirectory: String?, connectedAt: Date)
    case ssh(SSHConnectionInfo)

    var id: String {
        switch self {
        case .local: return "local"
        case .ssh(let info): return "ssh-\(info.host)-\(info.port)"
        }
    }

    /// The connection start time
    var connectedAt: Date {
        switch self {
        case .local(_, _, let date): return date
        case .ssh(let info): return info.connectedAt
        }
    }

    /// User-entered host suitable for clipboard actions.
    var copyableHostname: String? {
        switch self {
        case .ssh(let info): return info.host
        case .local: return nil
        }
    }

    /// Resolved address for a live SSH session, when available.
    var copyableIPAddress: String? {
        switch self {
        case .ssh(let info): return info.resolvedIP
        case .local: return nil
        }
    }
}
