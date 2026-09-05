//
//  SSHHandshakeHandler.swift
//  shell
//
//  Monitors SSH handshake and authentication state.
//  Provides a future that completes when authentication succeeds or fails.
//

import Foundation
import NIOCore
import NIOSSH
import os.log

// MARK: - SSH Timeout Configuration

/// Configuration for SSH connection timeouts
struct SSHTimeoutConfig {
    /// TCP connection timeout (how long to wait for initial connection)
    nonisolated static let connectionTimeout: TimeAmount = .seconds(15)

    /// SSH handshake/authentication timeout (protocol-level operations)
    nonisolated static let handshakeTimeout: TimeAmount = .seconds(60)

    /// Host key approval timeout (user interaction - generous)
    nonisolated static let hostKeyApprovalTimeout: TimeAmount = .seconds(300)  // 5 minutes

    /// Citadel login timeout (SSH handshake + auth via Citadel path)
    /// Matches hostKeyApprovalTimeout because Citadel's handler doesn't support
    /// pause/resume during host key approval, so the full budget must cover
    /// the user reviewing and accepting a new host key
    nonisolated static let citadelLoginTimeout: TimeAmount = .seconds(300)
}

// MARK: - SSH Timeout Coordinator

/// Coordinates timeout behavior between SSH handshake handler and host key delegate.
/// Allows pausing the handshake timeout during user interactions (host key approval).
/// Thread-safe via NIO event loop execution.
/// Marked nonisolated to allow use from NIO event loops.
final class SSHTimeoutCoordinator: @unchecked Sendable {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHTimeout")

    // Properties marked nonisolated(unsafe) because this class is @unchecked Sendable
    // and accessed exclusively from NIO event loop threads
    nonisolated(unsafe) private var eventLoop: EventLoop?
    nonisolated(unsafe) private var isPaused = false
    nonisolated(unsafe) private var pauseStartTime: NIODeadline?
    nonisolated(unsafe) private var remainingTimeAtPause: TimeAmount?
    nonisolated(unsafe) private var onPause: (() -> Void)?
    nonisolated(unsafe) private var onResume: ((TimeAmount) -> Void)?

    nonisolated init() {}

    /// Register the event loop and callbacks from the handshake handler
    nonisolated func register(
        eventLoop: EventLoop,
        onPause: @escaping () -> Void,
        onResume: @escaping (TimeAmount) -> Void
    ) {
        self.eventLoop = eventLoop
        self.onPause = onPause
        self.onResume = onResume
    }

    /// Pause the handshake timeout (called when waiting for user input)
    nonisolated func pauseTimeout(remainingTime: TimeAmount) {
        guard let eventLoop = eventLoop else {
            Self.logger.warning("Cannot pause timeout - no event loop registered")
            return
        }

        eventLoop.execute { [self] in
            guard !self.isPaused else { return }
            self.isPaused = true
            self.pauseStartTime = .now()
            self.remainingTimeAtPause = remainingTime
            self.onPause?()
            Self.logger.info("Timeout paused for user interaction")
        }
    }

    /// Resume the handshake timeout (called after user input received)
    nonisolated func resumeTimeout() {
        guard let eventLoop = eventLoop else {
            Self.logger.warning("Cannot resume timeout - no event loop registered")
            return
        }

        eventLoop.execute { [self] in
            guard self.isPaused else { return }
            self.isPaused = false

            // Resume with the remaining time from when we paused
            let remaining = self.remainingTimeAtPause ?? SSHTimeoutConfig.handshakeTimeout
            self.onResume?(remaining)
            Self.logger.info("Timeout resumed with \(remaining.nanoseconds / 1_000_000_000)s remaining")

            self.pauseStartTime = nil
            self.remainingTimeAtPause = nil
        }
    }
}

// MARK: - SSH Handshake Handler

