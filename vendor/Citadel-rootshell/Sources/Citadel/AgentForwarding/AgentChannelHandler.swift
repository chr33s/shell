//===----------------------------------------------------------------------===//
//
// This source file is part of the Citadel open source project
//
// Copyright (c) 2025 Citadel contributors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOSSH
import Logging

/// A channel handler that processes SSH agent protocol messages.
///
/// This handler is added to agent channels (auth-agent@openssh.com) and
/// handles the SSH agent protocol, delegating actual operations to an
/// `SSHAgentDelegate`.
public final class AgentChannelHandler: ChannelDuplexHandler {
    public typealias InboundIn = SSHChannelData
    public typealias InboundOut = Never
    public typealias OutboundIn = SSHChannelData
    public typealias OutboundOut = SSHChannelData

    private let delegate: SSHAgentDelegate
    private var buffer: ByteBuffer
    private let logger: Logger

    /// Creates a new agent channel handler.
    ///
    /// - Parameters:
    ///   - delegate: The delegate to handle agent operations.
    ///   - allocator: The byte buffer allocator to use.
    public init(delegate: SSHAgentDelegate, allocator: ByteBufferAllocator = ByteBufferAllocator()) {
        self.delegate = delegate
        self.buffer = allocator.buffer(capacity: 4096)
        self.logger = Logger(label: "nl.orlandos.citadel.agent")
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)

        // Only handle channel data (not extended data)
        guard channelData.type == .channel else {
            return
        }

        // Extract buffer from IOData
        guard case .byteBuffer(var incoming) = channelData.data else {
            return
        }

        // Accumulate data in buffer
        buffer.writeBuffer(&incoming)

        // Process complete messages
        processMessages(context: context)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        logger.debug("Agent channel closed")
        context.fireChannelInactive()
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Agent channel error: \(error)")
        context.close(promise: nil)
    }

    // MARK: - Private

    private func processMessages(context: ChannelHandlerContext) {
        while let message = tryReadMessage() {
            handleMessage(message, context: context)
        }
    }

    private func tryReadMessage() -> SSHAgentMessage? {
        // Need at least 4 bytes for length
        guard buffer.readableBytes >= 4 else {
            return nil
        }

        // Peek at length without consuming
        let readerIndex = buffer.readerIndex
        guard let length = buffer.getInteger(at: readerIndex, as: UInt32.self) else {
            return nil
        }

        // Check if we have the full message
        let totalLength = 4 + Int(length)
        guard buffer.readableBytes >= totalLength else {
            return nil
        }

        // Consume length
        buffer.moveReaderIndex(forwardBy: 4)

        // Read and parse message
        guard var messageBuffer = buffer.readSlice(length: Int(length)) else {
            return nil
        }

        do {
            return try SSHAgentMessageParser.parse(&messageBuffer)
        } catch {
            logger.error("Failed to parse agent message: \(error)")
            return .failure
        }
    }

    private func handleMessage(_ message: SSHAgentMessage, context: ChannelHandlerContext) {
        let eventLoop = context.eventLoop

        switch message {
        case .requestIdentities:
            Task {
                await self.handleRequestIdentities(context: context, eventLoop: eventLoop)
            }

        case .signRequest(let request):
            Task {
                await self.handleSignRequest(request, context: context, eventLoop: eventLoop)
            }

        case .extensionRequest(let request):
            // Handle extension requests - we don't support any extensions currently,
            // so respond with SSH_AGENT_EXTENSION_FAILURE
            logger.debug("Received agent extension request: \(request.extensionName)")
            let response = SSHAgentMessageSerializer.serialize(.extensionFailure)
            let data = SSHChannelData(type: .channel, data: .byteBuffer(response))
            context.writeAndFlush(self.wrapOutboundOut(data), promise: nil)

        case .failure, .success, .identitiesAnswer, .signResponse, .extensionFailure:
            // These are responses, not requests - ignore them
            logger.warning("Received unexpected agent response message")

        case .unknown(let typeRaw):
            // Unknown message type - log the raw value for debugging
            logger.warning("Received unknown agent message type: \(typeRaw)")
        }
    }

    private func handleRequestIdentities(context: ChannelHandlerContext, eventLoop: EventLoop) async {
        do {
            let identities = try await delegate.listIdentities()
            let response = SSHAgentMessageSerializer.serialize(.identitiesAnswer(identities))
            await sendResponse(response, context: context, eventLoop: eventLoop)
        } catch {
            logger.error("Failed to list identities: \(error)")
            let response = SSHAgentMessageSerializer.serialize(.failure)
            await sendResponse(response, context: context, eventLoop: eventLoop)
        }
    }

    private func handleSignRequest(_ request: SSHAgentSignRequest, context: ChannelHandlerContext, eventLoop: EventLoop) async {
        do {
            if let signature = try await delegate.sign(
                publicKeyBlob: request.publicKeyBlob,
                data: request.data,
                flags: request.flags
            ) {
                let response = SSHAgentMessageSerializer.serialize(.signResponse(signature))
                await sendResponse(response, context: context, eventLoop: eventLoop)
            } else {
                // Signing denied
                let response = SSHAgentMessageSerializer.serialize(.failure)
                await sendResponse(response, context: context, eventLoop: eventLoop)
            }
        } catch {
            logger.error("Failed to sign: \(error)")
            let response = SSHAgentMessageSerializer.serialize(.failure)
            await sendResponse(response, context: context, eventLoop: eventLoop)
        }
    }

    private func sendResponse(_ buffer: ByteBuffer, context: ChannelHandlerContext, eventLoop: EventLoop) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            eventLoop.execute {
                let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
                context.writeAndFlush(self.wrapOutboundOut(data), promise: nil)
                continuation.resume()
            }
        }
    }
}
