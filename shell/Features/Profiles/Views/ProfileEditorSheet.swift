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

    /// The failed connection's reason, retained while editing its credentials.
    var connectionError: String? = nil

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
    @State private var jumpAuthType: AuthType = .savedPassword
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

        /// Auth modes a jump hop can actually authenticate with end to end.
        ///
        /// `.password` is excluded: the editor has no jump password field, so
        /// `buildConfig()` could only ever build a hop carrying `.password("")`
        /// — and `AuthMethod`'s decoder maps a persisted `.password` back to
        /// `.password("")` regardless, so a jump hop on this method always puts
        /// an empty credential on the wire. `.savedPassword` is the working
        /// equivalent: it is resolved from the Keychain before connect
        /// (`TerminalSessionController` calls `resolvedConfig()` for a jump hop
        /// on `.savedPassword`), and a failed load degrades into the jump-host
        /// password prompt instead of a silent auth failure.
        static let jumpCases: [AuthType] = [.savedPassword, .key, .keyboardInteractive]

        /// `self` when a jump hop supports it, `.savedPassword` otherwise.
        ///
        /// Migrates a profile saved by an older build (or synced as the
        /// `"password"` shape, which `CloudKitSyncable` already decodes to
        /// `.savedPassword`) onto the working method. Nothing is lost: the
        /// editor never had a jump password to preserve.
        var forJumpHost: AuthType {
            AuthType.jumpCases.contains(self) ? self : .savedPassword
        }

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
                if let connectionError {
                    Section {
                        Text(connectionError)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } header: {
                        Text("Connection Failed")
                    }
                }

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
                        // Read through `forJumpHost` so a legacy `.password`
                        // jump config shows its migrated value instead of
                        // rendering the picker blank (a SwiftUI `Picker` whose
                        // selection is absent from its `ForEach` has no row to
                        // highlight). `buildConfig()` normalizes on the way out.
                        Picker("Authentication", selection: Binding(
                            get: { jumpAuthType.forJumpHost },
                            set: { jumpAuthType = $0 }
                        )) {
                            ForEach(AuthType.jumpCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        if jumpAuthType.forJumpHost == .key {
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
        // A connection the user has never saved carries no tmux choice of its
        // own, so it opens on the global default — Settings ▸ tmux ▸ Default
        // Mode. A saved profile always wins, including a deliberate "Off".
        let defaultTmuxMode = SettingsStore.shared.value(Settings.Tmux.defaultMode)
        guard let config else {
            tmuxMode = defaultTmuxMode
            return
        }

        host = config.host
        portText = String(config.port)
        username = config.username
        terminalType = config.terminalType ?? ""
        // An `initialConfig` is not always a blank slate: the reconnect sheet and
        // the profile-backed deep link both hand one over with `profile == nil`,
        // and those already carry a tmux choice the user made. Only a connection
        // with no profile behind it at all — a bare `ssh://` URL — has never
        // expressed one, so only that opens on the global default. The host /
        // username test mirrors `handleSSHURL`'s own profile lookup.
        let isProfileBacked = profile != nil || profileManager.profiles.contains {
            $0.sshConfig.host == config.host && $0.sshConfig.username == config.username
        }
        tmuxMode = (isProfileBacked || config.tmuxMode != .off) ? config.tmuxMode : defaultTmuxMode
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
        // Fail closed: "SSH Identity" with no identity selected used to fall through
        // to `.savedPassword`, silently authenticating with a stored password (or
        // prompting for one) on a host the user believed was key-authenticated.
        guard authType != .key || identityID != nil else {
            errorMessage = String(localized: "Select an SSH identity.")
            return nil
        }

        var config = SSHConfig(host: host, port: port, username: username)
        config.authMethod = authMethod(authType, identityID: identityID, password: password)

        if jumpHostEnabled {
            guard let jumpPort = Int(jumpPortText), (1...65535).contains(jumpPort) else {
                errorMessage = String(localized: "Jump host port must be between 1 and 65535.")
                return nil
            }
            // Same fail-closed rule for the jump hop (see the target-host guard above).
            let resolvedJumpAuthType = jumpAuthType.forJumpHost
            guard resolvedJumpAuthType != .key || jumpIdentityID != nil else {
                errorMessage = String(localized: "Select an SSH identity for the jump host.")
                return nil
            }
            // `password: ""` is unreachable: `forJumpHost` never yields
            // `.password`, so the empty string is never read.
            config.jumpHost = SSHConfig.JumpHostConfig(
                host: jumpHost,
                port: jumpPort,
                username: jumpUsername,
                authMethod: authMethod(resolvedJumpAuthType, identityID: jumpIdentityID, password: "")
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
            // Unreachable — buildConfig() rejects `.key` with no identity. The
            // fallback stays unusable on purpose: never downgrade a key profile
            // to password auth (SSHConfig.resolvedConfig forbids that substitution).
            guard let identityID else { return .unknown(rawType: "key") }
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
