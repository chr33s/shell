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

import NIOCore

/// A ``NIOSSHClientUserAuthenticationDelegate`` is an object that can provide a sequence of
/// SSH user authentication methods based on the the acceptable list from the server.
///
/// This protocol defines the interface that will be used by the user authentication state
/// machine to move forward with challenges. Implementers of this protocol are free to take
/// time to actually get responses: for example, for password authentication it is possible
/// that the application would like to provide a user-interactive password prompt. This is
/// enabled by allowing implementers to satisfy a promise, rather than requiring that they
/// synchronously provide a response.
/// A single prompt within a keyboard-interactive (RFC 4256) challenge.
public struct NIOSSHKeyboardInteractivePrompt: Sendable, Equatable {
    /// The text to display to the user (e.g. "Password:" or "Verification code:").
    public var prompt: String

    /// Whether the user's typed response should be echoed. `false` for secrets
    /// such as passwords or one-time codes.
    public var echo: Bool

    public init(prompt: String, echo: Bool) {
        self.prompt = prompt
        self.echo = echo
    }
}

/// Thrown by the default ``NIOSSHClientUserAuthenticationDelegate/respondToKeyboardInteractiveChallenge(name:instruction:prompts:responsePromise:)``
/// implementation when a delegate does not support keyboard-interactive auth.
public struct NIOSSHKeyboardInteractiveAuthenticationNotSupported: Error {
    public init() {}
}

/// A ``NIOSSHClientUserAuthenticationDelegate`` is an object that can provide a sequence of
/// SSH user authentication methods based on the the acceptable list from the server.
///
/// This protocol defines the interface that will be used by the user authentication state
/// machine to move forward with challenges. Implementers of this protocol are free to take
/// time to actually get responses: for example, for password authentication it is possible
/// that the application would like to provide a user-interactive password prompt. This is
/// enabled by allowing implementers to satisfy a promise, rather than requiring that they
/// synchronously provide a response.
public protocol NIOSSHClientUserAuthenticationDelegate {
    /// Informs the delegate which public-key signature algorithms the server
    /// advertised through RFC 8308's `server-sig-algs` extension.
    ///
    /// This callback occurs before the first authentication offer whenever the
    /// server sends EXT_INFO. An absent callback means the server did not
    /// advertise this capability; compatibility policy for such legacy peers
    /// remains the responsibility of the delegate.
    func serverSignatureAlgorithmsReceived(_ algorithms: [String])

    /// Called when ``NIOSSH`` would like to attempt to offer a new authentication method.
    ///
    /// The callback is provided the authentictation methods that the server is willing to accept in
    /// `availableMethods`. The delegate needs to provide an authentication offer by completing
    /// `nextChallengePromise`. If no further authentication offers are available (perhaps because the server
    /// has rejected them all) then this promise should be failed, which will terminate connection establishment.
    ///
    /// - parameters:
    ///     - availableMethods: The authentication methods the server is willing to accept.
    ///     - nextChallengePromise: An `EventLoopPromise` to be fulfilled with the next authentication offer.
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>)

    /// Called when the server issues a keyboard-interactive INFO_REQUEST (RFC 4256) after the
    /// delegate offered the keyboard-interactive method.
    ///
    /// The delegate must fulfil `responsePromise` with exactly one response per prompt, in order.
    /// A request with zero prompts (an information-only message) still requires an empty-array
    /// response. Failing the promise aborts the keyboard-interactive method, after which
    /// ``nextAuthenticationType(availableMethods:nextChallengePromise:)`` may offer another method.
    ///
    /// The server may issue several rounds of INFO_REQUEST; this method is invoked once per round.
    ///
    /// - parameters:
    ///     - name: The challenge name supplied by the server (may be empty).
    ///     - instruction: Instruction text supplied by the server (may be empty).
    ///     - prompts: The prompts to present, each with an echo flag.
    ///     - responsePromise: An `EventLoopPromise` to be fulfilled with one response per prompt.
    func respondToKeyboardInteractiveChallenge(
        name: String,
        instruction: String,
        prompts: [NIOSSHKeyboardInteractivePrompt],
        responsePromise: EventLoopPromise<[String]>
    )

    /// Called when the server reports a partial authentication success — i.e. a
    /// method succeeded but the server still requires further authentication
    /// (RFC 4252 `partial_success`). Delegates should use this to avoid reusing a
    /// credential from the accepted method for a subsequent factor (for example,
    /// not auto-answering a one-time-code keyboard-interactive prompt with the
    /// password that was just accepted).
    func authenticationSucceededPartially()
}

extension NIOSSHClientUserAuthenticationDelegate {
    public func serverSignatureAlgorithmsReceived(_: [String]) {}

    /// Default: most delegates don't need to react to partial success.
    public func authenticationSucceededPartially() {}

    /// Default implementation: a delegate that does not opt in to keyboard-interactive
    /// auth fails the challenge, which aborts the method without affecting other methods.
    public func respondToKeyboardInteractiveChallenge(
        name: String,
        instruction: String,
        prompts: [NIOSSHKeyboardInteractivePrompt],
        responsePromise: EventLoopPromise<[String]>
    ) {
        responsePromise.fail(NIOSSHKeyboardInteractiveAuthenticationNotSupported())
    }
}
