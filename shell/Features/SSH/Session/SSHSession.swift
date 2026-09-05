import Foundation
import Network
//import NIO
@preconcurrency import NIOCore
@preconcurrency import NIOSSH
@preconcurrency import NIOPosix
@preconcurrency import NIOTransportServices
import Citadel
import Crypto
import os.log

// MARK: - NIOSSHHandler Sendable Workaround

/// Creates and adds NIOSSHHandler to a channel pipeline.
/// This is a workaround for NIOSSHHandler explicitly marking Sendable as unavailable in Swift 6.
/// Uses synchronous pipeline operations to avoid the Sendable requirement.
/// This is safe because:
/// 1. NIOSSHHandler is only used within its channel pipeline
/// 2. The handler is created and immediately added to the pipeline
/// 3. All operations happen on the channel's event loop
@inline(__always)
nonisolated private func createAndAddSSHHandler(
    to channel: Channel,
    config: SSHClientConfiguration
) -> EventLoopFuture<Void> {
    let handler = NIOSSHHandler(
        role: .client(config),
        allocator: channel.allocator,
        inboundChildChannelInitializer: nil
    )
    // Use synchronous operations to bypass Sendable check on the async addHandler
    do {
        try channel.pipeline.syncOperations.addHandler(handler)
        return channel.eventLoop.makeSucceededVoidFuture()
    } catch {
        return channel.eventLoop.makeFailedFuture(error)
    }
}

/// SSH session that connects to a remote server and provides terminal I/O
@MainActor
final class SSHSession: SSHTerminalSession {
    // Logger is nonisolated because it's accessed from Task groups and other non-main-actor contexts
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHSession")

    let pty: TerminalPTY
    let config: SSHConfig

    private(set) var isRunning: Bool = false
    private var group: NIOTSEventLoopGroup?
    private var connectionChannel: Channel?
    private var sessionTask: Task<Void, Never>?
    private var stopRequested = false

    // Store resolved IP address for .local hostname caching
    private(set) var resolvedIPAddress: String?

    // Store SSH child channel and PTY handler for window resizing
    private var sshChannel: Channel?
    private var ptyHandler: SSHPTYHandler?

    // Connection metadata for Connection Info sheet
    private(set) var connectionStartTime: Date?
    private(set) var negotiatedKeyExchange: String?
    private(set) var negotiatedHostKey: String?
    private(set) var negotiatedCipher: String?
    private(set) var negotiatedMac: String?

    // Store stdin continuation for sending user input
    private var stdinContinuation: AsyncStream<ByteBuffer>.Continuation?

    /// Server auth banners captured during authentication. Written from the
    /// NIO event loop by `SSHBannerHandler`, drained on the main actor.
    private let authBannerBuffer = AuthBannerBuffer()

    func consumeAuthBanners() -> [String] { authBannerBuffer.drain() }

    // Callbacks
    // NOTE: These callbacks may be called from a background thread (PTY handler).
    // Callers must ensure thread-safe handling.
    var onOutput: (@Sendable (String) -> Void)?
    var onOutputData: (@Sendable (Data) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onReady: (() -> Void)?

    // Error callback for connection issues
    var onError: ((Error) -> Void)?

    // Host key validation callback
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)?

    // State change callback for progress indicators
    var onStateChange: ((SSHSessionState) -> Void)?

    // Reconnection support
    var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?
    var supportsAutoReconnect: Bool { true }

    var connectionInfo: ConnectionInfo? {
        guard let startTime = connectionStartTime else { return nil }
        return .ssh(SSHConnectionInfo(
            host: config.host,
            port: config.port,
            username: config.username,
            resolvedIP: resolvedIPAddress,
            connectedAt: startTime,
            jumpHost: nil,
            jumpPort: nil,
            keyExchangeAlgorithm: negotiatedKeyExchange,
            hostKeyAlgorithm: negotiatedHostKey,
            cipherAlgorithm: negotiatedCipher,
            macAlgorithm: negotiatedMac
        ))
    }

    // Auth delegate reference for checking auth state
    private var authDelegate: FlexibleAuthDelegate?

    // Ephemeral private key for connections that don't use stored keys (e.g., EC2 Serial Console)
    private var ephemeralPrivateKey: SSHPrivateKeyVariant?

    // OpenSSH-style escape-character filter (~. disconnect, ~? help, etc.)
    private let escapeFilter = SSHEscapeFilter()

    /// Ensures onSessionEnd fires at most once. Set by `fireSessionEnd()`.
    private var didFireSessionEnd: Bool = false

    /// Idempotent helper for firing `onSessionEnd`. Safe to call from stop(),
    /// the session-task exit path, or the escape-filter disconnect handler.
    private func fireSessionEnd() {
        guard !didFireSessionEnd else { return }
        didFireSessionEnd = true
        onSessionEnd?()
    }

    /// Transitions to a new state and notifies the callback
    private func transition(to state: SSHSessionState) {
        onStateChange?(state)
    }

    /// Creates a new SSH session with the given PTY and configuration
    init(pty: TerminalPTY, config: SSHConfig) {
        self.pty = pty
        self.config = config
        wireEscapeFilter()
    }

