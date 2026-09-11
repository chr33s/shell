//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOCore

struct SSHKeyExchangeStateMachine {
    enum SSHKeyExchangeError: Error {
        case unexpectedMessage
        case inconsistentState
    }

    enum State {
        /// Key exchange has not begun yet.
        case idle

        /// We've sent our key exchange message.
        ///
        /// Either clients or servers can send this message: they are entitled to race. Thus, either
        /// party can enter this state.
        ///
        /// We store the message we sent for later.
        case keyExchangeSent(message: SSHMessage.KeyExchangeMessage)

        /// We've received a key exchange message.
        ///
        /// Either clients or servers can send this message: they are entitled to race. Thus, either
        /// party can enter this state. The remote peer may be sending a guess as well.
        ///
        /// We store the message we sent for later.
        case keyExchangeReceived(exchange: NIOSSHKeyExchangeAlgorithmProtocol, negotiated: NegotiationResult, expectingGuess: Bool)

        /// The peer has guessed what key exchange init packet is coming, and guessed wrong. We need to wait for them to send that packet.
        case awaitingKeyExchangeInitInvalidGuess(exchange: NIOSSHKeyExchangeAlgorithmProtocol, negotiated: NegotiationResult)

        /// Both sides have sent their initial key exchange message but we have not begun actually performing a key exchange.
        case awaitingKeyExchangeInit(exchange: NIOSSHKeyExchangeAlgorithmProtocol, negotiated: NegotiationResult)

        /// We've received the key exchange init, but not sent our reply yet.
        case keyExchangeInitReceived(result: KeyExchangeResult, negotiated: NegotiationResult)

        /// We've sent our keyExchangeInit, but not received the keyExchangeReply.
        case keyExchangeInitSent(exchange: NIOSSHKeyExchangeAlgorithmProtocol, negotiated: NegotiationResult)

        /// The keys have been exchanged.
        case keysExchanged(result: KeyExchangeResult, protection: NIOSSHTransportProtection, negotiated: NegotiationResult)

        /// We have received the remote peer's newKeys message, and are waiting to send our own.
        case newKeysReceived(result: KeyExchangeResult, protection: NIOSSHTransportProtection, negotiated: NegotiationResult)

        /// We have sent our newKeys message, and are waiting to receive the remote peer's.
        case newKeysSent(result: KeyExchangeResult, protection: NIOSSHTransportProtection, negotiated: NegotiationResult)

        /// We've completed the key exchange.
        case complete(result: KeyExchangeResult)
    }

    private let allocator: ByteBufferAllocator
    private let loop: EventLoop
    private let role: SSHConnectionRole
    private var state: State
    private var initialExchangeBytes: ByteBuffer
    private var transportProtectionSchemes: [NIOSSHTransportProtection.Type]
    private var keyExchangeAlgorithms: [NIOSSHKeyExchangeAlgorithmProtocol.Type]
    private var previousSessionIdentifier: ByteBuffer?
    private(set) var peerRequestedExtensionInfo = false
    private let remoteVersion: String
    private static let routerOSVersionPrefix = "SSH-2.0-ROSSSH"
    private static let routerOSKeyExchangeAlgorithms: Set<Substring> = [
        Substring("curve25519-sha256"),
        Substring("curve25519-sha256@libssh.org"),
    ]
    private static let clientExtensionInfoMarker: Substring = "ext-info-c"

    /// - Parameter localVersion: Defaults to `Constants.version`; tests may override this to model a peer with a different banner in exchange hash construction.
    init(allocator: ByteBufferAllocator, loop: EventLoop, role: SSHConnectionRole, remoteVersion: String, keyExchangeAlgorithms: [NIOSSHKeyExchangeAlgorithmProtocol.Type], transportProtectionSchemes: [NIOSSHTransportProtection.Type], previousSessionIdentifier: ByteBuffer?, localVersion: String = Constants.version) {
        self.allocator = allocator
        self.loop = loop
        self.role = role
        self.initialExchangeBytes = allocator.buffer(capacity: 1024)
        self.state = .idle
        self.keyExchangeAlgorithms = keyExchangeAlgorithms
        self.transportProtectionSchemes = transportProtectionSchemes
        self.previousSessionIdentifier = previousSessionIdentifier
        self.remoteVersion = remoteVersion

        switch self.role {
        case .client:
            self.initialExchangeBytes.writeSSHString(localVersion.utf8)
            self.initialExchangeBytes.writeSSHString(remoteVersion.utf8)
        case .server:
            self.initialExchangeBytes.writeSSHString(remoteVersion.utf8)
            self.initialExchangeBytes.writeSSHString(localVersion.utf8)
        }
    }

