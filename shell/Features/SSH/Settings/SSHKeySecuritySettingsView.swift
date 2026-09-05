import SwiftUI

/// View for modifying the security settings of an existing SSH key
struct SSHKeySecuritySettingsView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var sshKeyManager = SSHKeyManager.shared

    let key: SSHKey

    @State private var selectedStorageLevel: KeyStorageLevel
    @State private var selectedAuthRequirement: KeyAuthRequirement
    @State private var isMigrating = false
    @State private var showingError = false
    @State private var errorMessage = ""

    init(key: SSHKey) {
        self.key = key
        _selectedStorageLevel = State(initialValue: key.storageLevel)
        _selectedAuthRequirement = State(initialValue: key.authRequirement)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Current settings section
                Section("Current Settings") {
                    HStack {
                        Label("Storage", systemImage: key.storageLevel.iconName)
                        Spacer()
                        Text(key.storageLevel.displayName)
                            .foregroundColor(.secondary)
                    }
                    .themedRow()

                    HStack {
                        Label("Authentication", systemImage: key.authRequirement.iconName)
                        Spacer()
                        Text(key.authRequirement.displayName)
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }

                // New storage level section
                Section {
                    Picker("Key Storage", selection: $selectedStorageLevel) {
                        ForEach(KeyStorageLevel.allCases, id: \.self) { level in
                            Label(level.displayName, systemImage: level.iconName)
                                .tag(level)
                        }
                    }
                    .pickerStyle(.inline)
                    .themedRow()
                } header: {
                    Text("New Storage Level")
                } footer: {
                    Text(selectedStorageLevel.description)
                }

                // New auth requirement section
                Section {
                    Picker("Authentication", selection: $selectedAuthRequirement) {
                        ForEach(KeyAuthRequirement.allCases, id: \.self) { req in
                            Label(req.displayName, systemImage: req.iconName)
                                .tag(req)
                        }
                    }
                    .pickerStyle(.inline)
                    .themedRow()
                } header: {
                    Text("New Authentication Requirement")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedAuthRequirement.description)

                        if selectedAuthRequirement != .none {
                            HStack {
                                Image(systemName: SSHKeyAuthManager.shared.biometricIconName)
                                    .foregroundColor(.appAccent)
                                Text("Uses \(SSHKeyAuthManager.shared.biometricTypeName) or device passcode")
                            }
                            .padding(.top, 4)

                            if selectedStorageLevel == .iCloudSync {
                                Text(KeyAuthRequirement.iCloudAuthenticationAdvisory)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }

                // Warnings section
                if hasSecurityDowngrade {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.appHighlight)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Security Downgrade")
                                    .font(.subheadline.bold())
                                Text(downgradeWarningMessage)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .themedRow()
                    }
                }

                // iCloud sync warning
                if selectedStorageLevel == .iCloudSync && key.storageLevel != .iCloudSync {
                    Section {
                        HStack {
                            Image(systemName: "icloud")
                                .foregroundColor(.appAccent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("iCloud Sync")
                                    .font(.subheadline.bold())
                                Text("This key will sync to all devices signed into your iCloud account. Make sure you trust all those devices.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .themedRow()
                    }
                }

                // Apply button
                Section {
                    Button(action: applyChanges) {
                        HStack {
                            Spacer()
                            if isMigrating {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isMigrating ? String(localized: "Updating...", comment: "SSH key security: migration in progress") : String(localized: "Apply Changes", comment: "SSH key security: apply button"))
                            Spacer()
                        }
                    }
                    .disabled(!hasChanges || isMigrating)
                    .themedRow()
                }
            }
            .themedList()
            .navigationTitle("Security Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isMigrating)
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Computed Properties

    private var hasChanges: Bool {
        selectedStorageLevel != key.storageLevel ||
        selectedAuthRequirement != key.authRequirement
    }

    private var hasSecurityDowngrade: Bool {
        // Check if either storage or auth is being downgraded
        let storageDowngrade = storageLevelValue(selectedStorageLevel) < storageLevelValue(key.storageLevel)
        let authDowngrade = authRequirementValue(selectedAuthRequirement) < authRequirementValue(key.authRequirement)
        return storageDowngrade || authDowngrade
    }

    private var downgradeWarningMessage: String {
        var warnings: [String] = []

        if storageLevelValue(selectedStorageLevel) < storageLevelValue(key.storageLevel) {
            warnings.append("Storage security is being reduced")
        }

        if authRequirementValue(selectedAuthRequirement) < authRequirementValue(key.authRequirement) {
            warnings.append("Authentication requirement is being reduced")
        }

        return warnings.joined(separator: ". ") + "."
    }

    private func storageLevelValue(_ level: KeyStorageLevel) -> Int {
        switch level {
        case .deviceOnly: return 3
        case .backupOnly: return 2
        case .iCloudSync: return 1
        }
    }

    private func authRequirementValue(_ req: KeyAuthRequirement) -> Int {
        switch req {
        case .none: return 1
        case .perSession: return 2
        case .perUse: return 3
        }
    }

    // MARK: - Actions

    private func applyChanges() {
        isMigrating = true

        Task {
            do {
                try await sshKeyManager.migrateKeySecurity(
                    id: key.id,
                    newStorageLevel: selectedStorageLevel,
                    newAuthRequirement: selectedAuthRequirement
                )

                await MainActor.run {
                    isMigrating = false
                    dismiss()
                }
            } catch let error as SSHKeyManager.MigrationError {
                await MainActor.run {
                    isMigrating = false
                    switch error {
                    case .authenticationCancelled:
                        // User cancelled, just dismiss the error state
                        break
                    default:
                        errorMessage = error.localizedDescription
                        showingError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isMigrating = false
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
}

#Preview {
    SSHKeySecuritySettingsView(
        key: SSHKey(
            name: "Test Key",
            keyType: .ed25519,
            fingerprint: "a1b2c3d4e5f6",
            hasPassphrase: false,
            storageLevel: .backupOnly,
            authRequirement: .none
        )
    )
}
