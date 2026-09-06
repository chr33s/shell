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
    // The CloudKit toggles read and write the manager, not the store: the
    // manager owns the in-memory flags the sync engine gates on, and its
    // `saveSettings()` is the writer of record for the underlying keys.
    @Setting(Settings.System.syncSoftwareKeys) private var syncSoftwareKeys: Bool

    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var pendingMerge: SettingsMergePreview?

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
                    Toggle("Sync Profiles", isOn: Binding(
                        get: { syncManager.isProfilesSyncEnabled },
                        set: { syncManager.setProfilesSyncEnabled($0) }
                    ))
                    .themedRow()
                    Toggle("Sync Known Hosts", isOn: Binding(
                        get: { syncManager.isKnownHostsSyncEnabled },
                        set: { syncManager.setKnownHostsSyncEnabled($0) }
                    ))
                    .themedRow()
                    Toggle("Sync Settings", isOn: Binding(
                        get: { syncManager.isAppSettingsSyncEnabled },
                        set: { setAppSettingsSync($0) }
                    ))
                    .disabled(isBusy)
                    .themedRow()
                    Toggle("Sync Identity Metadata", isOn: Binding(
                        get: { syncManager.isIdentityMetadataSyncEnabled },
                        set: { syncManager.setIdentityMetadataSyncEnabled($0) }
                    ))
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
        .confirmationDialog(
            "Merge Settings with iCloud",
            isPresented: Binding(
                get: { pendingMerge != nil },
                set: { if !$0 { cancelMerge() } }
            ),
            titleVisibility: .visible,
            presenting: pendingMerge
        ) { preview in
            Button("Use iCloud Settings") {
                pendingMerge = nil
                resolveMerge(preview, .useCloud)
            }
            Button("Keep This Device's Settings") {
                pendingMerge = nil
                resolveMerge(preview, .uploadLocal)
            }
            Button("Cancel", role: .cancel) { cancelMerge() }
        } message: { preview in
            Text("iCloud has \(preview.cloudCount) settings from \(preview.cloudDeviceIDs.count) other device(s); this device has \(preview.localCount), \(preview.overlapping) in common. \(preview.resetCount) local values were reset on another device.")
        }
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

    private func setAppSettingsSync(_ enabled: Bool) {
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                switch try await syncManager.setAppSettingsSyncEnabled(enabled) {
                case .enabled:
                    break
                case .needsMergeChoice(let preview):
                    pendingMerge = preview
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Dismissed without a choice — the Cancel button, or a tap outside the
    /// popover on iPad. The toggle snaps back on its own (the manager's flag
    /// was never set), but the record cache the preview fetch filled has to go
    /// with it: `completeAppSettingsSyncEnable` prefers that cache over
    /// `preview.cloud`, so a record deleted server-side between this attempt
    /// and a later confirm would otherwise linger there and be merged back in.
    ///
    /// Guarded on `pendingMerge` still being set, because SwiftUI drives the
    /// `isPresented` binding to false on EVERY dismissal, including the one
    /// that follows a chosen merge. Both choice buttons clear `pendingMerge`
    /// before starting `resolveMerge`, so the dismissal that trails them finds
    /// nil here and leaves the cache alone for the in-flight completion to read.
    @MainActor
    private func cancelMerge() {
        guard pendingMerge != nil else { return }
        pendingMerge = nil
        syncManager.cancelAppSettingsSyncEnable()
    }

    private func resolveMerge(_ preview: SettingsMergePreview, _ choice: SettingsMergeChoice) {
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await syncManager.completeAppSettingsSyncEnable(preview: preview, choice: choice)
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
