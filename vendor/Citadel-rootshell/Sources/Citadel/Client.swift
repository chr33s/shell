import Foundation
import NIOCore
import NIOPosix
import Crypto
import Logging
import NIOSSH

extension SSHAlgorithms.Modification<NIOSSHTransportProtection.Type> {
    func apply(to configuration: inout [any NIOSSHTransportProtection.Type]) {
        switch self {
        case .add(let algorithms):
            configuration.append(contentsOf: algorithms)

            for algorithm: any NIOSSHTransportProtection.Type in algorithms {
                NIOSSHAlgorithms.register(transportProtectionScheme: algorithm)
            }
        case .replace(with: let algorithms):
            configuration = algorithms

            for algorithm in algorithms {
                NIOSSHAlgorithms.register(transportProtectionScheme: algorithm)
            }
        case .prepend(let algorithms):
            configuration.insert(contentsOf: algorithms, at: 0)

            for algorithm: any NIOSSHTransportProtection.Type in algorithms {
                NIOSSHAlgorithms.register(transportProtectionScheme: algorithm)
            }
        }
    }
}

extension SSHAlgorithms.Modification<NIOSSHKeyExchangeAlgorithmProtocol.Type> {
    func apply(to configuration: inout [any NIOSSHKeyExchangeAlgorithmProtocol.Type]) {
        switch self {
        case .add(let algorithms):
            configuration.append(contentsOf: algorithms)

            for algorithm in algorithms {
                NIOSSHAlgorithms.register(keyExchangeAlgorithm: algorithm)
            }
        case .replace(with: let algorithms):
            configuration = algorithms

            for algorithm in algorithms {
                NIOSSHAlgorithms.register(keyExchangeAlgorithm: algorithm)
            }
        case .prepend(let algorithms):
            configuration.insert(contentsOf: algorithms, at: 0)

            for algorithm in algorithms {
                NIOSSHAlgorithms.register(keyExchangeAlgorithm: algorithm)
            }
        }
    }
}

extension SSHAlgorithms.Modification<(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)>{
    func register() {
        let values: [(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)]
        switch self {
        case .add(let algorithms), .prepend(let algorithms):
            values = algorithms
        case .replace(with: let algorithms):
            values = algorithms
        }

        for registration in groupedPublicKeyAlgorithms(values) {
            NIOSSHAlgorithms.register(
                publicKey: registration.publicKey,
                signatures: registration.signatures
            )
        }
    }
}

private func groupedPublicKeyAlgorithms(
    _ algorithms: [(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)]
) -> [(
    publicKey: NIOSSHPublicKeyProtocol.Type,
    signatures: [NIOSSHSignatureProtocol.Type]
)] {
    var result: [(
        publicKey: NIOSSHPublicKeyProtocol.Type,
        signatures: [NIOSSHSignatureProtocol.Type]
    )] = []

    for (publicKey, signature) in algorithms {
        if let index = result.firstIndex(where: {
            ObjectIdentifier($0.publicKey) == ObjectIdentifier(publicKey)
        }) {
            if !result[index].signatures.contains(where: {
                ObjectIdentifier($0) == ObjectIdentifier(signature)
            }) {
                result[index].signatures.append(signature)
            }
        } else {
            result.append((publicKey: publicKey, signatures: [signature]))
        }
    }
    return result
}

public struct SSHAlgorithms: Sendable {
    /// Represents a modification to a list of items.
    ///
    /// - replace: Replaces the existing list of items with the given list of items.
    /// - add: Adds the given list of items to the list of items.
    public enum Modification<T: Sendable>: Sendable {
        case replace(with: [T])
        case add([T])
        /// Inserts algorithms at the front of the list (highest priority).
        case prepend([T])
    }
    
    /// The enabled TransportProtectionSchemes.
    public var transportProtectionSchemes: Modification<NIOSSHTransportProtection.Type>?
    
    /// The enabled KeyExchangeAlgorithms
    public var keyExchangeAlgorithms: Modification<NIOSSHKeyExchangeAlgorithmProtocol.Type>?

    /// Key exchange algorithms to insert at the front (highest priority).
    /// Applied before `keyExchangeAlgorithms`. Use this for algorithms that
    /// should be preferred over NIOSSH's built-in defaults.
    public var preferredKeyExchangeAlgorithms: [any NIOSSHKeyExchangeAlgorithmProtocol.Type]?

    public var publicKeyAlgorihtms: Modification<(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)>?

    /// Public key algorithms to insert at the front (highest priority).
    /// These are advertised before NIOSSH's built-in host key algorithms during negotiation.
    public var preferredPublicKeyAlgorithms: [(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)]?

