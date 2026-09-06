//
//  DeviceKeyOverridesView.swift
//  shell
//
//  Management surface for the per-device key pins created by
//  `KeyResolutionSheet`'s "Always use on this device" toggle.
//
//  Without this screen an override was write-only: once saved it silently
//  redirected every future connection for that profile or host to a key the
//  user could not see, could not check against the profile it was pinned from,
//  and could not revoke. Deleting the row here is the revocation — the next
//  connection resolves normally and re-prompts if the key still does not exist.
//

import SwiftUI

struct DeviceKeyOverridesView: View {
    @State private var overrideManager = DeviceKeyOverrideManager.shared
    @StateObject private var keyManager = SSHKeyManager.shared
    @State private var overrideToDelete: DeviceKeyOverride?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        List {
            if overrideManager.overrides.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "pin.slash")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                            .padding(.top, 20)

                        Text("No Device Key Overrides")
                            .font(.headline)

                        Text("When a connection's key isn't on this device you can pick a replacement and tick “Always use on this device”. Those choices appear here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .themedRow()
                }
            } else {
                Section {
                    ForEach(overrideManager.overrides) { override in
                        DeviceKeyOverrideRow(
                            override: override,
                            targetLabel: targetLabel(for: override.target),
                            targetKeyStatus: keyStatus(for: override.targetKeyID),
                            jumpHostKeyStatus: keyStatus(for: override.jumpHostKeyID),
                            isStale: isStale(override)
                        )
                        .themedRow()
                    }
                    .onDelete(perform: confirmDelete)
                } header: {
                    Text("Pinned Keys")
                } footer: {
                    Text("Removing a pin restores normal key resolution for that connection. You'll be asked to pick a key again the next time it can't be resolved.")
                }
            }

            Section {
                Text("Overrides are stored on this device only and never sync to iCloud.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Device Key Overrides")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Remove Override", isPresented: $showingDeleteConfirmation, presenting: overrideToDelete) { override in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                // Target-keyed, matching the manager's own documented
                // revocation API: `save` merges into the record for a target
                // and keeps its `id`, so the target is the stable handle.
                overrideManager.remove(forTarget: override.target)
            }
        } message: { override in
            Text("Stop using the pinned key for '\(targetLabel(for: override.target))' on this device?")
        }
    }

    // MARK: - Row data

    /// What the override applies to, in the user's terms: a profile by its
    /// current name, or the `user@host:port` a QuickConnect identity encodes.
    private func targetLabel(for target: OverrideTarget) -> String {
        switch target {
        case .profile(let id):
            if let profile = ConnectionProfileManager.shared.profile(for: id) {
                return profile.name
            }
            // The profile is gone but the pin survived it — say so rather than
            // showing a bare UUID the user cannot act on.
            return String(localized: "Deleted profile", comment: "Device key override target whose profile no longer exists")
        case .connectionIdentity(let identity):
            // Stored as "ssh:user@host:port"; the scheme is plumbing.
            return identity.hasPrefix("ssh:") ? String(identity.dropFirst(4)) : identity
        }
    }

    /// The pinned key's name, or nil when nothing is pinned for that slot.
    /// Returns a "missing" marker when the pin outlived the key it points at.
    private func keyStatus(for keyID: UUID?) -> DeviceKeyOverrideRow.KeyStatus? {
        guard let keyID else { return nil }
        if let key = keyManager.findKey(id: keyID) {
            return .present(name: key.name, type: key.keyType.shortName)
        }
        return .missing
    }

    /// Whether the pinned profile has been edited since the pin was made — the
    /// case `DeviceKeyOverrideManager.isStale` was written for. A QuickConnect
    /// identity has no source record, so it is never stale.
    private func isStale(_ override: DeviceKeyOverride) -> Bool {
        guard case .profile(let id) = override.target,
              let profile = ConnectionProfileManager.shared.profile(for: id) else {
            return false
        }
        return overrideManager.isStale(override, currentSourceModifiedAt: profile.modifiedAt)
    }

    // MARK: - Actions

    private func confirmDelete(at offsets: IndexSet) {
        for index in offsets {
            overrideToDelete = overrideManager.overrides[index]
            showingDeleteConfirmation = true
        }
    }
}

struct DeviceKeyOverrideRow: View {
    enum KeyStatus {
        case present(name: String, type: String)
        case missing
    }

    let override: DeviceKeyOverride
    let targetLabel: String
    let targetKeyStatus: KeyStatus?
    let jumpHostKeyStatus: KeyStatus?
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: targetIcon)
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text(targetLabel)
                    .font(.body)
                Spacer()
                if isStale {
                    badge(String(localized: "Stale", comment: "Badge: the profile changed after this key override was saved"), color: .appWarning)
                }
            }

            if let targetKeyStatus {
                keyLine(label: String(localized: "Key", comment: "Device key override row: the pinned target-host key"), status: targetKeyStatus)
            }

            if let jumpHostKeyStatus {
                keyLine(label: String(localized: "Jump host key", comment: "Device key override row: the pinned jump-host key"), status: jumpHostKeyStatus)
            }

            Text("Pinned \(override.createdAt, style: .relative) ago")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var targetIcon: String {
        switch override.target {
        case .profile: return "person.crop.rectangle"
        case .connectionIdentity: return "terminal"
        }
    }

    @ViewBuilder
    private func keyLine(label: String, status: KeyStatus) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            switch status {
            case .present(let name, let type):
                Text(name)
                    .font(.caption)
                Text(type)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            case .missing:
                // The pin points at a key that has been deleted. Connections
                // using it fail with key-not-found until the pin is removed.
                Text("Key no longer on this device")
                    .font(.caption)
                    .foregroundColor(.appDanger)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

#Preview {
    NavigationStack {
        DeviceKeyOverridesView()
    }
}
