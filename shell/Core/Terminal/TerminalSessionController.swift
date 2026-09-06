import Foundation
import os

/// Owns a terminal's `TerminalSession` and its callback wiring, on behalf of a
/// `TerminalSessionHost` (the `TerminalView`).
///
/// This is the first step in peeling the session domain off the oversized
/// `Ghostty.TerminalView`. It mirrors the established `ReconnectionManager`
/// pattern: an owned `@MainActor` type that the view holds, talking back to the
/// view through a small delegate protocol rather than sharing the view's ~198
/// stored properties.
///
/// This controller owns `session`/`pty`, common callback wiring, startup for
/// normal connection configs, response-pipe monitoring, reconnection, and
/// teardown. The view still owns the Ghostty surface, terminal output plumbing,
/// and UI state, and exposes those pieces through `TerminalSessionControllerHost`.
@MainActor
final class TerminalSessionController {

    /// The view that owns this controller. Weak rather than `unowned`: although
    /// the view normally outlives the controller, an in-flight session
    /// callback's deferred `Task` can land after the view has been torn down
    /// (e.g. during an app-tab swipe), so every access guards against a released
    /// host instead of trapping on an `unowned` load.
    private weak var host: TerminalSessionControllerHost?
    private let responsePipeline: TerminalResponsePipeline
    private let reconnectionController: TerminalReconnectionController

    /// The active session. Settable so existing `TerminalView.session`
    /// forwarders and the transfer-receive path can still assign through the
    /// controller while the view is decomposed incrementally.
    var session: TerminalSession? {
        willSet { host?.terminalSessionWillChange() }
    }

    /// The PTY backing the active session (nil for sessionless tmux panes).
    var pty: TerminalPTY?

    init(host: TerminalSessionControllerHost) {
        self.host = host
        self.responsePipeline = TerminalResponsePipeline(host: host)
        self.reconnectionController = TerminalReconnectionController(host: host)
    }