    func apply(to clientConfiguration: inout SSHClientConfiguration) {
        // Prepend preferred algorithms first (highest priority)
        if let preferred = preferredKeyExchangeAlgorithms {
            for algorithm in preferred {
                NIOSSHAlgorithms.register(keyExchangeAlgorithm: algorithm)
            }
            clientConfiguration.keyExchangeAlgorithms.insert(contentsOf: preferred, at: 0)
        }
        transportProtectionSchemes?.apply(to: &clientConfiguration.transportProtectionSchemes)
        keyExchangeAlgorithms?.apply(to: &clientConfiguration.keyExchangeAlgorithms)
        registerPublicKeyAlgorithms()
    }

    func apply(to serverConfiguration: inout SSHServerConfiguration) {
        if let preferred = preferredKeyExchangeAlgorithms {
            for algorithm in preferred {
                NIOSSHAlgorithms.register(keyExchangeAlgorithm: algorithm)
            }
            serverConfiguration.keyExchangeAlgorithms.insert(contentsOf: preferred, at: 0)
        }
        transportProtectionSchemes?.apply(to: &serverConfiguration.transportProtectionSchemes)
        keyExchangeAlgorithms?.apply(to: &serverConfiguration.keyExchangeAlgorithms)
        registerPublicKeyAlgorithms()
    }

    /// Registers the default/custom public-key parsers and their associated
    /// signature parsers without applying transport configuration.
    ///
    /// Apps that need to parse keys before connecting can call this same
    /// source of truth used by ``apply(to:)``.
    public func registerPublicKeyAlgorithms() {
        if let preferredPublicKeyAlgorithms {
            for registration in groupedPublicKeyAlgorithms(preferredPublicKeyAlgorithms) {
                NIOSSHAlgorithms.registerPreferred(
                    publicKey: registration.publicKey,
                    signatures: registration.signatures
                )
            }
        }
        publicKeyAlgorihtms?.register()
    }
    
    public init() {}

    public static let all: SSHAlgorithms = {
        var algorithms = SSHAlgorithms()

        algorithms.transportProtectionSchemes = .add([
            AES256CTR_ETM.self,   // ETM preferred (more secure)
            AES128CTR_ETM.self,
            AES256CTR.self,       // EaM fallback
            AES128CTR.self
        ])

        // Match OpenSSH: PQ KEX first, classical host signatures first. The
        // canonical hybrid follows RSA; experimental formats remain parsable.
        algorithms.preferredKeyExchangeAlgorithms = [Sntrup761X25519Sha512.self]
        if #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) {
            algorithms.preferredKeyExchangeAlgorithms?.insert(MLKem768X25519Sha256.self, at: 0)
        }
        var publicKeys: [(NIOSSHPublicKeyProtocol.Type, NIOSSHSignatureProtocol.Type)] = [
            (Insecure.RSA.PublicKey.self, Insecure.RSA.Signature.self),
            (Insecure.RSA.PublicKey.self, Insecure.RSA.SHA1Signature.self),
            (MLDSA44Ed25519SSH.PublicKey.self, MLDSA44Ed25519SSH.Signature.self),
            (LegacyMLDSA44Ed25519SSH.PublicKey.self, LegacyMLDSA44Ed25519SSH.Signature.self),
            (MLDSA44SSH.PublicKey.self, MLDSA44SSH.Signature.self),
        ]
        if #available(iOS 26, macOS 26, macCatalyst 26, visionOS 26, *) {
            publicKeys += [
                (MLDSA65SSH.PublicKey.self, MLDSA65SSH.Signature.self),
                (MLDSA87SSH.PublicKey.self, MLDSA87SSH.Signature.self),
            ]
        }
        algorithms.publicKeyAlgorihtms = .add(publicKeys)

        // Classical DH appended after NIOSSH defaults (fallback for AWS etc.)
        algorithms.keyExchangeAlgorithms = .add([
            DiffieHellmanGroup14Sha1.self,
            DiffieHellmanGroup14Sha256.self
        ])

        return algorithms
    }()


}

/// Represents an SSH connection.
public final class SSHClient {
    private(set) var session: SSHClientSession
    private var userInitiatedClose = false
    let authenticationMethod: () -> SSHAuthenticationMethod
    let hostKeyValidator: SSHHostKeyValidator
    internal var connectionSettings = SSHConnectionPoolSettings()
    private let algorithms: SSHAlgorithms
    private let protocolOptions: Set<SSHProtocolOption>
    private var onDisconnect: (@Sendable () -> ())?
    public let logger = Logger(label: "nl.orlandos.citadel.client")
    public var isConnected: Bool {
        session.channel.isActive
    }
    
    /// The event loop that this SSH connection is running on.
    public var eventLoop: EventLoop {
        session.channel.eventLoop
    }
    
