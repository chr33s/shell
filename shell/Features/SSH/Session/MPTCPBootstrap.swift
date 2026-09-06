//
//  MPTCPBootstrap.swift
//  shell
//
//  Network.framework-backed TCP bootstrap for SSH connections. Every SSH TCP
//  connect goes through NIOTSConnectionBootstrap (NWConnection under the hood)
//  so we get VPN on-demand triggering and VPN-scoped path evaluation —
//  necessary for Tailscale `.ts.net` and any other on-demand NetworkExtension
//  VPN where POSIX `connect()` to the CGNAT IPv4 is racy against WireGuard
//  peer wake-up. The "MPTCP" name is retained for historical continuity;
//  Multipath TCP itself is not used, because it requires the `multipath`
//  entitlement that the minimal entitlement set deliberately drops
//  (spec section 8).
//

import Foundation
import Network
import NIOCore
import NIOTransportServices
import os.log

enum MPTCPBootstrap {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "MPTCPBootstrap")

    /// Shared event loop group for all SSH connections.
    /// Must be kept alive for the lifetime of any channels created on it.
    ///
    /// `loopCount` is bumped above the default of 1: NIOSSH's
    /// `NIOSSHPrivateKeyProtocol.signature(for:)` is a synchronous API,
    /// and a Secure Enclave key signs inside it via `SecKeyCreateSignature`,
    /// which blocks until the Face ID / Touch ID / passcode prompt guarding
    /// the key has been dismissed. With a single-loop group, that wait
    /// stalls the event loop for the duration of the prompt, freezing every
    /// other live SSH session (Citadel keep-alives, in-flight channel reads,
    /// the lot). Spreading sessions across multiple loops bounds the blast
    /// radius: only sessions that happen to land on the blocked loop
    /// stall, others continue to drive their channels normally.
    private static let tsEventLoopGroup: NIOTSEventLoopGroup = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let loopCount = max(2, min(cores, 4))
        return NIOTSEventLoopGroup(loopCount: loopCount)
    }()

    private static var shouldForceIPv4: Bool {
        SettingsStore.shared.value(Settings.Connections.forceIPv4)
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        host.contains(":")
    }

    /// Create a pre-connected channel suitable for passing to SSHClient.connect(on:).
    /// No SSH handlers are added — Citadel adds those itself.
    ///
    /// Callers are responsible for pre-resolving CGNAT/`.local` hostnames to an
    /// IPv4 literal before invoking this function (see CitadelSSHSession and
    /// SSHConnectionHelper). Passing an IP literal disables NWConnection's
    /// Happy Eyeballs v2, which is what we want — the connection then uses
    /// exactly the address the caller resolved, with no silent IPv6-ULA
    /// preference.
    static func connectPlainChannel(
        host: String,
        port: Int,
        timeout: TimeAmount = .seconds(30)
    ) async throws -> Channel {
        var bootstrap = NIOTSConnectionBootstrap(group: tsEventLoopGroup)
            .connectTimeout(timeout)
        let mode = "niots"
        if shouldForceIPv4 && !isIPv6Literal(host) {
            bootstrap = bootstrap.configureNWParameters { parameters in
                if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                    ipOptions.version = .v4
                }
            }
        }
        logger.info("\(mode) connect \(host):\(port) timeout=\(timeout.nanoseconds / 1_000_000_000)s")
        let channel = try await bootstrap.connect(host: host, port: port).get()
        let local = channel.localAddress?.description ?? "?"
        let remote = channel.remoteAddress?.description ?? "?"
        logger.info("\(mode) connected local=\(local) remote=\(remote)")
        return channel
    }
}
