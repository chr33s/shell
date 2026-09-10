//
//  TerminalReconnectionController.swift
//  shell
//
//  Binds one terminal to its `ReconnectionManager` and publishes recovery
//  status to the native strip (spec.connectivity.md §12).
//
//  This file used to write recovery UI into Ghostty: a spinner animated at
//  0.08s, a 0.1s countdown timer rewriting a status line, a centred error
//  message, and a "✓ Reconnected!" line — all as escape sequences injected
//  into the terminal's byte stream. That is unrecoverable corruption for any
//  full-screen application on the alternate screen, and it is the reason the
//  spec requires recovery status to live outside the stream entirely.
//
//  Nothing here writes to the surface any more. The controller maps manager
//  state onto a `RecoveryStatusPresentation` and hands it to the host; the
//  strip renders it above the surface. The terminal's bytes after a recovery
//  are exactly the bytes the remote sent (AC-18).
//

import Foundation
import os

@MainActor
final class TerminalReconnectionController {
    private weak var host: TerminalSessionControllerHost?

    private(set) var manager: ReconnectionManager?

    /// True between `pauseUI()` and `resumeUI()` (i.e. while backgrounded).
    /// No animated polling continues while suspended (§12), so the strip is
    /// cleared and the manager's own status ticker is stopped by `pause()`.
    private var isUIPaused = false

    init(host: TerminalSessionControllerHost) {
        self.host = host
    }

    var state: ReconnectionManager.State? {
        manager?.state
    }

    /// Honest recovery state, for callers that want the typed vocabulary.
    var recoveryState: RecoveryState? {
        manager?.recoveryState
    }

    func setup(
        for session: TerminalSession,
        currentSession: @escaping @MainActor () -> TerminalSession?,
        reconnect: @escaping @MainActor () async throws -> Void
    ) {
        guard session.supportsAutoReconnect else {
            Ghostty.logger.debug("Session type does not support auto-reconnect")
            return
        }

        let config = ReconnectionManager.Config.fromUserDefaults()

        let manager: ReconnectionManager
        if let existingManager = self.manager {
            existingManager.config = config
            manager = existingManager
        } else {
            // The logical session id is the terminal's own UUID, not a fresh
            // one. It has to be stable across every reconnect and app launch:
            // a per-manager UUID would key a new descriptor on each setup and
            // leave the store growing a record per attempt.
            var policy = RecoveryPolicy.default
            policy.burstAttempts = max(1, config.maxAttempts)
            let context = RecoveryContext(
                logicalSessionID: host?.terminalUUID ?? UUID(),
                intent: .interactiveShell,
                targetIdentity: RecoveryTargetIdentity(host: "", port: 22, username: ""),
                policy: policy)
            manager = ReconnectionManager(config: config, context: context)
            self.manager = manager
        }

        // The master gate turns automatic *replacement* off. It must not
        // close a healthy connection, and the manager must still exist so the
        // user can retry by hand and see honest status (§14).
        manager.coordinator.isAutomaticRecoveryEnabled = config.enabled

        adoptTargetIdentity(for: manager)

        let configuredSessionID = ObjectIdentifier(session as AnyObject)

        manager.onReconnectAttempt = { [weak self] in
            self?.host?.terminalSessionWillChange()
            try await reconnect()
        }

        manager.onStateChange = { [weak self] state in
            self?.handleStateChange(state)
        }

        manager.onGiveUp = { [weak self] in
            self?.handleGiveUp()
        }

        manager.onReconnected = { [weak self] in
            self?.handleSuccess()
        }

        manager.onRecoveryStatusChange = { [weak self] presentation in
            self?.publish(presentation)
        }

        manager.validateTransport = { [weak session] reason in
            (session as? CitadelSSHSession)?.validateTransport(reason: reason)
        }

        session.onDisconnect = { [weak self] reason in
            guard let self else { return }
            guard let current = currentSession(),
                  ObjectIdentifier(current as AnyObject) == configuredSessionID else {
                Ghostty.logger.info("Ignoring disconnect from stale session: \(reason.description)")
                return
            }
            Ghostty.logger.info("Session disconnected: \(reason.description)")
            self.host?.terminalSessionWillChange()
            self.manager?.handleDisconnect(reason: reason)
        }

        Ghostty.logger.info("Reconnection manager configured for session")
    }

