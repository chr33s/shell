//
//  MainView+ConnectionSheet.swift
//  shell
//
//  Connection sheet content and connect dispatch for MainView. The fork has
//  two session kinds: a local shell and SSH.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

extension MainView {

    // MARK: - Connection Sheet Content

    /// The connection sheet, used on every platform. `onClose` is set, so the
    /// dismiss button reads "Done".
    @ViewBuilder
    var connectionSheetContent: some View {
        SSHConnectionView(
            initialConfig: connectionSheetPrefill?.config,
            connectionError: connectionSheetPrefill?.reconnectTarget?
                .resolve(in: terminals)?.pane.asTerminal?.error?.localizedDescription,
            onConnect: { (config: SSHConfig?, splitOption: SSHConnectionView.SplitOption) in
                handleSSHOrLocalConnection(config: config, splitOption: splitOption)
            },
            onProfileConnect: { profile, splitOption in
                showConnectionSidebar = false
                connectToProfile(profile, splitOption: splitOption)
            },
            preventDismissal: terminals.isEmpty && tabBarHidden,
            onClose: { showConnectionSidebar = false },
            initialTab: connectionSidebarInitialTab
        )
        // The prefill is one-shot: it belongs to the presentation that armed
        // it. Clearing on disappear covers every dismissal path, including the
        // interactive swipe-down and the deep-link prefill in
        // `presentPrefilledConnection`, neither of which routes through
        // `onClose`. Connect handlers run before the sheet actually
        // disappears, so they still observe the armed state.
        .onDisappear {
            connectionSheetPrefill = nil
        }
    }

    private func handleSSHOrLocalConnection(config: SSHConfig?, splitOption: SSHConnectionView.SplitOption) {
        // A reconnect-armed sheet replaces only the pane whose authentication
        // failed, resolved by identity now — tabs may have been reordered,
        // closed, or moved to another window while the sheet was open. A target
        // that no longer resolves is cancelled, never redirected to whatever
        // tab now sits at its old position or to a new session.
        let reconnectTarget = connectionSheetPrefill?.reconnectTarget
        connectionSheetPrefill = nil
        if let config, let reconnectTarget {
            if !reconnectPane(reconnectTarget, with: config) {
                alerts.reportStaleReconnect(host: config.displayName)
            }
            return
        }
        if let config {
            switch splitOption {
            case .newTab:
                createSSHTab(with: config)
            case .splitRight:
                createSSHSplit(with: config, direction: .right)
            case .splitDown:
                createSSHSplit(with: config, direction: .down)
            }
        } else {
            switch splitOption {
            case .newTab:
                createLocalShellTab()
            case .splitRight:
                createLocalShellSplit(direction: .right)
            case .splitDown:
                createLocalShellSplit(direction: .down)
            }
        }
    }

    // MARK: - Profiles

