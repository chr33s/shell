//
//  CitadelSSHSession.swift
//  shell
//
//  SSH session using Citadel's high-level API with jump host support
//

import Foundation
import Citadel
import Combine
import NIOCore
import NIOSSH
import NIOPosix
import NIOTransportServices
import Crypto
import os.log

/// SSH session that uses Citadel's high-level API for connections
/// Supports jump host (ProxyJump) functionality via Citadel's jump() method
@MainActor
final class CitadelSSHSession: SSHTerminalSession {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "CitadelSSHSession")

    /// Overall connection timeout for Citadel connections
    /// This is generous (5 minutes) to allow time for host key approval
    /// since Citadel doesn't expose granular timeout control
    private static let connectionTimeout: TimeInterval = 300  // 5 minutes

    let pty: TerminalPTY
    let config: SSHConfig

    private(set) var isRunning: Bool = false
    private(set) var client: SSHClient?
    private var jumpClient: SSHClient? // Keep reference to jump client for cleanup
    private var sessionTask: Task<Void, Never>?
    private var stdinWriter: TTYStdinWriter?

    /// Ordered stdin pipeline: `sendInput` yields into this stream and a
    /// single task performs the writes sequentially (mirrors SSHSession's
    /// stdin AsyncStream). One unstructured Task per write raced: MainActor
    /// serializes task STARTS, but `TTYStdinWriter.write` is a nonisolated
    /// async function (hops off the actor), so once task A suspended at the
    /// write, task B could start and both writes raced to the NIO event loop
    /// — large pastes could reach the channel out of order.
    private var stdinStreamContinuation: AsyncStream<ByteBuffer>.Continuation?
    private var stdinWriterTask: Task<Void, Never>?

    // Store resolved IP address for .local hostname caching
    private(set) var resolvedIPAddress: String?

    // Connection health monitoring
    private var healthMonitor: ConnectionHealthMonitor?

    /// Tracks the in-flight cleanup Task spawned by `cleanup()`. Held so
    /// `forceCleanupForBackground()` can cancel it on suspension instead of
    /// leaking NIO event-loop threads parked on a dead socket.
    private var cleanupTask: Task<Void, Never>?

    /// In-flight bootstrap retry task created by `start()`. Held so `stop()`
    /// can cancel it mid-retry — without this, closing the tab during the
    /// (up to ~5min) interactive retry budget would let the retry continue
    /// and silently start a PTY on a session the user already abandoned.
    private var bootstrapTask: Task<SSHClient, Error>?

    /// Cleanup budget per close call. NIO will not gracefully shut down a
    /// channel whose socket is dead (typical post-suspension), so we cap the
    /// wait and let the close future leak — the kernel reclaims the socket.
    private static let cleanupTimeoutSeconds: TimeInterval = 2.0

    /// Hard cap on the NIO TCP-connect wait. The per-attempt InitialConnectRetry
    /// budget covers TCP + KEX + auth (where auth can include slow human-factor
    /// prompts on the server side, hence 30/90/180s for interactive retries).
    /// The cap exists because `bootstrap.connect(...).get()` is not
    /// cancellation-aware: during the TCP-connect window there is no Channel
    /// yet, so the `withTaskCancellationHandler` + channel-close pattern used
    /// for the SSH handshake can't unwind a Ctrl-C until this timeout fires.
    /// 30s matches NIO `ClientBootstrap`'s own default and accommodates
    /// userspace VPN path setup (Tailscale peer wake-up via WireGuard,
    /// DERP-relay fallback when UDP hole punch fails on cellular/CGNAT NAT,
    /// corporate-VPN handshake delays). Shorter caps (e.g. 10s) silently
    /// break `.ts.net` connects from cellular when the peer is asleep or
    /// the path falls back through DERP.
    private static let tcpConnectTimeoutCap: TimeAmount = .seconds(30)

    // Connection metadata for Connection Info sheet
    private(set) var connectionStartTime: Date?
    private(set) var negotiatedKeyExchange: String?
    private(set) var negotiatedHostKey: String?
    private(set) var negotiatedCipher: String?
    private(set) var negotiatedMac: String?

    /// Metadata for the Connection Info sheet. Nil until the handshake
    /// completes (`connectionStartTime` is stamped alongside the negotiated
    /// algorithms), which is what keeps the menu item disabled while a tab is
    /// still connecting.
    var connectionInfo: ConnectionInfo? {
        guard let startTime = connectionStartTime else { return nil }
        return .ssh(SSHConnectionInfo(
            host: config.host,
            port: config.port,
            username: config.username,
            resolvedIP: resolvedIPAddress,
            connectedAt: startTime,
            jumpHost: config.jumpHost?.host,
            jumpPort: config.jumpHost?.port,
            keyExchangeAlgorithm: negotiatedKeyExchange,
            hostKeyAlgorithm: negotiatedHostKey,
            cipherAlgorithm: negotiatedCipher,
            macAlgorithm: negotiatedMac
        ))
    }

    // TerminalSession callbacks
    // NOTE: These callbacks may be called from a background thread (async for loop).
    // Callers must ensure thread-safe handling.
    //
    // The output loop runs off MainActor for latency, so reads go through `outputSink`
    // — a lock-protected sink that preserves dynamic rebinding. `didSet` observers
    // forward setter changes into the sink.
    private let outputSink = OutputSink()

    /// Server auth banners captured during authentication. Written from the
    /// NIO event loop via `SSHClientSettings.onUserAuthBanner`, drained on the
    /// main actor at the `.running` emit site.
    private let authBannerBuffer = AuthBannerBuffer()

    /// Live mirror of `authBannerBuffer` for the per-pane auth-banner card.
    /// The buffer's own drain reaches scrollback only at `.running`, which is
    /// too late for a banner that tells the user how to authenticate (a
    /// Tailscale re-auth URL, an MFA enrolment link). The observer installed in
    /// `init` feeds this model as each banner arrives; `.reset` from the
    /// buffer's drain/clear tears the card back down.
    let authBannerCardModel = SSHAuthBannerCardModel()

    func consumeAuthBanners() -> [String] { authBannerBuffer.drain() }

    var onOutput: (@Sendable (String) -> Void)? {
        didSet { outputSink.update(onOutput: onOutput, onOutputData: onOutputData) }
    }
    var onOutputData: (@Sendable (Data) -> Void)? {
        didSet { outputSink.update(onOutput: onOutput, onOutputData: onOutputData) }
    }
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onReady: (() -> Void)?

    // Error callback for connection issues
    var onError: ((Error) -> Void)?

    // Host key validation callback
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    // Keyboard-interactive (RFC 4256) challenge callback. Returns one response per
    // prompt, or nil if the user cancelled (which fails the method).
    var onKeyboardInteractiveChallenge: ((KeyboardInteractiveChallenge) async -> [String]?)?

    // State change callback for progress indicators
    var onStateChange: ((SSHSessionState) -> Void)?

    // Connection health callback
    var onHealthUpdate: ((ConnectionHealth) -> Void)?

    // Reconnection support
    var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?

    /// Whether this session type supports automatic reconnection
    var supportsAutoReconnect: Bool { true }

    /// Flag to track if stop() was called by user action (vs unexpected disconnect)
    private var userInitiatedStop: Bool = false

    /// Flag to track if we received an exit status from the shell (indicates normal exit vs network failure)
    private var receivedExitStatus: Bool = false

    // OpenSSH-style escape-character filter (~. disconnect, ~? help, etc.)
    private let escapeFilter = SSHEscapeFilter()

    /// Ensures onSessionEnd fires at most once. Set by `fireSessionEnd()`.
    private var didFireSessionEnd: Bool = false

    /// Idempotent helper for firing `onSessionEnd`. Safe to call from stop(),
    /// the PTY-session exit path, or the escape-filter disconnect handler.
    private func fireSessionEnd() {
        guard !didFireSessionEnd else { return }
        didFireSessionEnd = true
        onSessionEnd?()
    }

    /// Which hop of the connection the bootstrap is currently working on.
    /// There are exactly two credentials in play on a `ssh -J` connect, and
    /// this says which one the in-flight handshake is presenting.
    /// `internal` rather than `private` purely so `SSHHopAttributionTests` can
    /// read the recorded hop. No behavior change.
    enum ConnectionHop {
        /// The bastion: TCP connect, KEX and auth against `config.jumpHost`.
        case jumpHost
        /// The destination the user asked for — either a direct connect, or the
        /// tunnelled `jump(to:)` handshake that runs over an established bastion.
        case target
    }

    /// The hop that was in flight, recorded by `transition(to:)` as the
    /// bootstrap walks its states. `categorizeError` attributes auth and
    /// host-key failures with THIS, not with `config.usesJumpHost`: with a
    /// bastion configured, "a jump host exists" is not evidence that the jump
    /// host is what rejected us, and mis-attributing a target rejection to the
    /// bastion aims the user's typed password at the wrong host.
    ///
    /// Starts at `.target`: before any hop has begun, nothing has rejected a
    /// credential, and the host the user actually named is the only safe
    /// subject for a prompt. Only a transition that names the bastion moves it.
    var connectionHop: ConnectionHop = .target

    /// Transitions to a new state and notifies the callback
    func transition(to state: SSHSessionState) {
        // Record which hop this state belongs to, so a later failure is blamed
        // on the hop that was actually in flight. States that name no hop leave
        // the recorded value ALONE rather than clearing it — `.failed` is
        // emitted immediately before `categorizeError` runs, so clearing here
        // would erase the very attribution it is about to read.
        switch state {
        case .connecting(_, let isJumpHost), .authenticating(_, let isJumpHost):
            connectionHop = isJumpHost ? .jumpHost : .target
        case .connectingToTarget, .authenticatingTarget:
            // Reached only through a bastion, and both cover the tunnelled
            // target handshake — the bastion is already authenticated by here.
            connectionHop = .target
        default:
            break
        }

        // Deliberately NO immediate card clear on .failed/.disconnected:
        // Tailscale SSH sends its rejection reason ("tailnet policy does not
        // permit you to SSH as user …", "tailscale: access denied") as an auth
        // banner immediately before disconnecting, so on auth failure the card
        // is the only surface holding the explanation and must outlive the
        // failure. It outlives it on a countdown, not forever — a pane left
        // open on a failed connect would otherwise keep the card indefinitely.
        // Teardown still clears it sooner: stop() clears the buffer (firing
        // .reset), and a replacement session's observer replays nil.
        // This is that countdown: the auth phase is over, so start retiring the
        // card, and let a banner that lands after this point restart the clock
        // (the model re-arms on every later broadcast while latched).
        switch state {
        case .failed, .disconnected:
            authBannerCardModel.scheduleAutoDismiss()
        default:
            break
        }

        onStateChange?(state)
    }

    init(pty: TerminalPTY, config: SSHConfig) {
        self.pty = pty
        self.config = config
        wireEscapeFilter()
        // Must be set before the connection starts (see `setObserver`): banners
        // arrive during authentication, so an observer installed at `.running`
        // would miss every one of them. The closure captures only the model's
        // channel continuation, so this never retains the session.
        authBannerBuffer.setObserver(
            authBannerCardModel.makeBufferObserver(hostLabel: "\(config.username)@\(config.host)")
        )
    }

    private func wireEscapeFilter() {
        escapeFilter.onEcho = { [weak self] text in
            self?.onOutput?(text)
        }
        escapeFilter.onDisconnect = { [weak self] in
            // Defer the teardown to the next main-actor turn so sendInput unwinds
            // cleanly before stop() starts tearing down the transport.
            Task { @MainActor in
                self?.stop()
            }
        }
        escapeFilter.onShowConnectionInfo = { [weak self] in
            guard let self else { return }
            self.onOutput?(self.formatConnectionInfoForEcho())
        }
    }

    private func formatConnectionInfoForEcho() -> String {
        var lines: [String] = []
        lines.append("\(config.username)@\(config.host):\(config.port)")
        if let jump = config.jumpHost {
            lines.append("via: \(jump.username)@\(jump.host):\(jump.port)")
        }
        if let kex = negotiatedKeyExchange { lines.append("kex:    \(kex)") }
        if let cipher = negotiatedCipher { lines.append("cipher: \(cipher)") }
        if let mac = negotiatedMac { lines.append("mac:    \(mac)") }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    func start() async throws {
        guard !isRunning else { return }

        // Reset flags for new session
        receivedExitStatus = false
        userInitiatedStop = false
        didFireSessionEnd = false
        escapeFilter.reset()

        Self.logger.info("Starting Citadel SSH connection to \(self.config.displayName)")

        // Wrap the bootstrap retry in a cancellable Task we own. Two reasons:
        //  1. `stop()` (called when the user closes the tab) can call
        //     `bootstrapTask?.cancel()` to interrupt the retry mid-attempt
        //     or mid-backoff, instead of letting it run to completion and
        //     silently set up a PTY on a session that was already torn down.
        //  2. If our enclosing Task is cancelled by any other path
        //     (TerminalViewSession deinit, parent task chain), the `defer`
        //     cancellation guarantees the retry task is cancelled too.
        let task = Task<SSHClient, Error> {
            try await InitialConnectRetry.run(
                config: .interactive,
                label: "ssh:\(self.config.displayName)",
                isPermanent: InitialConnectRetry.isPermanentConnectErrorApp
            ) { attempt, timeout in
                if attempt > 1 {
                    let timeoutSec = Double(timeout.nanoseconds) / 1_000_000_000
                    Self.logger.info("SSH connect retry attempt \(attempt) (timeout=\(timeoutSec)s)")
                }
                return try await self.performInitialConnect(timeout: timeout)
            }
        }
        self.bootstrapTask = task
        defer {
            task.cancel()
            self.bootstrapTask = nil
        }

        do {
            // Forward outer-Task cancellation into the inner bootstrap Task.
            // Without this, when the enclosing Task is cancelled (e.g.
            // LocalShellSession cancels embeddedConnectionStartTask on Ctrl-C),
            // `try await task.value` throws CancellationError but the inner
            // bootstrap keeps running until NIO's connect/login timeouts fire
            // — leaving an orphan SSHClient that hogs the network path and
            // makes the user's next `ssh` feel serialized behind the old one.
            let finalClient = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }

            // Race window: stop() may have flipped userInitiatedStop, or the
            // outer Task may have been cancelled, after bootstrap succeeded
            // but before we reach this point. If so, the session was
            // abandoned — close the freshly-connected client and exit cleanly
            // without setting up a PTY.
            guard !userInitiatedStop, !Task.isCancelled else {
                Self.logger.info("Connection completed but session was stopped/cancelled during retry; closing")
                try? await withTimeout(seconds: Self.cleanupTimeoutSeconds) {
                    try? await finalClient.close()
                }
                if Task.isCancelled { throw CancellationError() }
                return
            }

            self.client = finalClient
            self.connectionStartTime = Date()

            // Query negotiated algorithms from Citadel client
            do {
                if let algos = try await finalClient.getNegotiatedAlgorithms() {
                    self.negotiatedKeyExchange = algos.keyExchange
                    self.negotiatedHostKey = algos.hostKey
                    self.negotiatedCipher = algos.cipher
                    self.negotiatedMac = algos.mac
                    Self.logger.info("Negotiated algorithms - KEX: \(algos.keyExchange), HostKey: \(algos.hostKey), Cipher: \(algos.cipher), MAC: \(algos.mac ?? "none")")
                }
            } catch {
                Self.logger.warning("Could not query negotiated algorithms: \(error.localizedDescription)")
            }

            // Second race-window check: getNegotiatedAlgorithms() above is an
            // additional `await` point. If stop() ran (or the outer Task was
            // cancelled) while parked there, the inner do/catch swallowed the
            // error and we must NOT continue to isRunning=true / startPTYSession.
            // stop() may have already nilled self.client and fired
            // fireSessionEnd(); we'd be racing a teardown.
            guard !userInitiatedStop, !Task.isCancelled else {
                Self.logger.info("Session stopped/cancelled during algorithm query; closing")
                let toClose = self.client
                self.client = nil
                try? await withTimeout(seconds: Self.cleanupTimeoutSeconds) {
                    try? await toClose?.close()
                }
                if Task.isCancelled { throw CancellationError() }
                return
            }

            isRunning = true

            // Start PTY session
            startPTYSession()

        } catch is CancellationError {
            // Bootstrap was cancelled. Three paths reach here:
            //  - stop() called bootstrapTask.cancel() (user closed the tab).
            //    cleanup() is also invoked by stop() so this call is a no-op
            //    (cleanup is idempotent — captures refs, nils props).
            //  - The enclosing Task was cancelled WITHOUT going through stop()
            //    — typically when LocalShellSession.startEmbeddedConnectionTask
            //    cancels the previous start task to launch a new one. In that
            //    case stop() never runs and `self.jumpClient` would be leaked
            //    if performInitialConnect set it before observing cancel.
            //  - performInitialConnect threw CancellationError after assigning
            //    self.jumpClient (between the jump-host connect and the target
            //    jump). Same leak risk.
            // Calling cleanup() here covers all three.
            Self.logger.info("SSH bootstrap cancelled")
            cleanup()
            throw CancellationError()
        } catch {
            let errorDetail = String(describing: error)
            Self.logger.error("SSH connection failed: \(errorDetail)")
            isRunning = false
            cleanup()

            // Signal failed state for progress indicator
            transition(to: .failed)

            // Convert to appropriate error type
            let finalError = categorizeError(error)
            onError?(finalError)
            throw finalError
        }
    }

    /// One attempt of the SSH connection-establishment phase. Called by
    /// `start()` through `InitialConnectRetry.run`, which loops on transient
    /// failures with exponential backoff. The retry helper passes in the
    /// per-attempt `timeout`, which we hand ONLY to the TCP connect cap
    /// (`min(timeout, tcpConnectTimeoutCap)`). It must NOT become Citadel's
    /// `loginTimeout`: that deadline is absolute and non-pausable and spans the
    /// whole post-TCP auth phase, including time the user spends typing an OTP
    /// for a keyboard-interactive challenge. A tight per-attempt value (30s on
    /// attempt 1) drops the connection mid-prompt. The login phase instead uses
    /// the generous fixed `SSHTimeoutConfig.citadelLoginTimeout` (5 min) — the
    /// same budget every other Citadel call site in the app uses.
    private func performInitialConnect(timeout: TimeAmount) async throws -> SSHClient {
        SSHCustomAlgorithms.ensureRegistered()

        // Fresh per attempt: drop any auth banners a prior failed attempt
        // buffered so the `.running` flush and the auth-banner card reflect
        // only this connection (mirrors TrzszSpawnHelper.createSSHClient).
        // The clear fires `.reset`, resetting the card between attempts.
        authBannerBuffer.clear()

        // Per-attempt cleanup: a previous attempt may have partially populated
        // self.jumpClient before the target connect failed. Close it before
        // retrying so we don't leak event-loop threads parked on a dead socket.
        // Bounded — Citadel's close future can park on a dead socket waiting
        // for a TCP ack that never arrives.
        if let stale = self.jumpClient {
            self.jumpClient = nil
            try? await withTimeout(seconds: Self.cleanupTimeoutSeconds) {
                try? await stale.close()
            }
        }

        try Task.checkCancellation()

        // Emit start/end CONN events with elapsed time so a "next ssh hung
        // behind the previous one" report can be diagnosed from logs: the
        // window between started/ended should not overlap with the next
        // session's window.
        let finalClient: SSHClient

        if let jumpConfig = config.jumpHost {
            // Connect via jump host
            Self.logger.info("Connecting via jump host: \(jumpConfig.displayName)")

            // Signal connecting to jump host
            transition(to: .connecting(host: jumpConfig.host, isJumpHost: true))

            // Step 1: Connect to jump host
            let jumpAuth = try await buildAuthMethod(for: jumpConfig)
            let jumpHostKeyValidator = buildHostKeyValidator(
                for: jumpConfig.host,
                port: jumpConfig.port,
                label: "[Jump Host]"
            )

            // Check for CGNAT address on jump host - force IPv4 if detected
            let jumpConnectHost: String
            if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: jumpConfig.host) {
                Self.logger.info("Detected CGNAT for jump host \(jumpConfig.host), forcing IPv4: \(cgnatIP)")
                jumpConnectHost = cgnatIP
            } else {
                jumpConnectHost = jumpConfig.host
            }

            Self.logger.info("Connecting to jump host \(jumpConfig.host):\(jumpConfig.port)")
            // Always route through MPTCPBootstrap.connectPlainChannel so we hold
            // a raw Channel handle for both MPTCP and non-MPTCP. Citadel's
            // `SSHClient.connect(to:)` hides the channel internally and its
            // NIO→async bridge ignores Swift Task cancellation — leaving Ctrl-C
            // unable to interrupt SSH handshake/auth for up to loginTimeout.
            // With a channel in hand, the cancellation handler below can close
            // it directly and the connect future fails within an event-loop hop.
            let jumpChannel = try await MPTCPBootstrap.connectPlainChannel(
                host: jumpConnectHost,
                port: jumpConfig.port,
                timeout: min(timeout, Self.tcpConnectTimeoutCap)
            )
            if Task.isCancelled {
                try? await jumpChannel.close()
                throw CancellationError()
            }
            var jumpSettings = SSHClientSettings(
                host: jumpConnectHost,
                port: jumpConfig.port,
                authenticationMethod: { jumpAuth },
                hostKeyValidator: jumpHostKeyValidator
            )
            jumpSettings.algorithms = .all
            // Generous fixed budget — must cover human OTP / host-key entry.
            // The per-attempt `timeout` bounds only TCP connect (above).
            jumpSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            jumpSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: jumpConfig.host)
            jumpSettings.onUserAuthBanner = { [authBannerBuffer = self.authBannerBuffer, jumpHost = jumpConfig.host] message, _ in
                authBannerBuffer.append(message, source: jumpHost)
            }
            let jumpChannelBox = CancellationChannelBox(jumpChannel)
            let jumpClientConnection: SSHClient
            do {
                jumpClientConnection = try await withTaskCancellationHandler {
                    try await SSHClient.connect(on: jumpChannel, settings: jumpSettings)
                } onCancel: {
                    _ = jumpChannelBox.channel.close()
                }
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                // Non-cancellation failure (auth, host-key reject, KEX, etc.).
                // Citadel's connect(on:settings:) does NOT close the channel
                // on failure — ownership only transfers on success — so we
                // still own this caller-created channel. Bounded close: a
                // half-dead channel can park NIO indefinitely.
                try? await withTimeout(seconds: Self.cleanupTimeoutSeconds) {
                    try? await jumpChannel.close()
                }
                throw error
            }
            // If the bootstrap Task was cancelled mid-await, close the freshly
            // built client instead of leaking it through self.jumpClient.
            if Task.isCancelled {
                try? await withTimeout(seconds: Self.cleanupTimeoutSeconds) {
                    try? await jumpClientConnection.close()
                }
                throw CancellationError()
            }
            self.jumpClient = jumpClientConnection

            // Signal jump host connected, now connecting to target
            transition(to: .authenticating(host: jumpConfig.host, isJumpHost: true))

            Self.logger.info("Jump host connected, creating tunnel to target")

            // Step 2: Jump to target host through the tunnel
            // Signal connecting to target
            transition(to: .connectingToTarget(host: config.host))

            let targetAuth = try await buildAuthMethod(for: config)
            let targetHostKeyValidator = buildHostKeyValidator(
                for: config.host,
                port: config.port,
                label: "[Target]"
            )

            var targetSettings = SSHClientSettings(
                host: config.host,
                port: config.port,
                authenticationMethod: { targetAuth },
                hostKeyValidator: targetHostKeyValidator
            )
            targetSettings.algorithms = .all
            // See jump branch: human-inclusive login budget, not the TCP cap.
            targetSettings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            targetSettings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: config.host)
            targetSettings.onUserAuthBanner = { [authBannerBuffer = self.authBannerBuffer] message, _ in
                authBannerBuffer.append(message)
            }

            try Task.checkCancellation()
            // Citadel's `jump(to:)` creates a DirectTCPIP child channel on the
            // jump client's session and awaits `handshakeHandler.authenticated.get()`
            // on it. EventLoopFuture.get() does not observe Swift cancellation,
            // so without a handler here Ctrl-C during the target handshake/auth
            // would park for up to loginTimeout. Closing the jump client on
            // cancel tears down its session channel, which cascades into the
            // in-flight DirectTCPIP child — failing the inner await fast.
            let jumpClientBox = CancellationSSHClientBox(jumpClientConnection)
            do {
                finalClient = try await withTaskCancellationHandler {
                    try await jumpClientConnection.jump(to: targetSettings)
                } onCancel: {
                    Task { try? await jumpClientBox.client.close() }
                }
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
            if Task.isCancelled {
                try? await withTimeout(seconds: Self.cleanupTimeoutSeconds) {
                    try? await finalClient.close()
                }
                throw CancellationError()
            }

            // Signal authenticating with target
            transition(to: .authenticatingTarget(host: config.host))

            Self.logger.info("Target connection established through jump host")

        } else {
            // Direct connection (no jump host)
            Self.logger.info("Direct connection to \(self.config.host):\(self.config.port)")

            // Signal connecting state
            transition(to: .connecting(host: config.host, isJumpHost: false))

            // Determine the host to connect to, with special handling for .local and CGNAT
            let connectHost: String

            if config.host.hasSuffix(".local") {
                // For .local hostnames, pre-resolve to get routable IPv4
                // Runs on background thread with timeout to avoid blocking main thread
                Self.logger.info("Pre-resolving .local hostname: \(self.config.host)")

                if let ipv4 = await NetworkAddressUtils.resolveToRoutableIPv4(hostname: config.host) {
                    // Connect using the resolved IPv4
                    Self.logger.info("Resolved \(self.config.host) to IPv4: \(ipv4)")
                    connectHost = ipv4
                    self.resolvedIPAddress = ipv4
                } else {
                    // Resolution failed; try the hostname as a last resort.
                    Self.logger.warning("No routable IPv4 for \(self.config.host), trying hostname")
                    connectHost = config.host
                }
            } else if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: config.host) {
                // Check for CGNAT address - force IPv4 if detected
                Self.logger.info("Detected CGNAT for \(self.config.host), forcing IPv4: \(cgnatIP)")
                connectHost = cgnatIP
                self.resolvedIPAddress = cgnatIP
            } else {
                connectHost = config.host
            }

            let auth = try await buildAuthMethod(for: config)
            let hostKeyValidator = buildHostKeyValidator(
                for: config.host,
                port: config.port,
                label: nil
            )

            try Task.checkCancellation()
            // See jump-host branch above — always route through
            // MPTCPBootstrap.connectPlainChannel so we hold a Channel handle
            // for both MPTCP and non-MPTCP. Citadel's `connect(to:)` hides the
            // channel and its NIO→async bridge ignores Swift cancellation, so
            // Ctrl-C during handshake/auth would otherwise leak for loginTimeout.
            let directChannel = try await MPTCPBootstrap.connectPlainChannel(
                host: connectHost,
                port: config.port,
                timeout: min(timeout, Self.tcpConnectTimeoutCap)
            )
            if Task.isCancelled {
                try? await directChannel.close()
                throw CancellationError()
            }
            var settings = SSHClientSettings(
                host: connectHost,
                port: config.port,
                authenticationMethod: { auth },
                hostKeyValidator: hostKeyValidator
            )
            settings.algorithms = .all
            // See jump branch: human-inclusive login budget, not the TCP cap.
            settings.loginTimeout = SSHTimeoutConfig.citadelLoginTimeout
            settings.protocolOptions = SSHConnectionHelper.hostCertificateProtocolOptions(forHost: config.host)
            settings.onUserAuthBanner = { [authBannerBuffer = self.authBannerBuffer] message, _ in
                authBannerBuffer.append(message)
            }
            let directChannelBox = CancellationChannelBox(directChannel)
            do {
                finalClient = try await withTaskCancellationHandler {
                    try await SSHClient.connect(on: directChannel, settings: settings)
                } onCancel: {
                    _ = directChannelBox.channel.close()
                }
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                // Citadel does not close the channel on failure — see jump
                // branch above for rationale.
                try? await withTimeout(seconds: Self.cleanupTimeoutSeconds) {
                    try? await directChannel.close()
                }
                throw error
            }
            if Task.isCancelled {
                try? await withTimeout(seconds: Self.cleanupTimeoutSeconds) {
                    try? await finalClient.close()
                }
                throw CancellationError()
            }

            // Signal authenticating state
            transition(to: .authenticating(host: config.host, isJumpHost: false))
        }

        return finalClient
    }

    func stop() {
        Self.logger.info("Stopping Citadel SSH session")
        authBannerBuffer.clear()

        // Mark this as user-initiated so we don't trigger reconnection
        userInitiatedStop = true

        // Cancel any in-flight bootstrap retry. If start() is mid-retry the
        // CancellationError will propagate out of `try await task.value` and
        // the session will tear down cleanly without ever setting up a PTY.
        bootstrapTask?.cancel()
        // Signal disconnected state for progress indicator (only if was running)
        if isRunning {
            transition(to: .disconnected)
        }

        isRunning = false

        // Always call cleanup - it's safe to call multiple times
        // This ensures port forwards are stopped even if PTY session ended first
        cleanup()

        // Fire onSessionEnd now so outer owners (e.g., LocalShellSession routing
        // input to an embedded SSH session) drop back to their own mode without
        // waiting for the async PTY stream to end. The PTY-exit path will hit
        // the flag and not double-fire.
        fireSessionEnd()
    }

    func sendInput(_ data: Data) {
        guard isRunning, stdinWriter != nil, let continuation = stdinStreamContinuation else {
            Self.logger.warning("Cannot send input: session not ready")
            return
        }

        // Apply OpenSSH-style escape-character filtering (~. ~? ~I ~~).
        // Unknown and unsupported escapes fall through as literal bytes.
        let filtered = escapeFilter.filter(data)
        guard !filtered.isEmpty else { return }

        // AsyncStream yields are strictly FIFO and the single writer task
        // performs the writes sequentially, so bytes reach the channel in
        // sendInput() call order. (A Task per write only serialized task
        // STARTS; concurrent writes raced once the first one suspended.)
        var buffer = ByteBufferAllocator().buffer(capacity: filtered.count)
        buffer.writeBytes(filtered)
        continuation.yield(buffer)
    }

    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        pty.windowSize = size

        guard let writer = stdinWriter else { return }

        // Window-change goes out of band relative to the stdin stream
        // (matches SSHSession); resize/input relative order was never
        // guaranteed on an SSH channel anyway.
        Task {
            do {
                try await writer.changeSize(
                    cols: Int(size.cols),
                    rows: Int(size.rows),
                    pixelWidth: Int(size.pixelWidth),
                    pixelHeight: Int(size.pixelHeight)
                )
            } catch {
                Self.logger.error("Failed to resize PTY: \(error.localizedDescription)")
            }
        }
    }

    /// Stop heartbeat probes and force-cancel any in-flight cleanup Task that
    /// may be parked on a NIO close future for a now-dead socket. The probes
    /// would otherwise keep waking the main actor, and the cleanup Task would
    /// hold an event-loop thread until iOS reaped us.
    func pauseForBackground() {
        Self.logger.info("Citadel pauseForBackground")
        // Nil the monitor reference (not just .stop()) so resumeForForeground
        // re-creates it; startHealthMonitoringIfEnabled bails when non-nil.
        healthMonitor?.stop()
        healthMonitor = nil
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    /// Re-arm health monitoring if the session is still running.
    func resumeForForeground() {
        guard isRunning else { return }
        Self.logger.info("Citadel resumeForForeground")
        startHealthMonitoringIfEnabled()
    }

    // MARK: - Private Methods

    /// Handle PTY session I/O - extracted to share between withPTY and withPTYExec.
    ///
    /// `nonisolated` so the output iterator drains on the generic executor rather than
    /// competing with UI work on MainActor. Only state mutation and the one-shot setup
    /// hop through MainActor. Output dispatch goes through `outputSink`, which is
    /// lock-protected and honours later rebinding of `onOutput`/`onOutputData`.
    private nonisolated func handlePTYSession(inbound: TTYOutput, outbound: TTYStdinWriter) async throws {
        let sink = self.outputSink
        var firstByteLogged = false

        // One-shot setup on MainActor.
        await MainActor.run {
            self.stdinWriter = outbound

            // Single ordered writer for stdin — see the property doc on
            // `stdinStreamContinuation`. Fresh stream per PTY session; the
            // teardown paths finish() it so the loop exits.
            let (stdinStream, stdinContinuation) = AsyncStream.makeStream(of: ByteBuffer.self)
            self.stdinStreamContinuation = stdinContinuation
            self.stdinWriterTask = Task {
                for await buffer in stdinStream {
                    do {
                        try await outbound.write(buffer)
                    } catch {
                        Self.logger.error("Failed to write to SSH: \(error.localizedDescription)")
                    }
                }
            }

            Self.logger.info("SSH session ready, firing onReady callback")
            self.transition(to: .running)
            self.onReady?()

            // Start health monitoring
            self.startHealthMonitoring()
        }

        // Output loop runs off MainActor — dispatches each chunk through OutputSink
        // without an actor hop, matching SSHSession's zero-hop behavior while still
        // honouring dynamic callback rebinding.
        for try await output in inbound {
            switch output {
            case .stdout(let buffer), .stderr(let buffer):
                if !firstByteLogged {
                    firstByteLogged = true
                    let n = buffer.readableBytes
                    Self.logger.info("PTY session: first inbound byte received (n=\(n) bytes)")
                }
                if let bytesView = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
                    sink.emit(Data(bytesView))
                }

            case .exitStatus(let code):
                // Shell exited normally - deterministic signal (user typed exit or Ctrl+D).
                Self.logger.info("Received exit status: \(code)")
                await MainActor.run {
                    self.receivedExitStatus = true
                }
            }
        }

        if !firstByteLogged {
            Self.logger.error("PTY session ended before any inbound bytes — pty-req or shell-req likely rejected by server")
        }
    }

    private func startPTYSession() {
        guard let client = client else { return }

        // This fork forwards no agents: `agentDelegate` is always nil.
        let agentDelegate: SSHAgentDelegate? = nil

        sessionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            do {
                let terminalSize = self.pty.windowSize

                let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: self.config.effectiveTerminalType,
                    terminalCharacterWidth: Int(terminalSize.cols),
                    terminalRowHeight: Int(terminalSize.rows),
                    terminalPixelWidth: Int(terminalSize.pixelWidth),
                    terminalPixelHeight: Int(terminalSize.pixelHeight),
                    terminalModes: SSHConnectionHelper.defaultPTYTerminalModes
                )

                Self.logger.info("Opening PTY session with size \(terminalSize.rows)x\(terminalSize.cols)")

                // Build environment variable requests for locale
                // Uses LocaleHelper to produce clean POSIX locales (e.g., "en_US.UTF-8")
                // that work on Linux servers without iOS regional modifiers
                // Only set LANG (not LC_ALL) to allow users to customize individual LC_* categories
                var envVars: [SSHChannelRequestEvent.EnvironmentRequest] = []
                if let userLocale = LocaleHelper.effectiveLocale {
                    envVars.append(SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: userLocale))
                    if let languages = LocaleHelper.effectivePreferredLanguages {
                        envVars.append(SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANGUAGE", value: languages))
                    }
                }

                // Identify the client to the remote host. LC_* is the only namespace
                // stock ssh_config/sshd_config forward; servers without AcceptEnv LC_*
                // drop these silently (wantReply: false, so nothing fails).
                for envVar in TerminalIdentity.forwardedVariables {
                    envVars.append(SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: envVar.name, value: envVar.value))
                }

                Self.logger.info("PTY session: pty-req sent, awaiting first inbound byte")

                // Use PTY with exec request for remote command/tmux, or plain PTY for interactive shell
                if let execCommand = self.config.effectiveExecCommand {
                    try await client.withPTYExec(ptyRequest, command: execCommand, environment: envVars, agentDelegate: agentDelegate) { [weak self] inbound, outbound in
                        guard let self = self else { return }
                        try await self.handlePTYSession(inbound: inbound, outbound: outbound)
                    }
                } else {
                    try await client.withPTY(ptyRequest, environment: envVars, agentDelegate: agentDelegate) { [weak self] inbound, outbound in
                        guard let self = self else { return }
                        try await self.handlePTYSession(inbound: inbound, outbound: outbound)
                    }
                }

                // Session ended - check if this was expected or not
                await MainActor.run {
                    Self.logger.info("PTY session stream ended")
                    let wasRunning = self.isRunning
                    self.isRunning = false
                    self.stdinWriter = nil
                    self.finishStdinStream()

                    // Use deterministic exit status check instead of network reachability heuristics
                    if self.userInitiatedStop {
                        // User explicitly closed the tab/window
                        Self.logger.info("Session ended (user-initiated stop)")
                        self.fireSessionEnd()
                    } else if self.receivedExitStatus {
                        // Shell exited normally (user typed 'exit' or Ctrl+D)
                        Self.logger.info("Session ended normally (received exit status)")
                        self.fireSessionEnd()
                    } else if wasRunning, let onDisconnect = self.onDisconnect {
                        // No exit status = connection died unexpectedly → trigger reconnection
                        Self.logger.info("Session ended without exit status - triggering reconnection")
                        onDisconnect(.serverClosed)
                    } else {
                        self.fireSessionEnd()
                    }
                }

            } catch {
                await MainActor.run {
                    if self.isRunning {
                        Self.logger.error("SSH PTY error: \(error.localizedDescription)")

                        // Determine error type for logging/UI purposes
                        let isTCPShutdown = Self.isTCPShutdown(error)
                        let isChannelEOF = Self.isChannelEOF(error)

                        // Signal failed state for progress indicator (unless it's just EOF)
                        if !isChannelEOF {
                            self.transition(to: .failed)
                        }

                        self.isRunning = false
                        self.stdinWriter = nil
                        self.finishStdinStream()

                        // Use deterministic exit status check instead of network reachability heuristics
                        if self.userInitiatedStop {
                            // User explicitly closed the tab/window
                            Self.logger.info("Session error during user-initiated stop")
                            self.fireSessionEnd()
                        } else if self.receivedExitStatus {
                            // Shell exited normally before the error (unlikely but handle it)
                            Self.logger.info("Session error after receiving exit status - treating as normal close")
                            self.fireSessionEnd()
                        } else if let onDisconnect = self.onDisconnect {
                            // No exit status = connection died unexpectedly → trigger reconnection
                            let reason: ReconnectionManager.DisconnectReason = isTCPShutdown ? .networkLost : .serverClosed
                            Self.logger.info("Session error without exit status - triggering reconnection: \(reason.description)")
                            onDisconnect(reason)
                        } else {
                            // No reconnection handler - fall back to session end
                            self.onOutput?("\r\n[Connection lost]\r\n")
                            self.fireSessionEnd()
                        }
                    }
                }
            }
        }
    }

    /// End the ordered stdin pipeline. Buffered-but-unwritten input drains
    /// against the (now dead) writer and error-logs; the writer task then
    /// exits its loop. Yields after finish() are silently dropped, which
    /// preserves the escapeFilter `~.` deferred-stop contract.
    private func finishStdinStream() {
        stdinStreamContinuation?.finish()
        stdinStreamContinuation = nil
        stdinWriterTask = nil
    }

    private func cleanup() {
        sessionTask?.cancel()
        sessionTask = nil
        stdinWriter = nil
        finishStdinStream()
        // Stop health monitoring
        healthMonitor?.stop()
        healthMonitor = nil

        // Capture references before nil'ing so the Task can use them
        let clientToClose = client
        let jumpClientToClose = jumpClient

        client = nil
        jumpClient = nil

        // Single coordinated cleanup Task. Each close gets a hard timeout: NIO will park indefinitely waiting for
        // a TCP teardown ACK that never arrives if the socket died during iOS
        // suspension. We'd rather leak a closed-but-unconfirmed NIO channel
        // (kernel reclaims the FD) than hold an event-loop thread forever.
        cleanupTask?.cancel()
        cleanupTask = Task {
            do {
                try await withTimeout(seconds: Self.cleanupTimeoutSeconds) {
                    try? await clientToClose?.close()
                }
            } catch {
                Self.logger.warning("Citadel client close timed out — abandoning")
            }
            do {
                try await withTimeout(seconds: Self.cleanupTimeoutSeconds) {
                    try? await jumpClientToClose?.close()
                }
            } catch {
                Self.logger.warning("Jump client close timed out — abandoning")
            }
        }
    }


    // MARK: - Health Monitoring

    /// Start connection health monitoring
    private func startHealthMonitoring() {
        // Check if health monitoring is enabled in settings (defaults to true)
        let healthMonitoringEnabled = SettingsStore.shared.value(Settings.Connections.healthMonitoring)
        guard healthMonitoringEnabled else { return }
        guard let client = client else { return }

        // Get configured probe interval (defaults to 15 seconds)
        let probeInterval = TimeInterval(SettingsStore.shared.value(Settings.Connections.healthProbeInterval))

        let monitor = ConnectionHealthMonitor(client: client, pingInterval: probeInterval)
        monitor.onHealthUpdate = { [weak self] health in
            self?.onHealthUpdate?(health)
        }
        monitor.start()
        self.healthMonitor = monitor
    }

    /// Re-time the live probe loop. `ConnectionHealthMonitor.updateInterval`
    /// rescales its rolling window, drops the samples measured at the old
    /// cadence and restarts the loop, so an interval change applies to the
    /// running session instead of waiting for the next connect.
    func updateHealthProbeInterval(_ newInterval: TimeInterval) {
        healthMonitor?.updateInterval(newInterval)
    }

    /// Stop health monitoring (called when the setting is switched off).
    /// Publishes `.initial` so the tab's indicator drops back to "no data"
    /// rather than freezing on the last measured RTT.
    func stopHealthMonitoring() {
        guard healthMonitor != nil else { return }
        healthMonitor?.stop()
        healthMonitor = nil
        onHealthUpdate?(ConnectionHealth.initial)
    }

    /// Start health monitoring if enabled in settings and connected
    func startHealthMonitoringIfEnabled() {
        guard healthMonitor == nil else { return }
        guard client != nil else { return }
        startHealthMonitoring()
    }

    // MARK: - Authentication Helpers (delegated to SSHConnectionHelper)

    private func buildAuthMethod(for config: SSHConfig) async throws -> SSHAuthenticationMethod {
        try await SSHConnectionHelper.buildAuthMethod(
            for: config,
            sessionName: config.displayName,
            onKeyboardInteractiveChallenge: bannerAwareKeyboardInteractiveHandler
        )
    }

    private func buildAuthMethod(for jumpConfig: SSHConfig.JumpHostConfig) async throws -> SSHAuthenticationMethod {
        try await SSHConnectionHelper.buildAuthMethod(
            for: jumpConfig,
            sessionName: "[Jump Host] \(jumpConfig.displayName)",
            onKeyboardInteractiveChallenge: bannerAwareKeyboardInteractiveHandler
        )
    }

    /// `onKeyboardInteractiveChallenge` with this connection's live auth
    /// banners stamped into every challenge before it reaches the UI.
    ///
    /// The prompt sheet covers the pane on iPhone, and with it the pane's
    /// auth-banner card — precisely when the banner carries the enrolment URL
    /// or the "approve the push on your phone" instruction the challenge is
    /// asking about. Snapshotting at raise time is enough: RFC 4252 §5.4
    /// banners arrive before the auth method that prompts, and each further
    /// keyboard-interactive round raises a fresh challenge and re-snapshots.
    private var bannerAwareKeyboardInteractiveHandler: ((KeyboardInteractiveChallenge) async -> [String]?)? {
        guard let handler = onKeyboardInteractiveChallenge else { return nil }
        // Capture the model rather than `self`: this closure is retained by the
        // auth delegate on the NIO event loop, and it has no business keeping a
        // whole SSH session alive.
        let model = authBannerCardModel
        return { challenge in
            var enriched = challenge
            enriched.authBanners = await MainActor.run { model.current?.items ?? [] }
            return await handler(enriched)
        }
    }

    private func buildHostKeyValidator(for host: String, port: Int, label: String?) -> SSHHostKeyValidator {
        SSHConnectionHelper.buildHostKeyValidator(for: host, port: port, label: label, onValidation: onHostKeyValidation)
    }

    /// Categorize an error into a disconnect reason for the reconnection manager
    private static func categorizeDisconnectReason(_ error: Error) -> ReconnectionManager.DisconnectReason {
        let description = error.localizedDescription.lowercased()

        // Check for network-related errors
        if description.contains("network") ||
           description.contains("internet") ||
           description.contains("connection reset") ||
           description.contains("connection refused") ||
           description.contains("no route to host") ||
           description.contains("unreachable") {
            return .networkLost
        }

        // Check for timeout errors
        if description.contains("timeout") ||
           description.contains("timed out") {
            return .timeout
        }

        // Check for server-initiated close
        if description.contains("closed") ||
           description.contains("disconnected") ||
           description.contains("terminated") {
            return .serverClosed
        }

        // Default to generic error
        return .error(error.localizedDescription)
    }

    /// Check if the error represents a TCP shutdown (network failure)
    /// This is the definitive signal that the TCP connection was lost unexpectedly
    private static func isTCPShutdown(_ error: Error) -> Bool {
        // Check for NIOSSHError.tcpShutdown
        if let sshError = error as? NIOSSHError {
            return sshError.type == .tcpShutdown
        }

        // Also check string representation as fallback
        let description = String(describing: error)
        return description.contains("tcpShutdown") || description.contains("NIOSSHError.tcpShutdown")
    }

    /// Check if the error represents a normal channel close (EOF)
    private static func isChannelEOF(_ error: Error) -> Bool {
        // Check for NIO ChannelError.eof
        if let channelError = error as? ChannelError {
            switch channelError {
            case .eof, .alreadyClosed, .inputClosed, .outputClosed:
                return true
            default:
                return false
            }
        }

        // Also check string representation as fallback
        let description = String(describing: error)
        return description.contains("eof") || description.contains("ChannelError error 6")
    }

    /// Host + hop to blame for an auth or host-key failure, taken from the hop
    /// that was in flight (`connectionHop`) rather than from whether a jump
    /// host is merely configured. Consumers turn `isJumpHost` straight into the
    /// subject of a password prompt and into the host a typed secret is applied
    /// to, so a wrong answer here sends the user's credential to the wrong host.
    var failedHopAttribution: (host: String, isJumpHost: Bool) {
        switch connectionHop {
        case .jumpHost:
            // `.jumpHost` is only ever recorded from a transition carrying the
            // bastion's own host, so `config.jumpHost` is non-nil here. If it
            // somehow is not, fall back to the target rather than force-unwrap:
            // naming a bastion we cannot identify would be worse than a crash.
            guard let jump = config.jumpHost else { return (config.host, false) }
            return (jump.host, true)
        case .target:
            return (config.host, false)
        }
    }

    func categorizeError(_ error: Error) -> Error {
        // Check for Citadel SSHClientError - conforms to Error but not LocalizedError,
        // so NSError bridging produces opaque "error N" messages
        if let sshClientError = error as? SSHClientError {
            switch sshClientError {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedKeyboardInteractiveAuthentication:
                let hop = failedHopAttribution
                return SSHJumpError.authenticationFailed(
                    host: hop.host,
                    isJumpHost: hop.isJumpHost
                )
            case .unsupportedHostBasedAuthentication:
                let hop = failedHopAttribution
                return SSHJumpError.authenticationFailed(
                    host: hop.host,
                    isJumpHost: hop.isJumpHost
                )
            case .channelCreationFailed:
                return SSHConnectionError.sshError(host: config.host, detail: "Failed to open SSH channel")
            @unknown default:
                return SSHConnectionError.sshError(host: config.host, detail: String(describing: sshClientError))
            }
        }

        // Check for host key rejection
        if error is HostKeyRejectedError || error is InvalidHostKey {
            // Same attribution as auth: the target's host key is validated
            // during the tunnelled `jump(to:)`, long after the bastion's was
            // accepted, so a rejection there is the TARGET's — not the bastion's.
            let hop = failedHopAttribution
            return SSHJumpError.hostKeyRejected(
                host: hop.host,
                isJumpHost: hop.isJumpHost
            )
        }

        // Check for NIOSSHError - these produce useless "error 1" when bridged to NSError
        if let sshError = error as? NIOSSHError {
            return SSHConnectionError(nioSSHError: sshError, host: config.host)
        }

        // Check for NIOConnectionError - Happy Eyeballs / TCP connection failures
        if let connError = error as? NIOConnectionError {
            return SSHConnectionError(nioConnectionError: connError, host: config.host)
        }

        // Check for Citadel login timeout (distinct from TCP connect timeout).
        // CitadelError.loginTimeout fires when the SSH handshake + auth exceeds
        // the configured loginTimeout. This timer covers host-key approval too,
        // so it's not specifically an auth failure — map to connectionTimeout
        // to show a clear "timed out" message without triggering re-auth flow.
        // NIO's ChannelError.connectTimeout (TCP-level) is left unmapped and
        // falls through to the default, preserving its connection-failure semantics.
        if let citadelError = error as? CitadelError, citadelError == .loginTimeout {
            return SSHError.connectionTimeout
        }

        // Return original error
        return error
    }

    /// Execute an async operation with a timeout
    /// Used for Citadel connections which don't expose granular timeout control
    private func withConnectionTimeout<T>(
        _ operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add the actual operation
            group.addTask {
                try await operation()
            }

            // Add a timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.connectionTimeout * 1_000_000_000))
                throw SSHError.connectionTimeout
            }

            // Wait for the first task to complete
            guard let result = try await group.next() else {
                throw SSHError.connectionTimeout
            }

            // Cancel the remaining task
            group.cancelAll()

            return result
        }
    }

    nonisolated deinit {
        sessionTask?.cancel()
    }
}

