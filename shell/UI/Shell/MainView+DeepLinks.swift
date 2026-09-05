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
        config.port = components.port
        if let username = components.username {
            config.username = username
        }

        switch config.authMethod {
        case .key, .savedPassword, .keyboardInteractive:
            createSSHTab(with: config, sourceProfileID: profile.id)
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
