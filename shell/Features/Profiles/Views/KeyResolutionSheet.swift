//
//  KeyResolutionSheet.swift
//  shell
//
//  Picker UI shown when a synced profile or history entry references
//  an SSH key that doesn't exist on the current device.
//

import SwiftUI

/// Sheet presented when a connection's SSH key can't be resolved locally.
/// Shows the original key's metadata and lets the user pick a local replacement.
struct KeyResolutionSheet: View {
    let unresolvedKeys: [UnresolvedKeyInfo]
    let config: SSHConfig
    let profileID: UUID?
    let connectionIdentity: String?
    let onResolved: (SSHConfig) -> Void
    let onCancel: () -> Void

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var targetKeySelection: UUID?
    @State private var jumpHostKeySelection: UUID?
    @State private var saveAsDeviceOverride: Bool = true

    private var keyManager: SSHKeyManager { SSHKeyManager.shared }

    private var targetUnresolved: UnresolvedKeyInfo? {
        unresolvedKeys.first { !$0.isJumpHost }
    }

    private var jumpHostUnresolved: UnresolvedKeyInfo? {
        unresolvedKeys.first { $0.isJumpHost }
    }

    /// The profile's `modifiedAt` at the moment the override is saved, so
    /// `DeviceKeyOverrideManager.isStale(_:currentSourceModifiedAt:)` can later
    /// tell the user their pinned key predates an edit to the profile. A
    /// QuickConnect identity has no source record, so it has no stamp.
    private var sourceModifiedAt: Date? {
        guard let profileID else { return nil }
        return ConnectionProfileManager.shared.profile(for: profileID)?.modifiedAt
    }

    var body: some View {
        NavigationStack {
            Form {
                // Header explaining the situation
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SSH Key Not Available")
                                .font(.headline)
                            Text("The key used by this connection isn't available on this device. Select a local key to use instead.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "key.slash")
                            .foregroundStyle(.appHighlight)
                            .font(.title3)
                    }
                    .themedRow()
                }

                // Target key resolution
                if let info = targetUnresolved {
                    Section {
                        hintInfoView(hint: info.hint)
                            .themedRow()
                        keyPickerView(selection: $targetKeySelection, filterType: info.hint?.keyType)
                            .themedRow()
                    } header: {
                        Text("Target Host Key")
                    }
                }

                // Jump host key resolution
                if let info = jumpHostUnresolved {
                    Section {
                        hintInfoView(hint: info.hint)
                            .themedRow()
                        keyPickerView(selection: $jumpHostKeySelection, filterType: info.hint?.keyType)
                            .themedRow()
                    } header: {
                        Text("Jump Host Key")
                    }
                }

                // Save option
                Section {
                    Toggle("Always use on this device", isOn: $saveAsDeviceOverride)
                        .themedRow()
                } footer: {
                    Text("Save this key selection so future connections from this device use it automatically.")
                }
            }
            .themedList()
            .navigationTitle("Select Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        applyResolution()
                    }
                    .disabled(!isSelectionComplete)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func hintInfoView(hint: KeyResolutionHint?) -> some View {
        if let hint {
            VStack(alignment: .leading, spacing: 4) {
                if let name = hint.keyName {
                    HStack {
                        Text("Original Key")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(name)
                    }
                }
                if let keyType = hint.keyType {
                    HStack {
                        Text("Type")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(keyType.displayName)
                    }
                }
                if let fingerprint = hint.fingerprint {
                    HStack {
                        Text("Fingerprint")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("SHA256:\(fingerprint.prefix(12))...")
                            .font(.caption)
                            .monospaced()
                    }
                }
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private func keyPickerView(selection: Binding<UUID?>, filterType: SSHKey.KeyType?) -> some View {
        // Narrow to the algorithm the original key used — a replacement of a
        // different type usually is not in the server's authorized_keys. If no
        // local key matches, fall back to the full list rather than a dead end:
        // the user may well have a working key of another algorithm.
        let sameType = filterType.map { type in
            keyManager.savedKeys.filter { $0.keyType == type }
        } ?? keyManager.savedKeys
        let availableKeys = sameType.isEmpty ? keyManager.savedKeys : sameType
        if availableKeys.isEmpty {
            Text("No SSH keys available on this device")
                .foregroundStyle(.secondary)
                .italic()
        } else {
            Picker("Key", selection: selection) {
                Text("Select a key...").tag(nil as UUID?)
                ForEach(availableKeys) { key in
                    HStack {
                        Text(key.name)
                        Spacer()
                        Text(key.keyType.shortName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(key.id as UUID?)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Logic

    private var isSelectionComplete: Bool {
        let targetOK = targetUnresolved == nil || targetKeySelection != nil
        let jumpOK = jumpHostUnresolved == nil || jumpHostKeySelection != nil
        return targetOK && jumpOK
    }

    private func applyResolution() {
        var resolved = config

        // Apply target key selection
        if targetUnresolved != nil, let selectedID = targetKeySelection {
            resolved.authMethod = .key(selectedID)
        }

        // Apply jump host key selection
        if jumpHostUnresolved != nil, let selectedID = jumpHostKeySelection, var jumpConfig = resolved.jumpHost {
            jumpConfig.authMethod = .key(selectedID)
            resolved.jumpHost = jumpConfig
        }

        // Save device override if requested.
        //
        // A saved profile keys the override by UUID. Everything else —
        // QuickConnect (`ssh me@host`), a deep link, a history entry — has no
        // UUID, so it keys off the connection's own identity. Falling back to
        // `config.connectionIdentity` here is what makes the toggle above mean
        // anything outside the profile case: without it the sheet returned
        // early and the user got re-prompted on every single connect.
        // `ConnectionKeyResolver.resolve` derives the same string when it looks
        // the override back up.
        if saveAsDeviceOverride {
            let target: OverrideTarget
            if let profileID {
                target = .profile(profileID)
            } else {
                target = .connectionIdentity(connectionIdentity ?? config.connectionIdentity)
            }

            let override = DeviceKeyOverride(
                target: target,
                targetKeyID: targetKeySelection,
                jumpHostKeyID: jumpHostKeySelection,
                createdAt: Date(),
                sourceModifiedAt: sourceModifiedAt
            )
            DeviceKeyOverrideManager.shared.save(override)
        }

        onResolved(resolved)
    }
}