// MARK: - Multi-Key Auth Delegate

/// One key to try during authentication, with an optional OpenSSH user certificate.
/// When a certificate is present, it is offered before the plain key (matching
/// OpenSSH's order: a certificate rejection falls back to the bare public key).
struct SSHAuthKeyCandidate {
    let variant: SSHPrivateKeyVariant
    let certifiedKey: NIOSSHCertifiedPublicKey?

    init(variant: SSHPrivateKeyVariant, certifiedKey: NIOSSHCertifiedPublicKey? = nil) {
        self.variant = variant
        self.certifiedKey = certifiedKey
    }

    /// Wrap the variant in the NIOSSHPrivateKey used for offers/signing.
    var nioPrivateKey: NIOSSHPrivateKey {
        switch variant {
        case .nioSSH(let key):
            return key
        case .rsa(let rsaKey):
            return NIOSSHPrivateKey(custom: rsaKey)
        case .secureEnclaveP256(let key):
            return key
        }
    }

    var legacyRSAAuthenticationKey: NIOSSHPrivateKey? {
        switch variant {
        case .rsa(let rsaKey):
            return rsaKey.legacySHA1Key
        default:
            return nil
        }
    }

    /// Plain-key attempts in preference order. The caller decides whether the
    /// server's RFC 8308 advertisement (or its absence for a legacy peer)
    /// permits the SHA-1 form.
    func plainAuthenticationKeys(allowLegacyRSA: Bool) -> [NIOSSHPrivateKey] {
        var keys = [nioPrivateKey]
        if allowLegacyRSA, let legacyRSAAuthenticationKey {
            keys.append(legacyRSAAuthenticationKey)
        }
        return keys
    }

