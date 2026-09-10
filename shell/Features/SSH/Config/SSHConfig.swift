import Foundation

/// Which flavor of tmux to launch when auto-start is enabled.
/// Only meaningful when `SSHConfig.tmuxAutoEnable` is true.
nonisolated enum TmuxAutoMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// Plain interactive session: `tmux new-session -A`.
    case regular

    /// Control mode gateway: `tmux -CC new-session -A`. Requires a raw byte
    /// transport.
    case control
}

/// The spec's three-state tmux selection for a profile: off, plain tmux, or
/// native control mode. Stored on `SSHConfig` as the pair
/// (`tmuxAutoEnable`, `tmuxAutoMode`); this is the UI-facing view of it.
nonisolated enum TmuxMode: String, Codable, CaseIterable, Hashable, Sendable {
    case off
    case regular
    case control

    init(tmuxEnabled: Bool, mode: TmuxAutoMode) {
        self = tmuxEnabled ? (mode == .control ? .control : .regular) : .off
    }

    /// Whether tmux auto-start is on.
    var tmuxEnabled: Bool { self != .off }

    /// The persisted tmux launch mode (`regular` when tmux is off, which is
    /// irrelevant then).
    var autoMode: TmuxAutoMode { self == .control ? .control : .regular }

    var displayName: String {
        switch self {
        case .off: return String(localized: "Off", comment: "tmux mode: off")
        case .regular: return String(localized: "tmux", comment: "tmux mode: plain tmux")
        case .control: return String(localized: "tmux Control Mode", comment: "tmux mode: control mode")
        }
    }
}

/// Configuration for an SSH connection.
///
/// This is the reduced fork model described by the extraction spec: host,
/// port, username, auth, optional jump host, `TERM`, and the tmux selection.
/// Nothing about agent forwarding, port forwarding, cloud labels, or other
/// transports survives here.
struct SSHConfig: Codable, Hashable {
    /// Hostname or IP address to connect to
    var host: String

    /// TCP port (default: 22)
    var port: Int = 22

    /// Username to authenticate as
    var username: String

    /// How to authenticate to the target host
    var authMethod: AuthMethod = .password("")

    /// Optional jump host (ProxyJump / bastion)
    var jumpHost: JumpHostConfig? = nil

    /// Whether to auto-start tmux on connect
    var tmuxAutoEnable: Bool = false

    /// Which tmux flavor to start when `tmuxAutoEnable` is true
    var tmuxAutoMode: TmuxAutoMode = .regular

    /// Per-profile tmux session name override (nil = use the global default)
    var tmuxSessionName: String? = nil

    /// Per-profile `TERM` override (nil = use the global default)
    var terminalType: String? = nil

    /// Additional identities to try if the primary one fails
    var fallbackKeyIDs: [UUID]? = nil

    /// Resolution hints for cross-device key matching (keyed by UUID string)
    var keyResolutionHints: [String: KeyResolutionHint]? = nil

    /// Set during `resolvedConfig()` when the password came from the Keychain.
    var usedSavedPassword: Bool = false

    /// Set during `resolvedConfig()` when the jump password came from the Keychain.
    var usedSavedJumpPassword: Bool = false

    /// The three-state tmux selection for this connection.
    var tmuxMode: TmuxMode {
        get { TmuxMode(tmuxEnabled: tmuxAutoEnable, mode: tmuxAutoMode) }
        set {
            tmuxAutoEnable = newValue.tmuxEnabled
            tmuxAutoMode = newValue.autoMode
        }
    }

