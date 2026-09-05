//
//  SettingsSyncSection.swift
//  shell
//
//  Sync settings (spec section 12). Only public, non-secret data goes to
//  CloudKit; passwords and synchronizable software private keys live in the
//  iCloud Keychain, and Secure Enclave private keys never leave the device
//  that created them.
//

import SwiftUI

struct SettingsSyncSection: View {
    @State private var syncManager = CloudKitSyncManager.shared
    @Setting(Settings.System.cloudKitSyncProfiles) private var syncProfiles: Bool
    @Setting(Settings.System.cloudKitSyncKnownHosts) private var syncKnownHosts: Bool
    @Setting(Settings.System.cloudKitSyncAppSettings) private var syncSettings: Bool
    @Setting(Settings.System.cloudKitSyncIdentityMetadata) private var syncIdentityMetadata: Bool
    @Setting(Settings.System.syncSoftwareKeys) private var syncSoftwareKeys: Bool

    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Toggle("iCloud Sync", isOn: Binding(
                    get: { syncManager.isSyncEnabled },
                    set: { setSyncEnabled($0) }
                ))
                .disabled(isBusy)
                .themedRow()
            } footer: {
                Text("Syncs this fork's own CloudKit container, \(CloudKitSyncManager.containerIdentifier).")
            }

            if syncManager.isSyncEnabled {
                Section {
                    Toggle("Sync Profiles", isOn: $syncProfiles)
                        .themedRow()
                    Toggle("Sync Known Hosts", isOn: $syncKnownHosts)
                        .themedRow()
                    Toggle("Sync Settings", isOn: $syncSettings)
                        .themedRow()
                    Toggle("Sync Identity Metadata", isOn: $syncIdentityMetadata)
                        .themedRow()
                } header: {
                    Text("CloudKit")
                } footer: {
                    Text("Identity metadata means the key type, fingerprint, public key, and any attached OpenSSH certificate — never private key material.")
                }

                Section {
                    Toggle("Sync Software Keys", isOn: $syncSoftwareKeys)
                        .themedRow()
                } header: {
                    Text("iCloud Keychain")
                } footer: {
                    Text("Software private keys and saved passwords sync through the iCloud Keychain, not CloudKit. Secure Enclave keys are device-bound: their metadata may appear on another device, but the private key stays here.")
                }

                Section {
                    LabeledContent("Last Sync") {
                        if let date = syncManager.lastSyncDate {
                            Text(date, format: .relative(presentation: .named))
                        } else {
                            Text("Never")
                        }
                    }
                    .themedRow()
                    LabeledContent("Pending Changes", value: "\(syncManager.pendingChangesCount)")
                        .themedRow()
                    Button("Sync Now") { syncNow() }
                        .disabled(isBusy)
                        .themedRow()
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.appDanger)
                }
            }
        }
        .themedList()
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setSyncEnabled(_ enabled: Bool) {
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await syncManager.setEnabled(enabled)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func syncNow() {
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await syncManager.syncNow()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