/// Handler that monitors SSH handshake and authentication state.
/// Provides a promise that completes when authentication succeeds or fails.
/// This handler runs on the NIO event loop, not the main actor.
/// Marked @unchecked Sendable because NIO guarantees single-threaded access on the event loop.
nonisolated final class SSHHandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHHandshake")

    private let promise: EventLoopPromise<Void>
    private let handshakeTimeout: TimeAmount
    private var scheduledTimeout: Scheduled<Void>?
    private var completed = false
    private var wasAddedToPipeline = false
    private var timeoutStartTime: NIODeadline?
    private weak var coordinator: SSHTimeoutCoordinator?
    private weak var channelContext: ChannelHandlerContext?

    /// A future that completes when SSH authentication succeeds
    var authenticated: EventLoopFuture<Void> {
        promise.futureResult
    }

    init(
        eventLoop: EventLoop,
        handshakeTimeout: TimeAmount = SSHTimeoutConfig.handshakeTimeout,
        coordinator: SSHTimeoutCoordinator? = nil
    ) {
        self.promise = eventLoop.makePromise(of: Void.self)
        self.handshakeTimeout = handshakeTimeout
        self.coordinator = coordinator
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.channelContext = context
        self.wasAddedToPipeline = true

        // Register with coordinator for pause/resume
        coordinator?.register(
            eventLoop: context.eventLoop,
            onPause: { [weak self] in
                self?.cancelTimeout()
            },
            onResume: { [weak self] remaining in
                self?.scheduleTimeout(duration: remaining, context: context)
            }
        )

        // Schedule initial timeout
        scheduleTimeout(duration: handshakeTimeout, context: context)
    }

    private func scheduleTimeout(duration: TimeAmount, context: ChannelHandlerContext) {
        timeoutStartTime = .now()
        scheduledTimeout = context.eventLoop.scheduleTask(deadline: .now() + duration) { [weak self] in
            guard let self = self, !self.completed else { return }
            Self.logger.error("SSH authentication timed out after \(duration.nanoseconds / 1_000_000_000) seconds")
            self.completed = true
            self.promise.fail(SSHError.authenticationTimeout)
        }
    }

    private func cancelTimeout() {
        scheduledTimeout?.cancel()
        scheduledTimeout = nil
    }

    /// Get remaining time on current timeout
    func remainingTime() -> TimeAmount {
        guard let startTime = timeoutStartTime else {
            return handshakeTimeout
        }
        let elapsed = NIODeadline.now() - startTime
        let remaining = handshakeTimeout - elapsed
        return remaining > .nanoseconds(0) ? remaining : .nanoseconds(0)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        cancelTimeout()
        // Complete the promise when handler is removed (channel closed)
        // This ensures the promise is fulfilled while EventLoop is still running,
        // preventing leaks when connection times out and EventLoop shuts down
        if !completed {
            Self.logger.debug("Handler removed before authentication completed, failing promise")
            completed = true
            promise.fail(ChannelError.eof)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // UserAuthSuccessEvent is fired by NIOSSH when authentication completes
        if event is UserAuthSuccessEvent {
            guard !completed else {
                context.fireUserInboundEventTriggered(event)
                return
            }
            Self.logger.info("SSH authentication succeeded")
            cancelTimeout()
            completed = true
            promise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let errorDetail = String(describing: error)
        Self.logger.error("SSH handshake error: \(errorDetail)")

        // Check if it's an NIOSSHError and log the type
        if let sshError = error as? NIOSSHError {
            Self.logger.error("NIOSSHError type: \(sshError.type)")

            if sshError.type == .keyExchangeNegotiationFailure {
                Self.logger.error("Key exchange failed - no common algorithms found")
                Self.logger.error("Client offers: diffie-hellman-group14-sha256/sha1, ecdh-sha2-nistp*, curve25519-sha256")
                Self.logger.error("Check server's supported algorithms")
            } else if sshError.type == .unknownPublicKey {
                Self.logger.error("Server's host key algorithm not supported")
                Self.logger.error("Client supports: ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp*")
            } else if sshError.type == .invalidExchangeHashSignature {
                Self.logger.error("Host key signature verification failed")
            }
        }

        guard !completed else {
            context.fireErrorCaught(error)
            return
        }

        cancelTimeout()
        completed = true
        promise.fail(error)
        context.fireErrorCaught(error)
    }

    deinit {
        // Safety: fail promise if we're deallocated without completing.
        // This should only happen if the handler was never added to a pipeline
        // (edge case). If it was added, handlerRemoved() should have already
        // completed the promise while the EventLoop was still running.
        if !completed && !wasAddedToPipeline {
            struct HandlerDeallocated: Error {}
            promise.fail(HandlerDeallocated())
        }
        // Note: If wasAddedToPipeline is true but completed is false, something
        // went wrong - handlerRemoved should have completed it. But we can't
        // safely fail the promise here because the EventLoop may be shut down.
        // This is a programming error that should be fixed in handlerRemoved.
    }
}