    /// Creates an SSH session with a directly-provided ephemeral private key.
    /// Used for keys that aren't stored in SSHKeyManager (e.g., EC2 Serial Console).
    init(pty: TerminalPTY, config: SSHConfig, ephemeralKey: SSHPrivateKeyVariant) {
        self.pty = pty
        self.config = config
        self.ephemeralPrivateKey = ephemeralKey
        wireEscapeFilter()
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
        escapeFilter.onListForwards = { [weak self] in
            // NIOSSH SSHSession doesn't manage port forwards — always report none.
            self?.onOutput?(SSHEscapeFilter.noForwardsMessage())
        }
    }

    private func formatConnectionInfoForEcho() -> String {
        var lines: [String] = []
        lines.append("\(config.username)@\(config.host):\(config.port)")
        if let kex = negotiatedKeyExchange { lines.append("kex:    \(kex)") }
        if let cipher = negotiatedCipher { lines.append("cipher: \(cipher)") }
        if let mac = negotiatedMac { lines.append("mac:    \(mac)") }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    /// Starts the SSH session by connecting to the remote server
    func start() async throws {
        guard !isRunning else { return }
        stopRequested = false

        // Reset one-shot per-run state so a reused session object starts clean.
        didFireSessionEnd = false
        escapeFilter.reset()

        Self.logger.info("Starting SSH connection to \(self.config.displayName)")

        // Signal connecting state for progress indicator
        transition(to: .connecting(host: config.host, isJumpHost: false))

        // Get known hosts manager on MainActor to avoid concurrency warning
        let knownHostsManager = await MainActor.run { KnownHostsManager.shared }
        var connectedChannel: Channel?

        do {
            // Prepare authentication based on config
            let authDelegate: NIOSSHClientUserAuthenticationDelegate

            // Check for ephemeral key first (used by EC2 Serial Console)
            if let ephemeralKey = ephemeralPrivateKey {
                Self.logger.info("Using ephemeral SSH key authentication")
                switch ephemeralKey {
                case .nioSSH:
                    Self.logger.info("Using ephemeral NIO SSH key (Ed25519/ECDSA)")
                case .rsa:
                    Self.logger.info("Using ephemeral RSA key")
                case .secureEnclaveP256:
                    Self.logger.info("Using ephemeral Secure Enclave P-256 key")
                #if targetEnvironment(macCatalyst) && STANDALONE
                case .externalAgent:
                    Self.logger.info("Using ephemeral external-agent key")
                #endif
                }

                let delegate = FlexibleAuthDelegate(
                    username: config.username,
                    password: nil,
                    privateKey: ephemeralKey
                )
                self.authDelegate = delegate
                authDelegate = delegate
            } else {
                // Use config-based authentication
                switch config.authMethod {
                case .password(let pwd):
                    Self.logger.info("Using password authentication")
                    let delegate = FlexibleAuthDelegate(
                        username: config.username,
                        password: pwd,
                        privateKey: nil
                    )
                    self.authDelegate = delegate
                    authDelegate = delegate

                case .key(let keyID):
                    Self.logger.info("Using SSH key authentication with key ID: \(keyID.uuidString)")

                    // Load all keys to try: primary key + any fallback keys
                    var keysToTry: [SSHPrivateKeyVariant] = []

                    // Load the primary key
                    let primaryKey = try await SSHKeyManager.shared.loadPrivateKey(id: keyID)
                    keysToTry.append(primaryKey)

                    // Debug: Log which key variant was loaded
                    switch primaryKey {
                    case .nioSSH:
                        Self.logger.info("Loaded primary key: NIO SSH key (Ed25519/ECDSA)")
                    case .rsa:
                        Self.logger.info("Loaded primary key: RSA key from Citadel")
                    case .secureEnclaveP256:
                        Self.logger.info("Loaded primary key: Secure Enclave P-256")
                    #if targetEnvironment(macCatalyst) && STANDALONE
                    case .externalAgent:
                        Self.logger.info("Loaded primary key: external SSH agent")
                    #endif
                    }

                    // Load fallback keys if present
                    if let fallbackIDs = config.fallbackKeyIDs {
                        for fallbackID in fallbackIDs {
                            do {
                                let fallbackKey = try await SSHKeyManager.shared.loadPrivateKey(id: fallbackID)
                                keysToTry.append(fallbackKey)
                                Self.logger.info("Loaded fallback key: \(fallbackID.uuidString)")
                            } catch {
                                Self.logger.warning("Failed to load fallback key \(fallbackID.uuidString): \(error.localizedDescription)")
                            }
                        }
                    }

                    Self.logger.info("Total keys to try: \(keysToTry.count)")

                    let delegate = FlexibleAuthDelegate(
                        username: config.username,
                        password: nil,
                        privateKeys: keysToTry
                    )
                    self.authDelegate = delegate
                    authDelegate = delegate

                case .savedPassword:
                    // Caller should resolve config using config.resolvedConfig() before creating session
                    Self.logger.error("Cannot use .savedPassword directly - config must be resolved first")
                    throw SSHError.invalidConfiguration("Saved password must be resolved before creating session")

                case .keyboardInteractive:
                    // The active path is CitadelSSHSession; this legacy NIOSSH path
                    // does not implement keyboard-interactive prompting.
                    Self.logger.error("Keyboard-interactive auth is not supported on the legacy SSHSession path")
                    throw SSHError.invalidConfiguration("Keyboard-interactive authentication is not supported on this connection path")

                case .unknown(let rawType):
                    throw SSHError.invalidConfiguration("Unsupported authentication method '\(rawType)'. Update the app to use this connection.")
                }
            }

            // Create event loop group (NIOTS / Network.framework-backed) so
            // every TCP connect goes via NWConnection. POSIX `connect()` races
            // Tailscale's NAT/DERP path setup outside the home network and
            // intermittently fails to NAT'd peers; NWConnection's pre-flight
            // path evaluation drives that setup before the first SYN.
            let group = NIOTSEventLoopGroup()
            self.group = group

            // Create timeout coordinator for pausing during user interactions
            let timeoutCoordinator = SSHTimeoutCoordinator()

            // Create host key validation delegate
            let hostKeyDelegate = SSHHostKeyDelegate(
                hostname: config.host,
                port: config.port,
                manager: knownHostsManager,
                timeoutCoordinator: timeoutCoordinator,
                onValidationRequired: { [weak self] request in
                    guard let self = self else { return .reject }
                    if let callback = self.onHostKeyValidation {
                        return await callback(request)
                    } else {
                        // No callback set - reject for security
                        Self.logger.warning("No host key validation callback set, rejecting connection")
                        return .reject
                    }
                }
            )

            // Register the app's global NIOSSH extensions once, before creating
            // a configuration that snapshots their negotiation order.
            SSHCustomAlgorithms.ensureRegistered()

            // Log SSH algorithm info for debugging
            if #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) {
                Self.logger.info("SSH client algorithms - KEX: mlkem768x25519-sha256 (PQ), sntrup761x25519-sha512 (PQ), diffie-hellman-group14-sha256/sha1, curve25519-sha256, ecdh-sha2-nistp* | Cipher: aes256-gcm, aes128-gcm, aes256-ctr, aes128-ctr | MAC: hmac-sha2-*-etm@openssh.com, hmac-sha2-* | HostKey: mldsa65/87 (PQ), mldsa44-ed25519 (PQ hybrid), ssh-rsa, ed25519, ecdsa")
            } else {
                Self.logger.info("SSH client algorithms - KEX: sntrup761x25519-sha512 (PQ), diffie-hellman-group14-sha256/sha1, curve25519-sha256, ecdh-sha2-nistp* | Cipher: aes256-gcm, aes128-gcm, aes256-ctr, aes128-ctr | MAC: hmac-sha2-*-etm@openssh.com, hmac-sha2-* | HostKey: mldsa44-ed25519 (PQ hybrid), ssh-rsa, ed25519, ecdsa")
            }

            // Create client bootstrap - build config inside closure to avoid capture issues
            // Capture logger for use in @Sendable closure (Logger is Sendable)
            let logger = Self.logger
            // Capture the (Sendable) banner buffer locally so the @Sendable
            // channelInitializer doesn't capture the MainActor-isolated `self`.
            let authBannerBuffer = self.authBannerBuffer
            var bootstrap = NIOTSConnectionBootstrap(group: group)
                .channelInitializer { channel in
                    // Build configuration inside the closure to ensure proper capture
                    var clientConfig = SSHClientConfiguration(
                        userAuthDelegate: authDelegate,
                        serverAuthDelegate: hostKeyDelegate
                    )

                    // Log default algorithms before modification
                    logger.info("Default KEX algorithms count: \(clientConfig.keyExchangeAlgorithms.count)")
                    for (i, alg) in clientConfig.keyExchangeAlgorithms.enumerated() {
                        logger.info("  KEX[\(i)]: \(alg.keyExchangeAlgorithmNames)")
                    }

                    // Prepend key exchange algorithms in priority order
                    // PQ hybrid first, then DH for AWS compatibility
                    if #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) {
                        clientConfig.keyExchangeAlgorithms.insert(MLKem768X25519Sha256.self, at: 0)
                        clientConfig.keyExchangeAlgorithms.insert(Sntrup761X25519Sha512.self, at: 1)
                        clientConfig.keyExchangeAlgorithms.insert(DiffieHellmanGroup14Sha256.self, at: 2)
                        clientConfig.keyExchangeAlgorithms.insert(DiffieHellmanGroup14Sha1.self, at: 3)
                    } else {
                        clientConfig.keyExchangeAlgorithms.insert(Sntrup761X25519Sha512.self, at: 0)
                        clientConfig.keyExchangeAlgorithms.insert(DiffieHellmanGroup14Sha256.self, at: 1)
                        clientConfig.keyExchangeAlgorithms.insert(DiffieHellmanGroup14Sha1.self, at: 2)
                    }

                    // Add CTR ciphers — ETM first (preferred, required by NixOS hardened sshd)
                    clientConfig.transportProtectionSchemes.append(AES256CTR_ETM.self)
                    clientConfig.transportProtectionSchemes.append(AES128CTR_ETM.self)
                    clientConfig.transportProtectionSchemes.append(AES256CTR.self)
                    clientConfig.transportProtectionSchemes.append(AES128CTR.self)

                    // Log after modification
                    logger.info("Modified KEX algorithms count: \(clientConfig.keyExchangeAlgorithms.count)")
                    for (i, alg) in clientConfig.keyExchangeAlgorithms.enumerated() {
                        logger.info("  KEX[\(i)]: \(alg.keyExchangeAlgorithmNames)")
                    }

                    // Create handshake handler with timeout coordinator
                    // Timeout pauses during host key approval to give user time to verify fingerprint
                    let handshakeHandler = SSHHandshakeHandler(
                        eventLoop: channel.eventLoop,
                        handshakeTimeout: SSHTimeoutConfig.handshakeTimeout,
                        coordinator: timeoutCoordinator
                    )
                    let errorHandler = ErrorHandler()
                    let bannerHandler = SSHBannerHandler { message, _ in
                        authBannerBuffer.append(message)
                    }

                    return createAndAddSSHHandler(to: channel, config: clientConfig)
                        .flatMap { channel.pipeline.addHandler(handshakeHandler) }
                        .flatMap { channel.pipeline.addHandler(errorHandler) }
                        .flatMap { channel.pipeline.addHandler(bannerHandler) }
                }
                // POSIX socket options (SO_REUSEADDR, TCP_NODELAY) and
                // AdaptiveRecvByteBufferAllocator don't apply to NWConnection
                // — Network.framework manages its own buffers and TCP options.
                .connectTimeout(SSHTimeoutConfig.connectionTimeout)
            if SettingsStore.shared.value(Settings.Connections.forceIPv4),
               !config.host.contains(":") {
                bootstrap = bootstrap.configureNWParameters { parameters in
                    if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                        ipOptions.version = .v4
                    }
                }
            }

