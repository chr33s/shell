import SwiftUI

/// Detailed view for a known SSH host
struct KnownHostDetailView: View {
    let host: KnownHost
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @StateObject private var manager = KnownHostsManager.shared
    @State private var showingDeleteAlert = false
    @State private var fingerprintCopied = false

    var body: some View {
        Form {
            Section("Host Information") {
                LabeledContent("Hostname", value: host.hostname)
                    .hostAddressCopyMenu(hostname: host.hostname)
                    .themedRow()
                LabeledContent("Port", value: "\(host.port)")
                    .themedRow()
                LabeledContent("Display Name", value: host.displayName)
                    .themedRow()
            }

            Section("Key Information") {
                LabeledContent("Key Type", value: host.keyType.uppercased())
                    .themedRow()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Fingerprint")
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: copyFingerprint) {
                            HStack(spacing: 4) {
                                Image(systemName: fingerprintCopied ? "checkmark" : "doc.on.doc")
                                Text(fingerprintCopied ? String(localized: "Copied", comment: "Copy button state: copied") : String(localized: "Copy", comment: "Copy button"))
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(fingerprintCopied ? .appSuccess : .appAccent)
                    }

                    Text(host.fullFingerprint)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(6)
                }
                .themedRow()
            }

            Section("Verification History") {
                LabeledContent("First Seen", value: host.firstSeen, format: .dateTime)
                    .themedRow()
                LabeledContent("Last Verified", value: host.lastSeen, format: .dateTime)
                    .themedRow()

                HStack {
                    Text("Time Since Last Verification")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(timeSinceLastVerification)
                        .foregroundColor(.primary)
                }
                .themedRow()
            }

            Section {
                Button(role: .destructive, action: { showingDeleteAlert = true }) {
                    HStack {
                        Spacer()
                        Label("Remove from Known Hosts", systemImage: "trash")
                        Spacer()
                    }
                }
                .themedRow()
            } footer: {
                Text("Removing this host will require you to verify and trust its key again on your next connection.")
                    .font(.caption)
            }
        }
        .themedList()
        .navigationTitle("Known Host Details")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Remove Known Host?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                manager.removeHost(hostname: host.hostname, port: host.port)
                dismiss()
            }
        } message: {
            Text("Are you sure you want to remove \(host.displayName) from known hosts? You will need to verify and trust this host again on your next connection.")
        }
    }

    private var timeSinceLastVerification: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: host.lastSeen, relativeTo: Date())
    }

    private func copyFingerprint() {
        UIPasteboard.general.string = host.fullFingerprint
        fingerprintCopied = true

        // Reset the copied state after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            fingerprintCopied = false
        }
    }
}

#Preview {
    NavigationView {
        KnownHostDetailView(host: KnownHost(
            hostname: "example.com",
            port: 22,
            publicKeyData: "AAAAC3NzaC1lZDI1NTE5AAAAIExample==",
            keyType: "ed25519",
            fingerprint: "SHA256:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99",
            firstSeen: Date().addingTimeInterval(-86400 * 7), // 7 days ago
            lastSeen: Date().addingTimeInterval(-3600) // 1 hour ago
        ))
    }
}
