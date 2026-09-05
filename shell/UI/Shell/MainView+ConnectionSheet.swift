//
//  MainView+ConnectionSheet.swift
//  shell
//
//  Connection sheet content and connect dispatch for MainView. The fork has
//  two session kinds: a local shell and SSH.
//

import SwiftUI
import Combine
import GhosttyKit
import os

#if canImport(UIKit)
import UIKit
#endif

extension MainView {

    // MARK: - Connection Sheet Content

    /// iPhone variant: no onClose (shows "Cancel", uses dismiss()).
    @ViewBuilder
    var connectionSheetContentForPhone: some View {
        SSHConnectionView(
            initialConfig: reconnectConfig,
            onConnect: { (config: SSHConfig?, splitOption: SSHConnectionView.SplitOption) in
                handleSSHOrLocalConnection(config: config, splitOption: splitOption)
            },
            onProfileConnect: { profile, splitOption in
                showConnectionSidebar = false
                connectToProfile(profile, splitOption: splitOption)
            },
            preventDismissal: terminals.isEmpty && tabBarHidden,
            initialTab: connectionSidebarInitialTab
        )
    }

    /// iPad/Catalyst/visionOS variant: onClose set (shows "Done").
    @ViewBuilder
    var connectionSheetContent: some View {
        SSHConnectionView(
            initialConfig: reconnectConfig,
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
    }

    private func handleSSHOrLocalConnection(config: SSHConfig?, splitOption: SSHConnectionView.SplitOption) {
        if let config {
            if let tabIndex = reconnectingTabIndex {
                // Reconnecting an existing tab
                reconnectTab(at: tabIndex, with: config)
            } else {
                switch splitOption {
                case .newTab:
                    createSSHTab(with: config)
                case .splitRight:
                    createSSHSplit(with: config, direction: .right)
                case .splitDown:
                    createSSHSplit(with: config, direction: .down)
                }
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
        // Clear reconnection state
        reconnectingTabIndex = nil
        reconnectConfig = nil
    }

    // MARK: - Profiles

    func connectToProfile(_ profile: SSHProfile, splitOption: SSHConnectionView.SplitOption) {
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
            keyResolutionConfig = partialConfig
            keyResolutionUnresolvedKeys = unresolvedKeys
            keyResolutionProfileID = profile.id
            keyResolutionConnectionIdentity = nil
            keyResolutionSplitOption = splitOption
            showKeyResolutionSheet = true
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
        passwordPromptProfile = profile
        passwordPromptSplitOption = splitOption
        showPasswordPromptSheet = true
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
                keyResolutionConfig = partialConfig
                keyResolutionUnresolvedKeys = unresolvedKeys
                keyResolutionProfileID = nil
                keyResolutionConnectionIdentity = nil
                keyResolutionSplitOption = splitOption
                showKeyResolutionSheet = true
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

    func handlePasswordSubmit(profile: SSHProfile, password: String, shouldSave: Bool) {
        showPasswordPromptSheet = false
        passwordPromptProfile = nil

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
        connectWithConfig(config, splitOption: passwordPromptSplitOption, sourceProfileID: profile.id)
    }
}