            // Connect to SSH server (with .local pre-resolution and fallback)
            let resolvedIPv4: String?

            // For .local hostnames, pre-resolve to get routable IPv4
            if config.host.hasSuffix(".local") {
                Self.logger.info("Pre-resolving .local hostname: \(self.config.host)")

                // Try to resolve to routable IPv4 (runs on background thread with timeout)
                if let ipv4 = await NetworkAddressUtils.resolveToRoutableIPv4(hostname: config.host) {
                    // Connect using the resolved IPv4
                    Self.logger.info("Connecting to \(self.config.host) via IPv4: \(ipv4)")
                    connectedChannel = try await bootstrap.connect(host: ipv4, port: config.port).get()
                    resolvedIPv4 = ipv4
                    await MainActor.run {
                        self.resolvedIPAddress = ipv4
                    }
                    Self.logger.info("SSH connected to \(self.config.host) (resolved to \(ipv4))")
                } else {
                    // No routable IPv4, try connecting with hostname as last resort
                    Self.logger.warning("No routable IPv4 for \(self.config.host), trying hostname")
                    connectedChannel = try await bootstrap.connect(host: config.host, port: config.port).get()
                    guard let channel = connectedChannel else { throw CancellationError() }
                    if let remoteAddr = channel.remoteAddress {
                        resolvedIPv4 = extractIPAddress(from: remoteAddr)
                    } else {
                        resolvedIPv4 = nil
                    }
                    await MainActor.run {
                        self.resolvedIPAddress = resolvedIPv4
                    }
                    Self.logger.info("SSH connected to \(self.config.host)")
                }
            } else {
                // Non-.local hostname: check for CGNAT addresses first
                // CGNAT (100.64.0.0/10) is used by VPNs that often lack IPv6 support
                // Force IPv4 to avoid Happy Eyeballs timeout issues
                if let cgnatIP = await NetworkAddressUtils.resolveToCGNATIPv4(hostname: config.host) {
                    Self.logger.info("Detected CGNAT address for \(self.config.host), forcing IPv4: \(cgnatIP)")
                    connectedChannel = try await bootstrap.connect(host: cgnatIP, port: config.port).get()
                    resolvedIPv4 = cgnatIP
                    await MainActor.run {
                        self.resolvedIPAddress = cgnatIP
                    }
                    Self.logger.info("SSH connected to \(self.config.host) via CGNAT IPv4 \(cgnatIP)")
                } else {
                    // Standard connection (Happy Eyeballs will try IPv4/IPv6)
                    connectedChannel = try await bootstrap.connect(host: config.host, port: config.port).get()
                    guard let channel = connectedChannel else { throw CancellationError() }
                    if let remoteAddr = channel.remoteAddress {
                        resolvedIPv4 = extractIPAddress(from: remoteAddr)
                    } else {
                        resolvedIPv4 = nil
                    }
                    await MainActor.run {
                        self.resolvedIPAddress = resolvedIPv4
                    }
                    Self.logger.info("SSH connected to \(self.config.host)")
                }
            }

