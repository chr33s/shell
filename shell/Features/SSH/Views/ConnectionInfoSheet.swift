//
//  ConnectionInfoSheet.swift
//  shell
//
//  Displays detailed connection information for a terminal session
//

import SwiftUI

struct ConnectionInfoSheet: View {
    let info: ConnectionInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch info {
                case .ssh(let sshInfo):
                    sshContent(sshInfo)
                case .local(let shell, let workingDirectory, _):
                    localContent(shell: shell, workingDirectory: workingDirectory)
                }
            }
            .themedList()
            .navigationTitle("Connection Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: .constant(.large))
    }

    // MARK: - SSH Content

    @ViewBuilder
    private func sshContent(_ info: SSHConnectionInfo) -> some View {
        securityStatusSection(info)
        connectionSection(info)
        cryptographySection(info)
        if info.jumpHost != nil {
            featuresSection(info)
        }
    }

    @ViewBuilder
    private func securityStatusSection(_ info: SSHConnectionInfo) -> some View {
        Section {
            if info.isPostQuantumKeyExchange {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Post-Quantum Secure")
                            .font(.headline)
                            .foregroundStyle(.appSuccess)
                        Text("This connection uses hybrid post-quantum key exchange, protecting against future quantum computer attacks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "shield.checkered")
                        .font(.title2)
                        .foregroundStyle(.appSuccess)
                }
                .themedRow()
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Classically Secure")
                            .font(.headline)
                            .foregroundStyle(.appAccent)
                        Text("This connection uses classical cryptography. Secure against current threats.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundStyle(.appAccent)
                }
                .themedRow()
            }
        }
    }

    @ViewBuilder
    private func connectionSection(_ info: SSHConnectionInfo) -> some View {
        Section("Connection") {
            infoRow("Host", value: info.host)
            infoRow("Port", value: "\(info.port)")
            infoRow("User", value: info.username)
            if let ip = info.resolvedIP, ip != info.host {
                infoRow("IP Address", value: ip)
            }
            liveDurationRow(since: info.connectedAt)
            if let jumpHost = info.jumpHost {
                let jumpPort = info.jumpPort.map { ":\($0)" } ?? ""
                infoRow("Jump Host", value: "\(jumpHost)\(jumpPort)")
            }
        }
    }

    @ViewBuilder
    private func cryptographySection(_ info: SSHConnectionInfo) -> some View {
        Section("Cryptography") {
            algorithmRow("Key Exchange", value: info.keyExchangeAlgorithm, isPostQuantum: info.isPostQuantumKeyExchange)
            algorithmRow("Host Key", value: info.hostKeyAlgorithm, isPostQuantum: info.isPostQuantumHostKey)
            algorithmRow("Cipher", value: info.cipherAlgorithm)
            algorithmRow("MAC", value: info.macAlgorithm)
        }
    }

    @ViewBuilder
    private func featuresSection(_ info: SSHConnectionInfo) -> some View {
        // Wrapped around the whole Section: with the condition inside, a direct
        // connection rendered an empty "Features" header.
        if info.jumpHost != nil {
            Section("Features") {
                Label("Proxy Jump", systemImage: "arrow.triangle.branch")
                    .themedRow()
            }
        }
    }

    // MARK: - Local Content

    @ViewBuilder
    private func localContent(shell: String, workingDirectory: String?) -> some View {
        Section {
            Label {
                Text("Local Shell")
                    .font(.headline)
            } icon: {
                Image(systemName: "terminal")
                    .foregroundStyle(.appSuccess)
            }
            .themedRow()
        }
        Section("Details") {
            infoRow("Shell", value: shell)
            if let cwd = workingDirectory {
                infoRow("Directory", value: cwd)
            }
            liveDurationRow(since: info.connectedAt)
        }
    }

    // MARK: - Rows

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
        .themedRow()
    }

    private func liveDurationRow(since date: Date) -> some View {
        HStack {
            Text("Duration")
                .foregroundStyle(.secondary)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.formatDuration(from: date, to: context.date))
                    .font(.system(.body, design: .monospaced))
                    .contentTransition(.numericText())
                    .monospacedDigit()
            }
        }
        .themedRow()
    }

    /// Format elapsed time between two dates
    static func formatDuration(from start: Date, to now: Date) -> String {
        let elapsed = now.timeIntervalSince(start)
        let totalSeconds = max(0, Int(elapsed))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    private func algorithmRow(_ label: String, value: String?, isPostQuantum: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let value {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    if isPostQuantum {
                        Image(systemName: "shield.checkered")
                            .font(.caption2)
                            .foregroundStyle(.appSuccess)
                    }
                }
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .themedRow()
    }
}
