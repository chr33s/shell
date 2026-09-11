//===----------------------------------------------------------------------===//
//
// This source file is part of the Citadel open source project
//
// Copyright (c) 2026 Citadel contributors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOSSH
import Logging

/// Channel handler that translates between `SSHChannelData` (NIOSSH's
/// raw channel transport) and plain `ByteBuffer`s so callers consuming a
/// forwarded-streamlocal channel can treat it as a normal NIO byte
/// pipeline. Inbound channel data is unwrapped and forwarded; outbound
/// writes are wrapped into `SSHChannelData(type: .channel, ...)`.
///
/// Mirrors what the existing `DataToBufferCodec` does for TCP-IP
/// forwarding, but lives here so the streamlocal feature is
/// self-contained and discoverable.
public final class StreamLocalChannelHandler: ChannelDuplexHandler {
    public typealias InboundIn = SSHChannelData
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = SSHChannelData

    private let logger: Logger

    public init() {
        self.logger = Logger(label: "nl.orlandos.citadel.streamlocal")
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        // Only normal channel data; extended data (stderr equivalent)
        // never appears on streamlocal channels.
        guard channelData.type == .channel else { return }
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        context.fireChannelRead(self.wrapInboundOut(buffer))
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = self.unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        context.write(self.wrapOutboundOut(wrapped), promise: promise)
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("streamlocal channel error: \(error)")
        context.close(promise: nil)
    }
}