            try throwIfStopRequested()

            guard let channel = connectedChannel else {
                throw CancellationError()
            }

            await MainActor.run {
                self.connectionChannel = channel
            }

            // Signal authenticating state
            transition(to: .authenticating(host: config.host, isJumpHost: false))

            // Wait for SSH authentication to complete before proceeding
            // This ensures NIOSSHHandler is in a valid state before creating child channels
            do {
                // Access the handler on the event loop to avoid Sendable issues
                let authenticated = channel.eventLoop.flatSubmit {
                    channel.pipeline.handler(type: SSHHandshakeHandler.self).flatMap { handler in
                        handler.authenticated
                    }
                }
                try await authenticated.get()
                try throwIfStopRequested()
                Self.logger.info("SSH authentication completed successfully")
            } catch {
                Self.logger.error("SSH authentication failed: \(error.localizedDescription)")
                try? await channel.close()
                throw SSHError.sshHandshakeFailed(error)
            }

            // Capture connection metadata
            self.connectionStartTime = Date()

            // Query negotiated algorithms from NIOSSHHandler on the event loop
            do {
                let algos = try await channel.eventLoop.flatSubmit {
                    channel.pipeline.handler(type: NIOSSHHandler.self).map { handler in
                        handler.negotiatedAlgorithms
                    }
                }.get()
                if let algos {
                    self.negotiatedKeyExchange = algos.keyExchange
                    self.negotiatedHostKey = algos.hostKey
                    self.negotiatedCipher = algos.cipher
                    self.negotiatedMac = algos.mac
                    Self.logger.info("Negotiated algorithms - KEX: \(algos.keyExchange), HostKey: \(algos.hostKey), Cipher: \(algos.cipher), MAC: \(algos.mac ?? "none")")
                }
            } catch {
                Self.logger.warning("Could not query negotiated algorithms: \(error.localizedDescription)")
            }

