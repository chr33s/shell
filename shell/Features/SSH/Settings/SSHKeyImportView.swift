import SwiftUI
import UniformTypeIdentifiers
import os.log

struct SSHKeyImportView: View {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHKeyImport")
    @Environment(\.dismiss) var dismiss
    @StateObject private var sshKeyManager = SSHKeyManager.shared

    @State private var importMethod: ImportMethod = .paste
    @State private var keyName = ""
    @State private var pastedKeyText = ""
    @State private var passphrase = ""
    @State private var showingFilePicker = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isImporting = false

    // Security options
    @State private var showSecurityOptions = false
    /// The user's explicit pick in the Key Storage picker, or nil while the
    /// picker is still showing the default. Kept separate from the effective
    /// `storageLevel` so an explicit pick always outranks the default.
    @State private var storageLevelChoice: KeyStorageLevel?
    @State private var authRequirement: KeyAuthRequirement = .none

    /// Settings > Sync > "Sync Software Keys". Every key that arrives through
    /// this screen is a software key, so this decides its *default* storage
    /// level. It never re-files a key that was imported earlier.
    @Setting(Settings.System.syncSoftwareKeys) private var syncSoftwareKeys: Bool

    enum ImportMethod: String, CaseIterable {
        case paste = "Paste"
        case file = "File"

        var displayName: String {
            switch self {
            case .paste: return String(localized: "Paste", comment: "SSH key import method: paste key text")
            case .file: return String(localized: "File", comment: "SSH key import method: import from file")
            }
        }
    }

