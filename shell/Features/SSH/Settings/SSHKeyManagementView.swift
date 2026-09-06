import SwiftUI

struct SSHKeyManagementView: View {
    @StateObject private var sshKeyManager = SSHKeyManager.shared
    @State private var showingImport = false
    @State private var showingCertImportSheet = false
    @State private var showingGenerate = false
    @State private var showingDeleteConfirmation = false
    @State private var keyToDelete: SSHKey?
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var overrideManager = DeviceKeyOverrideManager.shared

    var body: some View {
        List {
            if sshKeyManager.savedKeys.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "key.fill").font(.system(size: 48)).foregroundColor(.secondary).padding(.top, 20)

                        Text("No SSH Keys").font(.headline)

                        Text("Generate or import an SSH key to use for authentication").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(
                            .center
                        ).padding(.bottom, 20)
                    }.frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(sshKeyManager.savedKeys) { key in
                        NavigationLink {
                            SSHKeyDetailView(key: key)
                        } label: {
                            SSHKeyRow(
                                key: key,
                                defaultPriority: sshKeyManager.defaultPriority(for: key.id),
                                needsUnlock: sshKeyManager.keysNeedingUnlock.contains(key.id)
                            )
                        }
                    }.onDelete(perform: deleteKeys).themedRow()
                }
            }

            // Per-device key pins. The sheet that creates them ("Always use on
            // this device") had no counterpart screen, so an override could be
            // created but never seen or revoked.
            Section {
                NavigationLink {
                    DeviceKeyOverridesView()
                } label: {
                    HStack {
                        Label("Device Key Overrides", systemImage: "pin")
                        Spacer()
                        Text(overrideManager.overrides.count, format: .number).foregroundColor(.secondary)
                    }
                }.themedRow()
            } footer: {
                Text("Keys pinned to this device when a connection's own key wasn't available.")
            }

            Section { Text("SSH keys are stored securely in the system Keychain").font(.caption).foregroundColor(.secondary).themedRow() }
        }.themedList().refreshable { await sshKeyManager.refreshKeysAsync() }.navigationTitle("SSH Keys").navigationBarTitleDisplayMode(.inline).toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { showingGenerate = true }) { Label("Generate New Key", systemImage: "wand.and.stars") }

                    Button(action: { showingImport = true }) { Label("Import Existing Key", systemImage: "square.and.arrow.down") }

                    Button(action: { showingCertImportSheet = true }) { Label("Import Certificate", systemImage: "checkmark.seal") }

                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $showingImport) {
            SSHKeyImportView()
        }
        .navigationDestination(isPresented: $showingCertImportSheet) {
            SSHUserCertificateImportView(targetKey: nil)
        }
        .navigationDestination(isPresented: $showingGenerate) {
            SSHKeyGenerateView()
        }
        .alert("Delete Key", isPresented: $showingDeleteConfirmation, presenting: keyToDelete) { key in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteKey(key)
            }
        } message: { key in
            Text("Are you sure you want to delete the key '\(key.name)'? This cannot be undone.")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func deleteKeys(at offsets: IndexSet) {
        for index in offsets {
            let key = sshKeyManager.savedKeys[index]
            keyToDelete = key
            showingDeleteConfirmation = true
        }
    }

    private func deleteKey(_ key: SSHKey) {
        do { try sshKeyManager.deleteKey(id: key.id) } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

// MARK: - SSH Key Row

struct SSHKeyRow: View {
    let key: SSHKey
    /// Priority in the default keys list (0 = highest priority, nil = not a default)
    let defaultPriority: Int?
    /// Legacy-encrypted key that needs a one-time manual unlock on this device
    let needsUnlock: Bool

    /// Fixed width for badge alignment (accommodates "ED25519")
    private static let badgeWidth: CGFloat = 62

    init(key: SSHKey, defaultPriority: Int?, needsUnlock: Bool = false) {
        self.key = key
        self.defaultPriority = defaultPriority
        self.needsUnlock = needsUnlock
    }

    var body: some View {
        HStack(spacing: 12) {
            // Key type badge with fixed width for alignment
            Text(key.keyType.shortName).font(.caption.bold()).foregroundStyle(keyTypeColor).frame(width: Self.badgeWidth).padding(.vertical, 4).background(
                keyTypeColor.opacity(0.18)
            ).cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.name).font(.body).lineLimit(1)

                    if let priority = defaultPriority {
                        // Show priority badge for default keys
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill").font(.caption2)
                            if priority > 0 { Text("\(priority + 1)").font(.caption2.bold()) }
                        }.foregroundColor(.appWarning).padding(.horizontal, 4).padding(.vertical, 2).background(Color.appWarning.opacity(0.2)).cornerRadius(4)
                    }

                    if let cert = key.userCertificate {
                        // Certificate badge: green valid, orange expiring soon, red expired
                        Image(systemName: cert.isExpired ? "xmark.seal.fill" : "checkmark.seal.fill").font(.caption2).foregroundColor(
                            certificateBadgeColor(cert)
                        ).padding(.horizontal, 4).padding(.vertical, 2).background(certificateBadgeColor(cert).opacity(0.2)).cornerRadius(4)
                    }

                    if needsUnlock {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundColor(.appHighlight).padding(
                            .horizontal, 4
                        ).padding(.vertical, 2).background(Color.appHighlight.opacity(0.2)).cornerRadius(4)
                    }
                }

                // Fingerprint with middle truncation to show both ends
                Text("SHA256:\(key.fingerprint)").font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)

                // Created date
                Text(key.createdDate, format: .dateTime.month(.abbreviated).day().year()).font(.caption2).foregroundStyle(.tertiary)
            }

            Spacer()
        }.padding(.vertical, 4).contentShape(Rectangle())
    }

    private var keyTypeColor: Color {
        switch key.keyType {
        case .rsa: return .appDanger
        case .ed25519: return .appAccent
        case .ecdsaP256: return .appSuccess
        case .ecdsaP384: return .appHighlight
        case .ecdsaP521: return .purple
        case .secureEnclaveP256: return .indigo
        }
    }

    private func certificateBadgeColor(_ cert: SSHUserCertificateInfo) -> Color {
        if cert.isExpired { return .appDanger }
        if cert.isExpiringSoon || cert.isNotYetValid { return .appHighlight }
        return .appSuccess
    }

}

#Preview { NavigationView { SSHKeyManagementView() } }