    /// Adopts a freshly-created session: stores it and wires the callbacks that
    /// are identical across SSH and
    /// local sessions. Was `TerminalView.configureCommonSessionCallbacks(for:)`.
    ///
    /// Session-type-specific extras (`LocalShellSession` reset/agent/challenge
    /// hooks, per-type `onError`/`onStateChange`) are wired by this controller
    /// before the session is started.
    func adopt(_ session: TerminalSession, pty: TerminalPTY?) {
        self.session = session
        self.pty = pty

        // The view is gone; there is nothing to wire callbacks back to.
        guard let host else { return }

        // Identity of the session these callbacks belong to, so a late callback
        // from a session we've since replaced can be ignored.
        let configuredSessionID = ObjectIdentifier(session as AnyObject)

        // Output sink is built by the host: it captures the view-owned I/O
        // plumbing (coalescer / gate / buffered writer) and runs on the
        // session's background queue, so it must not hop to the main actor.
        let outputSink = host.makeSessionOutputSink()
        session.onOutputData = { outputSink($0) }
        session.onOutput = { outputSink(Data($0.utf8)) }

        // The MainActor-hopping callbacks capture the controller weakly (a
        // concrete @MainActor final class is reliably Sendable) and reach the
        // host through `self.host`, rather than capturing the host existential.
        session.onTitleChange = { [weak self] title in
            Task { @MainActor in self?.host?.sessionDidChangeTitle(title) }
        }

        session.onWorkingDirectoryChange = { [weak self] pwd in
            Task { @MainActor in self?.host?.sessionDidChangeWorkingDirectory(pwd) }
        }

        session.onBell = { [weak self] in
            Task { @MainActor in self?.host?.sessionDidRingBell() }
        }

        session.onSessionEnd = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Ignore an end callback from a session we've since replaced
                // (e.g. a reconnect adopted a new session before the old one's
                // teardown callback landed on the main actor).
                guard let current = self.session,
                      ObjectIdentifier(current as AnyObject) == configuredSessionID else {
                    Ghostty.logger.info("Ignoring session end from stale session")
                    return
                }
                self.host?.sessionDidEnd()
            }
        }

        // `onReady` is invoked on the main actor by the session, so no hop.
        session.onReady = { [weak self] in
            Ghostty.logger.info("Session ready")
            self?.host?.sessionDidBecomeReady()
        }

        configureLocalSessionCallbacksIfNeeded(session)
        setupReconnection(for: session)
    }

    var reconnectionState: ReconnectionManager.State? {
        reconnectionController.state
    }

    var reconnectionManager: ReconnectionManager? {
        reconnectionController.manager
    }

    func handleSessionConnectedForReconnection() {
        reconnectionController.handleConnected()
    }

    func manualReconnect() {
        reconnectionController.manualReconnect()
    }

    func cancelReconnection() {
        reconnectionController.cancelReconnection()
    }

    func pauseReconnectionUI() {
        reconnectionController.pauseUI()
    }

    func resumeReconnectionUI() {
        reconnectionController.resumeUI()
    }

    /// Starts the terminal session for the host's current connection config.
    /// Returns false only for configs that intentionally remain view-owned for
    /// now, such as Continuity transfer receive.
    @discardableResult
    func startSession() -> Bool {
        guard let host else { return true }
        guard host.terminalSurfaceAvailable, host.terminalSurfaceGridSize != nil else {
            Ghostty.logger.error("Cannot setup PTY: surface is nil")
            return true
        }


        guard prepareRestoredConnectionIfNeeded() else {
            return true
        }

        if case .ssh(let sshConfig) = host.terminalConnectionConfig,
           sshConfig.authMethod.isSavedPassword || sshConfig.jumpHost?.authMethod.isSavedPassword == true {
            resolveSavedPasswordAndRetry(for: sshConfig)
            return true
        }

        if startDirectSessionIfSupported(connectionConfig: host.terminalConnectionConfig) {
            return true
        }

        switch host.terminalConnectionConfig {
        case .ssh:
            assertionFailure("Direct session was not started by TerminalSessionController")
            return true
        case .local:
            startLocalShellSession(workingDirectory: host.terminalConnectionConfig.workingDirectory)
            return true
        case .shellLaunchedSSH(let sshConfig, let shellCwd):
            #if targetEnvironment(macCatalyst)
            Ghostty.logger.warning("Shell-launched SSH not supported on Catalyst, falling back to local shell")
            startCatalystLocalSession(workingDirectory: host.terminalConnectionConfig.workingDirectory)
            #else
            startShellLaunchedSession(shellWorkingDirectory: shellCwd) { localSession, _ in
                Ghostty.logger.info("Local shell started, launching embedded SSH to \(sshConfig.displayName)")
                await localSession.startEmbeddedSSHSession(config: sshConfig)
            }
            #endif
            return true
        }
    }

    func startRestoredSession() -> Result<Void, Error> {
        guard let host else { return .failure(RestoredSessionError.surfaceNotReady) }
        let configName = host.terminalConnectionConfig.displayName
        Ghostty.logger.info("Starting restored session for \(configName)")

        guard host.terminalSurfaceAvailable else {
            Ghostty.logger.error("Cannot start restored session: surface not ready")
            return .failure(RestoredSessionError.surfaceNotReady)
        }

        if host.terminalHasPendingScrollbackRestore {
            host.terminalOutputPipeline.enableScrollbackRestoreGate()
        }
        host.terminalRestorationState = .connectingFromRestore
        _ = startSession()
        return .success(())
    }

    private func prepareRestoredConnectionIfNeeded() -> Bool {
        guard let host else { return false }
        guard host.terminalRestorationState == .pendingReconnection else {
            return true
        }

        func checkSSHPasswordAndUpdate(_ sshConfig: inout SSHConfig) -> Bool {
            if case .password(let pwd) = sshConfig.authMethod, pwd.isEmpty {
                if SSHPasswordManager.shared.hasPassword(
                    host: sshConfig.host,
                    port: sshConfig.port,
                    username: sshConfig.username
                ) {
                    sshConfig.authMethod = .savedPassword
                } else {
                    Ghostty.logger.info("SSH requires password - showing overlay")
                    host.terminalRestorationState = .needsPassword(sshConfig)
                    return false
                }
            }

            if let jump = sshConfig.jumpHost,
               case .password(let pwd) = jump.authMethod,
               pwd.isEmpty {
                if SSHPasswordManager.shared.hasPassword(
                    host: jump.host,
                    port: jump.port,
                    username: jump.username
                ) {
                    var updatedJump = jump
                    updatedJump.authMethod = .savedPassword
                    sshConfig.jumpHost = updatedJump
                } else {
                    Ghostty.logger.info("SSH jump host requires password - showing overlay")
                    host.terminalRestorationState = .needsPassword(sshConfig)
                    return false
                }
            }
            return true
        }

        switch host.terminalConnectionConfig {
        case .ssh(var sshConfig):
            guard checkSSHPasswordAndUpdate(&sshConfig) else { return false }
            host.terminalConnectionConfig = .ssh(sshConfig)
        case .shellLaunchedSSH(var sshConfig, let shellCwd):
            guard checkSSHPasswordAndUpdate(&sshConfig) else { return false }
            host.terminalConnectionConfig = .shellLaunchedSSH(sshConfig: sshConfig, shellWorkingDirectory: shellCwd)
        case .local:
            break
        }

        Ghostty.logger.info("Auto-reconnecting restored terminal: \(host.terminalConnectionConfig.displayName)")
        host.terminalRestorationState = .connectingFromRestore
        host.terminalNotifyRestorationStateChanged()
        return true
    }

    private func resolveSavedPasswordAndRetry(for sshConfig: SSHConfig) {
        Ghostty.logger.info("Resolving saved password for \(sshConfig.displayName)")

        Task { @MainActor [weak self] in
            guard let self, let host = self.host else { return }
            do {
                let resolvedConfig = try await sshConfig.resolvedConfig()
                host.terminalConnectionConfig = .ssh(resolvedConfig)
                _ = self.startSession()
            } catch {
                self.handleSavedPasswordResolutionFailure(for: sshConfig)
            }
        }
    }

    private func handleSavedPasswordResolutionFailure(for sshConfig: SSHConfig) {
        guard let host else { return }
        var fallbackConfig = sshConfig

        if fallbackConfig.authMethod.isSavedPassword {
            fallbackConfig.authMethod = .password("")
        }

        if var jump = fallbackConfig.jumpHost, jump.authMethod.isSavedPassword {
            jump.authMethod = .password("")
            fallbackConfig.jumpHost = jump
        }

        if host.terminalRestorationState == .pendingReconnection || host.terminalRestorationState == .connectingFromRestore {
            host.terminalRestorationState = .needsPassword(fallbackConfig)
            host.terminalNotifyRestorationStateChanged()
        } else {
            host.terminalClearProgressAndSpinner()
            host.terminalRequestAuthentication(fallbackConfig)
        }
    }

    private func startLocalShellSession(workingDirectory: String?) {
        #if targetEnvironment(macCatalyst)
        startCatalystLocalSession(workingDirectory: workingDirectory)
        #else
        guard let host else { return }
        guard let surfaceSize = host.terminalSurfaceGridSize else {
            Ghostty.logger.error("Surface not ready, cannot start local shell")
            return
        }

        let pty = TerminalPTY()
        pty.windowSize = TerminalPTY.TerminalSize(rows: surfaceSize.rows, cols: surfaceSize.cols)
        self.pty = pty

        Ghostty.logger.info("Setting up local shell session with ios_system (external I/O), size: \(surfaceSize.cols)x\(surfaceSize.rows)")
        let localSession = makeLocalShellSession(
            pty: pty,
            workingDirectory: workingDirectory,
            suppressPromptOnRestore: host.terminalRestorationState == .connectingFromRestore
                ? ScrollbackPersistenceManager.shared.wasAtPrompt(for: host.terminalUUID)
                : false
        )
        adoptAndStart(localSession, pty: pty, connectionConfig: host.terminalConnectionConfig)
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private func startShellLaunchedSession(
        shellWorkingDirectory: String?,
        launchEmbeddedSession: @escaping @MainActor (LocalShellSession, Bool) async -> Void
    ) {
        guard let host else { return }
        guard let surfaceSize = host.terminalSurfaceGridSize else {
            Ghostty.logger.error("Surface not ready, cannot start shell-launched session")
            return
        }

        let pty = TerminalPTY()
        pty.windowSize = TerminalPTY.TerminalSize(rows: surfaceSize.rows, cols: surfaceSize.cols)
        self.pty = pty

        let localSession = makeLocalShellSession(
            pty: pty,
            workingDirectory: shellWorkingDirectory,
            suppressPromptOnRestore: host.terminalRestorationState == .connectingFromRestore
        )
        self.session = localSession
        host.terminalNotifySessionDidChange()
        adopt(localSession, pty: pty)

        Task { @MainActor [weak self, weak localSession] in
            try? await Task.sleep(nanoseconds: 100_000_000)

            guard let self, let localSession, let host = self.host else { return }
            guard host.terminalSurfaceAvailable else {
                Ghostty.logger.error("Surface not ready, cannot start session")
                return
            }

            do {
                try await localSession.start()
                try? await Task.sleep(nanoseconds: 100_000_000)

                let isRestoring = host.terminalRestorationState == .connectingFromRestore
                await launchEmbeddedSession(localSession, isRestoring)

                self.responsePipeline.start(for: localSession)
            } catch {
                Ghostty.logger.error("Failed to start shell-launched session: \(error)")
                host.terminalSetError(error)
            }
        }
    }

    private func makeLocalShellSession(
        pty: TerminalPTY,
        workingDirectory: String?,
        suppressPromptOnRestore: Bool
    ) -> LocalShellSession {
        let localSession = LocalShellSession(pty: pty)
        localSession.currentWorkingDirectory = workingDirectory
        if let host {
            localSession.terminalId = host.terminalUUID
            localSession.containingTabId = host.terminalContainingTabID
            localSession.windowId = host.terminalWindowID
            if host.terminalRestorationState == .connectingFromRestore {
                localSession.showWelcomeBanner = false
                localSession.suppressPromptOnRestore = suppressPromptOnRestore
            }
            // One-shot shared-file handoff (see FileOpenCoordinator): consumed
            // here so a restored/reconnected session never re-opens the editor.
            if let fileToOpen = host.terminalPendingFileToOpen {
                localSession.startupFileToEdit = fileToOpen
                host.terminalPendingFileToOpen = nil
            }
        }
        localSession.onEmbeddedConnectionConfigChanged = { [weak self, weak localSession] embeddedConfig in
            guard let self, let host = self.host else { return }
            if let embeddedConfig {
                host.terminalConnectionConfig = embeddedConfig
            } else {
                host.terminalConnectionConfig = .local(workingDirectory: localSession?.currentWorkingDirectory)
            }
            host.terminalNotifyConnectionConfigChanged()
        }
        localSession.onLocalTaskActiveChanged = { [weak self] isActive in
            self?.host?.terminalSetLocalTaskActive(isActive)
        }
        return localSession
    }
    #endif

    #if targetEnvironment(macCatalyst)
    private func startCatalystLocalSession(workingDirectory: String?) {
        guard let host else { return }
        guard let surfaceSize = host.terminalSurfaceGridSize else {
            Ghostty.logger.error("Surface not ready, cannot start Catalyst shell")
            return
        }

        let shell = LocalShellSettings.command
        Ghostty.logger.info("Creating Catalyst shell session: \(surfaceSize.cols)x\(surfaceSize.rows), cwd=\(workingDirectory ?? "nil"), shell=\(shell ?? "login")")

        CatalystLocalShellSession.create(
            rows: surfaceSize.rows,
            cols: surfaceSize.cols,
            workingDirectory: workingDirectory,
            shell: shell,
            enableShellIntegration: true,
            paneToken: host.terminalUUID.uuidString
        ) { [weak self] result in
            guard let self, let host = self.host else { return }

            switch result {
            case .success(let session):
                Ghostty.logger.info("Catalyst session created successfully")
                self.session = session
                self.pty = session.pty
                host.terminalNotifySessionDidChange()
                self.adopt(session, pty: session.pty)
                session.startMonitoring()
                self.responsePipeline.start(for: session)
                // Taken now so a later restore/reconnect never re-runs it.
                let startupCommand = host.terminalPendingStartupCommand
                host.terminalPendingStartupCommand = nil

                Task {
                    do {
                        try await session.start()
                        Ghostty.logger.info("Catalyst session started")
                        await MainActor.run {
                            self.host?.terminalUpdatePTYSize()
                        }
                        // sendInput serializes and retries partial/EAGAIN writes.
                        if let startupCommand, !startupCommand.isEmpty,
                           let data = (startupCommand + "\n").data(using: .utf8) {
                            session.sendInput(data)
                        }
                    } catch {
                        Ghostty.logger.error("Failed to start Catalyst session: \(error)")
                        Task { @MainActor in
                            self.host?.terminalSetError(error)
                        }
                    }
                }

            case .failure(let error):
                Ghostty.logger.error("Failed to create Catalyst session: \(error)")
                Task { @MainActor in
                    self.host?.terminalSetError(error)
                }
            }
        }
    }
    #endif

    @discardableResult
    func startDirectSessionIfSupported(connectionConfig: ConnectionConfig) -> Bool {
        guard let host else { return false }
        let newSession: TerminalSession
        let newPTY = TerminalPTY()
        pty = newPTY

        switch connectionConfig {
        case .ssh(let sshConfig):
            let sshSession = SSHSessionFactory.createSession(
                pty: newPTY, config: sshConfig, paneToken: host.terminalUUID.uuidString)

            sshSession.onError = { [weak self] error in
                Task { @MainActor in
                    guard let self, let host = self.host else { return }
                    let isAuthError = (error as? SSHError)?.isAuthenticationRelated == true ||
                        ((error as? SSHJumpError)?.isJumpHostError == false &&
                         error.localizedDescription.lowercased().contains("authentication"))

                    if isAuthError {
                        host.terminalClearProgressAndSpinner()
                        host.terminalRequestAuthentication(sshConfig)
                    } else {
                        host.terminalHandleSessionError(error, prefix: "SSH Error")
                    }
                }
            }

            if let sshTerminalSession = sshSession as? SSHTerminalSession {
                sshTerminalSession.onHostKeyValidation = { [weak self] request in
                    guard let self, let host = self.host else { return .reject }
                    return await host.terminalValidateHostKey(request)
                }

                sshTerminalSession.onStateChange = { [weak self, weak sshTerminalSession] state in
                    Task { @MainActor in
                        guard let self, let host = self.host else { return }
                        switch state {
                        case .running:
                            host.terminalProgressFinish(.clearAlways)
                            host.terminalRestoreScrollbackAfterAnimation()
                            if let sshTerminalSession {
                                for raw in sshTerminalSession.consumeAuthBanners() {
                                    let rendered = SSHBanner.renderAuthBanner(raw)
                                    if !rendered.isEmpty { host.terminalWriteToGhostty(rendered) }
                                }
                            }
                            if let sshTerminalSession,
                               let banner = SSHBanner.postConnectionWarning(for: sshTerminalSession) {
                                host.terminalWriteToGhostty(banner)
                            }
                        case .failed:
                            host.terminalProgressFinish(.cleanupOnly)
                        case .disconnected:
                            host.terminalProgressFinish(.clearAlways)
                        case .initial:
                            break
                        default:
                            host.terminalProgressUpdate(
                                message: state.statusDescription,
                                style: state.spinnerColorStyle
                            )
                        }
                    }
                }

                if let citadelSession = sshSession as? CitadelSSHSession {
                    citadelSession.onKeyboardInteractiveChallenge = { [weak self] challenge in
                        guard let self, let host = self.host else { return nil }
                        return await host.terminalHandleKeyboardInteractive(challenge)
                    }

                    citadelSession.onHealthUpdate = { [weak self] health in
                        Task { @MainActor in
                            self?.host?.terminalApplyConnectionHealth(health)
                        }
                    }
                }
            }

            newSession = sshSession

        default:
            pty = nil
            return false
        }

        adoptAndStart(newSession, pty: newPTY, connectionConfig: connectionConfig)
        return true
    }

    private func wireStandardError(on session: TerminalSession, prefix: String? = nil) {
        session.onError = { [weak self] error in
            Task { @MainActor in
                self?.host?.terminalHandleSessionError(error, prefix: prefix)
            }
        }
    }

    private func configureLocalSessionCallbacksIfNeeded(_ session: TerminalSession) {
        #if !targetEnvironment(macCatalyst)
        guard let localSession = session as? LocalShellSession else { return }
        localSession.onTerminalReset = { [weak self] in
            self?.host?.terminalPerformResetAction()
        }
        localSession.onKeyboardInteractiveChallenge = { [weak self] challenge in
            guard let self, let host = self.host else { return nil }
            return await host.terminalHandleKeyboardInteractive(challenge)
        }
        #endif
    }

    private func setupReconnection(for session: TerminalSession) {
        reconnectionController.setup(
            for: session,
            currentSession: { [weak self] in self?.session },
            reconnect: { [weak self] in
                guard let self else { return }
                try await self.performReconnection()
            }
        )
    }

    private func performReconnection() async throws {
        Ghostty.logger.info("Performing reconnection attempt")

        guard let host else { return }
        host.terminalResetUserTypingForReconnect()

        session?.stop()

        let newSession = try createReconnectSession()
        adopt(newSession, pty: pty)
        // Let the pane re-subscribe its session-scoped observers (the SSH
        // auth-banner card in particular) BEFORE start() begins authenticating
        // — a Tailscale check-mode re-auth banner arrives during this very
        // reconnect attempt, and the old subscription points at the replaced
        // session.
        host.terminalNotifySessionDidChange()
        try await newSession.start()

        // Cancellation is cooperative: "Cancel Recovery" (or pause on
        // backgrounding) during start() can't abort it. The manager will
        // discard this attempt's success — don't leave a live session
        // running behind a cancelled-looking UI. Tear it down instead.
        if Task.isCancelled {
            newSession.stop()
            throw CancellationError()
        }

        responsePipeline.start(for: newSession)

        Ghostty.logger.info("Reconnection successful")
    }

    private func createReconnectSession() throws -> TerminalSession {
        guard let pty else {
            throw ReconnectionError.noPTY
        }
        guard let host else {
            throw ReconnectionError.unsupportedSessionType
        }

        switch host.terminalConnectionConfig {
        case .ssh(let sshConfig):
            let sshSession = SSHSessionFactory.createSession(
                pty: pty, config: sshConfig, paneToken: host.terminalUUID.uuidString)
            if let sshTerminalSession = sshSession as? SSHTerminalSession {
                sshTerminalSession.onHostKeyValidation = { [weak self] request in
                    guard let self, let host = self.host else { return .reject }
                    return await host.terminalValidateHostKey(request)
                }

                sshTerminalSession.onStateChange = { [weak self] state in
                    Task { @MainActor in
                        self?.handleSSHStateChangeDuringReconnect(state)
                    }
                }

                if let citadelSession = sshSession as? CitadelSSHSession {
                    citadelSession.onKeyboardInteractiveChallenge = { [weak self] challenge in
                        guard let self, let host = self.host else { return nil }
                        return await host.terminalHandleKeyboardInteractive(challenge)
                    }

                    citadelSession.onHealthUpdate = { [weak self] health in
                        Task { @MainActor in
                            self?.host?.terminalApplyConnectionHealth(health)
                        }
                    }
                }
            }

            sshSession.onError = { [weak self] error in
                Task { @MainActor in
                    guard let self, let host = self.host else { return }
                    if let sshError = error as? SSHError, sshError.isAuthenticationRelated {
                        self.reconnectionController.handlePermanentFailure(reason: "Authentication failed")
                        host.terminalRequestAuthentication(sshConfig)
                    }
                }
            }
            return sshSession

        case .local, .shellLaunchedSSH:
            throw ReconnectionError.unsupportedSessionType
        }
    }

    private func handleSSHStateChangeDuringReconnect(_ state: SSHSessionState) {
        guard let host else { return }
        switch state {
        case .running:
            if let sshSession = session as? SSHTerminalSession {
                for raw in sshSession.consumeAuthBanners() {
                    let rendered = SSHBanner.renderAuthBanner(raw)
                    if !rendered.isEmpty { host.terminalWriteToGhostty(rendered) }
                }
            }
        case .failed, .disconnected, .initial:
            break
        default:
            let themeColors = SpinnerAnimator.ThemeColors.fromThemeManager()
            let rgb = themeColors.colorFor(style: .connecting)
            let color = "\u{1B}[38;2;\(rgb.0);\(rgb.1);\(rgb.2)m"
            let reset = "\u{1B}[0m"
            host.terminalWriteToGhostty(color + "  \(state.statusDescription)" + reset + "\r\n")
        }
    }

    private func adoptAndStart(
        _ session: TerminalSession,
        pty: TerminalPTY,
        connectionConfig: ConnectionConfig
    ) {
        self.session = session
        self.pty = pty
        host?.terminalNotifySessionDidChange()
        adopt(session, pty: pty)

        Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: 100_000_000)

            guard let self, let session, let host = self.host else { return }
            guard host.terminalSurfaceAvailable else {
                Ghostty.logger.error("Surface not ready, cannot start session")
                return
            }

            do {
                try await session.start()
                Ghostty.logger.info("Session started successfully")

                self.responsePipeline.start(for: session)
            } catch is CancellationError {
                Ghostty.logger.info("Session start cancelled (tab closing)")
            } catch {
                Ghostty.logger.error("Failed to start session: \(error)")
                host.terminalSetError(error)

                if let sshError = error as? SSHError, sshError.isAuthenticationRelated,
                   let config = connectionConfig.sshConfig {
                    host.terminalRequestAuthentication(config)
                } else {
                    host.terminalWriteToGhostty("\r\n❌ Connection failed: \(error.localizedDescription)\r\n")
                }
            }
        }
    }

    /// Stops the session and closes the PTY, applying the per-session-type
    /// teardown semantics. Was the session-stop switch in `TerminalView.cleanup`.
    ///
    /// For a local session with an active embedded SSH session the `reason`
    /// drives whether the embedded connection is torn down: `.sceneTeardown`
    /// keeps it resumable, everything else stops it outright.
    func teardown(reason: Ghostty.TerminalView.CleanupReason) {
        responsePipeline.cancel()

        #if !targetEnvironment(macCatalyst)
        if let localSession = session as? LocalShellSession,
           localSession.hasActiveEmbeddedSession,
           reason == .sceneTeardown {
            localSession.stopForReconnect()
        } else {
            session?.stop()
        }
        #else
        session?.stop()
        #endif
        session = nil

        pty?.close()
        pty = nil
    }

    func startTerminalResponseMonitoring(for session: TerminalSession) {
        responsePipeline.start(for: session)
    }

    func resetGatewayReportFilter() {
        responsePipeline.resetGatewayReportFilter()
    }

    func configureGatewayFastPath(
        fastWrite: (@Sendable (Data) -> Void)?,
        ownerKey: Int
    ) {
        responsePipeline.configureGatewayFastPath(fastWrite: fastWrite, ownerKey: ownerKey)
    }

    func clearGatewayFastPath() {
        responsePipeline.clearGatewayFastPath()
    }

    enum RestoredSessionError: LocalizedError {
        case surfaceNotReady

        var errorDescription: String? {
            switch self {
            case .surfaceNotReady:
                return "Terminal surface not ready"
            }
        }
    }

    enum ReconnectionError: LocalizedError {
        case noPTY
        case unsupportedSessionType

        var errorDescription: String? {
            switch self {
            case .noPTY:
                return "No PTY available for reconnection"
            case .unsupportedSessionType:
                return "This session type does not support reconnection"
            }
        }
    }
}