    var body: some View {
        Form {
                // Import method picker
                Section {
                    Picker("Import Method", selection: $importMethod) {
                        ForEach(ImportMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .themedRow()
                }

                // Key name input
                Section {
                    TextField("Key Name", text: $keyName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .themedRow()
                } header: {
                    Text("Name")
                } footer: {
                    Text("A friendly name for this key (e.g., 'Work Server', 'GitHub')")
                }

                // Import method-specific UI
                if importMethod == .paste {
                    Section {
                        TextEditor(text: $pastedKeyText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 200)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .themedRow()
                    } header: {
                        Text("Private Key")
                    } footer: {
                        Text("Paste your private key here (PEM or OpenSSH format)")
                    }
                } else {
                    Section {
                        Button(action: {
                            showingFilePicker = true
                        }) {
                            HStack {
                                Image(systemName: "doc.fill")
                                Text("Select Key File")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .themedRow()

                        if !pastedKeyText.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.appSuccess)
                                Text("File loaded")
                                    .foregroundColor(.secondary)
                            }
                            .themedRow()
                        }
                    } header: {
                        Text("Private Key File")
                    } footer: {
                        Text("Select a .pem, .key, or other private key file")
                    }
                }

                // Passphrase input (shown when key content is present)
                if !pastedKeyText.isEmpty && keyLooksEncrypted {
                    Section {
                        SecureField("Passphrase", text: $passphrase)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .themedRow()
                    } header: {
                        Text("Passphrase")
                    } footer: {
                        Text("This key appears to be encrypted. The passphrase is used once to decrypt the key during import and is never stored.")
                    }
                }

                // Security options (collapsible)
                Section {
                    DisclosureGroup("Security Options", isExpanded: $showSecurityOptions) {
                        // Storage level picker
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Key Storage")
                                .font(.subheadline.bold())

                            Picker("Key Storage", selection: storageLevelBinding) {
                                ForEach(KeyStorageLevel.allCases, id: \.self) { level in
                                    Label(level.displayName, systemImage: level.iconName)
                                        .tag(level)
                                }
                            }
                            .pickerStyle(.menu)

                            Text(storageLevel.description)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if usesSyncedStorageDefault {
                                Text("Default from Settings → Sync → Sync Software Keys. Pick another level to override it for this key.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)

                        Divider()

                        // Auth requirement picker
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Require Authentication")
                                .font(.subheadline.bold())

                            Picker("Authentication", selection: $authRequirement) {
                                ForEach(KeyAuthRequirement.allCases, id: \.self) { req in
                                    Label(req.displayName, systemImage: req.iconName)
                                        .tag(req)
                                }
                            }
                            .pickerStyle(.menu)

                            Text(authRequirement.description)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if authRequirement != .none {
                                HStack {
                                    Image(systemName: SSHKeyAuthManager.shared.biometricIconName)
                                        .foregroundColor(.appAccent)
                                    Text("Uses \(SSHKeyAuthManager.shared.biometricTypeName) or device passcode")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                if storageLevel == .iCloudSync {
                                    Text(KeyAuthRequirement.iCloudAuthenticationAdvisory)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .themedRow()
                } footer: {
                    if !showSecurityOptions {
                        Text("Tap to configure storage and authentication options")
                    }
                }

                // Hint for unencrypted keys
                if !pastedKeyText.isEmpty && !keyLooksEncrypted && authRequirement == .none {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.appHighlight)
                            Text("This key has no passphrase. Consider enabling authentication in Security Options for additional protection.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                }

                // Import button
                Section {
                    Button(action: importKey) {
                        HStack {
                            Spacer()
                            if isImporting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isImporting ? String(localized: "Importing...", comment: "SSH key import: in progress") : String(localized: "Import Key", comment: "SSH key import: button"))
                            Spacer()
                        }
                    }
                    .disabled(!canImport || isImporting)
                    .themedRow()
                }

                // Info section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Supported key types:", systemImage: "info.circle")
                            .font(.caption.bold())

                        Text("• RSA (widely compatible)")
                        Text("• Ed25519 (recommended)")
                        Text("• ECDSA P-256, P-384, P-521")

                        Text("\nEncrypted keys with passphrases are supported")
                            .font(.caption.bold())
                            .foregroundColor(.appSuccess)

                        Text("The passphrase is used once to decrypt the key during import and is never stored; the imported key is protected by the Keychain")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
                }
            }
            .themedList()
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationTitle("Import SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result)
            }
            .alert("Import Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
    }

    // MARK: - Computed Properties

    private var canImport: Bool {
        !keyName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !pastedKeyText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var keyLooksEncrypted: Bool {
        // Use the parser's proper encryption detection which parses the binary format
        SSHKeyParser.isEncrypted(keyString: pastedKeyText)
    }

    // MARK: - Storage Level

    /// Default storage level for a newly imported (always software) key.
    ///
    /// Settings > Sync > "Sync Software Keys" is the one switch that says
    /// whether new software private keys are marked for iCloud Keychain
    /// synchronization. With it off this stays `.backupOnly` — byte-for-byte
    /// the behaviour before the switch was read by anything.
    private var defaultSoftwareStorageLevel: KeyStorageLevel {
        syncSoftwareKeys ? .iCloudSync : .backupOnly
    }

    /// The storage level this import will actually use: the user's explicit
    /// pick when there is one, otherwise the default above.
    private var storageLevel: KeyStorageLevel {
        storageLevelChoice ?? defaultSoftwareStorageLevel
    }

    /// True while the picker is still showing an iCloud default that came
    /// from the sync setting rather than from the user.
    private var usesSyncedStorageDefault: Bool {
        storageLevelChoice == nil && syncSoftwareKeys
    }

    private var storageLevelBinding: Binding<KeyStorageLevel> {
        Binding(
            get: { storageLevel },
            set: { storageLevelChoice = $0 }
        )
    }

    // MARK: - Actions

    private func importKey() {
        isImporting = true

        // Snapshot the security options up front so the Keychain write and
        // the log line below can never disagree about where the private key
        // was filed.
        let storageLevel = self.storageLevel
        let authRequirement = self.authRequirement

        Task {
            do {
                let trimmedName = keyName.trimmingCharacters(in: .whitespaces)
                let trimmedKey = pastedKeyText.trimmingCharacters(in: .whitespaces)
                let passphraseToUse = passphrase.isEmpty ? nil : passphrase

                let importedKey = try await Task { @MainActor in
                    try sshKeyManager.importKey(
                        name: trimmedName,
                        keyString: trimmedKey,
                        passphrase: passphraseToUse,
                        storageLevel: storageLevel,
                        authRequirement: authRequirement
                    )
                }.value

                await MainActor.run {
                    isImporting = false
                    Self.logger.info("Successfully imported SSH key: \(importedKey.name) with storage=\(storageLevel.rawValue), auth=\(authRequirement.rawValue)")
                    dismiss()
                }
            } catch let error as SSHKeyParser.ParserError {
                await MainActor.run {
                    isImporting = false
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    errorMessage = error.localizedDescription
                    showingError = true
                }
            }
        }
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Unable to access the file"
                showingError = true
                return
            }

            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let keyContent = try String(contentsOf: url, encoding: .utf8)
                pastedKeyText = keyContent

                // Auto-fill name from filename if empty
                if keyName.isEmpty {
                    let filename = url.deletingPathExtension().lastPathComponent
                    // Clean up common suffixes like "_rsa", "_ed25519", etc.
                    let cleanedName = filename
                        .replacingOccurrences(of: "_rsa", with: "")
                        .replacingOccurrences(of: "_ed25519", with: "")
                        .replacingOccurrences(of: "_ecdsa", with: "")
                        .replacingOccurrences(of: "id_", with: "")

                    keyName = cleanedName.isEmpty ? "Imported Key" : cleanedName
                }
            } catch {
                errorMessage = "Failed to read file: \(error.localizedDescription)"
                showingError = true
            }

        case .failure(let error):
            errorMessage = "File selection failed: \(error.localizedDescription)"
            showingError = true
        }
    }
}

#Preview {
    SSHKeyImportView()
}