    /// Give the coordinator the trust scope and intent it must reconnect with.
    ///
    /// The intent is what decides whether a successful reconnect may be
    /// called a restored session: only a tmux profile promises continuity, so
    /// a plain SSH profile can never report `sessionRestored` (CON-09).
    private func adoptTargetIdentity(for manager: ReconnectionManager) {
        guard let host else { return }
        switch host.terminalConnectionConfig {
        case .ssh(let sshConfig):
            let identity = RecoveryTargetIdentity(
                host: sshConfig.host,
                port: sshConfig.port,
                username: sshConfig.username,
                credentialReference: sshConfig.recoveryCredentialReference,
                jumpHostDescriptor: sshConfig.jumpHost.map {
                    "\($0.username)@\($0.host):\($0.port)"
                },
                tmuxSocket: nil)
            let intent: RecoveryIntent = sshConfig.tmuxAutoEnable ? .attachExistingTmux : .interactiveShell
            manager.displaySessionName = sshConfig.tmuxAutoEnable
                ? sshConfig.tmuxSessionNameForConnection
                : nil
            let verifiesContinuity = sshConfig.tmuxAutoEnable && sshConfig.tmuxAutoMode == .control
            manager.adoptTarget(identity, intent: intent,
                                verifiesTmuxContinuity: verifiesContinuity)

            // Control mode can prove it reattached to the same session, so it
            // must before the recovery is called restored. The gateway calls
            // back through the registry once it has asked the server.
            if verifiesContinuity {
                TmuxContinuityRegistry.shared.setVerificationHandler(
                    forConnection: identity.connectionKey
                ) { [weak manager] verdict in
                    guard let manager else { return }
                    manager.coordinator.noteTmuxAttachmentVerified(
                        verdict, generation: manager.coordinator.context.connectionGeneration)
                }
            }

            // Checkpoint the intent now, not only on the background callback:
            // the process can be terminated without one (§13). What is stored
            // is intent and evidence — never a transport, a task, or a secret.
            let evidence = TmuxContinuityRegistry.shared.evidence(
                forConnection: identity.connectionKey)
            manager.coordinator.updateTmuxIdentity(evidence)
            let descriptor = RecoveryDescriptor(
                logicalSessionID: manager.coordinator.context.logicalSessionID,
                intent: intent,
                target: identity,
                tmuxEvidence: evidence,
                tabID: host.terminalContainingTabID)
            RecoveryDescriptorStore.shared.saveIfChanged(descriptor)

        case .local, .shellLaunchedSSH:
            break
        }
    }

    func handleConnected() {
        manager?.handleConnected()
    }

    /// A keepalive round trip passed its deadline.
    ///
    /// This marks the round trip unverified and gates input. It does NOT
    /// declare the remote process dead, and for a plain-shell intent it does
    /// not tear the transport down to build another one — the user's apparent
    /// session survives and the explicit "Open new shell" action is offered
    /// instead (§8.3).
    func noteProbeDeadlineExpired() {
        manager?.coordinator.noteProbeDeadlineExpired()
    }

    /// A keepalive round trip completed. Clears the suspect state.
    func noteConfirmedRoundTrip(milliseconds: Double) {
        manager?.coordinator.noteConfirmedRoundTrip(milliseconds: milliseconds)
    }

    /// Authenticated inbound traffic arrived from the destination.
    ///
    /// This is the other way out of `suspect`, and the only one available when
    /// a keepalive is parked on a socket that never answers: the server is
    /// demonstrably still sending, even though the round trip is unverified
    /// (§8.1, §8.3).
    func noteTargetActivity() {
        guard let manager else { return }
        manager.coordinator.noteTargetActivity()
        manager.coordinator.noteSuspectResolvedByInboundActivity()
    }

    /// Input was refused. Say so.
    ///
    /// Silently dropping keystrokes is worse than the drop itself: the user
    /// keeps typing into a terminal that looks alive and finds out later that
    /// none of it arrived. The strip carries the reason and the way out (§10).
    func noteInputRejected(_ decision: RecoveryInputDecision) {
        guard let manager, let host else { return }
        // A live connection that merely hit its byte budget is not a recovery
        // state; show a standalone notice rather than pretending otherwise.
        guard case .rejectBudgetExhausted = decision else {
            manager.republishRecoveryStatus()
            return
        }
        host.terminalRecoveryStatus = RecoveryStatusPresentation(
            title: String(
                localized: "Input paused",
                comment: "Recovery status: pending-input budget is full"),
            detail: String(
                localized: "The connection has not accepted the pending input yet.",
                comment: "Recovery detail: producer backpressure"),
            actions: [.dismiss],
            severity: .warning,
            showsActivity: false,
            announces: true,
            isStale: false)
        host.terminalNotifyRecoveryStatusChanged()
    }

