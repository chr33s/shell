#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog
import Citadel

private struct EmbeddedSessionCoordinator {
    let session: TerminalSession
    let kind: EmbeddedSessionKind
    let titlePrefix: String?

    func attach(to owner: LocalShellSession) {
        owner.attachOutputCallbacks(to: session, kind: kind)
        owner.attachStandardCallbacks(
            to: session,
            titlePrefix: titlePrefix,
            kind: kind
        )
    }
}

enum EmbeddedSessionKind: Sendable {
    case ssh
}

extension LocalShellSession {
    // MARK: - Embedded Session Helpers

    private func startEmbeddedConnectionTask(
        _ operation: @escaping @MainActor (LocalShellSession) async -> Void
    ) {
        cancelEmbeddedConnectionStartTask()

        let taskID = UUID()
        embeddedConnectionStartTaskID = taskID
        embeddedConnectionStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(self)

            guard self.embeddedConnectionStartTaskID == taskID else { return }
            self.embeddedConnectionStartTask = nil
            self.embeddedConnectionStartTaskID = nil
        }
    }

    func cancelEmbeddedConnectionStartTask() {
        embeddedConnectionStartTaskID = nil
        embeddedConnectionStartTask?.cancel()
        embeddedConnectionStartTask = nil
    }

    func launchEmbeddedSSHSession(config: SSHConfig) {
        startEmbeddedConnectionTask { session in
            await session.startEmbeddedSSHSession(config: config)
        }
    }

    private func isCurrentEmbeddedSession(_ sessionID: ObjectIdentifier, kind: EmbeddedSessionKind) -> Bool {
        guard let session = embeddedSSHSession else { return false }
        return ObjectIdentifier(session) == sessionID
    }

    /// Build a partial SSH config for password prompts.
    /// - Parameter subject: which hop the prompt will collect a credential for.
    ///   `.jumpHost` carries the already-resolved target credential across the
    ///   round trip so the target is not re-asked for a secret it already has.
    private func makePartialSSHConfig(
        from config: SSHConfig,
        subject: SSHCommandParser.PasswordSubject = .target
    ) -> SSHCommandParser.PartialSSHConfig {
        var partial = SSHCommandParser.PartialSSHConfig(
            host: config.host,
            port: config.port,
            username: config.username,
            jumpHost: config.jumpHost,
            tmuxAutoEnable: config.tmuxAutoEnable,
            tmuxAutoMode: config.tmuxAutoMode,
            tmuxSessionName: config.tmuxSessionName
        )
        partial.passwordSubject = subject
        if subject == .jumpHost {
            partial.targetAuthMethod = config.authMethod
            partial.targetFallbackKeyIDs = config.fallbackKeyIDs
        }
        return partial
    }

    /// Begin a password prompt for the given session mode.
    func beginPasswordPrompt(_ mode: SessionMode) {
        sessionMode = mode
        passwordBuffer = ""
        onOutput?(normalizeLineEndings(Self.passwordPromptText(for: mode)))
    }

    /// Prompt line naming the hop being authenticated. Mirrors OpenSSH's
    /// "user@host's password:" and the reconnection overlay's jump-host wording
    /// (`ReconnectionOverlayView.passwordPrompt(for:)`), so the user can always
    /// see WHICH host is asking before typing a credential into it.
    private static func passwordPromptText(for mode: SessionMode) -> String {
        guard case .passwordPrompt(let partial) = mode else { return "Password: " }
        switch partial.passwordSubject {
        case .jumpHost:
            guard let jump = partial.jumpHost else { return "Password: " }
            let jumpName = jump.displayName
            return String(
                localized: "[jump host] \(jumpName)'s password: ",
                comment: "Inline terminal password prompt for an `ssh -J` bastion; names the jump host"
            )
        case .target:
            let userHost = partial.port == 22
                ? "\(partial.username)@\(partial.host)"
                : "\(partial.username)@\(partial.host):\(partial.port)"
            return String(
                localized: "\(userHost)'s password: ",
                comment: "Inline terminal password prompt for an embedded SSH connection; names the target host"
            )
        }
    }

    /// Resolve SSH config or fall back to a password prompt.
    private func resolveSSHConfigOrPrompt(
        _ config: SSHConfig,
        promptMode: (SSHCommandParser.PartialSSHConfig) -> SessionMode
    ) async -> SSHConfig? {
        do {
            return try await config.resolvedConfig()
        } catch {
            // `resolvedConfig()` loads the target's saved password first and the
            // jump host's second, so the failure belongs to the bastion only when
            // the target had no saved password to load. Asking for the other
            // hop's password would offer a credential the failing hop never
            // asked for — and would re-throw here forever.
            let subject: SSHCommandParser.PasswordSubject =
                (!config.authMethod.isSavedPassword && config.jumpHost?.authMethod.isSavedPassword == true)
                ? .jumpHost
                : .target
            let partialConfig = makePartialSSHConfig(from: config, subject: subject)
            beginPasswordPrompt(promptMode(partialConfig))
            return nil
        }
    }

    /// Start inline spinner animation with standard settings.
    func startInlineSpinner(
        message: String,
        style: SpinnerAnimator.ColorStyle = .connecting
    ) {
        inlineSpinnerAnimator = InlineSpinnerAnimator()
        let outputSink = outputSink
        inlineSpinnerAnimator?.start(
            message: message,
            style: style,
            terminalWidth: Int(pty.windowSize.cols)
        ) { [outputSink] output in
            outputSink.emitString(output)
        }
    }

    /// Stop inline spinner and emit cleanup sequence if needed.
    func cleanupInlineSpinner(emitIfEmpty: Bool = true) {
        guard let spinner = inlineSpinnerAnimator else { return }
        let cleanup = spinner.getCleanupSequence()
        spinner.stop()
        inlineSpinnerAnimator = nil
        if emitIfEmpty || !cleanup.isEmpty {
            onOutput?(cleanup)
        }
    }

    /// Attach shared output callbacks to a terminal session.
    func attachOutputCallbacks(to session: TerminalSession, kind: EmbeddedSessionKind) {
        let sessionID = ObjectIdentifier(session)
        let outputCallback = onOutput
        let outputDataCallback = onOutputData
        session.onOutput = { [weak self] output in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                outputCallback?(output)
            }
        }
        session.onOutputData = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                outputDataCallback?(data)
            }
        }
    }

    /// Attach standard title/bell/end/error callbacks to a terminal session.
    func attachStandardCallbacks(
        to session: TerminalSession,
        titlePrefix: String?,
        kind: EmbeddedSessionKind
    ) {
        let sessionID = ObjectIdentifier(session)
        session.onTitleChange = { [weak self] title in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                if let prefix = titlePrefix {
                    self.onTitleChange?("\(prefix)\(title)")
                } else {
                    self.onTitleChange?(title)
                }
            }
        }

        session.onBell = { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                self.onBell?()
            }
        }

        session.onSessionEnd = {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                self.handleSSHSessionEnd()
            }
        }

        session.onError = { error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                self.handleSSHSessionError(error)
            }
        }
    }

    /// Save pending password if provided and not already stored.
    private func finalizePendingPasswordSaveIfNeeded() {
        if let pending = pendingPasswordToSave,
           !SSHPasswordManager.shared.hasPassword(host: pending.host, port: pending.port, username: pending.username) {
            do {
                try SSHPasswordManager.shared.savePassword(pending.password, host: pending.host, port: pending.port, username: pending.username)
                Self.logger.info("Password saved for \(pending.username)@\(pending.host)")
            } catch {
                Self.logger.warning("Failed to save password: \(error.localizedDescription)")
            }
        }
        pendingPasswordToSave = nil
    }

    /// Shared cleanup for embedded session end.
    private func handleEmbeddedSessionEnd(stopSession: () -> Void) {
        stopSession()
        sessionMode = .localShell
        lastCommandSucceeded = true
        scriptCommandExitCode = 0
        pendingPasswordToSave = nil

        // Notify that we've returned to local shell
        onEmbeddedConnectionConfigChanged?(nil)

        cleanupInlineSpinner()
        displayPrompt()
    }

    /// Cancel an in-progress embedded session connection (Ctrl-C during connect/auth).
    func cancelEmbeddedSessionConnection() {
        cancelEmbeddedConnectionStartTask()

        // Stop and release the session
        if let session = embeddedSSHSession {
            session.stop()
            embeddedSSHSession = nil
            activeEmbeddedSSHConfig = nil
            lastAttemptedSSHConfig = nil
        }

        sessionMode = .localShell
        lastCommandSucceeded = false
        scriptCommandExitCode = 130 // Standard SIGINT exit code
        pendingPasswordToSave = nil

        // Notify that we've returned to local shell
        onEmbeddedConnectionConfigChanged?(nil)

        // Clean up spinner and show cancellation
        cleanupInlineSpinner()
        onOutput?(normalizeLineEndings("\r\n^C\r\n"))
        displayPrompt()
    }

    /// Runs `teardown` — which nils the embedded session, clearing the card via
    /// its didSet — while preserving the auth banner that explains the failure.
    /// Tailscale-style rejection reasons arrive as banners immediately before
    /// the failure, so the card is the only surface holding the explanation.
    /// Restored on a countdown so it does not strand the local shell prompt.
    private func preservingAuthBannerCard(
        from provider: SSHAuthBannerCardProviding?,
        teardown: () -> Void
    ) {
        let banner = provider?.authBannerCardState ?? authBannerCardModel.current
        teardown()
        guard let banner else { return }
        authBannerCardModel.relay(banner)
        authBannerCardModel.scheduleAutoDismiss()
    }

    /// Attempt to fall back to a password prompt after auth failure.
    private func attemptPasswordFallback<Config>(
        error: Error,
        lastAttempted: inout Config?,
        isPasswordAuth: (Config) -> Bool,
        promptMode: (Config) -> SessionMode
    ) -> Bool {
        guard let config = lastAttempted,
              isAuthenticationError(error),
              !isPasswordAuth(config) else {
            return false
        }

        cleanupInlineSpinner()
        lastAttempted = nil
        pendingPasswordToSave = nil
        beginPasswordPrompt(promptMode(config))
        return true
    }

    // MARK: - Embedded SSH Support

    /// Handle an SSH command by parsing and starting an internal SSH session
    func handleSSHCommand(_ command: String) {
        let result = SSHCommandParser.parse(command: command)

        switch result {
        case .success(let config):
            // Have a complete config, start SSH session
            launchEmbeddedSSHSession(config: config)

        case .needsPassword(let partialConfig):
            // The saved-password shortcut is keyed by the TARGET triple, so it
            // only applies when the target is what we are being asked for. When
            // the prompt is for the bastion the parser already proved no password
            // is saved for it (ladder rung 2); a target password must never stand
            // in for the bastion's.
            if partialConfig.passwordSubject == .target,
               SSHPasswordManager.shared.hasPassword(host: partialConfig.host, port: partialConfig.port, username: partialConfig.username) {
                // Use saved password - create config with .savedPassword auth method
                var config = partialConfig.toSSHConfig(password: "")
                config.authMethod = .savedPassword
                launchEmbeddedSSHSession(config: config)
            } else {
                // No saved password, prompt for one
                beginPasswordPrompt(.passwordPrompt(partialConfig))
            }

        case .help:
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displaySSHHelp()

        case .error(let message):
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            onOutput?(normalizeLineEndings("ssh: \(message)\r\n"))
            displayPrompt()
        }
    }

    /// Start an embedded SSH session with the given configuration
    func startEmbeddedSSHSession(config: SSHConfig) async {
        // Guard against duplicate connection attempts
        guard embeddedSSHSession == nil else {
            Self.logger.warning("Ignoring duplicate SSH session start - session already in progress")
            return
        }

        // Resolve saved password if needed
        guard let resolvedConfig = await resolveSSHConfigOrPrompt(config, promptMode: { partialConfig in
            .passwordPrompt(partialConfig)
        }) else {
            return
        }

        // Start inline spinner animation with actual terminal width
        startInlineSpinner(message: "Connecting to \(resolvedConfig.displayName)...")

        // Create a PTY for the SSH session (uses same window size as our PTY)
        let sshPTY = TerminalPTY()
        sshPTY.windowSize = pty.windowSize

        // Use factory to create appropriate session type (SSHSession or CitadelSSHSession)
        let sshSession = SSHSessionFactory.createSession(pty: sshPTY, config: resolvedConfig)
        let sshSessionID = ObjectIdentifier(sshSession)

        // Configure callbacks - capture at setup time for thread-safe access
        let coordinator = EmbeddedSessionCoordinator(session: sshSession, kind: .ssh, titlePrefix: "ssh: ")
        coordinator.attach(to: self)

        // Handle SSH-specific callbacks if this is an SSH session
        if let sshTerminalSession = sshSession as? SSHTerminalSession {
            sshTerminalSession.onHostKeyValidation = { [weak self] request in
                guard let self = self else { return .reject }
                guard self.isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else { return .reject }
                return await self.handleHostKeyValidation(request)
            }

            sshTerminalSession.onStateChange = { [weak self, weak sshTerminalSession] state in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard self.isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else { return }
                    // Update spinner with connection progress
                    switch state {
                    case .connecting(let host, let isJumpHost):
                        let message = isJumpHost ? "Connecting to jump host \(host)..." : "Connecting to \(host)..."
                        self.inlineSpinnerAnimator?.updateMessage(message, style: .connecting)
                    case .authenticating(let host, let isJumpHost):
                        let message = isJumpHost ? "Authenticating with jump host \(host)..." : "Authenticating with \(host)..."
                        self.inlineSpinnerAnimator?.updateMessage(message, style: .authenticating)
                    case .connectingToTarget(let host):
                        self.inlineSpinnerAnimator?.updateMessage("Connecting to \(host) via jump host...", style: .connecting)
                    case .authenticatingTarget(let host):
                        self.inlineSpinnerAnimator?.updateMessage("Authenticating with \(host)...", style: .authenticating)
                    case .running:
                        self.cleanupInlineSpinner()
                        // Emit server auth banners captured during authentication, then
                        // post-connection warnings (e.g. non-PQ KEX) — both AFTER spinner
                        // cleanup, otherwise clearToEndOfScreen wipes them.
                        if let sshTerminalSession {
                            for raw in sshTerminalSession.consumeAuthBanners() {
                                let rendered = SSHBanner.renderAuthBanner(raw)
                                if !rendered.isEmpty { self.onOutput?(rendered) }
                            }
                        }
                        if let sshTerminalSession,
                           let banner = SSHBanner.postConnectionWarning(for: sshTerminalSession) {
                            self.onOutput?(banner)
                        }
                    case .waitingToReconnect(let attempt, let delay):
                        self.inlineSpinnerAnimator?.updateMessage("Reconnecting in \(delay)s (attempt \(attempt))...", style: .reconnecting)
                    case .reconnecting(let attempt):
                        self.inlineSpinnerAnimator?.updateMessage("Reconnecting (attempt \(attempt))...", style: .reconnecting)
                    case .reconnectionFailed(let reason):
                        self.inlineSpinnerAnimator?.updateMessage("Reconnection failed: \(reason)", style: .error)
                    case .disconnected, .failed, .initial:
                        break
                    }
                }
            }
        }

        if let citadelSession = sshSession as? CitadelSSHSession {
            // Keyboard-interactive prompts render inline in the terminal (MFA/OTP/PAM).
            citadelSession.onKeyboardInteractiveChallenge = { [weak self] challenge in
                guard let self else { return nil }
                guard self.isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else { return nil }
                return await self.handleKeyboardInteractiveChallenge(challenge)
            }
        }

        // Store session and switch mode
        embeddedSSHSession = sshSession
        sessionMode = .sshSession

        // Store config for potential auth failure retry with password
        lastAttemptedSSHConfig = resolvedConfig

        // Start the SSH session
        do {
            try await sshSession.start()

            guard isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else {
                sshSession.stop()
                return
            }

            // Clear retry config on success (but keep active config for session recovery)
            lastAttemptedSSHConfig = nil

            // Store active config for session recovery (allows serialization of shell-launched sessions)
            activeEmbeddedSSHConfig = resolvedConfig

            // Notify that we've transitioned to an embedded SSH session
            onEmbeddedConnectionConfigChanged?(activeEmbeddedConnectionConfig)

            // Auto-save password if user entered it manually and it's not already saved
            finalizePendingPasswordSaveIfNeeded()

            Self.logger.info("Embedded SSH session started successfully")
        } catch is CancellationError {
            Self.logger.info("Embedded SSH connection cancelled")
        } catch {
            guard isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else {
                Self.logger.debug("Ignoring stale SSH session error after cancellation")
                return
            }
            handleSSHSessionError(error)
        }
    }

    /// Handle SSH session end (normal disconnect)
    private func handleSSHSessionEnd() {
        handleEmbeddedSessionEnd {
            embeddedSSHSession?.stop()
            embeddedSSHSession = nil
            activeEmbeddedSSHConfig = nil
        }
    }

    /// Handle SSH session error
    private func handleSSHSessionError(_ error: Error) {
        // Also guard if we're already in password prompt mode (fallback already happened)
        if case .passwordPrompt = sessionMode { return }

        preservingAuthBannerCard(from: embeddedSSHSession as? SSHAuthBannerCardProviding) {
            embeddedSSHSession?.stop()
            embeddedSSHSession = nil
            activeEmbeddedSSHConfig = nil
        }

        // Check if this is an auth failure we can retry with password
        // Only offer password fallback if:
        // 1. We have the original config
        // 2. The error is authentication-related
        // 3. The original auth was NOT already a password (avoid infinite loop)
        // Attribute the failure to the hop that actually rejected us. With the
        // bastion ladder holding no key fallbacks, a rejected bastion key has no
        // second chance — prompting for the TARGET's password here would ask for
        // the wrong host's secret while re-offering the same failing bastion key.
        let subject: SSHCommandParser.PasswordSubject =
            (error as? SSHJumpError)?.isJumpHostError == true ? .jumpHost : .target
        if attemptPasswordFallback(
            error: error,
            lastAttempted: &lastAttemptedSSHConfig,
            isPasswordAuth: { (config: SSHConfig) -> Bool in
                subject == .jumpHost
                    ? (config.jumpHost?.authMethod.isPassword ?? true)  // no jump hop ⇒ nothing to retry
                    : config.authMethod.isPassword
            },
            promptMode: { (config: SSHConfig) -> SessionMode in
                .passwordPrompt(makePartialSSHConfig(from: config, subject: subject))
            }
        ) {
            return
        }

        // Not an auth error or already tried password - show error normally
        sessionMode = .localShell
        lastCommandSucceeded = false
        scriptCommandExitCode = 1
        pendingPasswordToSave = nil
        lastAttemptedSSHConfig = nil

        // Notify that we've returned to local shell (in case session was previously running)
        onEmbeddedConnectionConfigChanged?(nil)

        // Clean up spinner first
        cleanupInlineSpinner()

        // Show error message and prompt
        let errorMessage = "\r\n\r\nssh: \(error.localizedDescription)\r\n"
        onOutput?(normalizeLineEndings(errorMessage))
        displayPrompt()
    }

    /// Check if an error is authentication-related
    private func isAuthenticationError(_ error: Error) -> Bool {
        // Check for SSHError.authenticationFailed
        if let sshError = error as? SSHError {
            if case .authenticationFailed = sshError {
                return true
            }
        }

        // Check for SSHJumpError.authenticationFailed
        if let jumpError = error as? SSHJumpError {
            if case .authenticationFailed = jumpError {
                return true
            }
        }

        // Check for Citadel SSHClientError authentication failures
        if let sshClientError = error as? SSHClientError {
            switch sshClientError {
            case .allAuthenticationOptionsFailed,
                    .unsupportedPasswordAuthentication,
                    .unsupportedPrivateKeyAuthentication:
                return true
            default:
                break
            }
        }

        // Check error description for common auth failure patterns
        let description = error.localizedDescription.lowercased()
        if description.contains("authentication failed") ||
            description.contains("permission denied") ||
            description.contains("publickey") {
            return true
        }

        return false
    }

}

#endif