    /// Currently we statically only use a single key exchange message. In future this will expand out to
    /// support arbitrary SSHTransportProtection schemes.
    func createKeyExchangeMessage() -> SSHMessage.KeyExchangeMessage {
        var rng = CSPRNG()

        let encryptionAlgorithms = self.supportedEncryptionAlgorithms
        let macAlgorithms = self.supportedMacAlgorithms

        return .init(
            cookie: rng.randomCookie(allocator: self.allocator),
            keyExchangeAlgorithms: self.keyExchangeAlgorithmProposal,
            serverHostKeyAlgorithms: self.supportedHostKeyAlgorithms,
            encryptionAlgorithmsClientToServer: encryptionAlgorithms,
            encryptionAlgorithmsServerToClient: encryptionAlgorithms,
            macAlgorithmsClientToServer: macAlgorithms,
            macAlgorithmsServerToClient: macAlgorithms,
            compressionAlgorithmsClientToServer: ["none"],
            compressionAlgorithmsServerToClient: ["none"],
            languagesClientToServer: [],
            languagesServerToClient: [],
            firstKexPacketFollows: false
        )
    }

    private var keyExchangeAlgorithmProposal: [Substring] {
        // RouterOS ROSSSH can stop responding when the client KEXINIT offers too many KEX algorithms.
        if self.role.isClient, self.isRouterOSPeer {
            let routerOSAlgorithms = self.role.keyExchangeAlgorithmNames.filter {
                Self.routerOSKeyExchangeAlgorithms.contains($0)
            }
            if !routerOSAlgorithms.isEmpty {
                NIOSSHTrace.event("KEX using RouterOS compact proposal for remoteVersion=\(self.remoteVersion)")
                return routerOSAlgorithms
            }

            NIOSSHTrace.event("KEX RouterOS compact proposal unavailable; Curve25519 algorithms are not configured")
            return self.role.keyExchangeAlgorithmNames
        }

        if self.role.isClient, self.previousSessionIdentifier == nil {
            return self.role.keyExchangeAlgorithmNames + [Self.clientExtensionInfoMarker]
        }
        return self.role.keyExchangeAlgorithmNames
    }

    private var isRouterOSPeer: Bool {
        self.remoteVersion == Self.routerOSVersionPrefix || self.remoteVersion.hasPrefix(Self.routerOSVersionPrefix + " ")
    }

    mutating func handle(keyExchange message: SSHMessage.KeyExchangeMessage) throws -> SSHMultiMessage? {
        if self.role.isServer,
           self.previousSessionIdentifier == nil,
           message.keyExchangeAlgorithms.contains(Self.clientExtensionInfoMarker) {
            self.peerRequestedExtensionInfo = true
        }

        switch self.state {
        case .keyExchangeSent(message: let ourMessage):
            switch self.role {
            case .client:
                self.addKeyExchangeInitMessagesToExchangeBytes(clientsMessage: ourMessage, serversMessage: message)

                // verify algorithms
                let negotiated: NegotiationResult
                do {
                    negotiated = try self.negotiatedAlgorithms(message)
                } catch {
                    NIOSSHTrace.error("kex.negotiate", error)
                    throw error
                }
                NIOSSHTrace.event(
                    "KEX negotiated kex=\(negotiated.negotiatedKeyExchangeAlgorithm) " +
                    "hostKey=\(negotiated.negotiatedHostKeyAlgorithm) " +
                    "transport=\(negotiated.negotiatedProtection) " +
                    "mac=\(negotiated.negotiatedMacAlgorithm.map { String($0) } ?? "implicit")"
                )
                let exchanger = try self.exchangerForAlgorithm(negotiated.negotiatedKeyExchangeAlgorithm)

                // Ok, we need to send the key exchange message.
                let publicKeyBuffer = exchanger.initiateKeyExchangeClientSide(allocator: self.allocator)
                let message = SSHMessage.keyExchangeInit(.init(publicKey: publicKeyBuffer))
                self.state = .awaitingKeyExchangeInit(exchange: exchanger, negotiated: negotiated)
                return SSHMultiMessage(message)
            case .server:
                // Write their message in first, then ours.
                self.addKeyExchangeInitMessagesToExchangeBytes(clientsMessage: message, serversMessage: ourMessage)

                let negotiated = try self.negotiatedAlgorithms(message)
                let exchanger = try self.exchangerForAlgorithm(negotiated.negotiatedKeyExchangeAlgorithm)

                // Ok, we're waiting for them to go. They might be sending a wrong guess, which we want to ignore.
                if self.expectingIncorrectGuess(message) {
                    self.state = .awaitingKeyExchangeInitInvalidGuess(exchange: exchanger, negotiated: negotiated)
                } else {
                    self.state = .awaitingKeyExchangeInit(exchange: exchanger, negotiated: negotiated)
                }
                return nil
            }
        case .idle:
            // We received a key exchange message while idle. We will need to send our own key exchange message back,
            // and also follow immediately up with our own key exchange init message.
            let ourMessage = self.createKeyExchangeMessage()

            switch self.role {
            case .client:
                self.addKeyExchangeInitMessagesToExchangeBytes(clientsMessage: ourMessage, serversMessage: message)
            case .server:
                self.addKeyExchangeInitMessagesToExchangeBytes(clientsMessage: message, serversMessage: ourMessage)
            }

            let negotiated = try self.negotiatedAlgorithms(message)
            let exchanger = try self.exchangerForAlgorithm(negotiated.negotiatedKeyExchangeAlgorithm)

            let result: SSHMultiMessage
            switch self.role {
            case .client:
                let publicKeyBuffer = exchanger.initiateKeyExchangeClientSide(allocator: self.allocator)
                result = SSHMultiMessage(.keyExchange(ourMessage), SSHMessage.keyExchangeInit(.init(publicKey: publicKeyBuffer)))
            case .server:
                result = SSHMultiMessage(.keyExchange(ourMessage))
            }

            self.state = .keyExchangeReceived(exchange: exchanger, negotiated: negotiated, expectingGuess: self.expectingIncorrectGuess(message))
            return result

        case .keyExchangeReceived, .awaitingKeyExchangeInit, .awaitingKeyExchangeInitInvalidGuess, .keyExchangeInitReceived, .keyExchangeInitSent, .keysExchanged, .newKeysSent, .newKeysReceived, .complete:
            throw SSHKeyExchangeError.unexpectedMessage
        }
    }

