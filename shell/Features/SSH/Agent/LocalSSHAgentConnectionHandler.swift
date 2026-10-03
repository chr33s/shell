//
//  LocalSSHAgentConnectionHandler.swift
//  shell
//
//  Plain-byte SSH agent transport for one AF_UNIX client
//  (ssh-agent-bridge-spec.md §8). Citadel's `AgentChannelHandler` speaks SSH
//  channel data for remote forwarding and is deliberately not reused; only
//  its message parser/serializer are.
//
//  Framing: `uint32 length || payload`, capped at 256 KiB. The decoder copes
//  with split headers, split payloads and several frames per read; an
//  over-long length fails the connection before anything of that size is
//  allocated. Requests on one connection are answered strictly in order.
//

import Foundation
import NIOCore
import Citadel
import os

/// Splits the byte stream into agent message payloads (length prefix removed).
nonisolated struct LocalSSHAgentFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    static let maxFrameLength = 256 * 1024

    enum FrameError: Error, Equatable {
        case frameTooLarge(UInt32)
    }

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let frame = try Self.nextFrame(from: &buffer) else {
            return .needMoreData
        }
        context.fireChannelRead(Self.wrapInboundOut(frame))
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        try decode(context: context, buffer: &buffer)
    }

    /// Consumes one complete frame from `buffer`, or nothing if it is not all
    /// there yet. Throws as soon as the header announces an over-cap length.
    static func nextFrame(from buffer: inout ByteBuffer) throws -> ByteBuffer? {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else {
            return nil
        }
        guard length <= UInt32(maxFrameLength) else {
            throw FrameError.frameTooLarge(length)
        }
        guard buffer.readableBytes >= 4 + Int(length) else {
            return nil
        }
        buffer.moveReaderIndex(forwardBy: 4)
        return buffer.readSlice(length: Int(length))
    }
}

/// Turns one request payload into one response. The read-only V1 surface:
/// identities, sign, and an extension failure; everything else fails.
nonisolated struct LocalSSHAgentResponder: Sendable {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "LocalSSHAgent")

    let delegate: any SSHAgentDelegate
    /// Global bound on in-flight signing (ssh-agent-bridge-v2-delta.md §7.3).
    let signLimiter: LocalSSHAgentSignLimiter

    init(delegate: any SSHAgentDelegate, signLimiter: LocalSSHAgentSignLimiter = LocalSSHAgentSignLimiter()) {
        self.delegate = delegate
        self.signLimiter = signLimiter
    }

    /// Returns the framed response (length prefix included). Never throws:
    /// every request gets exactly one answer so OpenSSH clients never hang.
    func respond(to payload: ByteBuffer) async -> ByteBuffer {
        SSHAgentMessageSerializer.serialize(await response(to: payload))
    }

    func response(to payload: ByteBuffer) async -> SSHAgentMessage {
        var payload = payload
        let message: SSHAgentMessage
        do {
            message = try SSHAgentMessageParser.parse(&payload)
        } catch {
            Self.logger.info("Agent request: malformed message")
            return .failure
        }

        switch message {
        case .requestIdentities:
            do {
                let identities = try await delegate.listIdentities()
                Self.logger.debug("Agent request: identities (\(identities.count) advertised)")
                return .identitiesAnswer(identities)
            } catch {
                return .failure
            }

        case .signRequest(let request):
            guard signLimiter.tryAcquire() else {
                Self.logger.info("Agent request: sign refused, in-flight limit reached")
                return .failure
            }
            defer { signLimiter.release() }
            do {
                guard let signature = try await delegate.sign(
                    publicKeyBlob: request.publicKeyBlob,
                    data: request.data,
                    flags: request.flags
                ) else {
                    return .failure
                }
                return .signResponse(signature)
            } catch {
                return .failure
            }

        case .extensionRequest(let request):
            Self.logger.debug("Agent request: unsupported extension \(request.extensionName, privacy: .public)")
            return .extensionFailure

        case .unknown(let type):
            // Add/remove identity, smartcard, lock/unlock and unknown types:
            // the agent is read-only, Shell's UI owns the key set.
            Self.logger.info("Agent request: rejected message type \(type)")
            return .failure

        case .identitiesAnswer, .signResponse, .failure, .success, .extensionFailure:
            // Agent → client message types sent to the agent. Answer rather
            // than ignore so a confused client does not wait forever.
            return .failure
        }
    }
}
