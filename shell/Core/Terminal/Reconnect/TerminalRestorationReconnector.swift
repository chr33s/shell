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

        // Check if password is needed for SSH.
        // Read through `sshConfig` rather than `if case .ssh`: a restored
        // shell-launched SSH terminal is also `.pendingReconnection`, and the
        // old pattern let Retry skip the password gate entirely and connect
        // with `.password("")`. `.local` still yields nil here, so a local
        // terminal is never rewritten into an SSH config. Writes go back
        // through `configReplacingSSH` to preserve the `.shellLaunchedSSH`
        // wrapper (and its shellWorkingDirectory).
        if var sshConfig = config.sshConfig {
            if case .password(let pwd) = sshConfig.authMethod, pwd.isEmpty {
                // Before showing password overlay, check if we have a saved password
                if SSHPasswordManager.shared.hasPassword(host: sshConfig.host, port: sshConfig.port, username: sshConfig.username) {
                    // Use saved password instead of prompting
                    sshConfig.authMethod = .savedPassword
                    terminalView.connectionConfig = configReplacingSSH(config, with: sshConfig)
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
                        terminalView.connectionConfig = configReplacingSSH(config, with: sshConfig)
                        performReconnection(terminalView)
                        return
                    }
                    // No saved jump host password - show overlay
                    terminalView.restorationState = .needsPassword(sshConfig)
                    return
                }
            }
        }

        // Can auto-reconnect (key auth, saved/inline password, or local shell)
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
        let config = terminalView.connectionConfig
        // Unwrap through `sshConfig` instead of `guard case .ssh`: the password
        // overlay is reachable for restored `.shellLaunchedSSH` terminals too
        // (the restoration gate arms `.needsPassword` for both kinds), and the
        // old guard made password entry a silent no-op there - no connect, no
        // error, overlay stuck with only Close Tab as an escape. `.local`
        // yields nil, so a local terminal is still never rewritten as SSH.
        guard var sshConfig = config.sshConfig else { return }

        // Check if this is for jump host or target
        if case .needsPassword(let promptedConfig) = terminalView.restorationState {
            // Update the appropriate password
            if let jump = promptedConfig.jumpHost,
               case .password(let jumpPwd) = jump.authMethod,
               jumpPwd.isEmpty {
                // Jump host needs password
                var newJump = jump
                newJump.authMethod = .password(password)
                sshConfig.jumpHost = newJump
            } else if case .password = promptedConfig.authMethod {
                // Target needs password
                sshConfig.authMethod = .password(password)
            }
        }

        // Write back in the ORIGINAL shape: assigning `.ssh(sshConfig)`
        // unconditionally would drop shellWorkingDirectory (losing the
        // shell-return CWD) and reroute a shell-launched config into the
        // direct-SSH path.
        terminalView.connectionConfig = configReplacingSSH(config, with: sshConfig)

        // Fail closed: one prompt fills ONE hop, but a config can need a
        // password for the jump host AND the target. Connecting with the other
        // hop still on `.password("")` burns a guaranteed-failed auth attempt
        // (MaxAuthTries / fail2ban) and cannot be re-gated afterwards, because
        // performReconnection moves the state to `.connectingFromRestore` and
        // the session controller's restoration gate only runs while the state
        // is `.pendingReconnection`. Re-arm the prompt for the remaining hop.
        if hasUnsuppliedPassword(sshConfig) {
            terminalView.restorationState = .needsPassword(sshConfig)
            // Required: RestorationState's `==` compares only the target's
            // host/username, and MainView does not observe the view model's
            // @Published properties - the overlay re-renders solely off the
            // .terminalRestorationStateChanged notification.
            terminalView.terminalNotifyRestorationStateChanged()
            return
        }

        performReconnection(terminalView)
    }

    /// Retry reconnection for a failed terminal
    static func retryReconnection(for terminalView: Ghostty.TerminalView) {
        initiateReconnection(terminalView)
    }

    // MARK: - Helpers

    /// Rebuilds `config` around an updated SSHConfig, preserving the
    /// `.shellLaunchedSSH` wrapper and its shellWorkingDirectory. `.local` is
    /// returned untouched so a local terminal can never be turned into an SSH
    /// connection by a reconnect path.
    private static func configReplacingSSH(
        _ config: ConnectionConfig,
        with sshConfig: SSHConfig
    ) -> ConnectionConfig {
        switch config {
        case .ssh:
            return .ssh(sshConfig)
        case .shellLaunchedSSH(_, let shellWorkingDirectory):
            return .shellLaunchedSSH(sshConfig: sshConfig, shellWorkingDirectory: shellWorkingDirectory)
        case .local:
            return config
        }
    }

    /// True while either hop still carries an unsupplied inline password.
    /// `.password("")` is the repo-wide marker for "password required but not
    /// supplied" (see SerializableConnectionConfig.liveAuth).
    private static func hasUnsuppliedPassword(_ sshConfig: SSHConfig) -> Bool {
        if case .password(let pwd) = sshConfig.authMethod, pwd.isEmpty { return true }
        if let jump = sshConfig.jumpHost,
           case .password(let pwd) = jump.authMethod,
           pwd.isEmpty {
            return true
        }
        return false
    }
}