    mutating func send(keyExchange message: SSHMessage.KeyExchangeMessage) {
        switch self.state {
        case .idle:
            self.state = .keyExchangeSent(message: message)
        case .keyExchangeReceived(let exchanger, let negotiated, let expectingGuess):
            switch self.role {
            case .server:
                // Ok, we're waiting for a key exchange init message.
                if expectingGuess {
                    self.state = .awaitingKeyExchangeInitInvalidGuess(exchange: exchanger, negotiated: negotiated)
                } else {
                    self.state = .awaitingKeyExchangeInit(exchange: exchanger, negotiated: negotiated)
                }

            case .client:
                // We're going to send a key exchange init message.
                self.state = .awaitingKeyExchangeInit(exchange: exchanger, negotiated: negotiated)
            }
        case .keyExchangeSent, .awaitingKeyExchangeInit, .awaitingKeyExchangeInitInvalidGuess, .keyExchangeInitReceived, .keyExchangeInitSent, .keysExchanged, .newKeysSent, .newKeysReceived, .complete:
            // This is a precondition not a throw because we control the sending of this message.
            preconditionFailure("Cannot send key exchange message after idle")
        }
    }

    mutating func handle(keyExchangeInit message: ByteBuffer) throws -> SSHMultiMessage? {
        switch self.state {
        case .awaitingKeyExchangeInitInvalidGuess(exchange: let exchanger, negotiated: let negotiated):
            // We're going to ignore this one, we already know it's wrong.
            assert(self.role.isServer, "Clients cannot be expecting invalid guess from the peer")
            self.state = .awaitingKeyExchangeInit(exchange: exchanger, negotiated: negotiated)
            return nil

        case .awaitingKeyExchangeInit(exchange: var exchanger, negotiated: let negotiated):
            switch self.role {
            case .client:
                throw SSHKeyExchangeError.unexpectedMessage
            case .server(let configuration):
                let (result, reply) = try exchanger.completeKeyExchangeServerSide(
                    clientKeyExchangeMessage: message,
                    serverHostKey: negotiated.negotiatedHostKey(configuration.hostKeys),
                    initialExchangeBytes: &self.initialExchangeBytes,
                    allocator: self.allocator, expectedKeySizes: negotiated.negotiatedProtection.keySizes(forMac: negotiated.negotiatedMacAlgorithm.map { String($0) })
                )

                let message = SSHMessage.keyExchangeReply(.init(hostKey: reply.hostKey, publicKey: reply.publicKey, signature: reply.signature))
                self.state = .keyExchangeInitReceived(result: result, negotiated: negotiated)
                return SSHMultiMessage(message, .newKeys)
            }
        case .idle, .keyExchangeSent, .keyExchangeReceived, .keyExchangeInitReceived, .keyExchangeInitSent, .keysExchanged, .newKeysSent, .newKeysReceived, .complete:
            throw SSHKeyExchangeError.unexpectedMessage
        }
    }

    mutating func send(keyExchangeInit message: SSHMessage.KeyExchangeECDHInitMessage) {
        switch self.state {
        case .awaitingKeyExchangeInit(exchange: let exchanger, negotiated: let negotiated):
            precondition(self.role.isClient, "Servers must not send ecdh key exchange init messages")
            self.state = .keyExchangeInitSent(exchange: exchanger, negotiated: negotiated)
        case .idle, .keyExchangeSent, .keyExchangeReceived, .awaitingKeyExchangeInitInvalidGuess, .keyExchangeInitSent, .keyExchangeInitReceived, .keysExchanged, .newKeysSent, .newKeysReceived, .complete:
            // This is a precondition not a throw because we control the sending of this message.
            preconditionFailure("Cannot send ECDH key exchange message in state \(self.state)")
        }
    }

