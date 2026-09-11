//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Configuration for an SSH client.
public struct SSHClientConfiguration {
    /// The user authentication delegate to be used with this client.
    public var userAuthDelegate: NIOSSHClientUserAuthenticationDelegate

    /// The server authentication delegate to be used with this client.
    public var serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate

    /// The global request delegate to be used with this client.
    public var globalRequestDelegate: GlobalRequestDelegate

    /// The enabled TransportProtectionSchemes
    public var transportProtectionSchemes: [NIOSSHTransportProtection.Type] = SSHConnectionStateMachine.bundledTransportProtectionSchemes

    /// The enabled KeyExchangeAlgorithms
    public var keyExchangeAlgorithms: [NIOSSHKeyExchangeAlgorithmProtocol.Type] = SSHKeyExchangeStateMachine.bundledKeyExchangeImplementations

    /// The maximum packet size that this NIOSSH client will accept
    public var maximumPacketSize = SSHPacketParser.defaultMaximumPacketSize

    /// The initial receive window size advertised for each SSH child channel.
    /// OpenSSH uses 64 * 32KiB (2MiB) for TCP forwarding channels.
    public var initialChannelWindowSize = SSHPacketParser.defaultMaximumPacketSize * 64

    /// The window size advertised in SSH_MSG_CHANNEL_OPEN messages.
    /// When set to a value smaller than `initialChannelWindowSize`, channels start
    /// with a small receive window (preventing burst saturation of the TCP pipe)
    /// and immediately ramp up to `initialChannelWindowSize` after the first data
    /// arrives via WindowAdjust. 0 means use `initialChannelWindowSize` (default).
    public var channelOpenWindowSize: Int = 0

    /// Maximum total outstanding WindowAdjust bytes across all child channels.
    /// When set to a positive value, limits the aggregate flow control credit to prevent
    /// data from saturating the shared TCP pipe and blocking control messages
    /// (like ChannelOpenConfirmation). 0 means unlimited (default).
    public var maximumAggregateWindowSize: Int = 0

    /// The trusted certificate authority public keys for host authentication.
    /// When set, hosts presenting certificates signed by these CAs will be authenticated
    /// if the certificate is valid and the principal matches the hostname.
    public var trustedHostCAKeys: [NIOSSHPublicKey] = []
    
    /// The hostname that this client is connecting to.
    /// This is used for validating host certificates when `trustedHostCAKeys` is configured.
    /// If not set, host certificate validation will accept any hostname.
    public var hostname: String?

    /// Whether the client advertises OpenSSH host-certificate algorithms
    /// (`*-cert-v01@openssh.com`) in its KEXINIT proposal.
    ///
    /// When `true`, the cert variants are offered ahead of the plain host-key
    /// algorithms, so a certificate-capable server will present a host
    /// certificate. The parsed certificate is delivered to the server-auth
    /// delegate's `validateHostKey` as a `.certified` `NIOSSHPublicKey` (the
    /// caller is then free to validate it against its own trusted CAs and
    /// decide how to handle failures). This is independent of
    /// `trustedHostCAKeys`: leaving that empty keeps certificate handling in
    /// the delegate rather than failing the connection inside key exchange.
    ///
    /// Defaults to `false`, so a client that does not opt in negotiates exactly
    /// as before.
    public var advertiseHostCertificateAlgorithms: Bool = false

    public init(userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
                serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate,
                globalRequestDelegate: GlobalRequestDelegate? = nil)
    {
        self.userAuthDelegate = userAuthDelegate
        self.serverAuthDelegate = serverAuthDelegate
        self.globalRequestDelegate = globalRequestDelegate ?? DefaultGlobalRequestDelegate()
    }
}
