//
//  ConnectionConfig.swift
//  shell
//
//  Unified connection configuration for terminal sessions. The fork has two
//  kinds: a local shell and SSH (optionally launched from the local shell).
//

import Foundation

/// Unified connection configuration for terminal sessions
enum ConnectionConfig: Equatable {
    /// Local shell (ios_system on iOS, PTY on Catalyst)
    /// workingDirectory: Initial CWD for the shell (nil = user's home directory)
    case local(workingDirectory: String? = nil)

    /// SSH connection to remote host
    case ssh(SSHConfig)

    /// SSH session launched from local shell - returns to shell when complete
    /// shellWorkingDirectory: CWD of the local shell at launch time (for shell return)
    case shellLaunchedSSH(sshConfig: SSHConfig, shellWorkingDirectory: String?)

    /// The underlying SSHConfig for connection types built on one. Used to
    /// derive a stable per-connection identity (user@host:port), e.g. for the
    /// tmux gateway's last-session-name persistence (TmuxGatewaySessionStore).
    var underlyingSSHConfig: SSHConfig? {
        switch self {
        case .ssh(let config):
            return config
        case .shellLaunchedSSH(let sshConfig, _):
            return sshConfig
        case .local:
            return nil
        }
    }

    /// Display name for UI
    var displayName: String {
        switch self {
        case .local:
            return String(localized: "Local Shell", comment: "Connection type: local terminal shell")
        case .ssh(let config):
            return config.displayName
        case .shellLaunchedSSH(let sshConfig, _):
            return sshConfig.displayName
        }
    }

    var lifecycleDebugKind: String {
        switch self {
        case .local: return "local"
        case .ssh: return "ssh"
        case .shellLaunchedSSH: return "shellLaunchedSSH"
        }
    }

    /// Whether this requires SSH callbacks (auth, host key validation)
    var requiresSSHCallbacks: Bool {
        switch self {
        case .ssh, .shellLaunchedSSH: return true
        case .local: return false
        }
    }

    // MARK: - Convenience Extractors

    /// Extract SSH config if this is an SSH connection
    var sshConfig: SSHConfig? {
        switch self {
        case .ssh(let config): return config
        case .shellLaunchedSSH(let config, _): return config
        case .local: return nil
        }
    }

    /// Extract working directory for local shell connections
    var workingDirectory: String? {
        if case .local(let cwd) = self { return cwd }
        return nil
    }

    // MARK: - Shell-Launched Support

    /// Whether this is a session launched from a local shell
    var isShellLaunched: Bool {
        if case .shellLaunchedSSH = self { return true }
        return false
    }

    /// Extract shell working directory for shell-launched connections
    var shellWorkingDirectory: String? {
        if case .shellLaunchedSSH(_, let cwd) = self { return cwd }
        return nil
    }

    /// Returns the inner connection config (unwrapping the shell-launched
    /// wrapper). For regular configs, returns self unchanged.
    var unwrappedConfig: ConnectionConfig {
        if case .shellLaunchedSSH(let config, _) = self { return .ssh(config) }
        return self
    }

    // MARK: - Split Support

    /// Creates a connection config suitable for a new split.
    /// - For local shells: preserves working directory
    /// - For SSH: returns the same config (each connection is independent)
    /// - For shell-launched: preserves shell context for the new split
    func forNewSplit() -> ConnectionConfig {
        switch self {
        case .local(let cwd):
            return .local(workingDirectory: cwd)
        case .ssh(let config):
            return .ssh(config)
        case .shellLaunchedSSH(let sshConfig, let shellCwd):
            return .shellLaunchedSSH(sshConfig: sshConfig, shellWorkingDirectory: shellCwd)
        }
    }
}