    mutating func handle(keyExchangeReply message: SSHMessage.KeyExchangeECDHReplyMessage) throws -> EventLoopFuture<SSHMultiMessage?> {
        switch self.state {
        case .keyExchangeInitSent(exchange: var exchanger, negotiated: let negotiated):
            switch self.role {
            case .client:
                guard message.hostKey.isValidAuthenticationAlgorithmName(
                    negotiated.negotiatedHostKeyAlgorithm.utf8
                ) else {
                    let expected = String(negotiated.negotiatedHostKeyAlgorithm)
                    let got = String(decoding: message.hostKey.keyPrefix, as: UTF8.self)
                    NIOSSHTrace.event("KEX host key alg mismatch expected=\(expected) got=\(got)")
                    throw NIOSSHError.invalidHostKeyForKeyExchange(expected: negotiated.negotiatedHostKeyAlgorithm,
                                                                   got: message.hostKey.keyPrefix)
                }
                guard message.signature.matches(
                    authenticationAlgorithmName: String(negotiated.negotiatedHostKeyAlgorithm),
                    publicKey: message.hostKey
                ) else {
                    throw NIOSSHError.invalidExchangeHashSignature
                }
                NIOSSHTrace.event("KEX deriving shared secret + verifying server signature")

                let result: KeyExchangeResult
                do {
                    result = try exchanger.receiveServerKeyExchangePayload(
                        serverKeyExchangeMessage: .init(
                            hostKey: message.hostKey,
                            publicKey: message.publicKey,
                            signature: message.signature
                        ),
                        initialExchangeBytes: &self.initialExchangeBytes,
                        allocator: self.allocator,
                        expectedKeySizes: negotiated.negotiatedProtection.keySizes(forMac: negotiated.negotiatedMacAlgorithm.map { String($0) })
                    )
                } catch {
                    NIOSSHTrace.error("kex.receiveServerKeyExchangePayload", error)
                    throw error
                }
                NIOSSHTrace.event("KEX shared secret derived, server signature verified")

                let protection = try negotiated.negotiatedProtection.init(initialKeys: result.keys, mac: negotiated.negotiatedMacAlgorithm.map { String($0) })
                self.state = .keysExchanged(result: result, protection: protection, negotiated: negotiated)

                // Ok, we've modified the state, now we can ask the user if they like this host key.
                guard case .client(let clientConfig) = self.role else {
                    preconditionFailure("Should not be in .keyExchangeInitSent as server")
                }

                // Check if this is a certificate and validate it if we have trusted CAs
                if let certifiedKey = NIOSSHCertifiedPublicKey(message.hostKey),
                   !clientConfig.trustedHostCAKeys.isEmpty {
                    // This is a certificate and we have trusted CAs configured
                    do {
                        // Use the configured hostname for validation, or empty string to accept any
                        let principal = clientConfig.hostname ?? ""
                        let _ = try certifiedKey.validate(
                            principal: principal,
                            type: .host,
                            allowedAuthoritySigningKeys: clientConfig.trustedHostCAKeys,
                            acceptableCriticalOptions: [] // Host certificates typically don't have critical options
                        )
                        // Certificate is valid, now let the delegate do additional validation
                        NIOSSHTrace.event("KEX awaiting host certificate approval from delegate")
                        let promise = self.loop.makePromise(of: Void.self)
                        clientConfig.serverAuthDelegate.validateHostCertificate(
                            hostKey: message.hostKey,
                            certifiedKey: certifiedKey,
                            validationCompletePromise: promise
                        )
                        return promise.futureResult.always { result in
                            switch result {
                            case .success:
                                NIOSSHTrace.event("KEX host certificate approved → emitting NEWKEYS")
                            case .failure(let err):
                                NIOSSHTrace.error("kex.hostCertApproval", err)
                            }
                        }.map {
                            SSHMultiMessage(SSHMessage.newKeys)
                        }
                    } catch {
                        // Certificate validation failed
                        NIOSSHTrace.error("kex.hostCertValidate", error)
                        return self.loop.makeFailedFuture(error)
                    }
                } else {
                    // Regular key validation or no trusted CAs configured
                    NIOSSHTrace.event("KEX awaiting host key approval from delegate (validateHostKey)")
                    let promise = self.loop.makePromise(of: Void.self)
                    clientConfig.serverAuthDelegate.validateHostKey(hostKey: message.hostKey, validationCompletePromise: promise)
                    return promise.futureResult.always { result in
                        switch result {
                        case .success:
                            NIOSSHTrace.event("KEX host key approved → emitting NEWKEYS")
                        case .failure(let err):
                            NIOSSHTrace.error("kex.hostKeyApproval", err)
                        }
                    }.map {
                        SSHMultiMessage(SSHMessage.newKeys)
                    }
                }
            case .server:
                preconditionFailure("Servers cannot enter key exchange init sent.")
            }
        case .idle, .keyExchangeSent, .keyExchangeReceived, .awaitingKeyExchangeInit, .awaitingKeyExchangeInitInvalidGuess, .keyExchangeInitReceived, .keysExchanged, .newKeysSent, .newKeysReceived, .complete:
            throw SSHKeyExchangeError.unexpectedMessage
        }
    }

