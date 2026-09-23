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

import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
@testable import NIOSSH
import XCTest

final class ExplodingAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    enum Error: Swift.Error {
        case kaboom
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        XCTFail("Next Authentication Type must not be called")
        nextChallengePromise.fail(Error.kaboom)
    }
}

final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

final class SSHConnectionStateMachineTests: XCTestCase {
    private func assertSuccessfulConnection(client: inout SSHConnectionStateMachine, server: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop) throws {
        let clientMessage: SSHMultiMessage? = client.start()
        let serverMessage: SSHMultiMessage? = server.start()

        try self.run(clientMessage: clientMessage, client: &client, serverMessage: serverMessage, server: &server, allocator: allocator, loop: loop)
    }

    private func run(clientMessage: SSHMultiMessage?, client: inout SSHConnectionStateMachine, serverMessage: SSHMultiMessage?, server: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop, dripFeed: Bool = false) throws {
        var clientMessage = clientMessage
        var serverMessage = serverMessage
        var clientBuffer = allocator.buffer(capacity: 1024)
        var serverBuffer = allocator.buffer(capacity: 1024)
        var waitingForClientMessage = false
        var waitingForServerMessage = false

        while clientMessage != nil || serverMessage != nil {
            if let clientMessage = clientMessage {
                for message in clientMessage {
                    XCTAssertNoThrow(try client.processOutboundMessage(message, buffer: &clientBuffer, allocator: allocator, loop: loop))
                }
            }

            if let serverMessage = serverMessage {
                for message in serverMessage {
                    XCTAssertNoThrow(try server.processOutboundMessage(message, buffer: &serverBuffer, allocator: allocator, loop: loop))
                }
            }

            if clientBuffer.readableBytes > 0 {
                if dripFeed {
                    while var next = clientBuffer.readSlice(length: 1) {
                        server.bufferInboundData(&next)
                        if clientBuffer.readableBytes > 0 {
                            switch try assertNoThrowWithValue(server.processInboundMessage(allocator: allocator, loop: loop)) {
                            case .some(.emitMessage(let message)):
                                serverMessage.append(message)
                            case .none:
                                ()
                            case .some(.noMessage):
                                ()
                            case .some(.unimplemented):
                                ()
                            case .some(.possibleFutureMessage(let futureMessage)):
                                waitingForServerMessage = true

                                futureMessage.whenComplete { result in
                                    waitingForServerMessage = false

                                    switch result {
                                    case .failure(let err):
                                        XCTFail("Unexpected error in delayed message production: \(err)")
                                    case .success(let message):
                                        if let message = message {
                                            serverMessage.append(message)
                                        }
                                    }
                                }
                            case .some(.forwardToMultiplexer), .some(.globalRequest), .some(.globalRequestResponse), .some(.disconnect):
                                fatalError("Currently unsupported")
                            case .some(.event):
                                ()
                            }
                        }
                    }
                } else {
                    server.bufferInboundData(&clientBuffer)
                }
                clientBuffer.clear()
            }

            if serverBuffer.readableBytes > 0 {
                if dripFeed {
                    while var next = serverBuffer.readSlice(length: 1) {
                        client.bufferInboundData(&next)
                        if serverBuffer.readableBytes > 0 {
                            switch try assertNoThrowWithValue(client.processInboundMessage(allocator: allocator, loop: loop)) {
                            case .some(.emitMessage(let message)):
                                clientMessage.append(message)
                            case .none:
                                ()
                            case .some(.noMessage):
                                ()
                            case .some(.unimplemented):
                                ()
                            case .some(.possibleFutureMessage(let futureMessage)):
                                waitingForClientMessage = true

                                futureMessage.whenComplete { result in
                                    waitingForClientMessage = false

                                    switch result {
                                    case .failure(let err):
                                        XCTFail("Unexpected error in delayed message production: \(err)")
                                    case .success(let message):
                                        if let message = message {
                                            clientMessage.append(message)
                                        }
                                    }
                                }
                            case .some(.forwardToMultiplexer), .some(.globalRequest), .some(.globalRequestResponse), .some(.unimplemented), .some(.disconnect), .some(.event):
                                fatalError("Currently unsupported")
                            }
                        }
                    }
                } else {
                    client.bufferInboundData(&serverBuffer)
                }
                serverBuffer.clear()
            }

            clientMessage = nil
            serverMessage = nil

            clientLoop: while true {
                switch try assertNoThrowWithValue(client.processInboundMessage(allocator: allocator, loop: loop)) {
                case .some(.emitMessage(let message)):
                    clientMessage.append(message)
                case .none:
                    break clientLoop
                case .some(.noMessage):
                    ()
                case .some(.unimplemented):
                    ()
                case .some(.possibleFutureMessage(let futureMessage)):
                    waitingForClientMessage = true

                    futureMessage.whenComplete { result in
                        waitingForClientMessage = false

                        switch result {
                        case .failure(let err):
                            XCTFail("Unexpected error in delayed message production: \(err)")
                        case .success(let message):
                            if let message = message {
                                clientMessage.append(message)
                            }
                        }
                    }
                case .some(.forwardToMultiplexer), .some(.globalRequest), .some(.globalRequestResponse), .some(.disconnect):
                    fatalError("Currently unsupported")
                case .some(.event):
                    ()
                }
            }

            serverLoop: while true {
                switch try assertNoThrowWithValue(server.processInboundMessage(allocator: allocator, loop: loop)) {
                case .some(.emitMessage(let message)):
                    serverMessage.append(message)
                case .none:
                    break serverLoop
                case .some(.noMessage):
                    ()
                case .some(.unimplemented):
                    ()
                case .some(.possibleFutureMessage(let futureMessage)):
                    precondition(!waitingForServerMessage, "Unexpected emit message while another message is being processed")
                    waitingForServerMessage = true

                    futureMessage.whenComplete { result in
                        waitingForServerMessage = false

                        switch result {
                        case .failure(let err):
                            XCTFail("Unexpected error in delayed message production: \(err)")
                        case .success(let message):
                            if let message = message {
                                serverMessage.append(message)
                            }
                        }
                    }
                case .some(.forwardToMultiplexer), .some(.globalRequest), .some(.globalRequestResponse), .some(.unimplemented), .some(.disconnect), .some(.event):
                    fatalError("Currently unsupported")
                }
            }

            // Bottom of the loop, run the event loop to fire any futures we might need.
            loop.run()
        }

        XCTAssertFalse(waitingForClientMessage, "Loop exited while waiting for a client message")
        XCTAssertFalse(waitingForServerMessage, "Loop exited while waiting for a server message")
    }

