//
//  SettingsSSHSection.swift
//  shell
//
//  SSH settings: profiles, identities, known hosts (spec section 12).
//

import SwiftUI

struct SettingsSSHSection: View {
    var body: some View {
        List {
            Section {
                NavigationLink(value: SettingsDestination.sshProfiles) {
                    Label("Profiles", systemImage: "server.rack")
                }
                .themedRow()
                NavigationLink(value: SettingsDestination.sshIdentities) {
                    Label("SSH Identities", systemImage: "key")
                }
                .themedRow()
                NavigationLink(value: SettingsDestination.knownHosts) {
                    Label("Known Hosts", systemImage: "checkmark.shield")
                }
                .themedRow()
            }

            Section {
                NavigationLink {
                    SavedPasswordsView()
                } label: {
                    Label("Saved Passwords", systemImage: "lock")
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Credentials", group: .connections)
            }

            Section {
                SettingToggle(Settings.Connections.autoReconnectEnabled, title: "Auto Reconnect")
                    .themedRow()
                SettingToggle(Settings.Connections.backgroundKeepalive, title: "Keep SSH Alive in Background")
                    .themedRow()
                SettingToggle(Settings.Connections.forceIPv4, title: "Force IPv4")
                    .themedRow()
            } header: {
                SettingGroupHeader("Connections", group: .connections)
            }
        }
        .themedList()
        .navigationTitle("SSH")
        .navigationBarTitleDisplayMode(.inline)
    }
}