    init(
        session: SSHClientSession,
        authenticationMethod: @escaping @autoclosure () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption>
    ) {
        self.session = session
        self.authenticationMethod = authenticationMethod
        self.hostKeyValidator = hostKeyValidator
        self.algorithms = algorithms
        self.protocolOptions = protocolOptions
        
        onNewSession(session)
    }
    
    public func onDisconnect(perform onDisconnect: @escaping @Sendable () -> ()) {
        self.onDisconnect = onDisconnect
    }

    /// Connects to an SSH server.
    /// - settings: The settings to use for the connection.
    /// - Returns: An SSH client.
    public static func connect(
        to settings: SSHClientSettings
    ) async throws -> SSHClient {
        let session = try await SSHClientSession.connect(settings: settings)
        
        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }

    /// Connects to an SSH server.
    /// - settings: The settings to use for the connection.
    /// - Returns: An SSH client.
    public static func connect(
        on channel: Channel,
        settings: SSHClientSettings
    ) async throws -> SSHClient {
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        // Dispatch to the channel's event loop — addHandlers uses
        // syncOperations which requires the caller to be on the event loop.
        try await channel.eventLoop.flatSubmit {
            SSHClientSession.addHandlers(
                on: channel,
                inboundChannelHandler: inboundChannelHandler,
                settings: settings
            )
        }.get()
        
        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let handshakeHandler = try await channel.pipeline.handler(type: ClientHandshakeHandler.self).get()
        let session = try await handshakeHandler.authenticated.map {
            SSHClientSession(channel: channel, inboundChannelHandler: inboundChannelHandler, sshHandler: sshHandler)
        }.get()

        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }

    public func jump(to settings: SSHClientSettings) async throws -> SSHClient {
        let originatorAddress = try SocketAddress(ipAddress: "fe80::1", port: 22)
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        let channel = try await self.createDirectTCPIPChannel(
            using: SSHChannelType.DirectTCPIP(
                targetHost: settings.host,
                targetPort: settings.port,
                originatorAddress: originatorAddress
            )
        ) { channel in
            SSHClientSession.addHandlers(
                on: channel,
                inboundChannelHandler: inboundChannelHandler,
                settings: settings
            )
        }
        
        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let handshakeHandler = try await channel.pipeline.handler(type: ClientHandshakeHandler.self).get()
        let session = try await handshakeHandler.authenticated.map {
            SSHClientSession(channel: channel, inboundChannelHandler: inboundChannelHandler, sshHandler: sshHandler)
        }.get()

        return SSHClient(
            session: session,
            authenticationMethod: settings.authenticationMethod(),
            hostKeyValidator: settings.hostKeyValidator,
            algorithms: settings.algorithms,
            protocolOptions: settings.protocolOptions
        )
    }
    
    /// Connects to an SSH server.
    /// - Parameters:
    ///  - channel: The channel to use for the connection.
    /// - authenticationMethod: The authentication method to use. See `SSHAuthenticationMethod` for more information.
    /// - hostKeyValidator: The host key validator to use. See `SSHHostKeyValidator` for more information.
    /// - algorithms: The algorithms to use. See `SSHAlgorithms` for more information.
    /// - protocolOptions: The protocol options to use. See `SSHProtocolOption` for more information.
    /// - Returns: An SSH client.
    public static func connect(
        on channel: Channel,
        authenticationMethod: @escaping @autoclosure () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = []
    ) async throws -> SSHClient {
        let inboundChannelHandler = SSHClientInboundChannelHandler()
        try await SSHClientSession.addHandlers(
            on: channel,
            authenticationMethod: authenticationMethod(),
            inboundChannelHandler: inboundChannelHandler,
            hostKeyValidator: hostKeyValidator,
            protocolOptions: protocolOptions
        ).get()
        
        let sshHandler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        let session = SSHClientSession(channel: channel, inboundChannelHandler: inboundChannelHandler, sshHandler: sshHandler)
        
        return SSHClient(
            session: session,
            authenticationMethod: authenticationMethod(),
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions
        )
    }
    