    func handlePermanentFailure(reason: String) {
        manager?.handlePermanentFailure(reason: reason)
    }

    func manualReconnect() {
        manager?.manualReconnect()
    }

    func cancelReconnection() {
        manager?.cancelReconnection()
        discardDescriptor()
    }

    /// Drop this logical session's stored intent. Called when the user stops
    /// recovery or the tab closes: a descriptor that outlives the intent it
    /// describes would offer to reconnect something nobody asked for.
    func discardDescriptor() {
        guard let manager else { return }
        RecoveryDescriptorStore.shared.remove(
            logicalSessionID: manager.coordinator.context.logicalSessionID)
    }

    /// Route a strip action. Every one of these is an explicit user action —
    /// nothing here happens automatically.
    func performRecoveryAction(_ action: RecoveryStatusAction) {
        guard let manager else { return }
        switch action {
        case .retryNow:
            manager.manualReconnect()
        case .stopRecovery:
            manager.cancelReconnection()
        case .dismiss:
            publish(nil)
        case .authenticate, .selectSession, .openNewShell, .reviewDraft:
            // These need view-layer flows (auth sheet, session picker, new
            // tab, compose overlay). The host owns them.
            host?.terminalRequestRecoveryAction(action)
        }
    }

    func pauseUI() {
        isUIPaused = true
        manager?.pause()
        publish(nil)
    }

    func resumeUI() {
        // Clear the flag before resuming: `resume()` re-evaluates and
        // republishes synchronously, and that first repaint must not be
        // swallowed.
        isUIPaused = false
        manager?.resume()
        // `resume()` only republishes when it actually changes state, and it
        // returns early unless the coordinator was `.suspended`. States that
        // are waiting on a person — a changed host key, a missing session, a
        // stopped recovery — never suspend, so relying on that repaint left
        // the user back from the background staring at a dead terminal with
        // the Authenticate / Choose Session / Retry buttons gone.
        manager?.republishRecoveryStatus()
    }

    private func publish(_ presentation: RecoveryStatusPresentation?) {
        guard let host else { return }
        guard !isUIPaused else {
            host.terminalRecoveryStatus = nil
            host.terminalNotifyRecoveryStatusChanged()
            return
        }
        host.terminalRecoveryStatus = presentation
        host.terminalNotifyRecoveryStatusChanged()
    }

    private func handleStateChange(_ state: ReconnectionManager.State) {
        guard let host else { return }

        // The restoration overlay and the live recovery strip are different
        // surfaces. Clear the restoration overlay once recovery is actually
        // moving again so the two don't stack.
        if host.terminalIsLiveDisconnectionOverlay {
            switch state {
            case .disconnected, .waitingToReconnect, .reconnecting, .connected, .idle:
                host.terminalIsLiveDisconnectionOverlay = false
                host.terminalRestorationState = .none
                host.terminalNotifyRestorationStateChanged()
            case .manualReconnectRequired, .failed:
                break
            }
        }

        if case .idle = state {
            // No intent left to describe — a clean exit, an explicit stop, or
            // a reset. A descriptor that outlives its intent would offer to
            // reconnect something nobody asked for on the next launch.
            discardDescriptor()
        }

        if case .failed(let reason) = state {
            host.terminalIsLiveDisconnectionOverlay = true
            host.terminalRestorationState = .failed(reason)
            host.terminalNotifyRestorationStateChanged()
        }
    }

    private func handleSuccess() {
        guard let host else { return }
        if host.terminalIsLiveDisconnectionOverlay {
            host.terminalIsLiveDisconnectionOverlay = false
            host.terminalRestorationState = .none
            host.terminalNotifyRestorationStateChanged()
        }
        // Success is reported by the strip disappearing, not by a line
        // written into the user's terminal.
        publish(nil)
    }

    private func handleGiveUp() {
        guard let host else { return }
        host.terminalIsLiveDisconnectionOverlay = true
        host.terminalRestorationState = .failed(
            String(localized: "Automatic reconnection stopped.",
                   comment: "Restoration overlay: automatic recovery halted"))
        host.terminalNotifyRestorationStateChanged()
    }
}
