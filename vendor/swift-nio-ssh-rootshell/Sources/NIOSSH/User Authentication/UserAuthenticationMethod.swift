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

/// The user authentication modes available at this point in time.
///
/// Note: SSH certificate authentication is supported through the publicKey method,
/// not as a separate authentication method. When using certificates, the publicKey
/// method is used with a certified key.
public struct NIOSSHAvailableUserAuthenticationMethods: OptionSet {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let publicKey: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 0)
    public static let password: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 1)
    public static let hostBased: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 2)
    public static let keyboardInteractive: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 3)

    // NOTE: keyboard-interactive is deliberately excluded from `.all`. `.all` is
    // what a server advertises and what the client optimistically assumes before
    // the server's first USERAUTH_FAILURE; since server-side keyboard-interactive
    // is not implemented, a server must not advertise it. A client discovers a
    // server's keyboard-interactive support from the parsed failure message
    // instead, and offers the method proactively via its auth delegate.
    public static let all: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password, .hostBased]
}

extension NIOSSHAvailableUserAuthenticationMethods {
    internal init(_ message: SSHMessage.UserAuthFailureMessage) {
        self = .init()

        for message in message.authentications {
            switch message {
            case "publickey":
                self.insert(.publicKey)
            case "password":
                self.insert(.password)
            case "hostbased":
                self.insert(.hostBased)
            case "keyboard-interactive":
                self.insert(.keyboardInteractive)
            default:
                // This is an unknown method, which we ignore.
                break
            }
        }
    }

    internal var strings: [Substring] {
        guard self != .init() else {
            return []
        }

        // We need an array.
        var methods = [Substring]()
        methods.reserveCapacity(4)

        if self.contains(.password) {
            methods.append("password")
        }
        if self.contains(.publicKey) {
            methods.append("publickey")
        }
        if self.contains(.hostBased) {
            methods.append("hostbased")
        }
        if self.contains(.keyboardInteractive) {
            methods.append("keyboard-interactive")
        }

        return methods
    }
}

extension NIOSSHAvailableUserAuthenticationMethods: Hashable {}

/// A specific request for user authentication. This type is the one observed from the server side. The
/// associated client side type is `NIOSSHUserAuthenticationOffer`.
public struct NIOSSHUserAuthenticationRequest {
    public var username: String

    public var request: Request

    public init(username: String, serviceName: String, request: Request) {
        self.username = username
        self.request = request
    }
}

public extension NIOSSHUserAuthenticationRequest {
    enum Request {
        case publicKey(PublicKey)
        case password(Password)
        case hostBased(HostBased)
        case none
    }
}

public extension NIOSSHUserAuthenticationRequest.Request {
    struct PublicKey {
        public var publicKey: NIOSSHPublicKey
        
        /// If the public key is a certificate, this contains the parsed certificate information.
        /// This includes critical options, extensions, and other certificate metadata.
        /// Certificate authentication in SSH uses the publicKey authentication method with
        /// a certified key, not a separate authentication method.
        public var certifiedKey: NIOSSHCertifiedPublicKey?

        public init(publicKey: NIOSSHPublicKey) {
            self.publicKey = publicKey
            self.certifiedKey = NIOSSHCertifiedPublicKey(publicKey)
        }
        
        public init(publicKey: NIOSSHPublicKey, certifiedKey: NIOSSHCertifiedPublicKey?) {
            self.publicKey = publicKey
            self.certifiedKey = certifiedKey
        }
    }

    struct Password {
        public var password: String

        public init(password: String) {
            self.password = password
        }
    }

    struct HostBased {
        init() {
            fatalError("HostBased authentication is currently unimplemented")
        }
    }
}

extension NIOSSHUserAuthenticationRequest: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.PublicKey: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.Password: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.HostBased: Hashable {}

/// A specific offer of user authentication. This type is the one used on the client side. The
/// associated server side type is `NIOSSHUserAuthenticationRequest`.
public struct NIOSSHUserAuthenticationOffer {
    public var username: String

    public var offer: Offer

    public init(username: String, serviceName: String, offer: Offer) {
        self.username = username
        self.offer = offer
    }
}

public extension NIOSSHUserAuthenticationOffer {
    enum Offer {
        case privateKey(PrivateKey)
        case password(Password)
        case hostBased(HostBased)
        case keyboardInteractive(KeyboardInteractive)
        case none
    }
}