    /// Connects to an SSH server.
    /// - Parameters:
    /// - host: The host to connect to.
    /// - port: The port to connect to. Defaults to 22.
    /// - authenticationMethod: The authentication method to use. See `SSHAuthenticationMethod` for more information.
    /// - hostKeyValidator: The host key validator to use. See `SSHHostKeyValidator` for more information.
    /// - reconnect: The reconnect mode to use. See `SSHReconnectMode` for more information.
    /// - algorithms: The algorithms to use. See `SSHAlgorithms` for more information.
    /// - protocolOptions: The protocol options to use. See `SSHProtocolOption` for more information.
    /// - group: The event loop group to use. Defaults to a single-threaded event loop group.
    /// - channelHandlers: Pass in an array of channel prehandlers that execute first. Default empty array
    /// - connectTimeout: Pass in the time before the connection times out. Default 30 seconds.
    /// - Returns: An SSH client.
    public static func connect(
        host: String,
        port: Int = 22,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator,
        reconnect: SSHReconnectMode,
        algorithms: SSHAlgorithms = SSHAlgorithms(),
        protocolOptions: Set<SSHProtocolOption> = [],
        group: MultiThreadedEventLoopGroup = .singleton,
        channelHandlers: [ChannelHandler] = [],
        connectTimeout: TimeAmount = .seconds(30),
        loginTimeout: TimeAmount = .seconds(60)
    ) async throws -> SSHClient {
        var settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: { authenticationMethod },
            hostKeyValidator: hostKeyValidator
        )
        settings.algorithms = algorithms
        settings.protocolOptions = protocolOptions
        settings.group = group
        settings.channelHandlers = channelHandlers
        settings.connectTimeout = connectTimeout
        settings.loginTimeout = loginTimeout
        let session = try await SSHClientSession.connect(
            settings: settings
        )
        
        let client = SSHClient(
            session: session,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            algorithms: algorithms,
            protocolOptions: protocolOptions
        )
        
        client.connectionSettings.loginTimeout = loginTimeout

        switch reconnect.mode {
        case .always:
            client.connectionSettings.reconnect = .always(to: host, port: port)
        case .once:
            client.connectionSettings.reconnect = .once(to: host, port: port)
        case .never:
            client.connectionSettings.reconnect = .never
        }

        return client
    }
    
    private func onNewSession(_ session: SSHClientSession) {
        session.channel.closeFuture.whenComplete { [weak self] _ in
            self?.onClose()
        }
    }
    
    private func onClose() {
        Task {
            self.onDisconnect?()
            
            switch connectionSettings.reconnect.mode {
            case .never:
                return
            case .once(let host, let port):
                _ = try? await self.recreateSession(host: host, port: port)
            case .always(let host, let port):
                func tryAgain() async throws {
                    do {
                        try await self.recreateSession(host: host, port: port)
                    } catch {
                        return try await tryAgain()
                    }
                }
                
                _ = try? await tryAgain()
            }
        }
    }
    
    private func recreateSession(host: String, port: Int) async throws {
        if userInitiatedClose {
            return
        }

        var settings = SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: self.authenticationMethod,
            hostKeyValidator: self.hostKeyValidator
        )
        settings.algorithms = self.algorithms
        settings.protocolOptions = self.protocolOptions
        settings.group = session.channel.eventLoop
        settings.loginTimeout = connectionSettings.loginTimeout

        self.session = try await SSHClientSession.connect(
            settings: settings
        )

        onNewSession(session)
    }
    
    public func close() async throws {
        self.userInitiatedClose = true
        try await self.session.channel.close()
    }

    /// Retrieves the negotiated SSH algorithms for this connection.
    ///
    /// This queries the underlying NIOSSHHandler on the event loop to get the
    /// key exchange, host key, cipher, and MAC algorithms that were negotiated
    /// during the SSH handshake.
    ///
    /// - Returns: A tuple of negotiated algorithm names, or nil if key exchange hasn't completed.
    public func getNegotiatedAlgorithms() async throws -> (keyExchange: String, hostKey: String, cipher: String, mac: String?)? {
        try await eventLoop.flatSubmit { [sshHandler = self.session.sshHandler] in
            let result = sshHandler.value.negotiatedAlgorithms
            return self.eventLoop.makeSucceededFuture(result)
        }.get()
    }

    // MARK: - Keepalive

    /// Sends an SSH keepalive request and measures round-trip time.
    ///
    /// This sends an SSH global request with `keepalive@openssh.com` and waits for the server's response.
    /// The RTT is measured from when the request is sent to when the response is received.
    ///
    /// - Parameter timeout: Maximum time to wait for a response. Defaults to 10 seconds.
    /// - Returns: Round-trip time in seconds.
    /// - Throws: If the request times out or the connection fails.
    public func sendKeepalive(timeout: TimeAmount = .seconds(10)) async throws -> TimeInterval {
        let startTime = DispatchTime.now()

        logger.debug("Sending keepalive@openssh.com global request")

        // Send keepalive global request with wantReply=true
        _ = try await eventLoop.flatSubmit { [eventLoop, sshHandler = self.session.sshHandler] in
            let responsePromise = eventLoop.makePromise(of: ByteBuffer?.self)
            sshHandler.value.sendCustomGlobalRequest(
                name: "keepalive@openssh.com",
                wantReply: true,
                data: nil,
                promise: responsePromise
            )
            return responsePromise.futureResult
        }.get()

        let endTime = DispatchTime.now()
        let rttNanoseconds = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
        let rttSeconds = Double(rttNanoseconds) / 1_000_000_000.0
        logger.debug("Keepalive response received, RTT: \(rttSeconds)s")
        return rttSeconds
    }
}