    var debugLabel: String {
        switch variant {
        case .nioSSH: return "NIO SSH key"
        case .rsa: return "RSA key"
        case .secureEnclaveP256: return "Secure Enclave P-256"
        }
    }
}

/// Auth delegate that supports trying multiple SSH keys in order
/// Used by Citadel for multi-key fallback authentication
final class MultiKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "MultiKeyAuth")

    private let username: String
    private let candidates: [SSHAuthKeyCandidate]
    private let publicKeyAuthMode: NIOSSHUserAuthenticationOffer.Offer.PrivateKey.AuthenticationMode
    private var keyIndex = 0
    private var triedCertForCurrentKey = false
    private var plainKeyAttempt = 0
    private var legacyRSAFallbackKeyIndex: Int?
    private var serverSignatureAlgorithms: Set<String>?

    init(
        username: String,
        candidates: [SSHAuthKeyCandidate],
        publicKeyAuthMode: NIOSSHUserAuthenticationOffer.Offer.PrivateKey.AuthenticationMode = .signedRequest
    ) {
        self.username = username
        self.candidates = candidates
        self.publicKeyAuthMode = publicKeyAuthMode
        let certCount = candidates.filter { $0.certifiedKey != nil }.count
        Self.logger.info("MultiKeyAuthDelegate initialized with \(candidates.count) keys (\(certCount) certified)")
    }

    convenience init(
        username: String,
        privateKeys: [SSHPrivateKeyVariant],
        publicKeyAuthMode: NIOSSHUserAuthenticationOffer.Offer.PrivateKey.AuthenticationMode = .signedRequest
    ) {
        self.init(
            username: username,
            candidates: privateKeys.map { SSHAuthKeyCandidate(variant: $0) },
            publicKeyAuthMode: publicKeyAuthMode
        )
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while keyIndex < candidates.count && availableMethods.contains(.publicKey) {
            let candidate = candidates[keyIndex]
            let position = "\(keyIndex + 1)/\(candidates.count)"

            // Certificate first, plain key on the next call (after USERAUTH_FAILURE).
            if let certifiedKey = candidate.certifiedKey, !triedCertForCurrentKey {
                triedCertForCurrentKey = true
                Self.logger.info("Trying key \(position): \(candidate.debugLabel) with certificate")
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: .privateKey(.init(privateKey: candidate.nioPrivateKey, certifiedKey: certifiedKey, authenticationMode: publicKeyAuthMode))
                ))
                return
            }

            let policyAllowsLegacyRSA = SSHRSASignaturePolicy.shouldAttemptLegacySHA1(
                serverSignatureAlgorithms: serverSignatureAlgorithms
            )
            if legacyRSAFallbackKeyIndex == nil,
               candidate.legacyRSAAuthenticationKey != nil,
               policyAllowsLegacyRSA {
                // Bound the compatibility tax to one RSA candidate so legacy
                // peers cannot consume two MaxAuthTries slots for every key.
                legacyRSAFallbackKeyIndex = keyIndex
            }
            let plainKeys = candidate.plainAuthenticationKeys(
                allowLegacyRSA: legacyRSAFallbackKeyIndex == keyIndex
                    && policyAllowsLegacyRSA
            )
            guard plainKeyAttempt < plainKeys.count else {
                // A second RFC 8308 EXT_INFO may refine the algorithm list
                // after the modern attempt. Skip a now-disallowed fallback
                // without indexing the recomputed array out of bounds.
                keyIndex += 1
                triedCertForCurrentKey = false
                plainKeyAttempt = 0
                continue
            }
            let privateKey = plainKeys[plainKeyAttempt]
            let usesLegacyRSA = plainKeys.count > 1 && plainKeyAttempt == 1
            plainKeyAttempt += 1
            if plainKeyAttempt == plainKeys.count {
                keyIndex += 1
                triedCertForCurrentKey = false
                plainKeyAttempt = 0
            }
            let suffix = usesLegacyRSA ? " using ssh-rsa/SHA-1 fallback" : ""
            Self.logger.info("Trying key \(position): \(candidate.debugLabel)\(suffix)")
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey, authenticationMode: publicKeyAuthMode))
            ))
            return
        }

        // All keys exhausted
        Self.logger.info("All \(self.candidates.count) keys exhausted")
        nextChallengePromise.succeed(nil)
    }

    func serverSignatureAlgorithmsReceived(_ algorithms: [String]) {
        serverSignatureAlgorithms = Set(algorithms)
    }
}

