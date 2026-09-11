import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Logging
import NIOConcurrencyHelpers
import Synchronization

final class SSHClientInboundChannelHandler: Sendable {
    typealias TCPIPForwardHandler = @Sendable (Channel, SSHChannelType.ForwardedTCPIP) -> EventLoopFuture<Void>
    typealias AgentChannelHandler = @Sendable (Channel) -> EventLoopFuture<Void>

    let forwardedTCPIPHosts = NIOLockedValueBox(
        [SSHRemotePortForward: TCPIPForwardHandler]()
    )
    let agentHandler = NIOLockedValueBox<AgentChannelHandler?>(nil)

    typealias StreamLocalForwardHandler = @Sendable (Channel) -> EventLoopFuture<Void>

    /// Map from remote socket path (the path bound via
    /// `streamlocal-forward@openssh.com`) to the per-forward callback
    /// that should receive each accepted channel. Keyed by socket path
    /// because that's the only field carried in the
    /// `forwarded-streamlocal@openssh.com` channel-open payload.
    let forwardedStreamLocalHandlers = NIOLockedValueBox(
        [String: StreamLocalForwardHandler]()
    )

    init() {}

    enum HandleRegistrationResult: Error {
        case success
        case alreadyRegistered
    }

    nonisolated func registerForwardedTCPIP(host: String, port: Int, handler: @escaping TCPIPForwardHandler) -> HandleRegistrationResult {
        let bound = SSHRemotePortForward(
            host: host,
            boundPort: port
        )
        return forwardedTCPIPHosts.withLockedValue { hosts in
            if hosts.keys.contains(bound) {
                return .alreadyRegistered
            }
            hosts[bound] = handler
            return .success
        }
    }

    nonisolated func unregisterForwardedTCPIP(host: String, port: Int) {
        let bound = SSHRemotePortForward(
            host: host,
            boundPort: port
        )
        forwardedTCPIPHosts.withLockedValue { hosts in
            _ = hosts.removeValue(forKey: bound)
        }
    }

    /// Registers a handler for SSH agent forwarding channels.
    ///
    /// - Parameter handler: The handler to call when an agent channel is opened.
    nonisolated func registerAgentHandler(_ handler: @escaping AgentChannelHandler) {
        agentHandler.withLockedValue { $0 = handler }
    }

    /// Unregisters the SSH agent forwarding handler.
    nonisolated func unregisterAgentHandler() {
        agentHandler.withLockedValue { $0 = nil }
    }

    /// Registers a per-path handler for incoming streamlocal-forward
    /// channels. Called once per `forwardRemoteUnixSocket(...)` so each
    /// forwarded socket path gets its own handler — multiple forwards
    /// can coexist on the same connection.
    nonisolated func registerStreamLocalForwardHandler(
        path: String,
        handler: @escaping StreamLocalForwardHandler
    ) -> HandleRegistrationResult {
        forwardedStreamLocalHandlers.withLockedValue { handlers in
            if handlers.keys.contains(path) { return .alreadyRegistered }
            handlers[path] = handler
            return .success
        }
    }

    nonisolated func unregisterStreamLocalForwardHandler(path: String) {
        forwardedStreamLocalHandlers.withLockedValue { handlers in
            _ = handlers.removeValue(forKey: path)
        }
    }

    nonisolated func handleChannel(channel: Channel, channelType: SSHChannelType) -> EventLoopFuture<Void> {
        switch channelType {
        case .session:
            return channel.eventLoop.makeFailedFuture(CitadelError.unsupported)
        case .directTCPIP:
            return channel.eventLoop.makeFailedFuture(CitadelError.unsupported)
        case .forwardedTCPIP(let forwardedTCPIP):
            return forwardedTCPIPHosts.withLockedValue { hosts in
                let bound = SSHRemotePortForward(
                    host: forwardedTCPIP.listeningHost,
                    boundPort: forwardedTCPIP.listeningPort
                )
                guard let host = hosts[bound] else {
                    return channel.eventLoop.makeFailedFuture(CitadelError.channelCreationFailed)
                }

                return host(channel, forwardedTCPIP)
            }
        case .authAgent:
            return agentHandler.withLockedValue { handler in
                guard let handler = handler else {
                    return channel.eventLoop.makeFailedFuture(CitadelError.unsupported)
                }
                return handler(channel)
            }
        case .forwardedStreamLocal(let info):
            return forwardedStreamLocalHandlers.withLockedValue { handlers in
                guard let handler = handlers[info.socketPath] else {
                    return channel.eventLoop.makeFailedFuture(CitadelError.unsupported)
                }
                return handler(channel)
            }
        case .directStreamLocal:
            // direct-streamlocal is client-initiated; a server must never
            // open one toward us.
            return channel.eventLoop.makeFailedFuture(CitadelError.unsupported)
        }
    }
}

