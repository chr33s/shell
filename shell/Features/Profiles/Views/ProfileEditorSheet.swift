//
//  ProfileEditorSheet.swift
//  shell
//
//  The profile edit screen (spec section 13): name, host, port, username,
//  authentication / identity, jump host, TERM, and tmux. Nothing else.
//

import SwiftUI

struct ProfileEditorSheet: View {
    /// Existing profile to edit; nil creates a new one.
    var profile: SSHProfile?

    /// Pre-filled config for an ad-hoc (unsaved) connection.
    var initialConfig: SSHConfig?

    /// Connect with the edited config without necessarily saving.
    var onConnect: ((SSHConfig) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var keyManager = SSHKeyManager.shared
    @State private var profileManager = ConnectionProfileManager.shared

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var portText: String = "22"
    @State private var username: String = ""
    @State private var authType: AuthType = .password
    @State private var identityID: UUID?
    @State private var password: String = ""

    @State private var jumpHostEnabled = false
    @State private var jumpHost: String = ""
    @State private var jumpPortText: String = "22"
    @State private var jumpUsername: String = ""
    @State private var jumpAuthType: AuthType = .password
    @State private var jumpIdentityID: UUID?

    @State private var terminalType: String = ""
    @State private var tmuxMode: TmuxMode = .off
    @State private var tmuxSessionName: String = ""

    @State private var errorMessage: String?

    enum AuthType: String, CaseIterable, Identifiable {
        case password
        case savedPassword
        case key
        case keyboardInteractive

        var id: String { rawValue }

        var displayName: LocalizedStringKey {
            switch self {
            case .password: "Password"
            case .savedPassword: "Saved Password"
            case .key: "SSH Identity"
            case .keyboardInteractive: "Keyboard Interactive"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("production", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Host") {
                        TextField("example.com", text: $host)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    LabeledContent("Port") {
                        TextField("22", text: $portText)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    LabeledContent("Username") {
                        TextField("root", text: $username)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }

                Section {
                    Picker("Authentication", selection: $authType) {
                        ForEach(AuthType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    if authType == .password {
                        SecureField("Password", text: $password)
                    }
                    if authType == .key {
                        identityPicker(selection: $identityID)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    if authType == .key, let identity = selectedIdentity(identityID) {
                        identityFooter(identity)
                    }
                }

                Section {
                    Toggle("Use Jump Host", isOn: $jumpHostEnabled)
                    if jumpHostEnabled {
                        LabeledContent("Host") {
                            TextField("bastion.example.com", text: $jumpHost)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        LabeledContent("Port") {
                            TextField("22", text: $jumpPortText)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        LabeledContent("Username") {
                            TextField("root", text: $jumpUsername)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        Picker("Authentication", selection: $jumpAuthType) {
                            ForEach(AuthType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        if jumpAuthType == .key {
                            identityPicker(selection: $jumpIdentityID)
                        }
                    }
                } header: {
                    Text("Jump Host")
                }

                Section {
                    LabeledContent("TERM") {
                        TextField(TerminalTypeSettings.fallback, text: $terminalType)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Terminal")
                }

                Section {
                    Picker("Mode", selection: $tmuxMode) {
                        ForEach(TmuxMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    if tmuxMode != .off {
                        LabeledContent("Session Name") {
                            TextField(SSHConfig.tmuxGlobalSessionName, text: $tmuxSessionName)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                } header: {
                    Text("tmux")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.appDanger)
                    }
                }
            }
            .navigationTitle(profile == nil ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Save") { save(thenConnect: false) }
                        if onConnect != nil {
                            Button("Save & Connect") { save(thenConnect: true) }
                            Button("Connect Without Saving") { connectWithoutSaving() }
                        }
                    } label: {
                        Text("Done").bold()
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Identity picker

    @ViewBuilder
    private func identityPicker(selection: Binding<UUID?>) -> some View {
        Picker("Identity", selection: selection) {
            Text("None").tag(UUID?.none)
            ForEach(keyManager.savedKeys) { key in
                Text(Self.identityLabel(key)).tag(UUID?.some(key.id))
            }
        }
    }

    private func selectedIdentity(_ id: UUID?) -> SSHKey? {
        guard let id else { return nil }
        return keyManager.findKey(id: id)
    }

    /// "Ed25519", "P-256 · Secure Enclave · Certificate", … (spec section 13).
    static func identityLabel(_ key: SSHKey) -> String {
        var parts: [String] = [key.keyType == .secureEnclaveP256 ? "P-256" : key.keyType.rawValue]
        if key.secureEnclaveInfo != nil { parts.append("Secure Enclave") }
        if key.userCertificate != nil { parts.append("Certificate") }
        return "\(key.name) — \(parts.joined(separator: " · "))"
    }

    @ViewBuilder
    private func identityFooter(_ identity: SSHKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if identity.secureEnclaveInfo != nil {
                Text("Secure Enclave key — usable only on the device that created it.")
            }
            if let certificate = identity.userCertificate {
                if certificate.isExpired {
                    Text("Certificate expired.").foregroundStyle(.appDanger)
                } else if certificate.isNotYetValid {
                    Text("Certificate is not yet valid.").foregroundStyle(.appHighlight)
                } else if certificate.isExpiringSoon {
                    Text("Certificate expires soon.").foregroundStyle(.appHighlight)
                }
            }
        }
    }

    // MARK: - Load / save

    private func load() {
        let config = profile?.sshConfig ?? initialConfig
        name = profile?.name ?? ""
        guard let config else { return }

        host = config.host
        portText = String(config.port)
        username = config.username
        terminalType = config.terminalType ?? ""
        tmuxMode = config.tmuxMode
        tmuxSessionName = config.tmuxSessionName ?? ""

        switch config.authMethod {
        case .password(let secret):
            authType = .password
            password = secret
        case .savedPassword:
            authType = .savedPassword
        case .key(let id):
            authType = .key
            identityID = id
        case .keyboardInteractive:
            authType = .keyboardInteractive
        case .unknown:
            authType = .password
        }

        if let jump = config.jumpHost {
            jumpHostEnabled = true
            jumpHost = jump.host
            jumpPortText = String(jump.port)
            jumpUsername = jump.username
            switch jump.authMethod {
            case .password: jumpAuthType = .password
            case .savedPassword: jumpAuthType = .savedPassword
            case .key(let id):
                jumpAuthType = .key
                jumpIdentityID = id
            case .keyboardInteractive: jumpAuthType = .keyboardInteractive
            case .unknown: jumpAuthType = .password
            }
        }
    }

    private func buildConfig() -> SSHConfig? {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = String(localized: "Host is required.")
            return nil
        }
        guard let port = Int(portText), (1...65535).contains(port) else {
            errorMessage = String(localized: "Port must be between 1 and 65535.")
            return nil
        }
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = String(localized: "Username is required.")
            return nil
        }

        var config = SSHConfig(host: host, port: port, username: username)
        config.authMethod = authMethod(authType, identityID: identityID, password: password)

        if jumpHostEnabled {
            guard let jumpPort = Int(jumpPortText), (1...65535).contains(jumpPort) else {
                errorMessage = String(localized: "Jump host port must be between 1 and 65535.")
                return nil
            }
            config.jumpHost = SSHConfig.JumpHostConfig(
                host: jumpHost,
                port: jumpPort,
                username: jumpUsername,
                authMethod: authMethod(jumpAuthType, identityID: jumpIdentityID, password: "")
            )
        }

        let term = terminalType.trimmingCharacters(in: .whitespaces)
        config.terminalType = term.isEmpty ? nil : term
        config.tmuxMode = tmuxMode
        let session = tmuxSessionName.trimmingCharacters(in: .whitespaces)
        config.tmuxSessionName = session.isEmpty ? nil : session

        errorMessage = nil
        return config
    }

    private func authMethod(_ type: AuthType, identityID: UUID?, password: String) -> SSHConfig.AuthMethod {
        switch type {
        case .password: return .password(password)
        case .savedPassword: return .savedPassword
        case .key:
            guard let identityID else { return .savedPassword }
            return .key(identityID)
        case .keyboardInteractive: return .keyboardInteractive
        }
    }

    private func save(thenConnect: Bool) {
        guard let config = buildConfig() else { return }
        let profileName = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "\(username)@\(host)"
            : name

        do {
            if var existing = profile {
                existing.name = profileName
                existing.sshConfig = config
                try profileManager.updateProfile(existing)
            } else {
                try profileManager.createProfile(name: profileName, sshConfig: config)
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if thenConnect, let onConnect {
            onConnect(config)
        } else {
            dismiss()
        }
    }

    private func connectWithoutSaving() {
        guard let config = buildConfig(), let onConnect else { return }
        onConnect(config)
    }
}
