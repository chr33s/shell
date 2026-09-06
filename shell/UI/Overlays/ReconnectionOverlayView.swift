//
//  ReconnectionOverlayView.swift
//  shell
//
//  Overlay displayed on terminals that need reconnection after state restoration.
//

import SwiftUI

/// Overlay view for terminals pending reconnection
struct ReconnectionOverlayView: View {
    let state: Ghostty.TerminalView.RestorationState
    let connectionConfig: ConnectionConfig
    let onReconnect: () -> Void
    let onEnterPassword: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        ReconnectPromptCard(
            title: stateTitle,
            subtitle: connectionConfig.displayName,
            icon: { stateIcon },
            content: { stateContent }
        )
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch state {
        case .pendingReconnection:
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 48))
                .foregroundColor(.appAccent)
                .symbolEffect(.breathe, isActive: true)
        case .connectingFromRestore:
            ProgressView()
                .scaleEffect(1.5)
        case .needsPassword:
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundColor(.appHighlight)
                .symbolEffect(.wiggle, isActive: true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.appDanger)
                .symbolEffect(.pulse, isActive: true)
        case .none:
            EmptyView()
        }
    }

    private var stateTitle: String {
        switch state {
        case .pendingReconnection:
            return String(localized: "Session Disconnected", comment: "Reconnection overlay: session lost")
        case .connectingFromRestore:
            return String(localized: "Reconnecting...", comment: "Reconnection overlay: in progress")
        case .needsPassword:
            return String(localized: "Password Required", comment: "Reconnection overlay: needs auth")
        case .failed:
            return String(localized: "Reconnection Failed", comment: "Reconnection overlay: failed")
        case .none:
            return ""
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .pendingReconnection:
            HStack(spacing: 16) {
                Button(action: onReconnect) {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive, action: onClose) {
                    Label("Close Tab", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }

        case .connectingFromRestore:
            Text("Please wait...")
                .font(.caption)
                .foregroundColor(.secondary)

        case .needsPassword(let config):
            ReconnectPasswordSection(
                prompt: passwordPrompt(for: config),
                onSubmit: { password, _ in onEnterPassword(password) }
            )

        case .failed(let errorMessage):
            VStack(spacing: 16) {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)

                HStack(spacing: 16) {
                    Button(action: onReconnect) {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive, action: onClose) {
                        Label("Close Tab", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .none:
            EmptyView()
        }
    }

    private func passwordPrompt(for config: SSHConfig) -> String {
        // Check if it's jump host or target that needs password
        if let jump = config.jumpHost,
           case .password(let pwd) = jump.authMethod,
           pwd.isEmpty {
            let userHost = "\(jump.username)@\(jump.host)"
            return String(localized: "Enter password for jump host \(userHost)", comment: "Password prompt for jump host reconnection")
        }
        let userHost = "\(config.username)@\(config.host)"
        return String(localized: "Enter password for \(userHost)", comment: "Password prompt for reconnection")
    }
}

// MARK: - Glass Background Modifier

extension View {
    @ViewBuilder
    func overlayCardBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        #if os(visionOS)
        self.background(.regularMaterial, in: shape)
        #else
        self.glassEffect(.regular, in: shape)
        #endif
    }
}

#Preview("Pending Reconnection") {
    ReconnectionOverlayView(
        state: .pendingReconnection,
        connectionConfig: .ssh(SSHConfig(host: "example.com", username: "user", password: "")),
        onReconnect: {},
        onEnterPassword: { _ in },
        onClose: {}
    )
}

#Preview("Needs Password") {
    ReconnectionOverlayView(
        state: .needsPassword(SSHConfig(host: "example.com", username: "user", password: "")),
        connectionConfig: .ssh(SSHConfig(host: "example.com", username: "user", password: "")),
        onReconnect: {},
        onEnterPassword: { _ in },
        onClose: {}
    )
}

#Preview("Failed") {
    ReconnectionOverlayView(
        state: .failed("Connection timed out. The server may be unreachable."),
        connectionConfig: .ssh(SSHConfig(host: "example.com", username: "user", password: "")),
        onReconnect: {},
        onEnterPassword: { _ in },
        onClose: {}
    )
}
