//
//  SettingsSSHSection.swift
//  shell
//
//  SSH settings: profiles, identities, known hosts (spec section 12).
//

import SwiftUI

struct SettingsSSHSection: View {
    @Setting(Settings.Connections.healthMonitoring) private var healthMonitoringEnabled: Bool
    @Setting(Settings.Connections.healthProbeInterval) private var healthProbeInterval: Int

    /// Probe cadences offered in the picker. `ConnectionHealthMonitor` sizes its
    /// rolling window to hold ~5 minutes of samples at whichever is chosen.
    private static let probeIntervalChoices = [5, 10, 15, 30, 60]

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
                SettingToggle(Settings.Connections.backgroundKeepalive, title: "Try to Keep SSH Alive in Background")
                    .themedRow()
                SettingToggle(Settings.Connections.forceIPv4, title: "Force IPv4")
                    .themedRow()
                SettingToggle(
                    Settings.Connections.healthMonitoring,
                    title: "Periodic Connection Health Checks"
                )
                .themedRow()
                if healthMonitoringEnabled {
                    Picker("Probe Interval", selection: $healthProbeInterval) {
                        ForEach(Self.probeIntervalChoices, id: \.self) { seconds in
                            Text(String(localized: "\(seconds) seconds",
                                        comment: "SSH connection health probe interval choice"))
                                .tag(seconds)
                        }
                    }
                    .themedRow()
                    .settingContextMenu(Settings.Connections.healthProbeInterval)
                }
            } header: {
                SettingGroupHeader("Connections", group: .connections)
            } footer: {
                // The distinction in the second sentence is the one §8.2
                // requires be explained: turning the periodic loop off does
                // not turn off recovery's own bounded validation.
                Text("Periodic checks measure round-trip time on live SSH sessions with regular keepalives, and mark a tab when the link degrades. Turning them off does not disable reconnection: a single check still runs when the app returns to the foreground, the network path changes, or a connection errors. Auto Reconnect sets how many attempts each rapid recovery burst makes; after a burst, attempts continue at a slower rate. Background continuity is best-effort within the limits iOS allows and is never guaranteed.")
            }
        }
        .themedList()
        .navigationTitle("SSH")
        .navigationBarTitleDisplayMode(.inline)
    }
}
