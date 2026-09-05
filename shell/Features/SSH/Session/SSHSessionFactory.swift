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
    ///   - paneToken: Stable identifier for the pane this session drives,
    ///     forwarded as `LC_ROOTSHELL_PANE` so an out-of-band probe can tell
    ///     which remote process belongs to it.
    static func createSession(
        pty: TerminalPTY,
        config: SSHConfig,
        paneToken: String? = nil
    ) -> TerminalSession {
        // Always use CitadelSSHSession - it's a higher-level wrapper around NIOSSH
        // that provides consistent behavior for all features including:
        // - Jump host support
        // - Agent forwarding
        // - Connection health monitoring
        let session = CitadelSSHSession(pty: pty, config: config)
        session.paneToken = paneToken
        return session
    }
}
