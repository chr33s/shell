import Foundation
import os

@MainActor
final class TerminalReconnectionController {
    private weak var host: TerminalSessionControllerHost?

    private(set) var manager: ReconnectionManager?
    private var reconnectionCountdownTimer: Timer?
    private var reconnectionSpinnerAnimator: InlineSpinnerAnimator?

    /// True between `pauseUI()` and `resumeUI()` (i.e. while backgrounded).
    ///
    /// Tearing down the timer and the animator in `pauseUI()` was not enough:
    /// `manager.onStateChange` and `session.onDisconnect` stay wired while
    /// paused, so a drop arriving in the background built a *fresh*
    /// `InlineSpinnerAnimator` whose 0.08s timer wrote escape sequences
    /// straight to the surface — and nothing ever stopped it, because
    /// `startReconnectionLoop()` bails while the manager is paused, so the
    /// state machine parks in `.disconnected` until `resumeUI()`. That is
    /// exactly the cursor corruption `pauseReconnectionUI()` exists to
    /// prevent. Every direct write path below is gated on this flag.
    private var isUIPaused = false

    init(host: TerminalSessionControllerHost) {
        self.host = host
    }

    var state: ReconnectionManager.State? {
        manager?.state
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
        guard config.enabled else {
            Ghostty.logger.info("Auto-reconnect is disabled in settings")
            return
        }

        let manager: ReconnectionManager
        if let existingManager = self.manager {
            existingManager.config = config
            manager = existingManager
        } else {
            manager = ReconnectionManager(config: config)
            self.manager = manager
        }
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

    func handleConnected() {
        manager?.handleConnected()
    }

    func handlePermanentFailure(reason: String) {
        manager?.handlePermanentFailure(reason: reason)
    }

    func manualReconnect() {
        manager?.manualReconnect()
    }

    func cancelReconnection() {
        manager?.cancelReconnection()
    }

    func pauseUI() {
        reconnectionCountdownTimer?.invalidate()
        reconnectionCountdownTimer = nil

        if let spinner = reconnectionSpinnerAnimator {
            let cleanup = spinner.getCleanupSequence()
            if !cleanup.isEmpty {
                host?.terminalWriteToGhostty(cleanup)
            }
            spinner.stop()
            reconnectionSpinnerAnimator = nil
        }

        manager?.pause()

        // Set last: the cleanup write above is the one write that must still
        // reach the surface.
        isUIPaused = true
    }

    func resumeUI() {
        // Order matters. `manager.resume()` restarts the loop from
        // `.disconnected`/`.waitingToReconnect` and repaints synchronously via
        // `handleStateChange`; clearing the flag afterwards would swallow that
        // first repaint too.
        isUIPaused = false
        manager?.resume()
    }

    private func handleStateChange(_ state: ReconnectionManager.State) {
        guard let host else { return }
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

        switch state {
        case .disconnected(let reason):
            stopCountdown()

            // Backgrounded: the reconnection loop is paused, so this spinner
            // would animate until `resumeUI()` with no state change to stop
            // it. `resumeUI()` clears the flag before `manager.resume()`,
            // which restarts the loop from `.disconnected` and repaints.
            guard !isUIPaused else { break }

            let message = "Connection lost: \(reason.description)"
            reconnectionSpinnerAnimator = InlineSpinnerAnimator()
            reconnectionSpinnerAnimator?.start(
                message: message,
                style: .error,
                terminalWidth: host.terminalReconnectionWidth
            ) { [weak host] output in
                host?.terminalWriteToGhostty(output)
            }

        case .waitingToReconnect(let attempt, let delay):
            startCountdown(delay: delay, attempt: attempt)

        case .reconnecting(let attempt):
            stopCountdown()

            let cleanup = reconnectionSpinnerAnimator?.getCleanupSequence() ?? ""
            reconnectionSpinnerAnimator?.stop()
            reconnectionSpinnerAnimator = nil

            let maxAttempts = manager?.config.maxAttempts ?? 5
            let themeColors = SpinnerAnimator.ThemeColors.fromThemeManager()
            let rgb = themeColors.colorFor(style: .reconnecting)
            let color = "\u{1B}[38;2;\(rgb.0);\(rgb.1);\(rgb.2)m"
            let reset = "\u{1B}[0m"

            host.terminalWriteToGhostty(
                cleanup + color + "Reconnecting (attempt \(attempt)/\(maxAttempts))..." + reset + "\r\n\r\n"
            )

        case .connected:
            break

        case .failed(let reason):
            stopCountdown()
            playFailureAnimation(reason: reason)

        case .manualReconnectRequired:
            break

        case .idle:
            cleanupAnimators()
        }
    }

    private func startCountdown(delay: TimeInterval, attempt: Int) {
        guard let host else { return }
        stopCountdown()

        // Backgrounded: neither the spinner nor the 0.1s countdown timer may
        // write escape sequences. The loop repaints on resume.
        guard !isUIPaused else { return }

        let endTime = Date().addingTimeInterval(delay)
        let maxAttempts = manager?.config.maxAttempts ?? 5

        if reconnectionSpinnerAnimator == nil {
            reconnectionSpinnerAnimator = InlineSpinnerAnimator()
        }

        let secondsLeft = Int(ceil(delay))
        let message = "Reconnecting in \(secondsLeft)s (attempt \(attempt)/\(maxAttempts))..."
        reconnectionSpinnerAnimator?.start(
            message: message,
            style: .reconnecting,
            terminalWidth: host.terminalReconnectionWidth
        ) { [weak host] output in
            host?.terminalWriteToGhostty(output)
        }

        reconnectionCountdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCountdown(endTime: endTime, attempt: attempt, maxAttempts: maxAttempts)
            }
        }
    }

    private func updateCountdown(endTime: Date, attempt: Int, maxAttempts: Int) {
        let remaining = endTime.timeIntervalSinceNow
        if remaining <= 0 {
            stopCountdown()
            return
        }

        let secondsRemaining = Int(ceil(remaining))
        let message = "Reconnecting in \(secondsRemaining)s (attempt \(attempt)/\(maxAttempts))..."
        reconnectionSpinnerAnimator?.updateMessage(message)
    }

    private func stopCountdown() {
        reconnectionCountdownTimer?.invalidate()
        reconnectionCountdownTimer = nil
    }

    private func cleanupAnimators() {
        stopCountdown()

        let cleanup = reconnectionSpinnerAnimator?.getCleanupSequence() ?? ""
        reconnectionSpinnerAnimator?.stop()
        reconnectionSpinnerAnimator = nil

        if !cleanup.isEmpty {
            host?.terminalWriteToGhostty(cleanup)
        }
    }

    private func playFailureAnimation(reason: String) {
        guard let host else { return }
        let spinnerCleanup = reconnectionSpinnerAnimator?.getCleanupSequence() ?? ""
        reconnectionSpinnerAnimator?.stop()
        reconnectionSpinnerAnimator = nil

        // Backgrounded: suppress the escape-sequence writes only.
        // `handlePermanentFailure` is driven from outside the reconnection
        // loop (SSH auth failure), so it lands here while paused, but
        // `manager.resume()` does not re-notify from `.failed` — the overlay
        // and restoration state below must still be set or the user returns
        // to a dead terminal with no indication of why.
        if !isUIPaused {
            if !spinnerCleanup.isEmpty {
                host.terminalWriteToGhostty(spinnerCleanup)
            }

            let themeColors = SpinnerAnimator.ThemeColors.fromThemeManager()
            let dimRGB = themeColors.dimmedForeground
            let dimColor = "\u{1B}[38;2;\(dimRGB.0);\(dimRGB.1);\(dimRGB.2)m"
            let reset = "\u{1B}[0m"

            let padding = max(0, (host.terminalReconnectionWidth - reason.count) / 2)
            let centeredError = String(repeating: " ", count: padding) + reason

            host.terminalWriteToGhostty("\r\n" + dimColor + centeredError + reset + "\r\n\r\n")
        }

        host.terminalIsLiveDisconnectionOverlay = true
        host.terminalRestorationState = .failed(reason)
        host.terminalNotifyRestorationStateChanged()
    }

    private func handleSuccess() {
        guard let host else { return }
        if host.terminalIsLiveDisconnectionOverlay {
            host.terminalIsLiveDisconnectionOverlay = false
            host.terminalRestorationState = .none
            host.terminalNotifyRestorationStateChanged()
        }

        stopCountdown()
        reconnectionSpinnerAnimator?.stop()
        reconnectionSpinnerAnimator = nil

        let themeColors = SpinnerAnimator.ThemeColors.fromThemeManager()
        let successRGB = themeColors.colorFor(style: .success)
        let successColor = "\u{1B}[38;2;\(successRGB.0);\(successRGB.1);\(successRGB.2)m"
        let reset = "\u{1B}[0m"

        host.terminalWriteToGhostty(successColor + "✓ Reconnected!" + reset + "\r\n")
    }

    private func handleGiveUp() {
        stopCountdown()

        let cleanup = reconnectionSpinnerAnimator?.getCleanupSequence() ?? ""
        reconnectionSpinnerAnimator?.stop()
        reconnectionSpinnerAnimator = nil

        guard let host else { return }
        host.terminalWriteToGhostty(cleanup)
        host.terminalIsLiveDisconnectionOverlay = true
        host.terminalRestorationState = .failed("Auto-reconnect failed after maximum attempts.")
        host.terminalNotifyRestorationStateChanged()
    }
}