    mutating func send(keyExchangeReply message: SSHMessage.KeyExchangeECDHReplyMessage) throws {
        switch self.state {
        case .keyExchangeInitReceived(result: let result, negotiated: let negotiated):
            precondition(self.role.isServer, "Clients cannot enter key exchange init received")
            
            let protection = try negotiated.negotiatedProtection.init(initialKeys: result.keys, mac: negotiated.negotiatedMacAlgorithm.map { String($0) })
            self.state = .keysExchanged(result: result, protection: protection, negotiated: negotiated)
        case .idle, .keyExchangeSent, .keyExchangeReceived, .awaitingKeyExchangeInit, .awaitingKeyExchangeInitInvalidGuess, .keyExchangeInitSent, .keysExchanged, .newKeysSent, .newKeysReceived, .complete:
            // This is a precondition not a throw because we control the sending of this message.
            preconditionFailure("Cannot send ECDH key exchange message in state \(self.state)")
        }
    }

    mutating func handleNewKeys() throws -> NIOSSHTransportProtection {
        switch self.state {
        case .keysExchanged(result: let result, protection: let protection, negotiated: let negotiated):
            self.state = .newKeysReceived(result: result, protection: protection, negotiated: negotiated)
            return protection
        case .newKeysSent(result: let result, protection: let protection, _):
            self.state = .complete(result: result)
            return protection
        case .idle, .keyExchangeSent, .keyExchangeReceived, .awaitingKeyExchangeInit, .awaitingKeyExchangeInitInvalidGuess, .keyExchangeInitSent, .keyExchangeInitReceived, .newKeysReceived, .complete:
            throw SSHKeyExchangeError.unexpectedMessage
        }
    }

    mutating func sendNewKeys() -> NIOSSHTransportProtection {
        switch self.state {
        case .keysExchanged(result: let result, protection: let protection, negotiated: let negotiated):
            self.state = .newKeysSent(result: result, protection: protection, negotiated: negotiated)
            return protection
        case .newKeysReceived(result: let result, protection: let protection, _):
            self.state = .complete(result: result)
            return protection
        case .idle, .keyExchangeSent, .keyExchangeReceived, .awaitingKeyExchangeInit, .awaitingKeyExchangeInitInvalidGuess, .keyExchangeInitSent, .keyExchangeInitReceived, .newKeysSent, .complete:
            // This is a precondition not a throw because we control the sending of this message.
            preconditionFailure("Cannot send ECDH key exchange message in state \(self.state)")
        }
    }

    private func negotiatedAlgorithms(_ message: SSHMessage.KeyExchangeMessage) throws -> NegotiationResult {
        let (keyExchange, hostKey) = try self.negotiatedKeyExchangeAlgorithm(peerKeyExchangeAlgorithms: message.keyExchangeAlgorithms,
                                                                             peerHostKeyAlgorithms: message.serverHostKeyAlgorithms)
        let (clientEncryption, clientMAC) = try self.negotiatedTransportProtection(peerEncryptionAlgorithms: message.encryptionAlgorithmsClientToServer, peerMacAlgorithms: message.macAlgorithmsClientToServer)
        let (serverEncryption, serverMAC) = try self.negotiatedTransportProtection(peerEncryptionAlgorithms: message.encryptionAlgorithmsServerToClient, peerMacAlgorithms: message.macAlgorithmsServerToClient)

        // We only support symmetrical negotiation results.
        guard clientEncryption == serverEncryption, clientMAC == serverMAC else {
            throw NIOSSHError.keyExchangeNegotiationFailure
        }

        // Ok, now we need to find the right transport protection scheme. This can technically fail.
        guard let scheme = self.transportProtectionSchemes.first(where: { $0.cipherName == clientEncryption && ($0.macNames.isEmpty || $0.macNames.contains(String(clientMAC))) }) else {
            throw NIOSSHError.keyExchangeNegotiationFailure
        }

        // Great, we have a protection scheme. Build the negotiation result.
        return NegotiationResult(negotiatedKeyExchangeAlgorithm: keyExchange, negotiatedHostKeyAlgorithm: hostKey, negotiatedMacAlgorithm: clientMAC, negotiatedProtection: scheme)
    }

