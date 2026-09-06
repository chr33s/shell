//
//  ReconnectionManager.swift
//  shell
//
//  State machine for managing automatic session reconnection with exponential backoff.
//  Coordinates with NetworkReachabilityMonitor for opportunistic reconnection.
//

import Foundation
import Combine
import os

/// Manages automatic reconnection attempts for a terminal session
@MainActor
public final class ReconnectionManager {

    // MARK: - Logger

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "Reconnection")

    // MARK: - Configuration

    /// Configuration for reconnection behavior
    struct Config: Equatable, Sendable {
        /// Whether auto-reconnect is enabled
        var enabled: Bool = true

        /// Initial delay before first reconnection attempt (seconds)
        var initialDelay: TimeInterval = 1.0

        /// Maximum delay between reconnection attempts (seconds)
        var maxDelay: TimeInterval = 30.0

        /// Maximum number of reconnection attempts before giving up
        var maxAttempts: Int = 5

        /// Multiplier for exponential backoff (delay * multiplier each attempt)
        var backoffMultiplier: Double = 2.0

        /// Whether to attempt immediate reconnection when network is restored
        var reconnectOnNetworkRestored: Bool = true

        /// Nonisolated init allows creation from any context
        nonisolated init(
            enabled: Bool = true,
            initialDelay: TimeInterval = 1.0,
            maxDelay: TimeInterval = 30.0,
            maxAttempts: Int = 5,
            backoffMultiplier: Double = 2.0,
            reconnectOnNetworkRestored: Bool = true
        ) {
            self.enabled = enabled
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
            self.maxAttempts = maxAttempts
            self.backoffMultiplier = backoffMultiplier
            self.reconnectOnNetworkRestored = reconnectOnNetworkRestored
        }

        /// Default configuration matching user requirements
        nonisolated static let `default` = Config()
    }

    // MARK: - State

    /// Reason for disconnection
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

        /// Whether this disconnect reason should trigger auto-reconnect
        public var shouldAutoReconnect: Bool {
            switch self {
            case .userInitiated:
                return false
            case .networkLost, .serverClosed, .timeout, .error:
                return true
            }
        }
    }

    /// Current state of the reconnection manager
    enum State: Equatable {
        /// Not managing any connection (initial state)
        case idle

        /// Session is connected and running
        case connected

        /// Session disconnected, evaluating whether to reconnect
        case disconnected(reason: DisconnectReason)

        /// Waiting before next reconnection attempt
        case waitingToReconnect(attempt: Int, nextAttemptIn: TimeInterval)

        /// Actively attempting to reconnect
        case reconnecting(attempt: Int)

        /// Reconnection permanently failed (e.g., auth error)
        case failed(reason: String)

        /// Max attempts reached, waiting for user to manually reconnect
        case manualReconnectRequired
    }

    // MARK: - Manager State

    /// Current state of the manager
    private(set) var state: State = .idle

    /// Current attempt number (1-based, 0 when not reconnecting)
    private(set) var currentAttempt: Int = 0

    // MARK: - Configuration

    /// Reconnection configuration
    var config: Config

    // MARK: - Callbacks

    /// Called when a reconnection attempt should be made.
    /// The callback should attempt to reconnect and throw on failure.
    var onReconnectAttempt: (() async throws -> Void)?

    /// Called whenever state changes
    var onStateChange: ((State) -> Void)?

    /// Called when max attempts reached and giving up
    var onGiveUp: (() -> Void)?

    /// Called when reconnection succeeds
    var onReconnected: (() -> Void)?

    // MARK: - Private Properties

    private var reconnectTask: Task<Void, Never>?
    private var networkCancellable: AnyCancellable?
    private var isPaused: Bool = false

    // MARK: - Initialization

    init(config: Config = .default) {
        self.config = config
        subscribeToNetworkChanges()
    }

    deinit {
        reconnectTask?.cancel()
        networkCancellable?.cancel()
    }

    // MARK: - Public Methods

    /// Called when a session connects successfully
    func handleConnected() {
        Self.logger.info("Session connected")
        transition(to: .connected)
        currentAttempt = 0
        isPaused = false
    }

    /// Called when a session disconnects unexpectedly
    func handleDisconnect(reason: DisconnectReason) {
        Self.logger.info("Session disconnected: \(reason.description)")

        // Cancel any existing reconnection
        cancelTasks()

        // Transition to disconnected state
        transition(to: .disconnected(reason: reason))

        // Check if we should auto-reconnect
        guard config.enabled && reason.shouldAutoReconnect else {
            Self.logger.info("Auto-reconnect disabled or user-initiated disconnect")
            return
        }

        // Start reconnection loop
        startReconnectionLoop()
    }

    /// Called when reconnection fails due to a permanent error (e.g., auth failure)
    func handlePermanentFailure(reason: String) {
        Self.logger.error("Permanent reconnection failure: \(reason)")
        cancelTasks()
        transition(to: .failed(reason: reason))
    }

    /// Cancels any ongoing reconnection attempts
    func cancelReconnection() {
        Self.logger.info("Reconnection cancelled")
        cancelTasks()
        transition(to: .idle)
        currentAttempt = 0
    }

    /// Manually trigger a reconnection attempt
    func manualReconnect() {
        Self.logger.info("Manual reconnection requested")
        cancelTasks()
        currentAttempt = 0
        isPaused = false
        startReconnectionLoop()
    }

    /// Reset the manager to idle state
    func reset() {
        Self.logger.debug("Resetting reconnection manager")
        cancelTasks()
        transition(to: .idle)
        currentAttempt = 0
        isPaused = false
    }

    /// Pause reconnection (e.g., when app goes to background)
    func pause() {
        guard !isPaused else { return }
        Self.logger.info("Pausing reconnection")
        isPaused = true
        cancelTasks()
    }

    /// Resume reconnection (e.g., when app returns to foreground)
    func resume() {
        guard isPaused else { return }
        Self.logger.info("Resuming reconnection")
        isPaused = false

        // If we were waiting, restart the loop
        if case .waitingToReconnect = state {
            startReconnectionLoop()
        } else if case .disconnected = state {
            startReconnectionLoop()
        } else if case .reconnecting = state {
            // pause() cancelled the loop mid-attempt and the attempt's
            // outcome was discarded, leaving this state behind. Restart
            // here or nothing ever will.
            startReconnectionLoop()
        }
    }

    // MARK: - Private Methods

    private func transition(to newState: State) {
        guard state != newState else { return }

        Self.logger.debug("State transition: \(String(describing: self.state)) -> \(String(describing: newState))")
        state = newState
        onStateChange?(newState)
    }

    /// - Parameter immediateFirstAttempt: Skip the backoff wait for the first
    ///   attempt of this loop. Used by the network-restored fast path —
    ///   without it, "retry immediately" would still sit out the next
    ///   scheduled backoff delay.
    private func startReconnectionLoop(immediateFirstAttempt: Bool = false) {
        guard !isPaused else {
            Self.logger.debug("Reconnection paused, not starting loop")
            return
        }

        reconnectTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            var skipDelay = immediateFirstAttempt
            while !Task.isCancelled && self.currentAttempt < self.config.maxAttempts {
                self.currentAttempt += 1
                let attempt = self.currentAttempt

                // Calculate delay for this attempt
                let delay = skipDelay ? 0 : self.calculateDelay(forAttempt: attempt)
                skipDelay = false

                Self.logger.info("Reconnection attempt \(attempt)/\(self.config.maxAttempts), delay: \(delay)s")

                // Wait before attempting (skipped on fast-path immediate retries)
                if delay > 0 {
                    self.transition(to: .waitingToReconnect(attempt: attempt, nextAttemptIn: delay))
                    await self.wait(delay: delay)

                    // Check if cancelled during wait
                    guard !Task.isCancelled else { return }
                }

                // Attempt reconnection
                self.transition(to: .reconnecting(attempt: attempt))

                do {
                    if let reconnectHandler = self.onReconnectAttempt {
                        try await reconnectHandler()
                    } else {
                        Self.logger.error("No reconnect handler configured")
                        throw ReconnectionError.noHandler
                    }

                    // Cancellation is cooperative: cancelReconnection() during
                    // an in-flight attempt can't abort the handler. If the
                    // handshake completed anyway, the canceller owns the state
                    // — don't report a late success.
                    guard !Task.isCancelled else {
                        Self.logger.info("Reconnection attempt \(attempt) completed after cancellation - discarding")
                        return
                    }

                    // Success!
                    Self.logger.info("Reconnection successful on attempt \(attempt)")
                    self.transition(to: .connected)
                    self.currentAttempt = 0
                    self.onReconnected?()
                    return

                } catch {
                    Self.logger.warning("Reconnection attempt \(attempt) failed: \(error.localizedDescription)")

                    // Check if this is a permanent failure
                    if self.isPermanentFailure(error) {
                        self.handlePermanentFailure(reason: error.localizedDescription)
                        return
                    }

                    // Continue to next attempt if we have retries left
                }
            }

            // A cancelled loop must not be reported as giving up (the
            // canceller owns the next state transition).
            guard !Task.isCancelled else { return }

            // Max attempts reached
            Self.logger.warning("Max reconnection attempts (\(self.config.maxAttempts)) reached")
            self.transition(to: .manualReconnectRequired)
            self.onGiveUp?()
        }
    }

    private func wait(delay: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func calculateDelay(forAttempt attempt: Int) -> TimeInterval {
        // Exponential backoff: initialDelay * multiplier^(attempt-1)
        // Attempt 1: 1s, Attempt 2: 2s, Attempt 3: 4s, Attempt 4: 8s, Attempt 5: 16s
        let baseDelay = config.initialDelay
        let multiplier = pow(config.backoffMultiplier, Double(attempt - 1))
        let calculatedDelay = baseDelay * multiplier
        return min(calculatedDelay, config.maxDelay)
    }

    private func isPermanentFailure(_ error: Error) -> Bool {
        // Legacy-encrypted key with no local passphrase — needs manual unlock
        if case SSHKeyManager.LoadError.legacyKeyNeedsUnlock = error { return true }

        // Check for authentication-related errors that shouldn't be retried
        let errorDescription = error.localizedDescription.lowercased()

        // Auth failures
        if errorDescription.contains("authentication") ||
           errorDescription.contains("permission denied") ||
           errorDescription.contains("access denied") {
            return true
        }

        // Host key rejection
        if errorDescription.contains("host key") ||
           errorDescription.contains("hostkey") {
            return true
        }

        return false
    }

    private func cancelTasks() {
        reconnectTask?.cancel()
        reconnectTask = nil
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
        guard config.reconnectOnNetworkRestored else { return }

        // If we're waiting to reconnect, attempt immediately
        if case .waitingToReconnect = state {
            Self.logger.info("Network restored - attempting immediate reconnection")
            cancelTasks()
            // Skip the pending delay but keep attempt count
            startReconnectionLoop(immediateFirstAttempt: true)
        }
        // If we gave up, offer another chance
        else if case .manualReconnectRequired = state {
            Self.logger.info("Network restored - resetting for manual reconnect")
            // Just log - user still needs to manually trigger
        }
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

// MARK: - UserDefaults Extension for Config

extension ReconnectionManager.Config {

    /// Load configuration from the settings store
    static func fromUserDefaults() -> ReconnectionManager.Config {
        var config = ReconnectionManager.Config.default
        config.enabled = SettingsStore.shared.value(Settings.Connections.autoReconnectEnabled)

        // A stored 0 still falls back to the default attempt count
        let maxAttempts = SettingsStore.shared.value(Settings.Connections.autoReconnectMaxAttempts)
        if maxAttempts > 0 {
            config.maxAttempts = maxAttempts
        }

        return config
    }

    /// Save configuration to the settings store
    func saveToUserDefaults() {
        SettingsStore.shared.set(Settings.Connections.autoReconnectEnabled, enabled)
        SettingsStore.shared.set(Settings.Connections.autoReconnectMaxAttempts, maxAttempts)
    }
}