    private func assertForwardsToMultiplexer(_ message: SSHMessage, sender: inout SSHConnectionStateMachine, receiver: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop) throws {
        var tempBuffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try sender.processOutboundMessage(message, buffer: &tempBuffer, allocator: allocator, loop: loop))
        XCTAssert(tempBuffer.readableBytes > 0)

        receiver.bufferInboundData(&tempBuffer)
        let result = try assertNoThrowWithValue(receiver.processInboundMessage(allocator: allocator, loop: loop))

        switch result {
        case .some(.forwardToMultiplexer(let forwardedMessage)):
            XCTAssertEqual(forwardedMessage, message)
        case .some(.emitMessage), .some(.possibleFutureMessage), .some(.noMessage), .some(.globalRequest), .some(.globalRequestResponse), .some(.unimplemented), .some(.disconnect), .some(.event), .none:
            XCTFail("Unexpected result: \(String(describing: result))")
        }
    }

    private func assertSendingIsProtocolError(_ message: SSHMessage, sender: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop) throws {
        var tempBuffer = allocator.buffer(capacity: 1024)
        XCTAssertThrowsError(try sender.processOutboundMessage(message, buffer: &tempBuffer, allocator: allocator, loop: loop)) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
        XCTAssertEqual(tempBuffer.readableBytes, 0)
    }

    private func assertDisconnects(_ message: SSHMessage, sender: inout SSHConnectionStateMachine, receiver: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop) throws {
        var tempBuffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try sender.processOutboundMessage(message, buffer: &tempBuffer, allocator: allocator, loop: loop))
        XCTAssert(tempBuffer.readableBytes > 0)

        receiver.bufferInboundData(&tempBuffer)
        let result = try assertNoThrowWithValue(receiver.processInboundMessage(allocator: allocator, loop: loop))

        switch result {
        case .some(.disconnect):
            // Good
            break
        case .some(.forwardToMultiplexer), .some(.emitMessage), .some(.possibleFutureMessage), .some(.noMessage), .some(.globalRequest), .some(.globalRequestResponse), .some(.unimplemented), .some(.event), .none:
            XCTFail("Unexpected result: \(String(describing: result))")
        }
    }

    private func assertTriggersGlobalRequest(_ message: SSHMessage, sender: inout SSHConnectionStateMachine, receiver: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop) throws {
        var tempBuffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try sender.processOutboundMessage(message, buffer: &tempBuffer, allocator: allocator, loop: loop))
        XCTAssert(tempBuffer.readableBytes > 0)

        receiver.bufferInboundData(&tempBuffer)
        let result = try assertNoThrowWithValue(receiver.processInboundMessage(allocator: allocator, loop: loop))

        switch result {
        case .some(.globalRequest(let receivedMessage)):
            // Good
            XCTAssertEqual(.globalRequest(receivedMessage), message)
        case .some(.forwardToMultiplexer), .some(.emitMessage), .some(.possibleFutureMessage), .some(.noMessage), .some(.globalRequestResponse), .some(.unimplemented), .some(.disconnect), .some(.event), .none:
            XCTFail("Unexpected result: \(String(describing: result))")
        }
    }

    private func assertTriggersGlobalRequestResponse(_ message: SSHMessage, sender: inout SSHConnectionStateMachine, receiver: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop) throws -> SSHConnectionStateMachine.StateMachineInboundProcessResult.GlobalRequestResponse? {
        var tempBuffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try sender.processOutboundMessage(message, buffer: &tempBuffer, allocator: allocator, loop: loop))
        XCTAssert(tempBuffer.readableBytes > 0)

        receiver.bufferInboundData(&tempBuffer)
        let result = try assertNoThrowWithValue(receiver.processInboundMessage(allocator: allocator, loop: loop))

        switch result {
        case .some(.globalRequestResponse(let response)):
            // Good
            return response
        case .some(.forwardToMultiplexer), .some(.emitMessage), .some(.possibleFutureMessage), .some(.noMessage), .some(.globalRequest), .some(.unimplemented), .some(.disconnect), .some(.event), .none:
            XCTFail("Unexpected result: \(String(describing: result))")
            return nil
        }
    }

    func assertTriggersNothing(_ message: SSHMessage, sender: inout SSHConnectionStateMachine, receiver: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop) throws {
        var tempBuffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try sender.processOutboundMessage(message, buffer: &tempBuffer, allocator: allocator, loop: loop))
        XCTAssert(tempBuffer.readableBytes > 0)

        receiver.bufferInboundData(&tempBuffer)
        let result = try assertNoThrowWithValue(receiver.processInboundMessage(allocator: allocator, loop: loop))

        switch result {
        case .some(.noMessage):
            // Good
            break
        case .some(.forwardToMultiplexer), .some(.emitMessage), .some(.possibleFutureMessage), .some(.globalRequest), .some(.globalRequestResponse), .some(.unimplemented), .some(.disconnect), .some(.event), .none:
            XCTFail("Unexpected result: \(String(describing: result))")
        }
    }

    /// UNIMPLEMENTED must be reported without throwing, and the message after it in the
    /// same buffer must still be processed: throwing skipped the state write-back.
    private func assertUnimplementedIsTolerated(sequenceNumber: UInt32, sender: inout SSHConnectionStateMachine, receiver: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop) throws {
        var tempBuffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try sender.processOutboundMessage(.unimplemented(.init(sequenceNumber: sequenceNumber)), buffer: &tempBuffer, allocator: allocator, loop: loop))
        XCTAssertNoThrow(try sender.processOutboundMessage(.ignore(.init(data: allocator.buffer(capacity: 0))), buffer: &tempBuffer, allocator: allocator, loop: loop))
        XCTAssert(tempBuffer.readableBytes > 0)

        receiver.bufferInboundData(&tempBuffer)

        switch try assertNoThrowWithValue(receiver.processInboundMessage(allocator: allocator, loop: loop)) {
        case .some(.unimplemented(let reported)):
            XCTAssertEqual(reported, sequenceNumber)
        case let other:
            XCTFail("Unexpected result: \(String(describing: other))")
        }

        switch try assertNoThrowWithValue(receiver.processInboundMessage(allocator: allocator, loop: loop)) {
        case .some(.noMessage):
            break
        case let other:
            XCTFail("Message after UNIMPLEMENTED was not processed: \(String(describing: other))")
        }

        XCTAssertNil(try assertNoThrowWithValue(receiver.processInboundMessage(allocator: allocator, loop: loop)))
    }

    func testBasicConnectionDance() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        XCTAssertTrue(client.isActive)
        XCTAssertTrue(server.isActive)
    }

    // Messages that are usable once child channels are allowed.
    let channelMessages: [SSHMessage] = [
        .channelOpen(.init(type: .session, senderChannel: 0, initialWindowSize: 0, maximumPacketSize: 12)),
        .channelOpenConfirmation(.init(recipientChannel: 0, senderChannel: 0, initialWindowSize: 0, maximumPacketSize: 12)),
        .channelOpenFailure(.init(recipientChannel: 0, reasonCode: 0, description: "foo", language: "bar")),
        .channelEOF(.init(recipientChannel: 0)),
        .channelClose(.init(recipientChannel: 0)),
        .channelWindowAdjust(.init(recipientChannel: 0, bytesToAdd: 1)),
        .channelData(.init(recipientChannel: 0, data: ByteBufferAllocator().buffer(capacity: 0))),
        .channelExtendedData(.init(recipientChannel: 0, dataTypeCode: .stderr, data: ByteBufferAllocator().buffer(capacity: 0))),
        .channelRequest(.init(recipientChannel: 0, type: .exec("uname"), wantReply: false)),
        .channelSuccess(.init(recipientChannel: 0)),
        .channelFailure(.init(recipientChannel: 0)),
    ]

    func testReceivingChannelMessagesGetForwardedOnceConnectionMade() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))
        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        for message in self.channelMessages {
            XCTAssertNoThrow(try self.assertForwardsToMultiplexer(message, sender: &client, receiver: &server, allocator: allocator, loop: loop))
        }
    }

    func testDisconnectMessageCausesImmediateConnectionClose() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        XCTAssertFalse(client.disconnected)
        XCTAssertFalse(server.disconnected)

        // Have the client send and the server receive a disconnection message.
        try self.assertDisconnects(.disconnect(.init(reason: 0, description: "", tag: "")), sender: &client, receiver: &server, allocator: allocator, loop: loop)

        XCTAssertTrue(client.disconnected)
        XCTAssertTrue(server.disconnected)

        // Further messages are not sent.
        for message in self.channelMessages {
            XCTAssertNoThrow(try self.assertSendingIsProtocolError(message, sender: &client, allocator: allocator, loop: loop))
        }
    }

    func testDisconnectedReturnsNil() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)
        try self.assertDisconnects(.disconnect(.init(reason: 0, description: "", tag: "")), sender: &client, receiver: &server, allocator: allocator, loop: loop)

        // Ok, in disconnected state. At this time, any attempt to process the connection should return nil.
        var junkBuffer = allocator.buffer(capacity: 1024)
        junkBuffer.writeBytes(0 ... 255)
        server.bufferInboundData(&junkBuffer)

        XCTAssertNoThrow(try XCTAssertNil(server.processInboundMessage(allocator: allocator, loop: loop)))
    }

    func testGlobalRequestCanBeSent() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        var message = SSHMessage.GlobalRequestMessage(wantReply: true, type: .tcpipForward("foo", 66))
        try self.assertTriggersGlobalRequest(.globalRequest(message), sender: &client, receiver: &server, allocator: allocator, loop: loop)

        message = SSHMessage.GlobalRequestMessage(wantReply: false, type: .cancelTcpipForward("foo", 66))
        try self.assertTriggersGlobalRequest(.globalRequest(message), sender: &client, receiver: &server, allocator: allocator, loop: loop)
    }

    func testGlobalRequestResponsesTriggerResponse() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        // Deliver a request success message.
        var response = try self.assertTriggersGlobalRequestResponse(
            .requestSuccess(.init(.tcpForwarding(.init(boundPort: 6)), allocator: allocator)), sender: &server, receiver: &client, allocator: allocator, loop: loop
        )
        guard case .some(.success(let firstResponse)) = response, GlobalRequest.TCPForwardingResponse(firstResponse).boundPort == 6 else {
            XCTFail("Unexpected response: \(String(describing: response))")
            return
        }

        // Now without a port.
        response = try self.assertTriggersGlobalRequestResponse(
            .requestSuccess(.init(.tcpForwarding(.init(boundPort: nil)), allocator: allocator)), sender: &server, receiver: &client, allocator: allocator, loop: loop
        )
        guard case .some(.success(let secondResponse)) = response, GlobalRequest.TCPForwardingResponse(secondResponse).boundPort == nil else {
            XCTFail("Unexpected response: \(String(describing: response))")
            return
        }

        // Now a failure.
        response = try self.assertTriggersGlobalRequestResponse(
            .requestFailure, sender: &server, receiver: &client, allocator: allocator, loop: loop
        )
        guard case .some(.failure) = response else {
            XCTFail("Unexpected response: \(String(describing: response))")
            return
        }
    }

    func testIgnoreDebugAndIgnoreMessages() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        try self.assertTriggersNothing(.ignore(.init(data: allocator.buffer(capacity: 1024))), sender: &client, receiver: &server, allocator: allocator, loop: loop)
        try self.assertTriggersNothing(.debug(.init(alwaysDisplay: true, message: "foo", language: "bar")), sender: &client, receiver: &server, allocator: allocator, loop: loop)
    }

    func testServerSendsExtensionInfoBeforeUserAuthSuccess() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        let authDelegate = SignatureAlgorithmsRecordingPasswordDelegate()
        var client = SSHConnectionStateMachine(role: .client(.init(
            userAuthDelegate: authDelegate,
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )))
        var server = SSHConnectionStateMachine(role: .server(.init(
            hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
            userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 0)
        )))

        try assertSuccessfulConnection(
            client: &client,
            server: &server,
            allocator: allocator,
            loop: loop
        )

        // RFC 8308 permits one EXT_INFO after NEWKEYS and a second immediately
        // before USERAUTH_SUCCESS. Reaching active state proves the second was
        // processed before success rather than arriving late in .active.
        XCTAssertEqual(authDelegate.receivedAlgorithms.count, 2)
        for algorithms in authDelegate.receivedAlgorithms {
            XCTAssertTrue(algorithms.contains("ssh-ed25519-cert-v01@openssh.com"))
            XCTAssertTrue(algorithms.contains("ecdsa-sha2-nistp256-cert-v01@openssh.com"))
        }
    }

    func testServerCannotSendExtensionInfoAfterAuthentication() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(
            userAuthDelegate: InfinitePasswordDelegate(),
            serverAuthDelegate: AcceptAllHostKeysDelegate()
        )))
        var server = SSHConnectionStateMachine(role: .server(.init(
            hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
            userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1)
        )))

        try assertSuccessfulConnection(
            client: &client,
            server: &server,
            allocator: allocator,
            loop: loop
        )

        try self.assertSendingIsProtocolError(
            .extensionInfo(.serverSignatureAlgorithms(["ssh-rsa"])),
            sender: &server,
            allocator: allocator,
            loop: loop
        )
    }

    func testUnimplementedIsNotFatal() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)
        try self.assertUnimplementedIsTolerated(sequenceNumber: 0, sender: &client, receiver: &server, allocator: allocator, loop: loop)
    }

    private func assertEmitsSingleMessage(_ receiver: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop, file: StaticString = #filePath, line: UInt = #line) throws -> SSHMessage? {
        switch try assertNoThrowWithValue(receiver.processInboundMessage(allocator: allocator, loop: loop)) {
        case .some(.emitMessage(let multi)):
            let messages = Array(multi)
            XCTAssertEqual(messages.count, 1, file: file, line: line)
            return messages.first
        case let other:
            XCTFail("Unexpected result: \(String(describing: other))", file: file, line: line)
            return nil
        }
    }

    func testUnknownMessageTriggersUnimplementedAndRecovers() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        var tempBuffer = allocator.buffer(capacity: 1024)
        let unknown = SSHMessage.unknown(.init(type: 200, payload: ByteBuffer(bytes: [1, 2, 3])))
        XCTAssertNoThrow(try server.processOutboundMessage(unknown, buffer: &tempBuffer, allocator: allocator, loop: loop))
        XCTAssertNoThrow(try server.processOutboundMessage(unknown, buffer: &tempBuffer, allocator: allocator, loop: loop))
        XCTAssertNoThrow(try server.processOutboundMessage(.ignore(.init(data: allocator.buffer(capacity: 0))), buffer: &tempBuffer, allocator: allocator, loop: loop))
        client.bufferInboundData(&tempBuffer)

        var sequenceNumbers: [UInt32] = []
        for _ in 0 ..< 2 {
            guard case .some(.unimplemented(let reply)) = try self.assertEmitsSingleMessage(&client, allocator: allocator, loop: loop) else {
                XCTFail("Expected UNIMPLEMENTED")
                return
            }
            sequenceNumbers.append(reply.sequenceNumber)
        }
        XCTAssertEqual(sequenceNumbers[1], sequenceNumbers[0] &+ 1)

        // The IGNORE after the unknown messages must still be processed: the packets were consumed.
        switch try assertNoThrowWithValue(client.processInboundMessage(allocator: allocator, loop: loop)) {
        case .some(.noMessage):
            break
        case let other:
            XCTFail("Unexpected result: \(String(describing: other))")
        }
        XCTAssertNil(try assertNoThrowWithValue(client.processInboundMessage(allocator: allocator, loop: loop)))

        // The UNIMPLEMENTED reply is itself sendable and tolerated by the peer.
        var reply = allocator.buffer(capacity: 64)
        XCTAssertNoThrow(try client.processOutboundMessage(.unimplemented(.init(sequenceNumber: sequenceNumbers[0])), buffer: &reply, allocator: allocator, loop: loop))
        server.bufferInboundData(&reply)
        switch try assertNoThrowWithValue(server.processInboundMessage(allocator: allocator, loop: loop)) {
        case .some(.unimplemented(let reported)):
            XCTAssertEqual(reported, sequenceNumbers[0])
        case let other:
            XCTFail("Unexpected result: \(String(describing: other))")
        }
    }

    func testPingIsAnsweredWhenActive() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        let payload = ByteBuffer(bytes: [0, 0, 0, 3, 0x61, 0x62, 0x63])
        var tempBuffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try server.processOutboundMessage(.unknown(.init(type: SSHMessage.UnknownMessage.pingType, payload: payload)), buffer: &tempBuffer, allocator: allocator, loop: loop))
        client.bufferInboundData(&tempBuffer)

        let reply = try self.assertEmitsSingleMessage(&client, allocator: allocator, loop: loop)
        XCTAssertEqual(reply, .unknown(.init(type: SSHMessage.UnknownMessage.pongType, payload: payload)))

        // PONG is ignored by the receiver.
        var pong = allocator.buffer(capacity: 64)
        XCTAssertNoThrow(try client.processOutboundMessage(reply!, buffer: &pong, allocator: allocator, loop: loop))
        server.bufferInboundData(&pong)
        switch try assertNoThrowWithValue(server.processInboundMessage(allocator: allocator, loop: loop)) {
        case .some(.noMessage):
            break
        case let other:
            XCTFail("Unexpected result: \(String(describing: other))")
        }
    }

    func testPingIsDroppedDuringRekey() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        var kexInit = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try client.beginRekeying(buffer: &kexInit, allocator: allocator, loop: loop))

        var tempBuffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try server.processOutboundMessage(.unknown(.init(type: SSHMessage.UnknownMessage.pingType, payload: ByteBuffer(bytes: [0, 0, 0, 0]))), buffer: &tempBuffer, allocator: allocator, loop: loop))
        client.bufferInboundData(&tempBuffer)

        switch try assertNoThrowWithValue(client.processInboundMessage(allocator: allocator, loop: loop)) {
        case .some(.noMessage):
            break
        case let other:
            XCTFail("Unexpected result: \(String(describing: other))")
        }
    }

    private func exchangeVersions(client: inout SSHConnectionStateMachine, server: inout SSHConnectionStateMachine, allocator: ByteBufferAllocator, loop: EmbeddedEventLoop, serverPreKexInitMessage: SSHMessage? = nil) throws -> (clientKexInit: SSHMultiMessage, serverKexInit: SSHMultiMessage) {
        var clientBuffer = allocator.buffer(capacity: 1024)
        var serverBuffer = allocator.buffer(capacity: 1024)
        for message in client.start()! {
            XCTAssertNoThrow(try client.processOutboundMessage(message, buffer: &clientBuffer, allocator: allocator, loop: loop))
        }
        for message in server.start()! {
            XCTAssertNoThrow(try server.processOutboundMessage(message, buffer: &serverBuffer, allocator: allocator, loop: loop))
        }
        server.bufferInboundData(&clientBuffer)
        guard case .some(.emitMessage(let serverKexInit)) = try assertNoThrowWithValue(server.processInboundMessage(allocator: allocator, loop: loop)) else {
            throw NIOSSHError.protocolViolation(protocolName: "test", violation: "server did not emit KEXINIT")
        }
        // The server may only send once it has the client's version; the test then slips a packet in ahead of KEXINIT.
        if let serverPreKexInitMessage = serverPreKexInitMessage {
            XCTAssertNoThrow(try server.processOutboundMessage(serverPreKexInitMessage, buffer: &serverBuffer, allocator: allocator, loop: loop))
        }
        for message in serverKexInit {
            XCTAssertNoThrow(try server.processOutboundMessage(message, buffer: &serverBuffer, allocator: allocator, loop: loop))
        }

        // The client sees the version (emitting its KEXINIT), then the server's KEXINIT (emitting ECDH_INIT).
        client.bufferInboundData(&serverBuffer)
        var clientMessages: [SSHMessage] = []
        while let result = try client.processInboundMessage(allocator: allocator, loop: loop) {
            if case .emitMessage(let multi) = result {
                clientMessages.append(contentsOf: multi)
            }
        }
        guard case .some(.keyExchange(let clientKexInit)) = clientMessages.first else {
            throw NIOSSHError.protocolViolation(protocolName: "test", violation: "client did not emit KEXINIT")
        }
        return (SSHMultiMessage(.keyExchange(clientKexInit)), serverKexInit)
    }

    func testStrictKeyExchangeIsNegotiatedByDefaultAndSurvivesRekey() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)
        XCTAssertTrue(client._testOnly_strictKeyExchange)
        XCTAssertTrue(server._testOnly_strictKeyExchange)

        // A server-initiated rekey completes and the connection keeps working with reset sequence numbers.
        var buffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try server.beginRekeying(buffer: &buffer, allocator: allocator, loop: loop))
        client.bufferInboundData(&buffer)
        guard case .some(.emitMessage(let clientReply)) = try assertNoThrowWithValue(client.processInboundMessage(allocator: allocator, loop: loop)) else {
            XCTFail("Client did not answer KEXINIT")
            return
        }
        try self.run(clientMessage: clientReply, client: &client, serverMessage: nil, server: &server, allocator: allocator, loop: loop)
        XCTAssertTrue(client.isActive)
        XCTAssertTrue(server.isActive)
        XCTAssertTrue(client._testOnly_strictKeyExchange)

        for message in self.channelMessages {
            XCTAssertNoThrow(try self.assertForwardsToMultiplexer(message, sender: &client, receiver: &server, allocator: allocator, loop: loop))
            XCTAssertNoThrow(try self.assertForwardsToMultiplexer(message, sender: &server, receiver: &client, allocator: allocator, loop: loop))
        }
    }

    func testStrictKeyExchangeRejectsPacketBeforeKexInit() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        // The server's IGNORE precedes its KEXINIT. The IGNORE itself is tolerated (strict is not yet known),
        // but KEXINIT then arrives as packet 1 and must be rejected.
        XCTAssertThrowsError(try self.exchangeVersions(client: &client, server: &server, allocator: allocator, loop: loop, serverPreKexInitMessage: .ignore(.init(data: allocator.buffer(capacity: 0))))) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    func testStrictKeyExchangeRejectsIgnoreDuringInitialKex() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        _ = try self.exchangeVersions(client: &client, server: &server, allocator: allocator, loop: loop)
        XCTAssertTrue(client._testOnly_strictKeyExchange)

        var buffer = allocator.buffer(capacity: 64)
        XCTAssertNoThrow(try server.processOutboundMessage(.ignore(.init(data: allocator.buffer(capacity: 0))), buffer: &buffer, allocator: allocator, loop: loop))
        client.bufferInboundData(&buffer)
        XCTAssertThrowsError(try client.processInboundMessage(allocator: allocator, loop: loop)) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    /// Delayed host key validation lets the client receive the server's NEWKEYS before sending its own.
    /// The peer clears its initial-KEX restrictions only when it receives ours, so a reply sent in that
    /// window is a non-KEX packet a strict peer must reject. It has to wait for our NEWKEYS.
    func testUnimplementedReplyWaitsForOurNewKeys() throws {
        final class ManualValidationDelegate: NIOSSHClientServerAuthenticationDelegate {
            var promise: EventLoopPromise<Void>?

            func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
                self.promise = validationCompletePromise
            }
        }

        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        let delegate = ManualValidationDelegate()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: delegate)))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        var clientBuffer = allocator.buffer(capacity: 1024)
        var serverBuffer = allocator.buffer(capacity: 1024)
        var delayedClientMessage: SSHMultiMessage?
        var serverResults: [SSHConnectionStateMachine.StateMachineInboundProcessResult] = []

        func send(_ messages: SSHMultiMessage?, from machine: inout SSHConnectionStateMachine, into buffer: inout ByteBuffer) throws {
            guard let messages = messages else { return }
            for message in messages {
                try machine.processOutboundMessage(message, buffer: &buffer, allocator: allocator, loop: loop)
            }
        }

        func deliverToServer() throws {
            server.bufferInboundData(&clientBuffer)
            clientBuffer.clear()
            while let result = try assertNoThrowWithValue(server.processInboundMessage(allocator: allocator, loop: loop)) {
                serverResults.append(result)
                if case .emitMessage(let messages) = result {
                    try send(messages, from: &server, into: &serverBuffer)
                }
            }
        }

        func deliverToClient() throws {
            client.bufferInboundData(&serverBuffer)
            serverBuffer.clear()
            while let result = try assertNoThrowWithValue(client.processInboundMessage(allocator: allocator, loop: loop)) {
                switch result {
                case .emitMessage(let messages):
                    try send(messages, from: &client, into: &clientBuffer)
                case .possibleFutureMessage(let future):
                    future.whenComplete { outcome in
                        switch outcome {
                        case .success(let messages):
                            delayedClientMessage = messages
                        case .failure(let error):
                            XCTFail("Unexpected validation failure: \(error)")
                        }
                    }
                case .noMessage, .unimplemented, .event:
                    ()
                default:
                    XCTFail("Unexpected client result: \(result)")
                }
            }
        }

        try send(client.start(), from: &client, into: &clientBuffer)
        try send(server.start(), from: &server, into: &serverBuffer)
        try deliverToServer()
        try deliverToClient()
        try deliverToServer()
        // The client now holds the server's NEWKEYS while its own waits on host key validation.
        try deliverToClient()
        XCTAssertTrue(client._testOnly_strictKeyExchange)
        XCTAssertNotNil(delegate.promise)
        XCTAssertEqual(clientBuffer.readableBytes, 0)

        try server.processOutboundMessage(.unknown(.init(type: 201, payload: ByteBuffer(bytes: [9]))), buffer: &serverBuffer, allocator: allocator, loop: loop)
        try deliverToClient()
        XCTAssertEqual(clientBuffer.readableBytes, 0, "UNIMPLEMENTED must not be sent before our NEWKEYS")

        delegate.promise?.succeed(())
        loop.run()
        try send(XCTUnwrap(delayedClientMessage), from: &client, into: &clientBuffer)

        serverResults.removeAll()
        try deliverToServer()
        let reported = serverResults.compactMap { result -> UInt32? in
            guard case .unimplemented(let sequenceNumber) = result else { return nil }
            return sequenceNumber
        }
        // Strict KEX reset the client's inbound counter at the server's NEWKEYS. The server's EXT_INFO
        // is then packet 0 and the unknown message packet 1, which is what the reply must name.
        XCTAssertEqual(reported, [1])
    }

    func testWeTolerateMessagesAfterSendingKexInit() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        // Ok, the server is going to try to rekey.
        var buffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try server.beginRekeying(buffer: &buffer, allocator: allocator, loop: loop))

        // We're not passing this to the client though. Now we'll send all the channel messages through: the server should tolerate them
        // all.
        for message in self.channelMessages {
            XCTAssertNoThrow(try self.assertForwardsToMultiplexer(message, sender: &client, receiver: &server, allocator: allocator, loop: loop))
        }
    }

    func testWeTolerateMultipleStarts() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))

        let message = client.start()
        guard case message = Optional.some(SSHMultiMessage(SSHMessage.version(Constants.version))) else {
            XCTFail("Unexpected message")
            return
        }

        var buffer = allocator.buffer(capacity: 42)
        XCTAssertNoThrow(try client.processOutboundMessage(SSHMessage.version(Constants.version), buffer: &buffer, allocator: allocator, loop: loop))

        XCTAssertNil(client.start())
    }

    func testClientToleratesLinesBeforeVersion() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))

        let message = client.start()
        guard case message = Optional.some(SSHMultiMessage(SSHMessage.version(Constants.version))) else {
            XCTFail("Unexpected message")
            return
        }

        var buffer = allocator.buffer(capacity: 42)
        XCTAssertNoThrow(try client.processOutboundMessage(SSHMessage.version(Constants.version), buffer: &buffer, allocator: allocator, loop: loop))

        var version = ByteBuffer(string: "xxxx\nyyy\nSSH-2.0-OpenSSH_8.1\r\n")
        client.bufferInboundData(&version)

        XCTAssertNoThrow(try client.processInboundMessage(allocator: allocator, loop: loop))
    }

    func testServerRejectsLinesBeforeVersion() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var server = SSHConnectionStateMachine(role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 1))))

        let message = server.start()
        guard case message = Optional.some(SSHMultiMessage(SSHMessage.version(Constants.version))) else {
            XCTFail("Unexpected message")
            return
        }

        var buffer = allocator.buffer(capacity: 42)
        XCTAssertNoThrow(try server.processOutboundMessage(SSHMessage.version(Constants.version), buffer: &buffer, allocator: allocator, loop: loop))

        var version = ByteBuffer(string: "xxxx\nyyy\nSSH-2.0-OpenSSH_8.1\r\n")
        server.bufferInboundData(&version)

        XCTAssertThrowsError(try server.processInboundMessage(allocator: allocator, loop: loop)) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    func testClintVersionNotFound() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))

        let message = client.start()
        guard case message = Optional.some(SSHMultiMessage(SSHMessage.version(Constants.version))) else {
            XCTFail("Unexpected message")
            return
        }

        var buffer = allocator.buffer(capacity: 42)
        XCTAssertNoThrow(try client.processOutboundMessage(SSHMessage.version(Constants.version), buffer: &buffer, allocator: allocator, loop: loop))

        var version = ByteBuffer(string: "SSH-\r\n")
        client.bufferInboundData(&version)

        XCTAssertThrowsError(try client.processInboundMessage(allocator: allocator, loop: loop)) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .protocolViolation)
        }
    }

    func testVersionNotSupported() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        var client = SSHConnectionStateMachine(role: .client(.init(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())))

        let message = client.start()
        guard case message = Optional.some(SSHMultiMessage(SSHMessage.version(Constants.version))) else {
            XCTFail("Unexpected message")
            return
        }

        var buffer = allocator.buffer(capacity: 42)
        XCTAssertNoThrow(try client.processOutboundMessage(SSHMessage.version(Constants.version), buffer: &buffer, allocator: allocator, loop: loop))

        var version = ByteBuffer(string: "SSH-1.0-OpenSSH_8.1\r\n")
        client.bufferInboundData(&version)

        XCTAssertThrowsError(try client.processInboundMessage(allocator: allocator, loop: loop)) { error in
            XCTAssertEqual((error as? NIOSSHError)?.type, .unsupportedVersion)
        }
    }

    func testFirstBlockDecodedOnce() throws {
        let allocator = ByteBufferAllocator()
        let loop = EmbeddedEventLoop()
        let schemes: [NIOSSHTransportProtection.Type] = [TestTransportProtection.self]
        
        var clientConfig = SSHClientConfiguration(userAuthDelegate: InfinitePasswordDelegate(), serverAuthDelegate: AcceptAllHostKeysDelegate())
        clientConfig.transportProtectionSchemes = schemes
        var serverConfig = SSHServerConfiguration(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: DenyThenAcceptDelegate(messagesToDeny: 0))
        serverConfig.transportProtectionSchemes = schemes
        var client = SSHConnectionStateMachine(role: .client(clientConfig))
        var server = SSHConnectionStateMachine(role: .server(serverConfig))
        try assertSuccessfulConnection(client: &client, server: &server, allocator: allocator, loop: loop)

        let message = SSHMessage.channelData(.init(recipientChannel: 1, data: ByteBuffer(repeating: 17, count: 5)))

        var tempBuffer = allocator.buffer(capacity: 1024)
        XCTAssertNoThrow(try client.processOutboundMessage(message, buffer: &tempBuffer, allocator: allocator, loop: loop))
        XCTAssert(tempBuffer.readableBytes > 0)

        while var next = tempBuffer.readSlice(length: 1) {
            server.bufferInboundData(&next)
            if tempBuffer.readableBytes > 0 {
                XCTAssertNil(try server.processInboundMessage(allocator: allocator, loop: loop))
            }
        }

        var result = try server.processInboundMessage(allocator: allocator, loop: loop)
        switch result {
        case .some(.forwardToMultiplexer(let forwardedMessage)):
            XCTAssertEqual(forwardedMessage, message)
        case .some(.emitMessage), .some(.possibleFutureMessage), .some(.noMessage), .some(.globalRequest), .some(.globalRequestResponse), .some(.unimplemented), .some(.disconnect), .some(.event), .none:
            XCTFail("Unexpected result: \(String(describing: result))")
        }

        tempBuffer.clear()
        XCTAssertNoThrow(try client.beginRekeying(buffer: &tempBuffer, allocator: allocator, loop: loop))

        while var next = tempBuffer.readSlice(length: 1) {
            server.bufferInboundData(&next)
            if tempBuffer.readableBytes > 0 {
                XCTAssertNil(try server.processInboundMessage(allocator: allocator, loop: loop))
            }
        }

        result = try server.processInboundMessage(allocator: allocator, loop: loop)
        switch result {
        case .some(.emitMessage(let message)):
            XCTAssertNoThrow(try self.run(clientMessage: nil, client: &client, serverMessage: message, server: &server, allocator: allocator, loop: loop, dripFeed: true))
        case .some(.forwardToMultiplexer), .some(.possibleFutureMessage), .some(.noMessage), .some(.globalRequest), .some(.globalRequestResponse), .some(.unimplemented), .some(.disconnect), .some(.event), .none:
            XCTFail("Unexpected result: \(String(describing: result))")
        }
    }
}

extension Optional where Wrapped == SSHMultiMessage {
    mutating func append(_ message: SSHMultiMessage) {
        if let original = self {
            precondition(original.count == 1)
            precondition(message.count == 1)
            self = .some(SSHMultiMessage(original.first!, message.first!))
        } else {
            self = .some(message)
        }
    }
}
