import SwiftUI

struct SSHKeyDetailView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @StateObject private var sshKeyManager = SSHKeyManager.shared

    let key: SSHKey

    @State private var showingDeleteConfirmation = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingSecuritySettings = false

    // Public key display
    @State private var publicKeyString: String = ""
    @State private var isLoadingPublicKey = true
    @State private var showingInstallInstructions = false

    // Rename functionality
    @State private var showingRenameAlert = false
    @State private var newKeyName = ""

    // Install on server

    // Legacy key unlock
    @State private var showingUnlockAlert = false
    @State private var unlockPassphrase = ""
    @State private var isUnlocking = false

    // OpenPGP public key export


    // User certificate
    @State private var showingCertImport = false
    @State private var showingCertRemoveConfirmation = false
    @State private var certificateCopied = false

    #if targetEnvironment(macCatalyst) && STANDALONE
    // External agent availability probe
    @State private var isCheckingAgentAvailability = false
    @State private var agentAvailability: (ok: Bool, message: String)?
    #endif

    var body: some View {
        List {
            keyInfoSection
            fingerprintSection
            publicKeySection
            certificateSection
            installInstructionsSection
            defaultKeysSection
            securitySection
            deleteSection
        }
        .themedList()
        .navigationTitle("SSH Key Details")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete Key", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteKey()
            }
        } message: {
            Text("Are you sure you want to delete the key '\(currentKey.name)'? This cannot be undone.")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showingSecuritySettings) {
            SSHKeySecuritySettingsView(key: currentKey)
                .themedSubSheet(sheetThemeColors)
        }
        .navigationDestination(isPresented: $showingCertImport) {
            SSHUserCertificateImportView(targetKey: currentKey)
        }
        .alert("Remove Certificate", isPresented: $showingCertRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                sshKeyManager.removeUserCertificate(keyID: key.id)
            }
        } message: {
            Text("Remove the certificate from '\(currentKey.name)'? The key itself is not affected; connections will use the plain key.")
        }
        .alert("Unlock Legacy Key", isPresented: $showingUnlockAlert) {
            SecureField("Passphrase", text: $unlockPassphrase)
            Button("Cancel", role: .cancel) {
                unlockPassphrase = ""
            }
            Button("Unlock") {
                unlockLegacyKey()
            }
        } message: {
            Text("This key was imported with a passphrase on another device. Enter it once to decrypt the key; it will then be protected by the Keychain and won't need the passphrase again.")
        }
        .alert("Rename Key", isPresented: $showingRenameAlert) {
            TextField("Key name", text: $newKeyName)
            Button("Cancel", role: .cancel) {
                newKeyName = ""
            }
            Button("Rename") {
                renameKey()
            }
        } message: {
            Text("Enter a new name for this SSH key.")
        }
        .onAppear {
            loadPublicKey()
        }
    }

    // MARK: - Computed Properties

    @ViewBuilder
    private var keyInfoSection: some View {
        // Key info section
        Section("Key Information") {
            Button(action: {
                newKeyName = currentKey.name
                showingRenameAlert = true
            }) {
                HStack {
                    Text("Name")
                    Spacer()
                    Text(currentKey.name)
                        .foregroundColor(.secondary)
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundColor(.appAccent)
                }
            }
            .foregroundColor(.primary)
            .themedRow()
            LabeledRow(label: "Type", value: currentKey.keyType.displayName)
                .themedRow()
            if currentKey.secureEnclaveInfo != nil {
                HStack {
                    Label("Protection", systemImage: "lock.shield.fill")
                    Spacer()
                    Text("Secure Enclave")
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
            LabeledRow(label: "Created", value: formattedDate)
                .themedRow()
            if isSoftwareKey {
                HStack {
                    Text("Key Material")
                    Spacer()
                    if keyNeedsUnlock {
                        Label("Unlock Required", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.appHighlight)
                    } else {
                        Text(currentKey.hasPassphrase ? "Migration Pending" : "Keychain Protected")
                            .foregroundColor(.secondary)
                    }
                }
                .themedRow()
                if keyNeedsUnlock {
                    Button {
                        unlockPassphrase = ""
                        showingUnlockAlert = true
                    } label: {
                        Label("Unlock Legacy Key", systemImage: "lock.open")
                    }
                    .disabled(isUnlocking)
                    .themedRow()
                }
            }
        }
    }

    @ViewBuilder
    private var fingerprintSection: some View {
        // Fingerprint section
        Section("Fingerprint") {
            CopyableValueBlock(
                title: "SHA256",
                value: key.colonFormattedFingerprint,
                copyText: "SHA256:\(key.colonFormattedFingerprint)"
            )
            .themedRow()
        }
    }

    @ViewBuilder
    private var publicKeySection: some View {
        // Public Key section
        Section("Public Key") {
            if isLoadingPublicKey {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading public key...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()
            } else {
                CopyableValueBlock(
                    title: String(localized: "OpenSSH Format", comment: "Public key format label"),
                    value: publicKeyString,
                    isCopyDisabled: publicKeyString.isEmpty || publicKeyString.hasPrefix("#")
                )
                .themedRow()
            }
        }
    }

    @ViewBuilder
    private var certificateSection: some View {
        // Certificate section
        Section {
            if let cert = currentKey.userCertificate {
                certificateStatusRow(for: cert)
                    .themedRow()

                LabeledRow(label: String(localized: "Key ID", comment: "Cert field: CA-assigned identity"), value: cert.keyID)
                    .themedRow()
                LabeledRow(label: String(localized: "Serial", comment: "Cert field: serial number"), value: "\(cert.serial)")
                    .themedRow()
                LabeledRow(
                    label: String(localized: "Principals", comment: "Cert field: valid usernames"),
                    value: cert.validPrincipals.isEmpty
                        ? String(localized: "Any user", comment: "Cert principals: unrestricted")
                        : cert.validPrincipals.joined(separator: ", ")
                )
                .themedRow()
                LabeledRow(label: String(localized: "Valid From", comment: "Cert field: validity start"), value: SSHUserCertificateFormatting.validFrom(cert))
                    .themedRow()
                LabeledRow(label: String(localized: "Valid Until", comment: "Cert field: validity end"), value: SSHUserCertificateFormatting.validUntil(cert))
                    .themedRow()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Certificate Authority")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(cert.caKeyType)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button {
                            UIPasteboard.general.string = cert.caFingerprint
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    Text(cert.caFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .themedRow()

                Button(action: copyCertificate) {
                    HStack(spacing: 4) {
                        Image(systemName: certificateCopied ? "checkmark" : "doc.on.doc")
                        Text(certificateCopied ? String(localized: "Copied", comment: "Copy button state: copied") : String(localized: "Copy Certificate", comment: "Cert detail: copy button"))
                    }
                }
                .themedRow()

                Group {
                    Button(action: { showingCertImport = true }) {
                        Label("Replace Certificate…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .themedRow()

                    Button(role: .destructive, action: { showingCertRemoveConfirmation = true }) {
                        Label("Remove Certificate", systemImage: "xmark.seal")
                    }
                    .themedRow()
                }
            } else {
                Button(action: { showingCertImport = true }) {
                    Label("Add Certificate", systemImage: "checkmark.seal")
                }
                .themedRow()
            }
        } header: {
            Text("Certificate")
        } footer: {
            if currentKey.userCertificate == nil {
                Text("Attach an OpenSSH user certificate (-cert.pub) issued for this key by a certificate authority. The certificate is offered first when connecting; servers configured with TrustedUserCAKeys accept it without an authorized_keys entry.")
            }
        }
    }

    @ViewBuilder
    private var installInstructionsSection: some View {
        // Installation Instructions section
        Section {
            DisclosureGroup("How to Use This Key", isExpanded: $showingInstallInstructions) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. Copy the public key above")
                        .font(.subheadline)

                    Text("2. Add it to the remote server's authorized_keys file:")
                        .font(.subheadline)

                    Text("~/.ssh/authorized_keys")
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(6)

                    Text("3. Make sure the file has correct permissions:")
                        .font(.subheadline)

                    Text("chmod 600 ~/.ssh/authorized_keys\nchmod 700 ~/.ssh")
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(6)

                    Text("4. If the .ssh directory doesn't exist:")
                        .font(.subheadline)

                    Text("mkdir -p ~/.ssh && chmod 700 ~/.ssh")
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(6)
                }
                .padding(.vertical, 8)
            }
            .themedRow()
        }
    }

    @ViewBuilder
    private var defaultKeysSection: some View {
        // Default keys section
        Section {
            Toggle("Include in Default Keys", isOn: Binding(
                get: { sshKeyManager.isDefault(id: key.id) },
                set: { enabled in
                    if enabled {
                        sshKeyManager.addToDefaults(id: key.id)
                    } else {
                        sshKeyManager.removeFromDefaults(id: key.id)
                    }
                }
            ))
            .themedRow()

            if isDefault,
               let priority = sshKeyManager.defaultPriority(for: key.id) {
                HStack {
                    Text("Priority")
                    Spacer()
                    Text("\(priority + 1) of \(sshKeyManager.defaultKeyIDs.count)")
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        } footer: {
            if defaultKeyAttemptCount > 6 {
                Text("Warning: SSH servers typically allow only 6 authentication attempts, and a key with a certificate uses two (certificate, then plain key). Consider removing some default keys.")
                    .foregroundColor(.appHighlight)
            } else {
                Text("Default keys are tried in order when connecting following the selected key")
            }
        }
    }

    @ViewBuilder
    private var securitySection: some View {
        // Security section
        Section("Security") {
            // Storage level
            HStack {
                Label("Storage", systemImage: currentKey.storageLevel.iconName)
                Spacer()
                Text(currentKey.storageLevel.displayName)
                    .foregroundColor(.secondary)
            }
            .themedRow()

            // Authentication requirement
            HStack {
                Label("Authentication", systemImage: currentKey.authRequirement.iconName)
                Spacer()
                Text(currentKey.authRequirement.displayName)
                    .foregroundColor(.secondary)
            }
            .themedRow()

            // Last modified date if available
            if let modifiedDate = currentKey.securityModifiedDate {
                HStack {
                    Text("Last Modified")
                    Spacer()
                    Text(formatDate(modifiedDate))
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }

            // Change security settings. Secure Enclave keys bake their
            // biometric/passcode gate into the enclave key at creation
            // time (it is immutable), so editing it after the fact would
            // desync metadata from real behavior — hide the control and
            // explain instead.
            if currentKey.secureEnclaveInfo == nil {
                Button(action: {
                    showingSecuritySettings = true
                }) {
                    HStack {
                        Image(systemName: "shield.checkerboard")
                        Text("Change Security Settings")
                    }
                }
                .themedRow()
            } else {
                Text("This key is generated in and bound to this device's Secure Enclave. Its protection cannot be exported, backed up, synced, or changed after creation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            }
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        // Delete section
        Section {
            Button(role: .destructive, action: {
                showingDeleteConfirmation = true
            }) {
                HStack {
                    Spacer()
                    Text("Delete Key")
                    Spacer()
                }
            }
            .themedRow()
        }
    }

    /// Get the current state of the key from the manager (to reflect any updates)
    private var currentKey: SSHKey {
        sshKeyManager.findKey(id: key.id) ?? key
    }

    private var isDefault: Bool {
        sshKeyManager.isDefault(id: key.id)
    }

    /// Keys backed by software material in the Keychain (not enclave references)
    private var isSoftwareKey: Bool {
        currentKey.secureEnclaveInfo == nil
    }

    private var keyNeedsUnlock: Bool {
        sshKeyManager.keysNeedingUnlock.contains(key.id)
    }

    private func unlockLegacyKey() {
        let passphrase = unlockPassphrase
        unlockPassphrase = ""
        guard !passphrase.isEmpty else { return }
        isUnlocking = true
        Task {
            defer { isUnlocking = false }
            do {
                try await sshKeyManager.unlockLegacyKey(id: key.id, passphrase: passphrase)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    /// Server auth attempts the default keys consume: certified keys count twice
    /// (certificate offer, then plain-key fallback).
    private var defaultKeyAttemptCount: Int {
        sshKeyManager.defaultKeyIDs.reduce(0) { total, id in
            total + (sshKeyManager.findKey(id: id)?.userCertificate != nil ? 2 : 1)
        }
    }

    private var formattedDate: String {
        formatDate(key.createdDate)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Actions


    private func loadPublicKey() {
        isLoadingPublicKey = true

        Task {
            do {
                let line = try SSHPublicKeyFormatter.authorizedKeysLine(for: currentKey)

                await MainActor.run {
                    publicKeyString = line
                    isLoadingPublicKey = false
                }
            } catch {
                await MainActor.run {
                    publicKeyString = "# Unable to load public key: \(error.localizedDescription)"
                    isLoadingPublicKey = false
                }
            }
        }
    }

    private func copyCertificate() {
        guard let cert = currentKey.userCertificate else { return }
        UIPasteboard.general.string = cert.exportLine(fallbackComment: currentKey.name)
        certificateCopied = true

        // Reset the copied state after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            certificateCopied = false
        }
    }

    private func deleteKey() {
        do {
            try sshKeyManager.deleteKey(id: key.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func renameKey() {
        let trimmedName = newKeyName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            errorMessage = "Key name cannot be empty"
            showingError = true
            return
        }

        sshKeyManager.updateKeyName(id: key.id, newName: trimmedName)
        newKeyName = ""
    }
}

// MARK: - Helper Views

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    NavigationView {
        SSHKeyDetailView(
            key: SSHKey(
                name: "Work Server",
                keyType: .ed25519,
                fingerprint: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
                hasPassphrase: true
            )
        )
    }
}