            isRunning = true

            // Start PTY session for all SSH connections including EC2 Serial Console
            startPTYSession()

        } catch {
            let errorDetail = String(describing: error)
            Self.logger.error("SSH connection failed: \(errorDetail)")
            isRunning = false

            let connectionChannel = connectedChannel ?? connectionChannel
            self.connectionChannel = nil
            let group = group
            self.group = nil

            // Bound the close — NIO's graceful shutdown can park indefinitely
            // on a dead socket if we lost connectivity mid-handshake.
            Task {
                try? await withTimeout(seconds: 2) {
                    _ = try? await connectionChannel?.close()
                }
                group?.shutdownGracefully { _ in }
            }

            if error is CancellationError || stopRequested || Task.isCancelled {
                throw CancellationError()
            }

            // Signal failed state for progress indicator
            transition(to: .failed)

            // Detect authentication failures and throw a clearer error
            let finalError: Error
            if isAuthenticationError(error) {
                finalError = SSHError.authenticationFailed
            } else if let sshError = error as? NIOSSHError {
                finalError = SSHConnectionError(nioSSHError: sshError, host: config.host)
            } else if let connError = error as? NIOConnectionError {
                finalError = SSHConnectionError(nioConnectionError: connError, host: config.host)
            } else {
                finalError = error
            }

            onError?(finalError)
            throw finalError
        }
    }

    /// Stops the SSH session gracefully
    func stop() {
        Self.logger.info("Stopping SSH session")
        stopRequested = true
        authBannerBuffer.clear()

        // Signal disconnected state for progress indicator
        if isRunning {
            transition(to: .disconnected)
        }

        isRunning = false
        stdinContinuation?.finish()
        stdinContinuation = nil
        sessionTask?.cancel()
        sessionTask = nil

        // Fire onSessionEnd now so outer owners (e.g., LocalShellSession routing
        // input to an embedded SSH session) drop back to their own mode without
        // waiting for the async transport teardown to complete. The session-task
        // exit path will hit the flag and not double-fire.
        fireSessionEnd()

        // Bound NIO close — see comment in start()'s catch block.
        let channelToClose = connectionChannel
        let groupToShutdown = group
        connectionChannel = nil
        group = nil
        Task {
            try? await withTimeout(seconds: 2) {
                _ = try? await channelToClose?.close()
            }
            groupToShutdown?.shutdownGracefully { _ in }
        }
    }

    private func throwIfStopRequested() throws {
        if stopRequested || Task.isCancelled {
            throw CancellationError()
        }
    }

    /// Sends input data to the SSH channel
    func sendInput(_ data: Data) {
        guard isRunning, let continuation = stdinContinuation else {
            Self.logger.warning("Cannot send input: session not ready")
            return
        }

        // Apply OpenSSH-style escape-character filtering (~. ~? ~# ~I ~~).
        // Unknown and unsupported escapes fall through as literal bytes.
        let filtered = escapeFilter.filter(data)
        guard !filtered.isEmpty else { return }

        // Convert Data to ByteBuffer and send to our stdin stream
        var buffer = ByteBufferAllocator().buffer(capacity: filtered.count)
        buffer.writeBytes(filtered)
        continuation.yield(buffer)
    }

    /// Sets the terminal window size and updates SSH PTY
    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        // For SSH sessions, we don't have a local PTY - just update the stored size
        // (pty.setWindowSize() would fail with .notOpen since there's no local PTY fd)
        pty.windowSize = size

        // Send window change signal to SSH server
        ptyHandler?.sendWindowChange(newSize: size)
    }

    /// Configures TCP keepalive on the connection socket
    private func enableTCPKeepalive() {
        guard let connectionChannel = connectionChannel else {
            return
        }

        connectionChannel.eventLoop.execute {
            // Enable TCP keepalive
            _ = connectionChannel.setOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)

            // Set keepalive time to 30 seconds (time before first probe)
            _ = connectionChannel.setOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPALIVE), value: 30)

            // Set keepalive interval to 10 seconds (time between probes)
            _ = connectionChannel.setOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPINTVL), value: 10)

            // Set keepalive count to 3 (number of failed probes before disconnect)
            _ = connectionChannel.setOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_KEEPCNT), value: 3)
        }
    }

    // MARK: - Private Methods

    /// Starts a PTY session with the SSH server using raw NIOSSH
    private func startPTYSession() {
        guard let connectionChannel = connectionChannel else { return }

        sessionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            do {
                let terminalSize = self.pty.windowSize

                // Create our own stdin stream that we can write to from sendInput()
                let (inputStream, inputContinuation) = AsyncStream.makeStream(of: ByteBuffer.self)
                await MainActor.run {
                    self.stdinContinuation = inputContinuation
                }

                Self.logger.info("Opening PTY session with size \(terminalSize.rows)x\(terminalSize.cols)")

                // Create exit status promise on the connection's event loop
                let exitPromise = connectionChannel.eventLoop.makePromise(of: Int.self)

                // Build exec command (remote command takes precedence over tmux)
                let execCommand: String? = self.config.effectiveExecCommand

                // Create our custom PTY handler
                let ptyHandler = SSHPTYHandler(terminalSize: terminalSize,
                                               exitPromise: exitPromise,
                                               execCommand: execCommand,
                                               term: self.config.effectiveTerminalType)
                await MainActor.run {
                    self.ptyHandler = ptyHandler
                }

                // Set up output callbacks - emit directly without batching for zero-latency response.
                // Only install the raw-data callback when a data handler exists to preserve UTF-8 buffering.
                // Capture callbacks now (they're set before start() is called).
                let onOutputData = self.onOutputData
                let onOutput = self.onOutput
                if let onOutputData {
                    ptyHandler.onOutputData = { data in
                        onOutputData(data)
                    }
                }
                if let onOutput {
                    ptyHandler.onOutput = { output in
                        onOutput(output)
                    }
                } else if let onOutputData {
                    ptyHandler.onOutput = { output in
                        onOutputData(Data(output.utf8))
                    }
                }

                // Create channel promise
                let channelPromise = connectionChannel.eventLoop.makePromise(of: Channel.self)

                // Run channel creation on the event loop
                connectionChannel.eventLoop.execute {
                    // Get the SSH handler and create a child channel
                    guard let sshHandler = try? connectionChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self) else {
                        channelPromise.fail(SSHError.channelCreationFailed)
                        return
                    }

                    sshHandler.createChannel(channelPromise) { childChannel, channelType in
                        guard channelType == .session else {
                            return connectionChannel.eventLoop.makeFailedFuture(SSHError.channelCreationFailed)
                        }

                        // Add our PTY handler to the pipeline
                        return childChannel.pipeline.addHandler(ptyHandler)
                    }
                }

                // Wait for channel creation (will fail immediately if auth failed)
                let childChannel = try await channelPromise.futureResult.get()
                await MainActor.run {
                    self.sshChannel = childChannel
                }

                Self.logger.info("PTY channel created, forwarding input")

                // Enable TCP keepalive to prevent connection timeout
                self.enableTCPKeepalive()

                // Session is now ready - notify callback
                Self.logger.info("SSH session ready, firing onReady callback")
                await MainActor.run {
                    self.transition(to: .running)
                    self.onReady?()
                }

                // Forward input stream to the channel
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Task: Forward input from our stream to SSH
                    group.addTask {
                        for await buffer in inputStream {
                            guard !Task.isCancelled else { break }
                            try await childChannel.writeAndFlush(buffer)
                        }
                    }

                    // Task: Wait for exit status
                    group.addTask {
                        let exitStatus = try await exitPromise.futureResult.get()
                        Self.logger.info("Shell exited with status: \(exitStatus)")
                    }

                    // Wait for either task to complete
                    try await group.next()

                    // Cancel remaining tasks
                    group.cancelAll()
                }

                Self.logger.info("PTY session tasks completed")

                // Session ended
                await MainActor.run {
                    self.isRunning = false
                    self.stdinContinuation?.finish()
                    self.stdinContinuation = nil
                    self.sshChannel = nil
                    self.ptyHandler = nil
                    self.fireSessionEnd()
                }

            } catch {
                if await MainActor.run(resultType: Bool.self, body: { self.isRunning }) {
                    Self.logger.error("SSH PTY error: \(error.localizedDescription)")

                    // Detect authentication failures and use clearer error
                    let finalError: Error = isAuthenticationError(error) ? SSHError.authenticationFailed : error

                    await MainActor.run {
                        // Signal failed state for progress indicator
                        self.transition(to: .failed)

                        self.isRunning = false
                        self.stdinContinuation?.finish()
                        self.stdinContinuation = nil
                        self.sshChannel = nil

                        // Fail the exit promise before releasing the handler
                        // This prevents promise leaks when auth fails before handler is added to pipeline
                        if let handler = self.ptyHandler {
                            handler.failExitPromise(with: finalError)
                        }

                        self.ptyHandler = nil
                        self.onError?(finalError)
                        // Error display handled by onError callback (handleSessionError plays animation + quip)
                    }
                }
            }
        }
    }

    /// Detects if an error is likely an authentication failure
    private func isAuthenticationError(_ error: Error) -> Bool {
        // First, check for explicit NIOSSHError types
        // NIOSSHError is imported via NIOSSH module (line 4)
        if let sshError = error as? NIOSSHError {
            Self.logger.debug("Checking NIOSSHError: \(String(describing: sshError))")

            // Check the error description for authentication-related failures
            // NIOSSHError doesn't expose cases directly, so we check the description
            let errorDesc = "\(sshError)".lowercased()
            if errorDesc.contains("authentication") ||
               errorDesc.contains("userauth") ||
               errorDesc.contains("key exchange failed") {
                Self.logger.info("Detected auth error from NIOSSHError type")
                return true
            }
        }

        let errorString = "\(error)"
        let localizedDesc = error.localizedDescription.lowercased()
        let description = errorString.lowercased()

        Self.logger.debug("Checking error description: '\(error.localizedDescription)'")

        // Check for "End of file" - this happens when SSH server closes connection after auth failure
        if description.contains("end of file") || localizedDesc.contains("end of file") {
            Self.logger.info("Detected auth error from 'end of file' pattern")
            return true
        }

        // Check for ChannelError error 9 (ioOnClosedChannel) in localized description
        // This happens when auth fails and SSH server closes the connection before PTY setup
        if (description.contains("channelerror") && description.contains("error 9")) ||
           (localizedDesc.contains("channelerror") && localizedDesc.contains("error 9")) {
            Self.logger.info("Detected auth error from ChannelError pattern")
            return true
        }

        // Check for explicit authentication keywords
        if description.contains("authentication") ||
           description.contains("auth failed") ||
           description.contains("permission denied") ||
           localizedDesc.contains("authentication") ||
           localizedDesc.contains("auth failed") ||
           localizedDesc.contains("permission denied") {
            Self.logger.info("Detected auth error from keyword pattern")
            return true
        }

        // Check for connection closure patterns that often indicate auth failure
        if description.contains("connection reset") ||
           description.contains("connection closed") ||
           localizedDesc.contains("connection reset") ||
           localizedDesc.contains("connection closed") {
            Self.logger.info("Detected possible auth error from connection closure pattern")
            // Note: This could also be a network issue, but often indicates auth failure
            // when it happens early in the connection
            return true
        }

        Self.logger.debug("Error not recognized as authentication failure")
        return false
    }

    /// Extracts IP address string from a SocketAddress
    private func extractIPAddress(from address: SocketAddress) -> String? {
        switch address {
        case .v4(let addr):
            return addr.host
        case .v6(let addr):
            return addr.host
        case .unixDomainSocket:
            return nil
        }
    }

    nonisolated deinit {
        // Cancel the session task
        sessionTask?.cancel()
    }
}

