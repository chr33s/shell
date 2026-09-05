import SwiftUI

struct SavedPasswordsView: View {
    @State private var passwordManager = SSHPasswordManager.shared
    @State private var showingDeleteConfirmation = false
    @State private var passwordToDelete: SSHSavedPassword?
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        List {
            if passwordManager.savedPasswords.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "key.horizontal.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                            .padding(.top, 20)

                        Text("No Saved Passwords")
                            .font(.headline)

                        Text("Passwords you save when connecting will appear here")
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
                    ForEach(passwordManager.savedPasswords) { password in
                        SavedPasswordRow(password: password)
                            .themedRow()
                    }
                    .onDelete(perform: deletePasswords)
                } header: {
                    Text("Saved Passwords")
                } footer: {
                    Text("\(passwordManager.savedPasswords.count) password\(passwordManager.savedPasswords.count == 1 ? "" : "s") saved")
                }
            }

            Section {
                Text("Passwords are stored securely in the system Keychain")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            }

            // Default security settings for new passwords
            Section {
                Picker("Storage Level", selection: Binding(
                    get: { passwordManager.defaultStorageLevel },
                    set: { passwordManager.defaultStorageLevel = $0 }
                )) {
                    ForEach(KeyStorageLevel.allCases, id: \.self) { level in
                        Label {
                            VStack(alignment: .leading) {
                                Text(level.displayName)
                                Text(level.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: level.iconName)
                        }
                        .tag(level)
                    }
                }
                .themedRow()

                Picker("Authentication", selection: Binding(
                    get: { passwordManager.defaultAuthRequirement },
                    set: { passwordManager.defaultAuthRequirement = $0 }
                )) {
                    ForEach(KeyAuthRequirement.allCases, id: \.self) { req in
                        Label {
                            VStack(alignment: .leading) {
                                Text(req.displayName)
                                Text(req.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: req.iconName)
                        }
                        .tag(req)
                    }
                }
                .themedRow()
            } header: {
                Text("Default Security Settings")
            } footer: {
                Text("These settings apply to newly saved passwords. Existing passwords keep their original settings.")
            }
        }
        .themedList()
        .navigationTitle("Saved Passwords")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete Password", isPresented: $showingDeleteConfirmation, presenting: passwordToDelete) { password in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deletePassword(password)
            }
        } message: { password in
            Text("Are you sure you want to delete the saved password for '\(password.displayName)'?")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func deletePasswords(at offsets: IndexSet) {
        for index in offsets {
            let password = passwordManager.savedPasswords[index]
            passwordToDelete = password
            showingDeleteConfirmation = true
        }
    }

    private func deletePassword(_ password: SSHSavedPassword) {
        do {
            try passwordManager.deletePassword(id: password.id)
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

struct SavedPasswordRow: View {
    let password: SSHSavedPassword

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "person.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text(password.displayName)
                    .font(.body)
            }

            HStack(spacing: 12) {
                // Storage level indicator
                HStack(spacing: 4) {
                    Image(systemName: password.storageLevel.iconName)
                        .font(.caption2)
                    Text(password.storageLevel.displayName)
                        .font(.caption)
                }
                .foregroundColor(.secondary)

                // Auth requirement indicator
                if password.authRequirement != .none {
                    HStack(spacing: 4) {
                        Image(systemName: password.authRequirement.iconName)
                            .font(.caption2)
                        Text(password.authRequirement.displayName)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }

            if let lastUsed = password.lastUsedDate {
                Text("Last used: \(lastUsed, style: .relative) ago")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        SavedPasswordsView()
    }
}