    /// Tool locations for non-interactive SSH exec requests, searched ahead of
    /// the system directories without depending on shell startup files.
    nonisolated static let remoteExecToolPathEntries = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "$HOME/go/bin",
        "/usr/local/go/bin"
    ]

    /// Linux-only tool locations, searched after the ones above. Never even
    /// stat'd on Darwin: /home is an autofs trigger there, so each lookup costs
    /// an automountd/opendirectoryd round trip.
    nonisolated static let remoteExecLinuxPathEntries = [
        "/home/linuxbrew/.linuxbrew/bin",
        "/snap/bin"
    ]

    nonisolated static let remoteExecSystemPathEntries = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    /// Shell snippet that prepends the entries above that exist on the target,
    /// in order, preserving its existing PATH. Existence is checked once here
    /// so nonexistent directories never reach a child's PATH search.
    nonisolated static let remoteExecPathPrefix: String = {
        func words(_ entries: [String]) -> String {
            entries.map { $0.contains("$") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        }
        let linux = remoteExecLinuxPathEntries.joined(separator: " ")
        let list = "\(words(remoteExecToolPathEntries)) $_rsl \(words(remoteExecSystemPathEntries))"
        // Absolute path: the incoming PATH is exactly what this snippet fixes.
        // Double quotes only: this prelude is embedded inside a single-quoted
        // `sh -c '...'` wrapper, so a single quote here would end that wrapper.
        return "_rsl=; [ \"$(/usr/bin/uname -s 2>/dev/null)\" = Linux ] && _rsl=\"\(linux)\"; "
            + "_p=; for _d in \(list); do [ -d \"$_d\" ] && _p=\"$_p:$_d\"; done; "
            + "PATH=\"${_p#:}${PATH:+:$PATH}\"; export PATH; unset _d _p _rsl; "
    }()

    // MARK: - Authentication

    /// Authentication method for SSH.
    ///
    /// Spec vocabulary: `SSHAuth`.
    enum AuthMethod: Codable, Hashable {
        case password(String)      // Password authentication (password provided inline)
        case savedPassword         // Password stored in Keychain (lookup by connection key)
        case key(UUID)             // SSH identity authentication (identity ID)
        case keyboardInteractive   // Keyboard-interactive (RFC 4256): server-driven prompts (OTP/2FA/PAM)
        /// An auth method written by a newer app version that this build does not
        /// recognise. Preserved verbatim so a synced profile is neither dropped nor
        /// lossily rewritten. Not connectable on this version.
        case unknown(rawType: String)

        private enum CodingKeys: String, CodingKey {
            case type
            case keyID
        }

        private enum MethodType: String, Codable {
            case password
            case savedPassword
            case key
            case keyboardInteractive
        }

        var isPassword: Bool {
            if case .password = self { return true }
            return false
        }

        var isSavedPassword: Bool {
            if case .savedPassword = self { return true }
            return false
        }

        var isKey: Bool {
            if case .key = self { return true }
            return false
        }

        var isKeyboardInteractive: Bool {
            if case .keyboardInteractive = self { return true }
            return false
        }

        /// True for an auth method written by a newer app version that this build
        /// cannot use. Such connections should not be attempted.
        var isUnknown: Bool {
            if case .unknown = self { return true }
            return false
        }

        /// Returns true if this auth method uses a password (either inline or saved)
        var usesPassword: Bool {
            switch self {
            case .password, .savedPassword:
                return true
            default:
                return false
            }
        }

        var keyID: UUID? {
            if case .key(let id) = self { return id }
            return nil
        }

        var password: String? {
            if case .password(let pwd) = self { return pwd }
            return nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Decode the discriminator as a raw string (not MethodType) so an
            // auth type written by a newer app version maps to `.unknown`
            // instead of throwing — which would otherwise drop the whole
            // synced profile on this (older) build.
            let typeString = try container.decode(String.self, forKey: .type)
            guard let method = MethodType(rawValue: typeString) else {
                self = .unknown(rawType: typeString)
                return
            }
            switch method {
            case .password:
                self = .password("")
            case .savedPassword:
                self = .savedPassword
            case .key:
                let keyID = try container.decode(UUID.self, forKey: .keyID)
                self = .key(keyID)
            case .keyboardInteractive:
                self = .keyboardInteractive
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .password:
                // Password values are never persisted to JSON.
                try container.encode(MethodType.password, forKey: .type)
            case .savedPassword:
                try container.encode(MethodType.savedPassword, forKey: .type)
            case .key(let keyID):
                try container.encode(MethodType.key, forKey: .type)
                try container.encode(keyID, forKey: .keyID)
            case .keyboardInteractive:
                try container.encode(MethodType.keyboardInteractive, forKey: .type)
            case .unknown(let rawType):
                // Re-emit the original discriminator verbatim so round-tripping
                // through this version does not corrupt the synced value.
                try container.encode(rawType, forKey: .type)
            }
        }
    }

    /// Configuration for an SSH jump host (bastion/proxy).
    ///
    /// Spec vocabulary: `SSHJumpHost`.
    struct JumpHostConfig: Codable, Hashable {
        /// The hostname or IP address of the jump host
        var host: String

        /// The port to connect to (default: 22)
        var port: Int = 22

        /// The username for authentication on the jump host
        var username: String

        /// The authentication method for the jump host
        var authMethod: AuthMethod

        /// Additional identities to try if the primary one fails
        var fallbackKeyIDs: [UUID]? = nil

        /// Resolution hints for cross-device key matching (keyed by UUID string)
        var keyResolutionHints: [String: KeyResolutionHint]? = nil

        private enum CodingKeys: String, CodingKey {
            case host, port, username, authMethod, fallbackKeyIDs, keyResolutionHints
        }

        init(host: String, port: Int = 22, username: String, authMethod: AuthMethod, fallbackKeyIDs: [UUID]? = nil, keyResolutionHints: [String: KeyResolutionHint]? = nil) {
            self.host = host
            self.port = port
            self.username = username
            self.authMethod = authMethod
            self.fallbackKeyIDs = fallbackKeyIDs
            self.keyResolutionHints = keyResolutionHints
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            host = try container.decode(String.self, forKey: .host)
            port = try container.decode(Int.self, forKey: .port)
            username = try container.decode(String.self, forKey: .username)
            authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
            fallbackKeyIDs = try container.decodeIfPresent([UUID].self, forKey: .fallbackKeyIDs)
            keyResolutionHints = try container.decodeIfPresent([String: KeyResolutionHint].self, forKey: .keyResolutionHints)
        }

        /// Display name for the jump host
        var displayName: String {
            port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
        }

        /// Validate the jump host configuration
        var isValid: Bool {
            let basicValid = !host.isEmpty && !username.isEmpty && port > 0 && port <= 65535

            switch authMethod {
            case .password(let pwd):
                return basicValid && !pwd.isEmpty
            case .savedPassword:
                return basicValid && SSHPasswordManager.shared.hasPassword(host: host, port: port, username: username)
            case .key(let keyID):
                let hint = keyResolutionHints?[keyID.uuidString]
                return basicValid && SSHKeyManager.shared.resolveKey(id: keyID, hint: hint) != nil
            case .keyboardInteractive:
                return basicValid  // Server drives the prompts; no stored credential required
            case .unknown:
                return false       // Auth method from a newer app version; not usable here
            }
        }
    }

    // MARK: - Derived values

    /// Whether this connection uses a jump host
    var usesJumpHost: Bool {
        jumpHost != nil
    }

    /// Whether this config uses a saved password (looks up from Keychain)
    var usesSavedPassword: Bool {
        authMethod.isSavedPassword
    }

    /// Connection key for password lookup (format: "host:port:username")
    var connectionKey: String {
        SSHSavedPassword.makeConnectionKey(host: host, port: port, username: username)
    }

    /// Stable identity for a connection that has no saved profile behind it —
    /// QuickConnect (`ssh me@host`), a deep link, or a history entry. This is
    /// the string `OverrideTarget.connectionIdentity` is keyed by, so both the
    /// writer (`KeyResolutionSheet`) and the reader (`ConnectionKeyResolver`)
    /// must derive it from here and nowhere else, or a saved "always use on
    /// this device" choice never matches on the next connect.
    ///
    /// Host is lowercased (DNS is case-insensitive, so `Host` and `host` are
    /// the same machine); the username is not (POSIX accounts are case
    /// sensitive). The port is always explicit so `:22` and the default form
    /// collapse to one key. No auth material appears here — this string is
    /// persisted to `device_key_overrides.json` in the clear.
    var connectionIdentity: String {
        "ssh:\(username)@\(host.lowercased()):\(port)"
    }

    /// Resolves the auth method by loading a saved password if needed.
    /// - Returns: A copy of this config with the password resolved from the Keychain.
    /// - Throws: If the saved password cannot be loaded. Never falls back to
    ///   another auth method — the spec forbids silently downgrading to password auth.
    @MainActor
    func resolvedConfig() async throws -> SSHConfig {
        var resolved = self

        if case .savedPassword = authMethod {
            let password = try await SSHPasswordManager.shared.loadPassword(
                host: host,
                port: port,
                username: username
            )
            resolved.authMethod = .password(password)
            resolved.usedSavedPassword = true
        }

        if var jumpConfig = resolved.jumpHost, case .savedPassword = jumpConfig.authMethod {
            let jumpPassword = try await SSHPasswordManager.shared.loadPassword(
                host: jumpConfig.host,
                port: jumpConfig.port,
                username: jumpConfig.username
            )
            jumpConfig.authMethod = .password(jumpPassword)
            resolved.jumpHost = jumpConfig
            resolved.usedSavedJumpPassword = true
        }

        return resolved
    }

    /// Display name for the connection (derived from host and username)
    var displayName: String {
        if let jump = jumpHost {
            return "\(username)@\(host) via \(jump.displayName)"
        }
        return "\(username)@\(host)"
    }

    /// Validate the configuration
    var isValid: Bool {
        let basicValid = !host.isEmpty && !username.isEmpty && port > 0 && port <= 65535

        let targetAuthValid: Bool
        switch authMethod {
        case .password(let pwd):
            targetAuthValid = basicValid && !pwd.isEmpty
        case .savedPassword:
            targetAuthValid = basicValid && SSHPasswordManager.shared.hasPassword(host: host, port: port, username: username)
        case .key(let keyID):
            let hint = keyResolutionHints?[keyID.uuidString]
            targetAuthValid = basicValid && SSHKeyManager.shared.resolveKey(id: keyID, hint: hint) != nil
        case .keyboardInteractive:
            targetAuthValid = basicValid  // Server drives the prompts; no stored credential required
        case .unknown:
            targetAuthValid = false       // Auth method from a newer app version; not usable here
        }

        if let jumpConfig = jumpHost {
            return targetAuthValid && jumpConfig.isValid
        }

        return targetAuthValid
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case host, port, username, authMethod, jumpHost
        case tmuxAutoEnable, tmuxAutoMode, tmuxSessionName
        case fallbackKeyIDs, keyResolutionHints, terminalType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        jumpHost = try container.decodeIfPresent(JumpHostConfig.self, forKey: .jumpHost)
        tmuxAutoEnable = try container.decode(Bool.self, forKey: .tmuxAutoEnable)
        tmuxAutoMode = try container.decode(TmuxAutoMode.self, forKey: .tmuxAutoMode)
        tmuxSessionName = try container.decodeIfPresent(String.self, forKey: .tmuxSessionName)
        fallbackKeyIDs = try container.decodeIfPresent([UUID].self, forKey: .fallbackKeyIDs)
        keyResolutionHints = try container.decodeIfPresent([String: KeyResolutionHint].self, forKey: .keyResolutionHints)
        terminalType = try container.decodeIfPresent(String.self, forKey: .terminalType)
    }

    /// Creates a new SSH configuration with password authentication
    init(host: String,
         port: Int = 22,
         username: String,
         password: String = "",
         jumpHost: JumpHostConfig? = nil,
         tmuxAutoEnable: Bool = false,
         tmuxAutoMode: TmuxAutoMode = .regular) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = .password(password)
        self.jumpHost = jumpHost
        self.tmuxAutoEnable = tmuxAutoEnable
        self.tmuxAutoMode = tmuxAutoMode
    }

    /// Creates a new SSH configuration with identity (key or certificate) authentication
    /// - Parameter fallbackKeyIDs: Additional identities to try if the primary one fails
    init(host: String,
         port: Int = 22,
         username: String,
         keyID: UUID,
         fallbackKeyIDs: [UUID]? = nil,
         jumpHost: JumpHostConfig? = nil,
         tmuxAutoEnable: Bool = false,
         tmuxAutoMode: TmuxAutoMode = .regular) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = .key(keyID)
        self.fallbackKeyIDs = fallbackKeyIDs
        self.jumpHost = jumpHost
        self.tmuxAutoEnable = tmuxAutoEnable
        self.tmuxAutoMode = tmuxAutoMode
    }

    /// Creates a new SSH configuration with an explicit auth method
    init(host: String,
         port: Int = 22,
         username: String,
         authMethod: AuthMethod,
         jumpHost: JumpHostConfig? = nil,
         tmuxAutoEnable: Bool = false,
         tmuxAutoMode: TmuxAutoMode = .regular) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.jumpHost = jumpHost
        self.tmuxAutoEnable = tmuxAutoEnable
        self.tmuxAutoMode = tmuxAutoMode
    }

    // MARK: - tmux launch

    /// Globally-configured default tmux session name ("main" when unset).
    static var tmuxGlobalSessionName: String {
        let name = SettingsStore.shared.value(Settings.Tmux.defaultSessionName)
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return "main"
    }

    /// Builds the `sh -c '...'` line that attaches to (or creates) a tmux
    /// session, optionally in control mode (`-CC`), falling back to `$SHELL`
    /// when tmux is missing. The session name must already be validated as
    /// embeddable in the single-quoted command (see TmuxGatewaySessionStore).
    static func tmuxExecCommandLine(sessionName: String, controlMode: Bool) -> String {
        let cc = controlMode ? "-CC " : ""
        return "sh -c '\(remoteExecPathPrefix)command -v tmux >/dev/null && exec tmux \(cc)new-session -A -s \(sessionName) || exec $SHELL'"
    }

    /// Shared tmux exec command used when no per-connection config applies.
    static var tmuxExecCommand: String {
        tmuxExecCommandLine(sessionName: tmuxGlobalSessionName, controlMode: false)
    }

    /// The profile's session-name override, trimmed, or nil when unset.
    var tmuxSessionNameOverride: String? {
        guard let name = tmuxSessionName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// Session name to attach to for this connection. The profile's explicit
    /// override wins, since declared intent outranks the inferred last-attached
    /// memory; then the session the user was last attached to ON THIS
    /// CONNECTION; then the global default.
    var tmuxSessionNameForConnection: String {
        if let override = tmuxSessionNameOverride,
           TmuxControlModeParser.isEmbeddableSessionName(override) {
            return override
        }
        let key = TmuxGatewaySessionStore.connectionKey(host: host, port: port, username: username)
        if let name = TmuxGatewaySessionStore.lastSessionName(forConnection: key),
           TmuxControlModeParser.isEmbeddableSessionName(name) {
            return name
        }
        return Self.tmuxGlobalSessionName
    }

    /// `TERM` to advertise for this connection: the profile's override when set,
    /// otherwise the global remote default from Settings.
    var effectiveTerminalType: String {
        TerminalTypeSettings.resolveRemote(terminalType)
    }

    /// Per-connection tmux launch line: uses the per-connection session name
    /// and the connection's `tmuxAutoMode` (regular vs `-CC` control mode).
    var tmuxExecCommandForConnection: String {
        Self.tmuxExecCommandLine(sessionName: tmuxSessionNameForConnection,
                                 controlMode: tmuxAutoMode == .control)
    }

    /// Remote command for a **recovery** reattachment to a verified session id.
    ///
    /// Deliberately not `tmuxExecCommandForConnection`: that one is
    /// `new-session -A`, which creates the session when it is missing. On a
    /// connect that is what the user asked for. On a recovery it would hand
    /// the user a brand-new empty session while the UI said "reattaching",
    /// which is precisely the silent target substitution CON-05 forbids.
    /// Returns `nil` when no verified session id is available, and the caller
    /// must then ask the user to choose rather than guessing.
    func tmuxRecoveryAttachCommand(sessionID: Int?, socketPath: String? = nil) -> String? {
        guard let sessionID else { return nil }
        return TmuxRecoveryIdentity.remoteAttachCommandLine(
            sessionID: sessionID,
            controlMode: tmuxAutoMode == .control,
            socketPath: socketPath,
            pathPrefix: Self.remoteExecPathPrefix)
    }

    /// Attach-only reconnect for **regular** tmux mode, which has no control
    /// channel and therefore no continuity evidence to attach by id with.
    ///
    /// Attaching by name cannot prove it is the same session, so this is never
    /// reported as a restored session. It does guarantee the other half:
    /// without `-A`, a missing session fails the attach instead of quietly
    /// creating a new one (§9.2).
    func tmuxRecoveryAttachByNameCommand() -> String? {
        TmuxRecoveryIdentity.remoteAttachByNameCommandLine(
            sessionName: tmuxSessionNameForConnection,
            pathPrefix: Self.remoteExecPathPrefix)
    }

    /// Opaque reference to the credential this profile authenticates with.
    ///
    /// Never the secret: a recovery descriptor stores this and the identity
    /// layer resolves it again at connection time, so nothing derived from a
    /// key or password is written to disk by the recovery machinery (§5).
    var recoveryCredentialReference: String? {
        switch authMethod {
        case .password: return "password:inline"
        case .savedPassword: return "password:saved"
        case .key(let id): return "identity:\(id.uuidString)"
        case .keyboardInteractive: return "keyboard-interactive"
        case .unknown(let rawType): return "unknown:\(rawType)"
        }
    }

    static func shellSingleQuote(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Whether the channel replaced the interactive shell with a command.
    var hasExecTakeoverCommand: Bool {
        tmuxAutoEnable
    }

    /// Replaces `effectiveExecCommand` for a recovery attempt.
    ///
    /// Set only by the recovery path, and only to an attach-by-id command
    /// built from verified continuity evidence. Nothing else may write it:
    /// the whole point is that a reconnect cannot fall back to
    /// `new-session -A` and call the result a restored session (CON-05).
    var recoveryExecCommandOverride: String?

    /// The exec command to run in place of the interactive shell, if any.
    var effectiveExecCommand: String? {
        if let recoveryExecCommandOverride { return recoveryExecCommandOverride }
        return tmuxAutoEnable ? tmuxExecCommandForConnection : nil
    }
}