    private func negotiatedKeyExchangeAlgorithm(peerKeyExchangeAlgorithms: [Substring], peerHostKeyAlgorithms: [Substring]) throws -> (keyExchange: Substring, hostKey: Substring) {
        // From RFC 4253:
        //
        // > The first algorithm MUST be the preferred (and guessed) algorithm.  If
        // > both sides make the same guess, that algorithm MUST be used.
        // > Otherwise, the following algorithm MUST be used to choose a key
        // > exchange method: Iterate over client's kex algorithms, one at a
        // > time.  Choose the first algorithm that satisfies the following
        // > conditions:
        // >
        // > +  the server also supports the algorithm,
        // >
        // > +  if the algorithm requires an encryption-capable host key,
        // >    there is an encryption-capable algorithm on the server's
        // >    server_host_key_algorithms that is also supported by the
        // >    client, and
        // >
        // > +  if the algorithm requires a signature-capable host key,
        // >    there is a signature-capable algorithm on the server's
        // >    server_host_key_algorithms that is also supported by the
        // >    client.
        // >
        // > If no algorithm satisfying all these conditions can be found, the
        // > connection fails, and both sides MUST disconnect.

        // Ok, rephrase as client and server instead of us and them.
        let clientAlgorithms: [Substring]
        let serverAlgorithms: [Substring]
        let clientHostKeyAlgorithms: [Substring]
        let serverHostKeyAlgorithms: [Substring]

        switch self.role {
        case .client:
            clientAlgorithms = self.keyExchangeAlgorithmProposal
            serverAlgorithms = peerKeyExchangeAlgorithms
            clientHostKeyAlgorithms = self.supportedHostKeyAlgorithms
            serverHostKeyAlgorithms = peerHostKeyAlgorithms
        case .server:
            clientAlgorithms = peerKeyExchangeAlgorithms
            serverAlgorithms = self.role.keyExchangeAlgorithmNames
            clientHostKeyAlgorithms = peerHostKeyAlgorithms
            serverHostKeyAlgorithms = self.supportedHostKeyAlgorithms
        }

        // Let's find the first protocol the client supports that the server does too.
        for algorithm in clientAlgorithms {
            guard serverAlgorithms.contains(algorithm) else {
                continue
            }

            // Ok, got one. We need a signing capable host key algorithm, which for us is all of them.
            // Again, we prefer the first one the client supports that the server does too.
            for hostKeyAlgorithm in clientHostKeyAlgorithms {
                guard serverHostKeyAlgorithms.contains(hostKeyAlgorithm) else {
                    continue
                }

                // Got one! This one works.
                return (keyExchange: algorithm, hostKey: hostKeyAlgorithm)
            }
        }

        // Completed the loop with usable protocols, we have to throw.
        throw NIOSSHError.keyExchangeNegotiationFailure
    }

    private func negotiatedTransportProtection(peerEncryptionAlgorithms: [Substring], peerMacAlgorithms: [Substring]) throws -> (encryption: Substring, mac: Substring) {
        // Ok, rephrase as client and server instead of us and them.
        let clientEncryptionAlgorithms: [Substring]
        let serverEncryptionAlgorithms: [Substring]
        let clientMACAlgorithms: [Substring]
        let serverMACAlgorithms: [Substring]

        switch self.role {
        case .client:
            clientEncryptionAlgorithms = self.supportedEncryptionAlgorithms
            clientMACAlgorithms = self.supportedMacAlgorithms
            serverEncryptionAlgorithms = peerEncryptionAlgorithms
            serverMACAlgorithms = peerMacAlgorithms
        case .server:
            clientEncryptionAlgorithms = peerEncryptionAlgorithms
            clientMACAlgorithms = peerMacAlgorithms
            serverEncryptionAlgorithms = self.supportedEncryptionAlgorithms
            serverMACAlgorithms = self.supportedMacAlgorithms
        }

        // Ok, the algorithm is that we choose the first encryption and MAC algorithm in the client's list that
        // is in the server's list as well.
        guard let encryption = clientEncryptionAlgorithms.first(where: { serverEncryptionAlgorithms.contains($0) }) else {
            throw NIOSSHError.keyExchangeNegotiationFailure
        }

        // Ok great, now work out what we negotiated as a MAC.
        guard let mac = clientMACAlgorithms.first(where: { serverMACAlgorithms.contains($0) }) else {
            throw NIOSSHError.keyExchangeNegotiationFailure
        }

        return (encryption, mac)
    }

    private mutating func addKeyExchangeInitMessagesToExchangeBytes(clientsMessage: SSHMessage.KeyExchangeMessage, serversMessage: SSHMessage.KeyExchangeMessage) {
        // Write the client's bytes to the exchange bytes first.
        self.initialExchangeBytes.writeCompositeSSHString { buffer in
            buffer.writeSSHMessage(.keyExchange(clientsMessage))
        }

        self.initialExchangeBytes.writeCompositeSSHString { buffer in
            buffer.writeSSHMessage(.keyExchange(serversMessage))
        }
    }

    private func exchangerForAlgorithm(_ algorithm: Substring) throws -> NIOSSHKeyExchangeAlgorithmProtocol {
        for implementation in self.keyExchangeAlgorithms {
            if implementation.keyExchangeAlgorithmNames.contains(algorithm) {
                return implementation.init(ourRole: self.role, previousSessionIdentifier: self.previousSessionIdentifier)
            }
        }

        // We didn't find a match
        throw NIOSSHError.keyExchangeNegotiationFailure
    }

    private func expectingIncorrectGuess(_ kexMessage: SSHMessage.KeyExchangeMessage) -> Bool {
        // A guess is wrong if the key exchange algorithm and/or the host key algorithm differ from our preference.
        kexMessage.firstKexPacketFollows && (
            kexMessage.keyExchangeAlgorithms.first != self.keyExchangeAlgorithmProposal.first ||
                kexMessage.serverHostKeyAlgorithms.first != self.supportedHostKeyAlgorithms.first
        )
    }