// MARK: - NIO Key Auth Delegate (single key)

/// Auth delegate that wraps NIOSSHPrivateKey for Citadel (single key).
/// With a certificate, offers cert-then-plain (OpenSSH behavior); without one,
/// behavior is identical to the original single-attempt delegate.
final class NIOKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private let legacyRSAKey: NIOSSHPrivateKey?
    private let certifiedKey: NIOSSHCertifiedPublicKey?
    private let publicKeyAuthMode: NIOSSHUserAuthenticationOffer.Offer.PrivateKey.AuthenticationMode
    private var triedCertificate = false
    private var plainKeyAttempt = 0
    private var serverSignatureAlgorithms: Set<String>?

    init(
        username: String,
        privateKey: NIOSSHPrivateKey,
        legacyRSAKey: NIOSSHPrivateKey? = nil,
        certifiedKey: NIOSSHCertifiedPublicKey? = nil,
        publicKeyAuthMode: NIOSSHUserAuthenticationOffer.Offer.PrivateKey.AuthenticationMode = .signedRequest
    ) {
        self.username = username
        self.privateKey = privateKey
        self.legacyRSAKey = legacyRSAKey
        self.certifiedKey = certifiedKey
        self.publicKeyAuthMode = publicKeyAuthMode
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }

        if !triedCertificate, let certifiedKey {
            triedCertificate = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey, certifiedKey: certifiedKey, authenticationMode: publicKeyAuthMode))
            ))
            return
        }

        var plainKeys = [privateKey]
        if SSHRSASignaturePolicy.shouldAttemptLegacySHA1(
            serverSignatureAlgorithms: serverSignatureAlgorithms
        ),
           let legacyRSAKey {
            plainKeys.append(legacyRSAKey)
        }
        guard plainKeyAttempt < plainKeys.count else {
            nextChallengePromise.succeed(nil)
            return
        }

        let key = plainKeys[plainKeyAttempt]
        plainKeyAttempt += 1
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: key, authenticationMode: publicKeyAuthMode))
        ))
    }

    func serverSignatureAlgorithmsReceived(_ algorithms: [String]) {
        serverSignatureAlgorithms = Set(algorithms)
    }
}

