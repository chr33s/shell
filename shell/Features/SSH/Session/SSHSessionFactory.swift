//
//  SSHSessionFactory.swift
//  shell
//
//  Factory for creating appropriate SSH session types
//

import Foundation

/// Factory to create the appropriate SSH session type based on configuration
@MainActor
enum SSHSessionFactory {
    /// Creates an SSH session for the given configuration
    /// - Parameters:
    ///   - pty: The PTY to use for the session
    ///   - config: The SSH configuration
    /// - Returns: A CitadelSSHSession for all SSH connections
    static func createSession(pty: TerminalPTY, config: SSHConfig) -> TerminalSession {
        // Always use CitadelSSHSession - it's a higher-level wrapper around NIOSSH
        // that provides consistent behavior for all features including:
        // - Jump host support
        // - Agent forwarding
        // - Connection health monitoring
        return CitadelSSHSession(pty: pty, config: config)
    }
}