    // The host key algorithms supported by this peer, in order of preference.
    private var supportedHostKeyAlgorithms: [Substring] {
        switch self.role {
        case .client(let configuration):
            // When the client opts into host certificates, advertise the
            // `*-cert-v01@openssh.com` variants ahead of the plain algorithms so
            // a certificate-capable server selects a cert (negotiation picks the
            // first client algorithm the server also supports).
            if configuration.advertiseHostCertificateAlgorithms {
                return Self.hostCertificateAlgorithms + Self.supportedServerHostKeyAlgorithms
            }
            return Self.supportedServerHostKeyAlgorithms
        case .server(let configuration):
            return configuration.hostKeys.flatMap { $0.hostKeyAlgorithms }
        }
    }

    /// The encryption algorithms supported by this peer, in order of preference.
    /// Order-preserving deduplication: ETM and non-ETM schemes share cipher names.
    private var supportedEncryptionAlgorithms: [Substring] {
        var seen = Set<Substring>()
        return self.transportProtectionSchemes.compactMap { scheme in
            let name = Substring(scheme.cipherName)
            return seen.insert(name).inserted ? name : nil
        }
    }

    /// The MAC algorithms supported by this peer, in order of preference.
    /// Order-preserving deduplication: multiple schemes may advertise the same MAC.
    private var supportedMacAlgorithms: [Substring] {
        var seen = Set<Substring>()
        let schemes = self.transportProtectionSchemes.reduce([Substring]()) { schemes, transport in
            schemes + transport.macNames.compactMap { name in
                let s = Substring(name)
                return seen.insert(s).inserted ? s : nil
            }
        }

        // We do a weird thing here: if there are no MAC schemes, we lie and put one in. This is
        // because some schemes (such as AES-GCM in OpenSSH mode) ignore the MAC negotiation.
        // Worse case, we fail out later in the handshake because the peer actually wanted it.
        if schemes.isEmpty {
            return ["hmac-sha2-256"]
        } else {
            return schemes
        }
    }
}

extension SSHKeyExchangeStateMachine {
    // For now this is a static list.
    static let bundledKeyExchangeImplementations: [NIOSSHKeyExchangeAlgorithmProtocol.Type] = [
        EllipticCurveKeyExchange<P384.KeyAgreement.PrivateKey>.self,
        EllipticCurveKeyExchange<P256.KeyAgreement.PrivateKey>.self,
        EllipticCurveKeyExchange<P521.KeyAgreement.PrivateKey>.self,
        EllipticCurveKeyExchange<Curve25519.KeyAgreement.PrivateKey>.self,
    ]

    /// All known host key algorithms.
    static let bundledServerHostKeyAlgorithms: [Substring] = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"]

    /// OpenSSH host-certificate algorithms, in the same preference order as
    /// `bundledServerHostKeyAlgorithms`. Only advertised when the client config
    /// sets `advertiseHostCertificateAlgorithms`. A host key received under one
    /// of these algorithms parses into a `.certified` `NIOSSHPublicKey`.
    ///
    /// Custom types opt in through `supportsHostCertificates` and must have an
    /// exact certificate negotiation name. Parser registration alone does not
    /// enable host authentication: an unsupported advertised key cannot fall
    /// back once KEX has selected it. RSA certificate aliases remain excluded
    /// until their host-authentication negotiation is independently supported.
    static var hostCertificateAlgorithms: [Substring] {
        let enabledPlainAlgorithms = Set(supportedServerHostKeyAlgorithms)
        var seen = Set<Substring>()
        func certificates(from registrations: [CustomPublicKeyRegistration]) -> [Substring] {
            registrations.compactMap { registration -> Substring? in
                let key = registration.publicKey
                guard key.supportsHostCertificates,
                      enabledPlainAlgorithms.contains(Substring(key.authAlgorithmName)),
                      let certificate = key.certifiedKeyPrefix,
                      key.certifiedAuthAlgorithmName == certificate else {
                    return nil
                }
                return Substring(certificate)
            }
        }

        // Explicit preferences apply to certificates as well as plain host keys.
        // Deduplicate after ordering so a preferred registration keeps its place
        // even when the same key is also registered with the defaults.
        return (certificates(from: NIOSSHPublicKey.preferredPublicKeyRegistrations) + [
            "ssh-ed25519-cert-v01@openssh.com",
            "ecdsa-sha2-nistp256-cert-v01@openssh.com",
            "ecdsa-sha2-nistp384-cert-v01@openssh.com",
            "ecdsa-sha2-nistp521-cert-v01@openssh.com",
        ] + certificates(from: NIOSSHPublicKey.customPublicKeyRegistrations))
            .filter { seen.insert($0).inserted }
    }