final class ClientHandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let promise: EventLoopPromise<Void>
    private let loginTimeout: TimeAmount
    private var scheduledTimeout: Scheduled<Void>?
    private var completed = false
    private let onBanner: (@Sendable (_ message: String, _ languageTag: String) -> Void)?
    let logger = Logger(label: "nl.orlandos.citadel.handshake")

    /// A future that will be fulfilled when the handshake is complete.
    public var authenticated: EventLoopFuture<Void> {
        promise.futureResult
    }

    init(
        eventLoop: EventLoop,
        loginTimeout: TimeAmount,
        onBanner: (@Sendable (_ message: String, _ languageTag: String) -> Void)? = nil
    ) {
        self.promise = eventLoop.makePromise(of: Void.self)
        self.loginTimeout = loginTimeout
        self.onBanner = onBanner
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.scheduledTimeout = context.eventLoop.scheduleTask(deadline: .now() + loginTimeout) { [weak self] in
            guard let self, !self.completed else { return }
            self.completed = true
            self.promise.fail(CitadelError.loginTimeout)
            context.close(promise: nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            guard !completed else { return }
            completed = true
            scheduledTimeout?.cancel()
            self.promise.succeed(())
        } else if let banner = event as? NIOUserAuthBannerEvent {
            // Surface server auth banners (SSH_MSG_USERAUTH_BANNER) to the
            // consumer, then forward downstream so we stay a good NIO citizen.
            onBanner?(banner.message, banner.languageTag)
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        guard !completed else { return }
        completed = true
        scheduledTimeout?.cancel()
        self.promise.fail(error)
    }

    deinit {
        scheduledTimeout?.cancel()
        struct Disconnected: Error {}
        self.promise.fail(Disconnected())
    }
}

public struct SSHClientSettings: Sendable {
    public var host: String
    public var port: Int
    public var authenticationMethod: @Sendable () -> SSHAuthenticationMethod
    public var hostKeyValidator: SSHHostKeyValidator
    public var algorithms: SSHAlgorithms = SSHAlgorithms()
    public var protocolOptions: Set<SSHProtocolOption> = []
    public var group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    internal var channelHandlers: [ChannelHandler & Sendable] = []
    public var connectTimeout: TimeAmount = .seconds(30)
    public var loginTimeout: TimeAmount = .seconds(60)

    /// Called on the event loop with the server's auth banner message and
    /// language tag (`SSH_MSG_USERAUTH_BANNER`, RFC 4252 §5.4) when one is
    /// received during authentication. Defaults to nil (banner ignored).
    public var onUserAuthBanner: (@Sendable (_ message: String, _ languageTag: String) -> Void)?

    public init(
        host: String,
        port: Int = 22,
        authenticationMethod: @Sendable @escaping () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator
    ) {
        self.host = host
        self.port = port
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
    }
}

final class SSHClientSession: Sendable {
    let channel: Channel
    let sshHandler: NIOLoopBoundBox<NIOSSHHandler>
    let inboundChannelHandler: SSHClientInboundChannelHandler
    
    init(channel: Channel, inboundChannelHandler: SSHClientInboundChannelHandler, sshHandler: NIOSSHHandler) {
        self.channel = channel
        self.inboundChannelHandler = inboundChannelHandler
        self.sshHandler = NIOLoopBoundBox(sshHandler, eventLoop: channel.eventLoop)
    }
    
    /// Creates a new SSH session on the given channel. This allows you to use an existing channel for the SSH session.
    /// - authenticationMethod: The authentication method to use, see `SSHAuthenticationMethod`.
    /// - hostKeyValidator: The host key validator to use, see `SSHHostKeyValidator`.
    /// - algorithms: The algorithms to use, will use the default algorithms if not specified.
    /// - protocolOptions: The protocol options to use, will use the default options if not specified.
    /// - group: The event loop group to use, will use a new group with one thread if not specified.
    static func addHandlers(
        on channel: Channel,
        authenticationMethod: @escaping @Sendable @autoclosure () -> SSHAuthenticationMethod,
        inboundChannelHandler: SSHClientInboundChannelHandler,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = []
    ) -> EventLoopFuture<Void> {
        addHandlers(
            on: channel,
            inboundChannelHandler: SSHClientInboundChannelHandler(),
            settings: SSHClientSettings(
                host: "127.0.0.1",
                port: 22,
                authenticationMethod: authenticationMethod,
                hostKeyValidator: hostKeyValidator
            )
        )
    }

    /// Creates a new SSH session on the given channel. This allows you to use an existing channel for the SSH session.
    /// - channel: The channel to use for the SSH session, could be an existing TCP socket or proxy connection.
    /// - settings: The settings to use for the SSH session.
    static func addHandlers(
        on channel: Channel,
        inboundChannelHandler: SSHClientInboundChannelHandler,
        settings: SSHClientSettings
    ) -> EventLoopFuture<Void> {
        let handshakeHandler = ClientHandshakeHandler(
            eventLoop: channel.eventLoop,
            loginTimeout: settings.loginTimeout,
            onBanner: settings.onUserAuthBanner
        )
        var clientConfiguration = SSHClientConfiguration(
            userAuthDelegate: settings.authenticationMethod(),
            serverAuthDelegate: settings.hostKeyValidator
        )
        
        settings.algorithms.apply(to: &clientConfiguration)
        
        for option in settings.protocolOptions {
            option.apply(to: &clientConfiguration)
        }
        
        do {
            try channel.pipeline.syncOperations.addHandlers(
                NIOSSHHandler(
                    role: .client(clientConfiguration),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { channel, channelType in
                        return inboundChannelHandler.handleChannel(channel: channel, channelType: channelType)
                    }
                ),
                handshakeHandler
            )
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    /// Creates a new SSH session on a new channel. This will connect to the given host and port.
    /// - settings: The settings to use for the SSH session.
    static func connect(
        settings: SSHClientSettings
    ) async throws -> SSHClientSession {
        let eventLoop = settings.group.any()
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        var clientConfiguration = SSHClientConfiguration(
            userAuthDelegate: settings.authenticationMethod(),
            serverAuthDelegate: settings.hostKeyValidator
        )
        
        settings.algorithms.apply(to: &clientConfiguration)
        
        for option in settings.protocolOptions {
            option.apply(to: &clientConfiguration)
        }
        
        let bootstrap = ClientBootstrap(group: eventLoop).channelInitializer { channel in
            return Self.addHandlers(on: channel, inboundChannelHandler: inboundChannelHandler, settings: settings)
        }
        .connectTimeout(settings.connectTimeout)
        .channelOption(ChannelOptions.autoRead, value: true)
        .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_SNDBUF), value: 2048 * 1024)
        .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_RCVBUF), value: 2048 * 1024)
        .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
        
        return try await bootstrap.connect(host: settings.host, port: settings.port).flatMap { channel in
            channel.pipeline.handler(type: ClientHandshakeHandler.self).flatMap { handshakeHandler in
                handshakeHandler.authenticated
            }.flatMap {
                channel.pipeline.handler(type: NIOSSHHandler.self)
            }.map { sshHandler in
                SSHClientSession(channel: channel, inboundChannelHandler: inboundChannelHandler, sshHandler: sshHandler)
            }
        }.get()
    }
    
    /// Creates a new SSH session on a new channel. This will connect to the given host and port.
    /// - Parameters:
    ///  - host: The host to connect to.
    /// - port: The port to connect to.
    /// - authenticationMethod: The authentication method to use, see `SSHAuthenticationMethod`.
    /// - hostKeyValidator: The host key validator to use, see `SSHHostKeyValidator`.
    /// - algorithms: The algorithms to use, will use the default algorithms if not specified.
    /// - protocolOptions: The protocol options to use, will use the default options if not specified.
    /// - group: The event loop group to use, will use a new group with one thread if not specified.
    /// - channelHandlers: Pass in an array of channel prehandlers that execute first. Default empty array
    /// - connectTimeout: Pass in the time before the connection times out. Default 30 seconds.
    static func connect(
        host: String,
        port: Int = 22,
        authenticationMethod: @Sendable @escaping @autoclosure () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = [],
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        channelHandlers: [ChannelHandler] = [],
        connectTimeout: TimeAmount = .seconds(30)
    ) async throws -> SSHClientSession {
        var settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator
        )

        settings.algorithms = algorithms
        settings.protocolOptions = protocolOptions
        settings.group = group
        settings.channelHandlers = channelHandlers
        settings.connectTimeout = connectTimeout
        
        return try await connect(
            settings: settings
        )
    }
}

