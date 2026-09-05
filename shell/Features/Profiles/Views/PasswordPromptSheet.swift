import SwiftUI

/// A lightweight modal for entering SSH password when connecting via profile
/// Used when a profile doesn't have a saved password or needs re-authentication
struct PasswordPromptSheet: View {
    let host: String
    let port: Int
    let username: String
    let onSubmit: (String, Bool) -> Void  // (password, shouldSave)
    let onCancel: () -> Void

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var password: String = ""
    @State private var savePassword: Bool = false
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading) {
                            Text(displayName)
                                .font(.headline)
                            if port != 22 {
                                Text("Port \(port)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .themedRow()
                } header: {
                    Text("Connection")
                }

                Section {
                    SecureField("Password", text: $password)
                        .focused($isPasswordFocused)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit {
                            if !password.isEmpty {
                                onSubmit(password, savePassword)
                            }
                        }
                        .themedRow()
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Enter your SSH password for \(username)")
                }

                Section {
                    Toggle("Save Password", isOn: $savePassword)
                        .themedRow()
                } footer: {
                    Text("Save password securely in Keychain for future connections")
                }
            }
            .themedList()
            .navigationTitle("Enter Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        onSubmit(password, savePassword)
                    }
                    .disabled(password.isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                // Focus password field immediately
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isPasswordFocused = true
                }
            }
        }
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.visible)
    }

    private var displayName: String {
        "\(username)@\(host)"
    }
}

#Preview {
    PasswordPromptSheet(
        host: "example.com",
        port: 22,
        username: "admin",
        onSubmit: { password, shouldSave in
            print("Password: \(password), Save: \(shouldSave)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}