public extension NIOSSHUserAuthenticationOffer.Offer {
    struct PrivateKey {
        public enum AuthenticationMode {
            case signedRequest
            case probeThenSign
        }

        public var privateKey: NIOSSHPrivateKey
        public var publicKey: NIOSSHPublicKey
        public var authenticationMode: AuthenticationMode

        public init(
            privateKey: NIOSSHPrivateKey,
            authenticationMode: AuthenticationMode = .signedRequest
        ) {
            self.privateKey = privateKey
            self.publicKey = privateKey.publicKey
            self.authenticationMode = authenticationMode
        }

        /// Creates a private key offer with a certified public key.
        /// Certificate authentication uses the publicKey authentication method.
        public init(
            privateKey: NIOSSHPrivateKey,
            certifiedKey: NIOSSHCertifiedPublicKey,
            authenticationMode: AuthenticationMode = .signedRequest
        ) {
            self.privateKey = privateKey
            self.publicKey = NIOSSHPublicKey(certifiedKey)
            self.authenticationMode = authenticationMode
        }
    }

    struct Password {
        public var password: String

        public init(password: String) {
            self.password = password
        }
    }

    /// A keyboard-interactive (RFC 4256) offer. The actual prompt responses are
    /// supplied later via the delegate's
    /// ``NIOSSHClientUserAuthenticationDelegate/respondToKeyboardInteractiveChallenge(name:instruction:prompts:responsePromise:)``;
    /// this offer only initiates the method.
    struct KeyboardInteractive {
        public var languageTag: String
        public var submethods: String

        public init(languageTag: String = "", submethods: String = "") {
            self.languageTag = languageTag
            self.submethods = submethods
        }
    }

    struct HostBased {
        init() {
            fatalError("HostBased authentication is currently unimplemented")
        }
    }
}

extension SSHMessage.UserAuthRequestMessage {
    init(request: NIOSSHUserAuthenticationOffer, sessionID: ByteBuffer) throws {
        // We only ever ask for the ssh-connection service.
        self.username = request.username
        self.service = "ssh-connection"

        switch request.offer {
        case .privateKey(let privateKeyRequest):
            switch privateKeyRequest.authenticationMode {
            case .signedRequest:
                let dataToSign = UserAuthSignablePayload(
                    sessionIdentifier: sessionID,
                    userName: self.username,
                    serviceName: self.service,
                    publicKey: privateKeyRequest.publicKey
                )
                let signature = try privateKeyRequest.privateKey.sign(dataToSign)
                self.method = .publicKey(.known(key: privateKeyRequest.publicKey, signature: signature))
            case .probeThenSign:
                self.method = .publicKey(.known(key: privateKeyRequest.publicKey, signature: nil))
                self.signingPrivateKey = privateKeyRequest.privateKey
            }
        case .password(let passwordRequest):
            self.method = .password(passwordRequest.password)
        case .keyboardInteractive(let kbd):
            // No signing key, so sendUserAuthRequest leaves pendingPublicKeyProbe
            // nil and byte 60 is interpreted as INFO_REQUEST, not PK_OK.
            self.method = .keyboardInteractive(.init(languageTag: kbd.languageTag, submethods: kbd.submethods))
        case .hostBased:
            fatalError("Unsupported")
        case .none:
            self.method = .none
        }
    }
}

/// The outcome of a user authentication attempt.
public enum NIOSSHUserAuthenticationOutcome {
    case success
    case partialSuccess(remainingMethods: NIOSSHAvailableUserAuthenticationMethods)
    case failure
}

enum NIOSSHUserAuthenticationResponseMessage {
    case success
    case failure(SSHMessage.UserAuthFailureMessage)
    case publicKeyOK(SSHMessage.UserAuthPKOKMessage)
}

extension NIOSSHUserAuthenticationResponseMessage {
    init(_ outcome: NIOSSHUserAuthenticationOutcome, supportedMethods: NIOSSHAvailableUserAuthenticationMethods) {
        switch outcome {
        case .success:
            self = .success
        case .partialSuccess(remainingMethods: let remaining):
            let message = SSHMessage.UserAuthFailureMessage(authentications: remaining.strings, partialSuccess: true)
            self = .failure(message)
        case .failure:
            let message = SSHMessage.UserAuthFailureMessage(authentications: supportedMethods.strings, partialSuccess: false)
            self = .failure(message)
        }
    }
}