public struct InvalidHostKey: Error, Equatable {}

/// A host key validator that can be used to validate an SSH host key. This can be used to validate the host key against a set of trusted keys, or to accept any key.
public struct SSHHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private enum Method {
        case trustedKeys(Set<NIOSSHPublicKey>)
        case acceptAnything
        case custom(NIOSSHClientServerAuthenticationDelegate)
    }
    
    private let method: Method
    
    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        switch method {
        case .trustedKeys(let keys):
            if keys.contains(hostKey) {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(InvalidHostKey())
            }
        case .acceptAnything:
            validationCompletePromise.succeed(())
        case .custom(let validator):
            validator.validateHostKey(hostKey: hostKey, validationCompletePromise: validationCompletePromise)
        }
    }
    
    /// Creates a new host key validator that will validate the host key against the given set of trusted keys. If the host key is not in the set, the validation will fail.
    /// - Parameter keys: The set of trusted keys.
    public static func trustedKeys(_ keys: Set<NIOSSHPublicKey>) -> SSHHostKeyValidator {
        SSHHostKeyValidator(method: .trustedKeys(keys))
    }
    
    /// Creates a new host key validator that will accept any host key. This is not recommended for production use.
    public static func acceptAnything() -> SSHHostKeyValidator {
        SSHHostKeyValidator(method: .acceptAnything)
    }
    
    /// Creates a new host key validator that will use the given custom validator. This can be used to implement custom host key validation logic.
    public static func custom(_ validator: NIOSSHClientServerAuthenticationDelegate) -> SSHHostKeyValidator {
        SSHHostKeyValidator(method: .custom(validator))
    }
}
