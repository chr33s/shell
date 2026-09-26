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
import os

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
///
/// `nonisolated` so NIO event loops can call it. Mutable state sits behind a lock:
/// `pauseTimeout` is invoked from the main actor, while the flags are mutated on
/// the event loop. `@unchecked Sendable` covers the event-loop reference and the
/// callbacks, which NIO does not mark `Sendable`; the lock is the synchronization
/// the compiler cannot see. Callbacks are copied out before they run so a re-entrant
/// pause cannot deadlock on the lock.
nonisolated final class SSHTimeoutCoordinator: @unchecked Sendable {
    private struct State {
        var eventLoop: EventLoop?
        var isPaused = false
        var pauseStartTime: NIODeadline?
        var remainingTimeAtPause: TimeAmount?
        var onPause: (() -> Void)?
        var onResume: ((TimeAmount) -> Void)?
    }

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHTimeout")
    private let lock = NSLock()
    private var state = State()

    init() {}

    /// Register the event loop and callbacks from the handshake handler
    func register(
        eventLoop: EventLoop,
        onPause: @escaping () -> Void,
        onResume: @escaping (TimeAmount) -> Void
    ) {
        lock.withLock {
            state.eventLoop = eventLoop
            state.onPause = onPause
            state.onResume = onResume
        }
    }

    /// Pause the handshake timeout (called when waiting for user input)
    func pauseTimeout(remainingTime: TimeAmount) {
        guard let eventLoop = lock.withLock({ state.eventLoop }) else {
            Self.logger.warning("Cannot pause timeout - no event loop registered")
            return
        }

        eventLoop.execute { [self] in
            let onPause: (() -> Void)? = self.lock.withLock {
                guard !self.state.isPaused else { return nil }
                self.state.isPaused = true
                self.state.pauseStartTime = .now()
                self.state.remainingTimeAtPause = remainingTime
                return self.state.onPause
            }
            guard let onPause else { return }
            onPause()
            Self.logger.info("Timeout paused for user interaction")
        }
    }

    /// Resume the handshake timeout (called after user input received)
    func resumeTimeout() {
        guard let eventLoop = lock.withLock({ state.eventLoop }) else {
            Self.logger.warning("Cannot resume timeout - no event loop registered")
            return
        }

        eventLoop.execute { [self] in
            let resume = self.lock.withLock { () -> (TimeAmount, ((TimeAmount) -> Void)?)? in
                guard self.state.isPaused else { return nil }
                self.state.isPaused = false
                let remaining = self.state.remainingTimeAtPause ?? SSHTimeoutConfig.handshakeTimeout
                let onResume = self.state.onResume
                self.state.pauseStartTime = nil
                self.state.remainingTimeAtPause = nil
                return (remaining, onResume)
            }
            guard let resume else { return }
            resume.1?(resume.0)
            Self.logger.info("Timeout resumed with \(resume.0.nanoseconds / 1_000_000_000)s remaining")
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

        // Register with coordinator for pause/resume. Capture the event loop,
        // not the handler context: the callbacks must be callable without
        // sending a non-Sendable context out of this method.
        let eventLoop = context.eventLoop
        coordinator?.register(
            eventLoop: eventLoop,
            onPause: { [weak self] in
                self?.cancelTimeout()
            },
            onResume: { [weak self] remaining in
                self?.scheduleTimeout(duration: remaining, eventLoop: eventLoop)
            }
        )

        // Schedule initial timeout
        scheduleTimeout(duration: handshakeTimeout, eventLoop: eventLoop)
    }

    private func scheduleTimeout(duration: TimeAmount, eventLoop: any EventLoop) {
        timeoutStartTime = .now()
        scheduledTimeout = eventLoop.scheduleTask(deadline: .now() + duration) { [weak self] in
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