// MARK: - SSH Error Types

enum SSHError: LocalizedError {
    case channelCreationFailed
    case notConnected
    case authenticationFailed
    case authenticationTimeout
    case connectionTimeout
    case sshHandshakeFailed(Error)
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .channelCreationFailed:
            return "Failed to open SSH channel"
        case .notConnected:
            return "Not connected to SSH server"
        case .authenticationFailed:
            return "SSH authentication failed"
        case .authenticationTimeout:
            return "SSH authentication timed out"
        case .connectionTimeout:
            return "SSH connection timed out"
        case .sshHandshakeFailed(let error):
            return "SSH handshake failed: \(error.localizedDescription)"
        case .invalidConfiguration(let message):
            return "Invalid SSH configuration: \(message)"
        }
    }

    /// Returns true if this error indicates an authentication-related failure
    var isAuthenticationRelated: Bool {
        switch self {
        case .authenticationFailed, .authenticationTimeout:
            return true
        case .sshHandshakeFailed, .channelCreationFailed, .notConnected, .connectionTimeout, .invalidConfiguration:
            return false
        }
    }
}

// MARK: - Authentication Delegates

/// Flexible authentication delegate that supports password, SSH key, and none authentication
/// Supports multiple SSH keys that are tried in order until one succeeds
final class FlexibleAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHAuth")

    private let username: String
    private let password: String?
    private let privateKeys: [SSHPrivateKeyVariant]
    private let useNoneAuth: Bool
    private var triedNone = false
    private var publicKeyIndex = 0  // Track which key we're trying
    private var triedPassword = false
    private var didExhaustMethods = false
    private var pendingLegacyRSAKey: Insecure.RSA.PrivateKey?
    private var didReserveLegacyRSAFallback = false
    private var serverSignatureAlgorithms: Set<String>?

    /// Creates an auth delegate with multiple private keys to try in order
    /// - Parameters:
    ///   - username: SSH username
    ///   - password: Optional password for fallback authentication
    ///   - privateKeys: Array of private keys to try in order
    ///   - useNoneAuth: Whether to try "none" authentication first (for Tailscale/WireGuard)
    init(username: String, password: String?, privateKeys: [SSHPrivateKeyVariant], useNoneAuth: Bool = false) {
        self.username = username
        self.password = password
        self.privateKeys = privateKeys
        self.useNoneAuth = useNoneAuth
    }

    /// Convenience initializer for single key (backward compatibility)
    convenience init(username: String, password: String?, privateKey: SSHPrivateKeyVariant?, useNoneAuth: Bool = false) {
        if let key = privateKey {
            self.init(username: username, password: password, privateKeys: [key], useNoneAuth: useNoneAuth)
        } else {
            self.init(username: username, password: password, privateKeys: [], useNoneAuth: useNoneAuth)
        }
    }

    /// Returns true if all available authentication methods have been exhausted
    func hasExhaustedMethods() -> Bool {
        return didExhaustMethods
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {

        if availableMethods.contains(.publicKey),
           let legacyRSAKey = pendingLegacyRSAKey {
            pendingLegacyRSAKey = nil
            if SSHRSASignaturePolicy.shouldAttemptLegacySHA1(
                serverSignatureAlgorithms: serverSignatureAlgorithms
            ) {
                Self.logger.info("Auth - Trying RSA ssh-rsa/SHA-1 compatibility fallback")
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: .privateKey(.init(privateKey: legacyRSAKey.legacySHA1Key))
                ))
                return
            }
        }

        // Try "none" authentication first if explicitly requested (Tailscale/WireGuard)
        if useNoneAuth && !triedNone {
            triedNone = true
            Self.logger.info("Auth - Trying 'none' authentication (Tailscale/WireGuard)")
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: .none
                )
            )
            return
        }

        // Try each public key in order until we've tried them all
        while publicKeyIndex < privateKeys.count && availableMethods.contains(.publicKey) {
            let privateKey = privateKeys[publicKeyIndex]
            publicKeyIndex += 1

            let key: NIOSSHPrivateKey
            let keyDescription: String
            switch privateKey {
            case .nioSSH(let nioKey):
                Self.logger.info("Auth - Trying key \(self.publicKeyIndex)/\(self.privateKeys.count): NIO SSH key")
                key = nioKey
                keyDescription = "ed25519/ecdsa"
            case .rsa(let rsaKey):
                Self.logger.info("Auth - Trying key \(self.publicKeyIndex)/\(self.privateKeys.count): RSA key")
                key = NIOSSHPrivateKey(custom: rsaKey)
                keyDescription = "rsa"
                if !didReserveLegacyRSAFallback,
                   SSHRSASignaturePolicy.shouldAttemptLegacySHA1(
                    serverSignatureAlgorithms: serverSignatureAlgorithms
                ) {
                    pendingLegacyRSAKey = rsaKey
                    didReserveLegacyRSAFallback = true
                }
            case .secureEnclaveP256(let nioKey):
                // Native NIOSSH Secure Enclave key — signing stays in the enclave
                Self.logger.info("Auth - Trying key \(self.publicKeyIndex)/\(self.privateKeys.count): Secure Enclave P-256")
                key = nioKey
                keyDescription = "secure-enclave-p256"
            #if targetEnvironment(macCatalyst) && STANDALONE
            case .externalAgent(let reference):
                // Signature comes from the external agent over its unix socket
                Self.logger.info("Auth - Trying key \(self.publicKeyIndex)/\(self.privateKeys.count): external agent (\(reference.algorithm))")
                guard let agentNIO = try? createExternalAgentPrivateKey(reference: reference) else {
                    Self.logger.error("Auth - Unsupported external-agent algorithm \(reference.algorithm), skipping key")
                    continue
                }
                key = NIOSSHPrivateKey(custom: agentNIO)
                keyDescription = "ssh-agent-\(reference.algorithm)"
            #endif
            }

            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: key))
            )
            Self.logger.info("Auth - Sending public key auth offer")
            nextChallengePromise.succeed(offer)
            return
        }

        // Fall back to password authentication if available and not yet tried
        if let password = password, availableMethods.contains(.password), !triedPassword {
            triedPassword = true
            Self.logger.info("Auth - Trying password authentication")
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: .password(.init(password: password))
                )
            )
            return
        }

        // No suitable authentication method or all methods exhausted
        Self.logger.info("Auth - No more authentication methods to try (tried \(self.publicKeyIndex) keys)")
        didExhaustMethods = true
        // Fail the promise with authentication error instead of succeeding with nil
        // This causes NIOSSH to immediately propagate the error
        nextChallengePromise.fail(SSHError.authenticationFailed)
    }

    func serverSignatureAlgorithmsReceived(_ algorithms: [String]) {
        serverSignatureAlgorithms = Set(algorithms)
    }
}

