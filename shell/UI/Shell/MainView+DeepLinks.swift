//
//  MainView+DeepLinks.swift
//  shell
//
//  SSH URL deep-link handling for MainView.
//

import SwiftUI

extension MainView {

    // MARK: - SSH URL Deep Link Handling

    /// Handle an incoming SSH URL (ssh://user@host:port).
    ///
    /// A saved profile for the same host (and username, when the URL names one)
    /// supplies the auth method, jump host and terminal settings. Without a
    /// match — or when the profile authenticates with a typed password — the
    /// launch screen opens pre-filled so the user can finish the connection.
    func handleSSHURL(_ components: SSHURLComponents) {
        let profile = ConnectionProfileManager.shared.profiles.first { profile in
            let config = profile.sshConfig
            return config.host == components.host
                && (components.username == nil || config.username == components.username)
        }

        guard let profile else {
            presentPrefilledConnection(
                SSHConfig(
                    host: components.host,
                    port: components.port,
                    username: components.username ?? "",
                    password: ""
                )
            )
            return
        }

        var config = profile.sshConfig
        // Only a port the URL actually named overrides the profile's. This used
        // to assign the 22-defaulted `components.port`, so `ssh://host` against a
        // profile pinned to :2222 dialled :22 and failed, while the same profile
        // opened from the Connect sheet worked.
        if let port = components.explicitPort {
            config.port = port
        }
        if let username = components.username {
            config.username = username
        }

        switch config.authMethod {
        case .key, .savedPassword, .keyboardInteractive:
            // Pre-flight identity resolution, exactly as `connectToProfile` does
            // for the Connect sheet. Going straight to `createSSHTab` skipped it,
            // so a profile synced from another device (whose identity has a
            // different local UUID) or one carrying a per-profile device key
            // override hit the exact-UUID lookup in `SSHKeyManager.loadPrivateKey`
            // and the tab died with key-not-found and no substitute-key prompt.
            //
            // `recordUsage` is not idempotent, but this path is disjoint from the
            // other two recording sites (`MainView.connectToProfile` and
            // `SSHConnectionView.connect`), so it records a deep-link launch once.
            ConnectionProfileManager.shared.recordUsage(id: profile.id)
            switch ConnectionKeyResolver.resolve(config: config, profileID: profile.id) {
            case .resolved(let resolvedConfig):
                createSSHTab(with: resolvedConfig, sourceProfileID: profile.id)
            case .unresolved(let partialConfig, let unresolvedKeys):
                keyResolutionConfig = partialConfig
                keyResolutionUnresolvedKeys = unresolvedKeys
                keyResolutionProfileID = profile.id
                keyResolutionConnectionIdentity = nil
                keyResolutionSplitOption = .newTab
                showKeyResolutionSheet = true
            }
        case .password, .unknown:
            // A typed password is never persisted, and an auth method from a
            // newer build is not connectable — let the user pick one.
            config.authMethod = .password("")
            presentPrefilledConnection(config)
        }
    }

    private func presentPrefilledConnection(_ config: SSHConfig) {
        reconnectConfig = config
        showConnectionSidebar = true
    }
}
