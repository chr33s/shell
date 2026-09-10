//
//  ReconnectionManager.swift
//  shell
//
//  Session-facing façade over `RecoveryCoordinator`
//  (spec.connectivity.md §3, §7.1, §16).
//
//  This type used to *be* the retry loop. It no longer is. The coordinator
//  owns recovery policy — attempt accounting, backoff, cooldown, path
//  coalescing, generation isolation — and this class exists to keep the
//  session/view layer's existing vocabulary (`State`, `DisconnectReason`,
//  `onReconnected`) working while that policy lives in one testable place.
//
//  Three behavioral changes come with the move, all of them required:
//
//   * Attempts are counted when a dial actually begins. The old loop
//     incremented before its wait, so a cancelled wait, a path event, or a
//     backgrounded app burned attempts that never touched the network.
//   * Exhausting the burst is no longer the end. The intent survives and
//     recovery continues at the cooldown rate while foreground-active and
//     path-eligible, instead of parking in a manual-only state forever.
//   * The session's own startup retry no longer multiplies with this one:
//     the recovery path asks for a single-attempt connect (§7.1).
//

import Foundation
import Combine
import os

/// Manages automatic reconnection attempts for a terminal session.
@MainActor
public final class ReconnectionManager {

    // MARK: - Logger

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "Reconnection")

    // MARK: - Configuration

    /// Configuration for reconnection behavior.
    struct Config: Equatable, Sendable {
        /// Master gate for automatic replacement attempts.
        var enabled: Bool = true

        /// Attempts per rapid recovery **burst** — not a session-lifetime cap.
        var maxAttempts: Int = 5

        /// Whether a restored path may trigger an opportunistic attempt.
        var reconnectOnNetworkRestored: Bool = true

        nonisolated init(
            enabled: Bool = true,
            maxAttempts: Int = 5,
            reconnectOnNetworkRestored: Bool = true
        ) {
            self.enabled = enabled
            self.maxAttempts = maxAttempts
            self.reconnectOnNetworkRestored = reconnectOnNetworkRestored
        }

        nonisolated static let `default` = Config()
    }

    // MARK: - State

    /// Reason for disconnection, as reported by a session.
    public enum DisconnectReason: Equatable, CustomStringConvertible {
        case networkLost
        case serverClosed
        case timeout
        case error(String)
        case userInitiated

        public var description: String {
            switch self {
            case .networkLost: return "Network connection lost"
            case .serverClosed: return "Server closed connection"
            case .timeout: return "Connection timed out"
            case .error(let msg): return msg
            case .userInitiated: return "Disconnected by user"
            }
        }

        /// Whether this disconnect reason should trigger auto-reconnect.
        public var shouldAutoReconnect: Bool {
            switch self {
            case .userInitiated:
                return false
            case .networkLost, .serverClosed, .timeout, .error:
                return true
            }
        }

        /// Typed classification for the coordinator.
        ///
        /// `.error` deliberately maps to `.unknown` rather than being matched
        /// against localized substrings: an unknown error gets the bounded
        /// burst and then requires attention (§7.3). Callers that know the
        /// real domain should set `ReconnectionManager.pendingFailure` instead
        /// of encoding it in a message string.
        var classified: RecoveryFailure {
            switch self {
            case .networkLost: return RecoveryFailure(domain: .transportUnavailable)
            case .serverClosed: return RecoveryFailure(domain: .transportUnavailable)
            case .timeout: return RecoveryFailure(domain: .timeout)
            case .userInitiated: return RecoveryFailure(domain: .cancelled, hop: .local)
            case .error(let message): return RecoveryFailure(domain: .unknown, detail: message)
            }
        }
    }

    /// Current state of the reconnection manager, in the vocabulary the
    /// session and view layers already speak.
    enum State: Equatable {
        case idle
        case connected
        case disconnected(reason: DisconnectReason)
        case waitingToReconnect(attempt: Int, nextAttemptIn: TimeInterval)
        case reconnecting(attempt: Int)
        case failed(reason: String)
        /// Automatic attempts have stopped and a user action is required.
        case manualReconnectRequired
    }

    // MARK: - Manager State

    private(set) var state: State = .idle

    /// Attempts that actually began dialing in the current recovery epoch.
    var currentAttempt: Int { coordinator.context.attemptState.dialCount }

    /// Configuration. Assigning adopts it at the coordinator's explicit
    /// boundary; a change mid-recovery is staged, not applied underneath it.
    var config: Config {
        didSet {
            guard config != oldValue else { return }
            coordinator.isAutomaticRecoveryEnabled = config.enabled
            var policy = coordinator.policy
            policy.burstAttempts = max(1, config.maxAttempts)
            coordinator.adoptPolicy(policy)
        }
    }

    // MARK: - Callbacks

    /// Called when a reconnection attempt should be made. The callback should
    /// attempt to reconnect and throw on failure.
    var onReconnectAttempt: (() async throws -> Void)?

    /// Called whenever the legacy state changes.
    var onStateChange: ((State) -> Void)?

    /// Called when automatic attempts stop and the user must act.
    var onGiveUp: (() -> Void)?

    /// Called when reconnection succeeds.
    var onReconnected: (() -> Void)?

    /// Called whenever the native recovery status should be re-rendered.
    var onRecoveryStatusChange: ((RecoveryStatusPresentation?) -> Void)?

    // MARK: - Recovery surface

    /// The coordinator that actually owns recovery for this connection.
    let coordinator: RecoveryCoordinator

    /// Observable recovery state, for callers that want the honest vocabulary
    /// rather than the legacy one.
    var recoveryState: RecoveryState { coordinator.state }

    /// Which of the three user-visible outcomes was last reached.
    var lastOutcome: RecoveryOutcome? { coordinator.lastOutcome }

    /// Native status for the recovery strip. `nil` means "nothing to show".
    private(set) var recoveryStatus: RecoveryStatusPresentation?

    /// The tmux session name being reattached, for display only.
    var displaySessionName: String?

    /// Validate the existing transport once, without replacing it. Set by the
    /// controller from the live session (§8.2).
    var validateTransport: ((ConnectionHealthMonitor.ValidationReason) -> Void)?

    /// A more precise failure than the session's `DisconnectReason` conveys,
    /// set by the layer that actually knows (host trust, credentials, hop).
    var pendingFailure: RecoveryFailure?

    // MARK: - Private

    private var networkCancellable: AnyCancellable?
    private var lastReason: DisconnectReason = .networkLost
    private var statusTicker: Timer?

    // MARK: - Initialization

    init(
        config: Config = .default,
        context: RecoveryContext? = nil,
        coordinator: RecoveryCoordinator? = nil
    ) {
        self.config = config

        let resolvedContext = context ?? RecoveryContext(
            intent: .interactiveShell,
            targetIdentity: RecoveryTargetIdentity(host: "", port: 22, username: ""),
            policy: {
                var policy = RecoveryPolicy.default
                policy.burstAttempts = max(1, config.maxAttempts)
                return policy
            }())

        self.coordinator = coordinator ?? RecoveryCoordinator(context: resolvedContext)
        self.coordinator.isAutomaticRecoveryEnabled = config.enabled

        wireCoordinator()
        subscribeToNetworkChanges()
    }

    deinit {
        networkCancellable?.cancel()
        statusTicker?.invalidate()
    }

    private func wireCoordinator() {
        coordinator.performAttempt = { [weak self] _ in
            guard let self else { throw CancellationError() }
            guard let handler = self.onReconnectAttempt else {
                throw ReconnectionError.noHandler
            }
            try await handler()
            // PTY allocated, shell/exec request accepted, handlers installed.
            // That is terminal readiness and nothing more — a control-mode
            // recovery is promoted to a restored session only when the tmux
            // layer verifies it reattached to the same session (§9.5).
            return RecoveryReadiness(
                kind: .terminalReady,
                generation: self.coordinator.context.connectionGeneration)
        }

        coordinator.classifyFailure = { [weak self] error in
            self?.classify(error) ?? RecoveryFailure(domain: .unknown)
        }

        coordinator.pathEligibilityProvider = {
            // A generic path result is a hint. `unknown` stays dialable so a
            // VPN-on-demand or captive-portal route still gets its bounded try.
            NetworkReachabilityMonitor.shared.isNetworkUnavailableOrRecentlyLost()
                ? .unavailable
                : .eligible
        }

        coordinator.onStateChange = { [weak self] recoveryState in
            self?.adoptRecoveryState(recoveryState)
        }

        coordinator.onOutcome = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .sessionRestored, .newShellOpened:
                self.onReconnected?()
            case .commandOutcomeUnknown:
                self.onGiveUp?()
            }
        }
    }

    // MARK: - Public Methods

    /// Called when a session connects successfully.
    func handleConnected() {
        Self.logger.info("Session connected")
        coordinator.noteReady(RecoveryReadiness(
            kind: .terminalReady,
            generation: coordinator.context.connectionGeneration))
        transition(to: .connected)
    }

    /// Called when a session disconnects unexpectedly.
    func handleDisconnect(reason: DisconnectReason) {
        Self.logger.info("Session disconnected: \(reason.description)")
        lastReason = reason
        transition(to: .disconnected(reason: reason))

        let failure = pendingFailure ?? reason.classified
        pendingFailure = nil
        coordinator.noteDisconnected(failure)
    }

    /// Called when reconnection fails due to a permanent error.
    func handlePermanentFailure(reason: String) {
        Self.logger.error("Permanent reconnection failure: \(reason)")
        coordinator.noteDisconnected(
            pendingFailure ?? RecoveryFailure(domain: .authenticationRejected, detail: reason))
        pendingFailure = nil
        transition(to: .failed(reason: reason))
    }

    /// Cancels any ongoing reconnection attempts.
    func cancelReconnection() {
        Self.logger.info("Reconnection cancelled")
        coordinator.stop()
        transition(to: .idle)
    }

    /// Manually trigger a reconnection attempt.
    func manualReconnect() {
        Self.logger.info("Manual reconnection requested")
        if case .awaitingUser = coordinator.state {
            coordinator.resumeAfterUserResolution()
        } else {
            coordinator.retryNow()
        }
    }

    /// Reset the manager to idle.
    func reset() {
        Self.logger.debug("Resetting reconnection manager")
        coordinator.stop()
        transition(to: .idle)
    }

    /// Pause recovery (app backgrounded). Consumes no attempts.
    func pause() {
        coordinator.suspend()
    }

    /// Resume recovery (app foregrounded). Re-evaluates once.
    func resume() {
        coordinator.resume()
    }

    /// A verified normal remote exit. Terminal — never auto-recovered.
    func handleRemoteExit() {
        coordinator.noteRemoteExit()
        transition(to: .idle)
    }

    /// Adopt the connection identity and intent for this logical session.
    func adoptTarget(
        _ identity: RecoveryTargetIdentity,
        intent: RecoveryIntent,
        verifiesTmuxContinuity: Bool = false
    ) {
        coordinator.updateTarget(
            identity, intent: intent, verifiesTmuxContinuity: verifiesTmuxContinuity)
    }

    // MARK: - Recovery state adoption

    private func adoptRecoveryState(_ recoveryState: RecoveryState) {
        switch recoveryState {
        case .live:
            transition(to: .connected)

        case .suspect:
            transition(to: .disconnected(reason: lastReason))

        case .waitingForConnectivity:
            transition(to: .waitingToReconnect(
                attempt: currentAttempt + 1, nextAttemptIn: 0))

        case .waitingForRetry(let deadline):
            let remaining = max(0, deadline.seconds - SystemRecoveryClock().now.seconds)
            transition(to: .waitingToReconnect(
                attempt: currentAttempt + 1, nextAttemptIn: remaining))

        case .recovering:
            transition(to: .reconnecting(attempt: max(1, currentAttempt)))

        case .awaitingUser(let reason):
            switch reason {
            case .burstExhausted, .autoReconnectDisabled:
                transition(to: .manualReconnectRequired)
                onGiveUp?()
            case .commandOutcomeUnknown:
                transition(to: .manualReconnectRequired)
            case .roundTripUnverified:
                // Not a failure state: the transport may still be alive and
                // the user's screen is intact. Keep the tab, show the strip.
                transition(to: .manualReconnectRequired)
            case .hostTrustRejected, .credentialUnavailable, .authenticationCancelled,
                 .tmuxSessionMissing, .tmuxIdentityAmbiguous, .unsupportedRecovery,
                 .protocolIncompatible:
                transition(to: .failed(reason: Self.describe(reason)))
                onGiveUp?()
            }

        case .suspended:
            break

        case .stopped, .exited:
            transition(to: .idle)
        }

        publishRecoveryStatus()
    }

    private static func describe(_ reason: RecoveryAttentionReason) -> String {
        RecoveryStatusPresentation.make(for: .awaitingUser(reason: reason), intent: .interactiveShell)?.title
            ?? String(localized: "Reconnection failed", comment: "Recovery status: generic failure")
    }

    /// Re-emit the current status without a state change behind it.
    func republishRecoveryStatus() {
        publishRecoveryStatus()
    }

    private func publishRecoveryStatus() {
        let context = coordinator.context
        let now = SystemRecoveryClock().now
        var retryRemaining: TimeInterval?
        if case .waitingForRetry(let deadline) = coordinator.state {
            retryRemaining = max(0, deadline.seconds - now.seconds)
        }

        recoveryStatus = RecoveryStatusPresentation.make(
            for: coordinator.state,
            intent: context.intent,
            isStale: context.presentationState.isStale,
            lastVerifiedActivityAge: context.freshness.roundTripAge(now: now)
                ?? context.freshness.targetActivityAge(now: now),
            retrySecondsRemaining: retryRemaining,
            sessionName: displaySessionName,
            hopDescription: hopDescription(),
            isInCooldown: context.attemptState.inCooldown)

        onRecoveryStatusChange?(recoveryStatus)
        updateStatusTicker()
    }

    private func hopDescription() -> String? {
        let identity = coordinator.context.targetIdentity
        guard !identity.host.isEmpty else { return nil }
        return identity.connectionKey
    }

    /// The countdown line needs a repaint each second, but only while there
    /// actually is a countdown. No animated polling continues while suspended.
    private func updateStatusTicker() {
        let needsTicker: Bool
        if case .waitingForRetry = coordinator.state { needsTicker = true } else { needsTicker = false }

        if needsTicker {
            guard statusTicker == nil else { return }
            statusTicker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshRecoveryStatusOnly() }
            }
        } else {
            statusTicker?.invalidate()
            statusTicker = nil
        }
    }

    private func refreshRecoveryStatusOnly() {
        guard case .waitingForRetry = coordinator.state else {
            updateStatusTicker()
            return
        }
        publishRecoveryStatus()
    }

    // MARK: - Failure classification

    /// Typed classification of an attempt error.
    ///
    /// Concrete error *types* decide the domain. The localized-message
    /// substring matching this replaced could not tell a jump-host auth
    /// failure from a destination one, and mistook any error mentioning
    /// "host key" for a rejection (§7.3).
    private func classify(_ error: Error) -> RecoveryFailure {
        if error is CancellationError { return RecoveryFailure(domain: .cancelled, hop: .local) }

        if case SSHKeyManager.LoadError.legacyKeyNeedsUnlock = error {
            return RecoveryFailure(domain: .authenticationNeeded, hop: .destination)
        }

        // The jump-host error type already carries which hop failed, which is
        // the whole reason to check it before the destination cases.
        if let jumpError = error as? SSHJumpError {
            let hop: RecoveryHop = jumpError.isJumpHostError ? .jumpHost : .destination
            switch jumpError {
            case .authenticationFailed:
                return RecoveryFailure(domain: .authenticationRejected, hop: hop)
            case .hostKeyRejected:
                return RecoveryFailure(domain: .hostTrustRejected, hop: hop)
            }
        }

        if error is HostKeyRejectedError {
            return RecoveryFailure(domain: .hostTrustRejected, hop: .destination)
        }

        if let sshError = error as? SSHError {
            switch sshError {
            case .authenticationFailed, .authenticationTimeout:
                return RecoveryFailure(domain: .authenticationRejected, hop: .destination)
            case .connectionTimeout:
                return RecoveryFailure(domain: .timeout, hop: .destination)
            case .notConnected, .channelCreationFailed:
                return RecoveryFailure(domain: .transportUnavailable, hop: .destination)
            case .sshHandshakeFailed:
                // A handshake failure is usually a dropped connection mid-KEX,
                // not an incompatible peer, so it keeps the bounded burst.
                return RecoveryFailure(domain: .transportUnavailable, hop: .destination)
            case .invalidConfiguration:
                return RecoveryFailure(domain: .configurationInvalid, hop: .local)
            }
        }

        if let reconnectError = error as? TerminalSessionController.ReconnectionError {
            switch reconnectError {
            case .tmuxSessionUnverified:
                // Retrying this changes nothing: the evidence will not
                // improve without the user choosing a session.
                return RecoveryFailure(domain: .sessionMissing, hop: .tmuxServer)
            case .endedBeforeReady, .readinessTimedOut:
                return RecoveryFailure(domain: .timeout, hop: .destination)
            case .noPTY, .unsupportedSessionType:
                return RecoveryFailure(domain: .configurationInvalid, hop: .local)
            }
        }

        if error is TimeoutError { return RecoveryFailure(domain: .timeout) }

        return RecoveryFailure(domain: .unknown, detail: error.localizedDescription)
    }

    // MARK: - Private Methods

    private func transition(to newState: State) {
        guard state != newState else { return }
        Self.logger.debug(
            "State transition: \(String(describing: self.state)) -> \(String(describing: newState))")
        state = newState
        onStateChange?(newState)
    }

    private nonisolated func subscribeToNetworkChanges() {
        Task { @MainActor [weak self] in
            self?.networkCancellable = NetworkReachabilityMonitor.shared.connectivityRestored
                .sink { [weak self] in
                    self?.handleNetworkRestored()
                }
        }
    }

    private func handleNetworkRestored() {
        // Validate before replacing. A path change does not mean the existing
        // connection is dead — on a Wi-Fi-to-cellular handoff it often is not
        // — and replacing a working transport loses the user's session for no
        // reason (AC-04).
        if coordinator.state == .live {
            validateTransport?(.pathChange)
        }

        guard config.reconnectOnNetworkRestored else { return }
        // A restored path is meaningful evidence; the coordinator still
        // coalesces it and rate-limits the bypass, so a flapping link cannot
        // reset backoff by shouting.
        coordinator.notePathEvent(meaningfulRestoration: true)
    }

    // MARK: - Errors

    enum ReconnectionError: LocalizedError {
        case noHandler

        var errorDescription: String? {
            switch self {
            case .noHandler:
                return "No reconnection handler configured"
            }
        }
    }
}

// MARK: - Settings

extension ReconnectionManager.Config {

    /// Load configuration from the settings store.
    static func fromUserDefaults() -> ReconnectionManager.Config {
        var config = ReconnectionManager.Config.default
        config.enabled = SettingsStore.shared.value(Settings.Connections.autoReconnectEnabled)

        // A stored 0 still falls back to the default attempt count.
        let maxAttempts = SettingsStore.shared.value(Settings.Connections.autoReconnectMaxAttempts)
        if maxAttempts > 0 {
            config.maxAttempts = maxAttempts
        }

        return config
    }

    /// Save configuration to the settings store.
    func saveToUserDefaults() {
        SettingsStore.shared.set(Settings.Connections.autoReconnectEnabled, enabled)
        SettingsStore.shared.set(Settings.Connections.autoReconnectMaxAttempts, maxAttempts)
    }
}
