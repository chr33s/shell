//
//  TerminalRestorationReconnector.swift
//  shell
//
//  Restoration-time reconnection, extracted from MainViewPersistence:
//  drives RestorationState / startRestoredSession for terminals rebuilt
//  from persisted window state (before a session controller exists).
//
//  Counterpart to TerminalReconnectionController, which is the per-session
//  LIVE auto-reconnect driver (countdown timer, inline overlay animators)
//  for mid-session disconnects. The two flows hand off via
//  isLiveDisconnectionOverlay / restorationState and are deliberately kept
//  separate.
//

import SwiftUI
import os

/// Stateless entry points for reconnecting restored terminals. MainActor by
/// the project's default isolation (mutates TerminalView view-model state).
enum TerminalRestorationReconnector {

    /// Initiate reconnection for a restored terminal
    static func initiateReconnection(_ terminalView: Ghostty.TerminalView) {
        let config = terminalView.connectionConfig

        // Check if password is needed for SSH
        if case .ssh(var sshConfig) = config {
            if case .password(let pwd) = sshConfig.authMethod, pwd.isEmpty {
                // Before showing password overlay, check if we have a saved password
                if SSHPasswordManager.shared.hasPassword(host: sshConfig.host, port: sshConfig.port, username: sshConfig.username) {
                    // Use saved password instead of prompting
                    sshConfig.authMethod = .savedPassword
                    terminalView.connectionConfig = .ssh(sshConfig)
                    performReconnection(terminalView)
                    return
                }
                // No saved password - show overlay
                terminalView.restorationState = .needsPassword(sshConfig)
                return
            }

            // Check jump host too
            if let jump = sshConfig.jumpHost {
                if case .password(let pwd) = jump.authMethod, pwd.isEmpty {
                    // Check for saved jump host password
                    if SSHPasswordManager.shared.hasPassword(host: jump.host, port: jump.port, username: jump.username) {
                        // Use saved password for jump host
                        var updatedJump = jump
                        updatedJump.authMethod = .savedPassword
                        sshConfig.jumpHost = updatedJump
                        terminalView.connectionConfig = .ssh(sshConfig)
                        performReconnection(terminalView)
                        return
                    }
                    // No saved jump host password - show overlay
                    terminalView.restorationState = .needsPassword(sshConfig)
                    return
                }
            }
        }

        // Can auto-reconnect (key auth or local/k8s/console)
        performReconnection(terminalView)
    }

    /// Perform the actual reconnection
    static func performReconnection(_ terminalView: Ghostty.TerminalView) {
        terminalView.restorationState = Ghostty.TerminalView.RestorationState.connectingFromRestore

        // Start the restored session
        terminalView.startRestoredSession { result in
            switch result {
            case .success:
                terminalView.restorationState = Ghostty.TerminalView.RestorationState.none
            case .failure(let error):
                Ghostty.logger.error("Reconnection failed: \(error.localizedDescription)")
                terminalView.restorationState = Ghostty.TerminalView.RestorationState.failed(error.localizedDescription)
            }
        }
    }

    /// Handle password entry for a restored SSH session
    static func handlePasswordEntry(for terminalView: Ghostty.TerminalView, password: String) {
        guard case .ssh(var sshConfig) = terminalView.connectionConfig else { return }

        // Check if this is for jump host or target
        if case .needsPassword(let config) = terminalView.restorationState {
            // Update the appropriate password
            if let jump = config.jumpHost,
               case .password(let jumpPwd) = jump.authMethod,
               jumpPwd.isEmpty {
                // Jump host needs password
                var newJump = jump
                newJump.authMethod = .password(password)
                sshConfig.jumpHost = newJump
            } else if case .password = config.authMethod {
                // Target needs password
                sshConfig.authMethod = .password(password)
            }
        }

        terminalView.connectionConfig = .ssh(sshConfig)
        performReconnection(terminalView)
    }

    /// Retry reconnection for a failed terminal
    static func retryReconnection(for terminalView: Ghostty.TerminalView) {
        initiateReconnection(terminalView)
    }
}
