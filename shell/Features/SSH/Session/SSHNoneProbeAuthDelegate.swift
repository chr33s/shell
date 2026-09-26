//
//  SSHNoneProbeAuthDelegate.swift
//  shell
//
//  Opens authentication with the "none" method, the way OpenSSH does.
//

import NIOCore
import NIOSSH
import Synchronization
import os.log

/// Wraps the configured authentication delegate and offers the `none` method once
/// before it, mirroring how OpenSSH opens every authentication (RFC 4252 §5.2).
///
/// Two things come out of that first exchange. Servers that grant access without a
/// credential accept it outright, which is how OpenSSH logs in to stock MikroTik
/// RouterOS. Otherwise the failure carries the server's real method list, so the
/// wrapped delegate sees it on its very first call instead of the synthetic
/// "everything is available" set NIOSSH starts with.
///
/// `nonisolated` + `@unchecked Sendable` because NIO drives it from the event loop,
/// like the delegates it wraps.
nonisolated final class NoneProbeAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHAuth")

    private let username: String
    /// Event-loop confined. The NIO protocol is not `Sendable`, which is why
    /// this type stays `@unchecked`; the probe flag itself is synchronized.
    private let inner: NIOSSHClientUserAuthenticationDelegate
    private let probed = Mutex(false)

    init(username: String, inner: NIOSSHClientUserAuthenticationDelegate) {
        self.username = username
        self.inner = inner
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let shouldProbe = probed.withLock { probed -> Bool in
            guard !probed else { return false }
            probed = true
            return true
        }
        guard shouldProbe else {
            inner.nextAuthenticationType(
                availableMethods: availableMethods,
                nextChallengePromise: nextChallengePromise
            )
            return
        }
        Self.logger.debug("Probing 'none' authentication before the configured method")
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .none
        ))
    }

    func serverSignatureAlgorithmsReceived(_ algorithms: [String]) {
        inner.serverSignatureAlgorithmsReceived(algorithms)
    }

    func authenticationSucceededPartially() {
        inner.authenticationSucceededPartially()
    }

    func respondToKeyboardInteractiveChallenge(
        name: String,
        instruction: String,
        prompts: [NIOSSHKeyboardInteractivePrompt],
        responsePromise: EventLoopPromise<[String]>
    ) {
        inner.respondToKeyboardInteractiveChallenge(
            name: name,
            instruction: instruction,
            prompts: prompts,
            responsePromise: responsePromise
        )
    }
}