/// Observes `NIOUserAuthBannerEvent`, writes the (truncated) banner text to the
/// SSH debug log, and forwards the full banner to `onBanner` for inline display.
/// Server banners are MOTD-style notices and `ssh -vv` prints them.
/// Runs on NIO event loop - marked nonisolated and @unchecked Sendable.
nonisolated final class SSHBannerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    /// Called on the NIO event loop with the full (untruncated) banner message
    /// and language tag when the server sends an auth banner.
    private let onBanner: (@Sendable (_ message: String, _ languageTag: String) -> Void)?

    init(onBanner: (@Sendable (_ message: String, _ languageTag: String) -> Void)? = nil) {
        self.onBanner = onBanner
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let banner = event as? NIOUserAuthBannerEvent {
            onBanner?(banner.message, banner.languageTag)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// Error handler for SSH connection - propagates errors to let SSHHandshakeHandler capture them
/// Runs on NIO event loop - marked nonisolated and @unchecked Sendable for Swift 6 compatibility
nonisolated final class ErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    private static let loggerInstance = Logger(subsystem: "dev.chr33s.shell", category: "SSHError")

    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Self.loggerInstance.error("SSH connection error: \(error.localizedDescription)")
        // Propagate the error instead of immediately closing
        // This allows SSHHandshakeHandler to capture it and fail its promise
        // The channel will be closed by the session code after handling the error
        context.fireErrorCaught(error)
    }
}