    static var supportedServerHostKeyAlgorithms: [Substring] {
        func algorithms(
            from registrations: [CustomPublicKeyRegistration],
            applyDefaults: Bool = true
        ) -> [Substring] {
            registrations.flatMap { registration in
                let validNames = [
                    registration.publicKey.authAlgorithmName,
                    registration.publicKey.publicKeyPrefix,
                ]
                return registration.signatures.compactMap { signature in
                    validNames.contains(signature.signaturePrefix)
                        && (!applyDefaults || registration.publicKey.defaultHostKeyAlgorithms?
                            .contains(signature.signaturePrefix) != false)
                        ? Substring(signature.signaturePrefix)
                        : nil
                }
            }
        }

        // Sort supported standard algorithms as OpenSSH does, independently of
        // parser registration order (apps may register FIDO keys after Citadel).
        let openSSHOrder: [Substring] = [
            "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
            "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
            "webauthn-sk-ecdsa-sha2-nistp256@openssh.com",
            "rsa-sha2-512", "rsa-sha2-256", "ssh-mldsa44-ed25519",
        ]
        let defaults = bundledServerHostKeyAlgorithms
            + algorithms(from: NIOSSHPublicKey.customPublicKeyRegistrations)
        let supported = Set(defaults)
        var seen = Set<Substring>()
        return (
            algorithms(from: NIOSSHPublicKey.preferredPublicKeyRegistrations, applyDefaults: false)
                + openSSHOrder.filter { supported.contains($0) }
                + defaults
        ).filter { seen.insert($0).inserted }
    }
}

extension SSHKeyExchangeStateMachine {
    struct NegotiationResult {
        var negotiatedKeyExchangeAlgorithm: Substring

        var negotiatedHostKeyAlgorithm: Substring
        
        var negotiatedMacAlgorithm: Substring?

        var negotiatedProtection: NIOSSHTransportProtection.Type

        func negotiatedHostKey(_ keys: [NIOSSHPrivateKey]) -> NIOSSHPrivateKey {
            // This force-unwrap is safe: to fail to obtain it is a programming error, as we must have negotiated
            // the host key algorithm.
            keys.first { $0.hostKeyAlgorithms.contains(self.negotiatedHostKeyAlgorithm) }!
                .selectingAuthenticationAlgorithm(self.negotiatedHostKeyAlgorithm)
        }
    }

    /// Obtains the session ID, if we have one already.
    var sessionID: ByteBuffer? {
        switch self.state {
        case .keyExchangeInitReceived(result: let result, _),
             .keysExchanged(result: let result, _, _),
             .newKeysSent(result: let result, _, _),
             .newKeysReceived(result: let result, _, _),
             .complete(result: let result):
            return result.sessionID

        case .idle, .keyExchangeSent, .keyExchangeReceived, .awaitingKeyExchangeInit, .awaitingKeyExchangeInitInvalidGuess, .keyExchangeInitSent:
            return nil
        }
    }

    var _testOnly_negotiatedHostKeyAlgorithm: Substring? {
        switch self.state {
        case .idle, .keyExchangeSent, .complete:
            return nil

        case .keyExchangeReceived(_, negotiated: let negotiated, _),
             .awaitingKeyExchangeInitInvalidGuess(_, negotiated: let negotiated),
             .awaitingKeyExchangeInit(_, negotiated: let negotiated),
             .keyExchangeInitReceived(_, negotiated: let negotiated),
             .keyExchangeInitSent(_, negotiated: let negotiated),
             .keysExchanged(_, _, negotiated: let negotiated),
             .newKeysReceived(_, _, negotiated: let negotiated),
             .newKeysSent(_, _, negotiated: let negotiated):
            return negotiated.negotiatedHostKeyAlgorithm
        }
    }

    var negotiatedAlgorithmInfo: (keyExchange: String, hostKey: String, cipher: String, mac: String?)? {
        switch self.state {
        case .idle, .keyExchangeSent, .complete:
            return nil

        case .keyExchangeReceived(_, negotiated: let negotiated, _),
             .awaitingKeyExchangeInitInvalidGuess(_, negotiated: let negotiated),
             .awaitingKeyExchangeInit(_, negotiated: let negotiated),
             .keyExchangeInitReceived(_, negotiated: let negotiated),
             .keyExchangeInitSent(_, negotiated: let negotiated),
             .keysExchanged(_, _, negotiated: let negotiated),
             .newKeysReceived(_, _, negotiated: let negotiated),
             .newKeysSent(_, _, negotiated: let negotiated):
            return (
                keyExchange: String(negotiated.negotiatedKeyExchangeAlgorithm),
                hostKey: String(negotiated.negotiatedHostKeyAlgorithm),
                cipher: negotiated.negotiatedProtection.cipherName,
                mac: negotiated.negotiatedMacAlgorithm.map { String($0) }
            )
        }
    }
}

private extension CSPRNG {
    /// A SSH key exchange cookie is 16 random bytes.
    mutating func randomCookie(allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 16)
        buffer.writeInteger(self.next())
        buffer.writeInteger(self.next())
        assert(buffer.readableBytes == 16)
        return buffer
    }
}