    func connectToProfile(_ profile: SSHProfile, splitOption: SSHConnectionView.SplitOption) {
        // This is the single usage-recording site for both entry points that
        // reach a profile connect: the connection sheet (via `onProfileConnect`
        // above) and the notification/deep-link path. `recordUsage` is not
        // idempotent (`useCount += 1` plus a profile write), and `useCount` is a
        // live sort key for `ProfileSortOrder.mostUsed` and `suggestions`, so
        // callers must not record usage again before or after calling this.
        ConnectionProfileManager.shared.recordUsage(id: profile.id)

        var config = profile.sshConfig

        // Pre-flight identity resolution for synced profiles: a profile can
        // reference an identity whose UUID differs on this device, or whose
        // private key has not arrived yet.
        let resolution = ConnectionKeyResolver.resolve(config: config, profileID: profile.id)
        switch resolution {
        case .resolved(let resolvedConfig):
            config = resolvedConfig
        case .unresolved(let partialConfig, let unresolvedKeys):
            keyResolution = KeyResolutionRequest(
                config: partialConfig,
                unresolvedKeys: unresolvedKeys,
                profileID: profile.id,
                splitOption: splitOption
            )
            return
        }

        switch config.authMethod {
        case .savedPassword:
            // Saved password: load it and connect directly.
            Task { @MainActor in
                do {
                    let resolvedConfig = try await config.resolvedConfig()
                    connectWithConfig(resolvedConfig, splitOption: splitOption, sourceProfileID: profile.id)
                } catch SSHPasswordManager.PasswordError.authenticationCancelled {
                    // User cancelled biometrics — do nothing.
                } catch {
                    // Password load failed (e.g. deleted) — prompt for it.
                    promptForPassword(profile: profile, splitOption: splitOption)
                }
            }

        case .password(let pwd) where !pwd.isEmpty:
            connectWithConfig(config, splitOption: splitOption, sourceProfileID: profile.id)

        case .password:
            // Password auth with nothing inline: try the Keychain, else prompt.
            if SSHPasswordManager.shared.hasPassword(host: config.host, port: config.port, username: config.username) {
                Task { @MainActor in
                    var savedConfig = config
                    savedConfig.authMethod = .savedPassword
                    do {
                        let resolvedConfig = try await savedConfig.resolvedConfig()
                        connectWithConfig(resolvedConfig, splitOption: splitOption, sourceProfileID: profile.id)
                    } catch SSHPasswordManager.PasswordError.authenticationCancelled {
                        // User cancelled biometrics — do nothing.
                    } catch {
                        promptForPassword(profile: profile, splitOption: splitOption)
                    }
                }
            } else {
                promptForPassword(profile: profile, splitOption: splitOption)
            }

        case .key, .keyboardInteractive, .unknown:
            // Identity / keyboard-interactive connect directly (the
            // keyboard-interactive UI handles any prompts). An `.unknown`
            // method falls through here and surfaces the "unsupported" error
            // on connect — it never silently downgrades to password auth.
            connectWithConfig(config, splitOption: splitOption, sourceProfileID: profile.id)
        }
    }

    private func promptForPassword(profile: SSHProfile, splitOption: SSHConnectionView.SplitOption) {
        passwordPrompt = PasswordPromptRequest(profile: profile, splitOption: splitOption)
    }

    func connectWithConfig(
        _ config: SSHConfig,
        splitOption: SSHConnectionView.SplitOption,
        sourceProfileID: UUID? = nil
    ) {
        // Safety net: verify the identity is still resolvable before creating a session.
        if case .key(let keyID) = config.authMethod, SSHKeyManager.shared.findKey(id: keyID) == nil {
            switch ConnectionKeyResolver.resolve(config: config) {
            case .resolved(let resolvedConfig):
                connectWithConfig(resolvedConfig, splitOption: splitOption, sourceProfileID: sourceProfileID)
                return
            case .unresolved(let partialConfig, let unresolvedKeys):
                keyResolution = KeyResolutionRequest(
                    config: partialConfig,
                    unresolvedKeys: unresolvedKeys,
                    profileID: nil,
                    splitOption: splitOption
                )
                return
            }
        }

        switch splitOption {
        case .newTab:
            createSSHTab(with: config, sourceProfileID: sourceProfileID)
        case .splitRight:
            createSSHSplit(with: config, direction: .right, sourceProfileID: sourceProfileID)
        case .splitDown:
            createSSHSplit(with: config, direction: .down, sourceProfileID: sourceProfileID)
        }
    }

    func handlePasswordSubmit(_ request: PasswordPromptRequest, password: String, shouldSave: Bool) {
        passwordPrompt = nil
        let profile = request.profile

        var config = profile.sshConfig

        // Optionally save the password for future connections.
        var savedSuccessfully = false
        if shouldSave {
            do {
                try SSHPasswordManager.shared.savePassword(
                    password,
                    host: config.host,
                    port: config.port,
                    username: config.username
                )
                savedSuccessfully = true
            } catch {
                savedSuccessfully = false
            }
        }

        // Reflect the saved-password preference on the profile.
        var updatedProfile = profile
        updatedProfile.sshConfig.authMethod = savedSuccessfully ? .savedPassword : .password("")
        try? ConnectionProfileManager.shared.updateProfile(updatedProfile)

        config.authMethod = .password(password)
        connectWithConfig(config, splitOption: request.splitOption, sourceProfileID: profile.id)
    }
}
