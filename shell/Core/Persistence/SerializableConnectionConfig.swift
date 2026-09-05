//
//  SerializableConnectionConfig.swift
//  shell
//
//  Codable connection config that strips passwords before serialization.
//  Used for state restoration — passwords are never persisted here; they
//  live in the Keychain and are re-resolved on reconnect.
//

import Foundation

/// Codable connection config that strips passwords before serialization
nonisolated struct SerializableConnectionConfig: Codable, Equatable, Sendable {
    nonisolated enum ConfigType: String, Codable, Sendable {
        case local
        case ssh
        case shellLaunchedSSH
    }

    let type: ConfigType
    let localWorkingDirectory: String?
    let sshConfig: SSHConfigSafe?
    /// CWD of the local shell for shell-launched sessions
    let shellWorkingDirectory: String?

    /// SSH config with every secret removed.
    nonisolated struct SSHConfigSafe: Codable, Equatable, Sendable {
        let host: String
        let port: Int
        let username: String
        let authMethod: AuthMethodSafe
        let jumpHost: JumpHostConfigSafe?
        let tmuxAutoEnable: Bool?
        let tmuxAutoMode: TmuxAutoMode?
        /// Per-connection TERM override. Optional for backward compat — older
        /// serialized sessions decode as nil and inherit the global default.
        let terminalType: String?
        /// Per-profile tmux session name. Optional for backward compat.
        let tmuxSessionName: String?

        /// Auth method that doesn't store actual passwords
        nonisolated enum AuthMethodSafe: Codable, Equatable, Sendable {
            case passwordRequired      // Password was used but not stored
            case key(UUID)             // SSH identity ID
            case keyboardInteractive   // Server-driven prompts
        }

        /// Jump host config without password
        nonisolated struct JumpHostConfigSafe: Codable, Equatable, Sendable {
            let host: String
            let port: Int
            let username: String
            let authMethod: AuthMethodSafe
        }

        init(from config: SSHConfig) {
            self.host = config.host
            self.port = config.port
            self.username = config.username
            self.tmuxAutoEnable = config.tmuxAutoEnable
            self.tmuxAutoMode = config.tmuxAutoMode
            self.terminalType = config.terminalType
            self.tmuxSessionName = config.tmuxSessionName
            self.authMethod = Self.safeAuth(config.authMethod)

            if let jump = config.jumpHost {
                self.jumpHost = JumpHostConfigSafe(
                    host: jump.host,
                    port: jump.port,
                    username: jump.username,
                    authMethod: Self.safeAuth(jump.authMethod)
                )
            } else {
                self.jumpHost = nil
            }
        }

        /// A saved password still counts as "password required": the secret is
        /// re-read from the Keychain (or re-entered) at reconnect time, never
        /// restored from this record.
        private static func safeAuth(_ method: SSHConfig.AuthMethod) -> AuthMethodSafe {
            switch method {
            case .password, .savedPassword, .unknown:
                return .passwordRequired
            case .key(let id):
                return .key(id)
            case .keyboardInteractive:
                return .keyboardInteractive
            }
        }

        private static func liveAuth(_ method: AuthMethodSafe) -> SSHConfig.AuthMethod {
            switch method {
            case .passwordRequired: return .password("")   // Empty — needs re-entry
            case .key(let id): return .key(id)
            case .keyboardInteractive: return .keyboardInteractive
            }
        }

        /// Convert back to SSHConfig, leaving the password empty.
        /// @MainActor: reads `SSHKeyManager.shared` for fallback identities;
        /// the Codable conformance stays nonisolated.
        @MainActor
        func toSSHConfig() -> SSHConfig {
            var config = SSHConfig(host: host, port: port, username: username)
            config.authMethod = Self.liveAuth(authMethod)
            config.tmuxAutoEnable = tmuxAutoEnable ?? false
            config.tmuxAutoMode = tmuxAutoMode ?? .regular
            config.terminalType = terminalType
            config.tmuxSessionName = tmuxSessionName

            if case .key(let keyID) = config.authMethod {
                let fallbacks = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }
                config.fallbackKeyIDs = fallbacks.isEmpty ? nil : fallbacks
            }

            if let jump = jumpHost {
                let jumpAuth = Self.liveAuth(jump.authMethod)
                let jumpFallbackIDs: [UUID]?
                if case .key(let keyID) = jumpAuth {
                    let fallbacks = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }
                    jumpFallbackIDs = fallbacks.isEmpty ? nil : fallbacks
                } else {
                    jumpFallbackIDs = nil
                }

                config.jumpHost = SSHConfig.JumpHostConfig(
                    host: jump.host,
                    port: jump.port,
                    username: jump.username,
                    authMethod: jumpAuth,
                    fallbackKeyIDs: jumpFallbackIDs
                )
            }

            return config
        }

        /// Whether this config needs a password to be entered before connecting
        var needsPassword: Bool {
            targetNeedsPassword || jumpHostNeedsPassword
        }

        /// Whether the jump host specifically needs a password
        var jumpHostNeedsPassword: Bool {
            if let jump = jumpHost, case .passwordRequired = jump.authMethod { return true }
            return false
        }

        /// Whether the target host specifically needs a password
        var targetNeedsPassword: Bool {
            if case .passwordRequired = authMethod { return true }
            return false
        }
    }

    // MARK: - Conversion

    init(from config: ConnectionConfig) {
        switch config {
        case .local(let cwd):
            self.type = .local
            self.localWorkingDirectory = cwd
            self.sshConfig = nil
            self.shellWorkingDirectory = nil
        case .ssh(let ssh):
            self.type = .ssh
            self.localWorkingDirectory = nil
            self.sshConfig = SSHConfigSafe(from: ssh)
            self.shellWorkingDirectory = nil
        case .shellLaunchedSSH(let ssh, let shellCwd):
            self.type = .shellLaunchedSSH
            self.localWorkingDirectory = nil
            self.sshConfig = SSHConfigSafe(from: ssh)
            self.shellWorkingDirectory = shellCwd
        }
    }

    /// Rebuild the live connection config. A record missing its SSH payload
    /// falls back to a local shell rather than failing restoration.
    @MainActor
    func toConnectionConfig() -> ConnectionConfig {
        switch type {
        case .local:
            return .local(workingDirectory: localWorkingDirectory)
        case .ssh:
            guard let ssh = sshConfig else { return .local() }
            return .ssh(ssh.toSSHConfig())
        case .shellLaunchedSSH:
            guard let ssh = sshConfig else { return .local() }
            return .shellLaunchedSSH(
                sshConfig: ssh.toSSHConfig(),
                shellWorkingDirectory: shellWorkingDirectory
            )
        }
    }

    /// Whether this config needs user input (password) before reconnecting
    var needsUserInput: Bool {
        sshConfig?.needsPassword ?? false
    }

    /// Display name for UI
    var displayName: String {
        switch type {
        case .local:
            return "Local Shell"
        case .ssh, .shellLaunchedSSH:
            return sshConfig.map { "\($0.username)@\($0.host)" } ?? "SSH"
        }
    }
}