// MARK: - None Auth Delegate (Tailscale/WireGuard)


// MARK: - Citadel Host Key Validator

/// Host key validator that performs validation inline without nested Tasks
/// This fixes a bug where the nested Task structure could cause lifecycle issues
/// leading to false "key changed" messages when using jump hosts
final class CitadelHostKeyValidatorDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let hostname: String
    private let port: Int
    private let label: String?
    private let onValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?
    /// CA public keys trusted for this host. When a server presents a host
    /// certificate signed by one of these, validation succeeds silently.
    private let trustedCAKeys: [NIOSSHPublicKey]
    private let logger = Logger(subsystem: "dev.chr33s.shell", category: "CitadelHostKey")

    init(
        hostname: String,
        port: Int,
        label: String?,
        trustedCAKeys: [NIOSSHPublicKey] = [],
        onValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) {
        self.hostname = hostname
        self.port = port
        self.label = label
        self.trustedCAKeys = trustedCAKeys
        self.onValidation = onValidation
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Capture all values BEFORE the Task to avoid any lifecycle issues
        let hostnameCopy = hostname
        let portCopy = port
        let labelCopy = label
        let validationCallback = onValidation

        Task { @MainActor in
            do {
                let result = try await performValidation(
                    hostKey: hostKey,
                    hostname: hostnameCopy,
                    port: portCopy,
                    label: labelCopy,
                    validationCallback: validationCallback
                )
                if result {
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(HostKeyRejectedError())
                }
            } catch {
                logger.error("Host key validation failed: \(error.localizedDescription)")
                validationCompletePromise.fail(error)
            }
        }
    }

    @MainActor
    private func performValidation(
        hostKey: NIOSSHPublicKey,
        hostname: String,
        port: Int,
        label: String?,
        validationCallback: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) async throws -> Bool {
        let labelTag = label ?? "Direct"

        // If the server presented an OpenSSH host certificate, try to validate
        // it against the configured certificate authorities first.
        if let cert = NIOSSHCertifiedPublicKey(hostKey) {
            if validateCertificate(cert, hostname: hostname, port: port, labelTag: labelTag) {
                logger.info("[\(labelTag)] Host certificate validated via trusted CA for \(hostname):\(port) — no prompt")
                return true
            }
            // Certificate present but not validated by any configured CA
            // (untrusted/unknown CA, expired, or hostname not in principals).
            // Fall back to the normal host-key flow on the certificate's
            // underlying base key, so reissued certs that share the same base
            // key won't re-prompt and the user sees the real host key.
            logger.info("[\(labelTag)] Host certificate not validated via CA; falling back to base key for \(hostname):\(port)")
            return try await validatePlainKey(
                cert.key,
                hostname: hostname,
                port: port,
                label: label,
                validationCallback: validationCallback
            )
        }

        // Plain (non-certificate) host key.
        return try await validatePlainKey(
            hostKey,
            hostname: hostname,
            port: port,
            label: label,
            validationCallback: validationCallback
        )
    }

    /// Attempt to validate a presented host certificate against the trusted CAs.
    /// Returns true only when a configured CA signs the cert, the cert is a host
    /// cert, is within its validity window, and the hostname matches its
    /// principals (with wildcard support).
    @MainActor
    private func validateCertificate(
        _ cert: NIOSSHCertifiedPublicKey,
        hostname: String,
        port: Int,
        labelTag: String
    ) -> Bool {
        guard !trustedCAKeys.isEmpty else { return false }

        // NIOSSH's `validate(principal:)` does exact-membership matching only.
        // Host certificates may list wildcard principals (e.g. *.dc1.example.com),
        // so we pre-match the hostname ourselves and hand `validate` a concrete
        // principal that is in the list, preserving its cryptographic checks.
        let principal: String
        if cert.validPrincipals.isEmpty {
            // Empty principals = valid for any host (the CA + our host-pattern
            // scoping already constrain trust).
            principal = hostname
        } else if cert.validPrincipals.contains(hostname) {
            principal = hostname
        } else if let matched = cert.validPrincipals.first(where: {
            SSHHostPatternMatcher.matchGlob(hostname.lowercased(), pattern: $0.lowercased())
        }) {
            principal = matched
        } else {
            let principals = cert.validPrincipals.joined(separator: ", ")
            logger.info("[\(labelTag)] Host cert principals [\(principals)] do not match \(hostname)")
            return false
        }

        do {
            _ = try cert.validate(
                principal: principal,
                type: .host,
                allowedAuthoritySigningKeys: trustedCAKeys,
                acceptableCriticalOptions: []
            )
            return true
        } catch {
            logger.info("[\(labelTag)] Host certificate validation failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Validate a plain (non-certificate) host key against known hosts, prompting
    /// the user when it is new or changed.
    @MainActor
    private func validatePlainKey(
        _ hostKey: NIOSSHPublicKey,
        hostname: String,
        port: Int,
        label: String?,
        validationCallback: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) async throws -> Bool {
        let manager = KnownHostsManager.shared

        // Generate fingerprint and key info
        let fingerprint = generateFingerprint(for: hostKey)
        let keyType = getKeyType(from: hostKey)
        let publicKeyData = try serializePublicKey(hostKey)

        let labelTag = label ?? "Direct"
        logger.info("[\(labelTag)] Validating host key for \(hostname):\(port) - Type: \(keyType)")

        // Check if we have a known host entry
        if let knownHost = manager.getHost(hostname: hostname, port: port) {
            let fingerprintsMatch = knownHost.fingerprint == fingerprint
            let publicKeyDataMatches = knownHost.publicKeyData == publicKeyData

            if fingerprintsMatch || publicKeyDataMatches {
                // Key matches - update last seen and accept
                logger.info("[\(labelTag)] Host key matches known host, accepting")

                if fingerprintsMatch && !publicKeyDataMatches {
                    // Update the stored key format
                    logger.info("[\(labelTag)] Updating stored publicKeyData format")
                    let updatedHost = KnownHost(
                        hostname: hostname,
                        port: port,
                        publicKeyData: publicKeyData,
                        keyType: keyType,
                        fingerprint: fingerprint,
                        firstSeen: knownHost.firstSeen,
                        lastSeen: Date()
                    )
                    manager.addHost(updatedHost)
                } else {
                    manager.updateLastSeen(hostname: hostname, port: port)
                }
                return true
            } else {
                // Key changed - potential MITM attack!
                logger.warning("[\(labelTag)] Host key CHANGED for \(hostname):\(port)! Old: \(knownHost.fingerprint), New: \(fingerprint)")

                // The exact key the user already approved with "Connect Once"
                // this run passes without re-prompting (still not persisted).
                if SessionApprovedHostKeys.shared.matches(hostname: hostname, port: port, publicKeyData: publicKeyData) {
                    logger.info("[\(labelTag)] Key matches session-approved (Connect Once) key, accepting")
                    return true
                }

                let labelPrefix = label.map { "\($0)\n" } ?? ""
                let message = "\(labelPrefix)The host key for \(hostname):\(port) has changed. " +
                    "This could indicate a man-in-the-middle attack!\n\n" +
                    "Previously Trusted:\n\(knownHost.fingerprint)\n\n" +
                    "New Key Received:\n\(fingerprint)"

                let request = HostKeyValidationRequest(message: message, isKeyChanged: true)
                return await handleUserResponse(
                    request,
                    hostname: hostname,
                    port: port,
                    publicKeyData: publicKeyData,
                    keyType: keyType,
                    fingerprint: fingerprint,
                    label: label,
                    validationCallback: validationCallback
                )
            }
        } else {
            // New host - prompt user
            logger.info("[\(labelTag)] New host \(hostname):\(port), requesting user validation")

            if SessionApprovedHostKeys.shared.matches(hostname: hostname, port: port, publicKeyData: publicKeyData) {
                logger.info("[\(labelTag)] Key matches session-approved (Connect Once) key, accepting")
                return true
            }

            let labelPrefix = label.map { "\($0)\n" } ?? ""
            let message = "\(labelPrefix)Do you want to trust this host?\n\n" +
                "Host: \(hostname):\(port)\n" +
                "Key Type: \(keyType)\n\n" +
                "Fingerprint:\n\(fingerprint)"

            let request = HostKeyValidationRequest(message: message, isKeyChanged: false)
            return await handleUserResponse(
                request,
                hostname: hostname,
                port: port,
                publicKeyData: publicKeyData,
                keyType: keyType,
                fingerprint: fingerprint,
                label: label,
                validationCallback: validationCallback
            )
        }
    }

    @MainActor
    private func handleUserResponse(
        _ request: HostKeyValidationRequest,
        hostname: String,
        port: Int,
        publicKeyData: String,
        keyType: String,
        fingerprint: String,
        label: String?,
        validationCallback: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?
    ) async -> Bool {
        let labelTag = label ?? "Direct"

        guard let callback = validationCallback else {
            logger.warning("[\(labelTag)] No validation callback set, rejecting")
            return false
        }

        let result = await callback(request)
        let manager = KnownHostsManager.shared

        switch result {
        case .accept:
            // User accepted - save to known hosts
            let newHost = KnownHost(
                hostname: hostname,
                port: port,
                publicKeyData: publicKeyData,
                keyType: keyType,
                fingerprint: fingerprint
            )
            manager.addHost(newHost)
            logger.info("[\(labelTag)] User accepted host, added to known hosts")
            return true

        case .acceptOnce:
            // Accept but don't persist; remember in-memory so ancillary
            // connections in the same flow (discovery, hole punch) don't
            // strict-reject the key the user just approved.
            SessionApprovedHostKeys.shared.remember(hostname: hostname, port: port, publicKeyData: publicKeyData)
            logger.info("[\(labelTag)] User accepted host for this session only")
            return true

        case .reject:
            logger.info("[\(labelTag)] User rejected host")
            return false
        }
    }

    // MARK: - Key Fingerprint Helpers

    /// SHA256 fingerprint in colon-separated hex (delegates to the shared
    /// formatter so CA imports and host-key storage compute it identically).
    private func generateFingerprint(for hostKey: NIOSSHPublicKey) -> String {
        SSHHostKeyFormatter.fingerprint(for: hostKey)
    }

    /// Get the key type as a string.
    private func getKeyType(from hostKey: NIOSSHPublicKey) -> String {
        SSHHostKeyFormatter.keyType(for: hostKey)
    }

    /// Serialize public key to base64 string for storage.
    private func serializePublicKey(_ hostKey: NIOSSHPublicKey) throws -> String {
        try SSHHostKeyFormatter.base64Blob(for: hostKey)
    }
}

// CancellationChannelBox and CancellationSSHClientBox live in
// SSHCancellationBoxes.swift — shared with SSHConnectionHelper.

// MARK: - Auth banner card

/// The pane's live auth-banner card reads through this conformance.
///
/// `CitadelSSHSession` is the only session `SSHSessionFactory` builds, so
/// without it every `as? SSHAuthBannerCardProviding` cast in the tree failed:
/// `LocalShellSession.updateAuthBannerCardForwarding` cleared its model instead
/// of relaying, and `TerminalScrollView` never hosted the card. All four
/// requirements are met by the protocol's own defaults over
/// `authBannerCardModel`, which the session stores and feeds from
/// `authBannerBuffer`.
extension CitadelSSHSession: SSHAuthBannerCardProviding {}

