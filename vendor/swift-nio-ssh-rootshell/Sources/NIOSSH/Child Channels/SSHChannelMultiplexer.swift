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

/// An object that controls multiplexing messages to multiple child channels.
final class SSHChannelMultiplexer {
    private var channels: [UInt32: SSHChildChannel]

    private var erroredChannels: [UInt32]

    // This object can cause a reference cycle, so we require it to be optional so that we can
    // break the cycle manually.
    private var delegate: SSHMultiplexerDelegate?

    /// The next local channel ID to use. We cycle through them monotonically for now.
    private var nextChannelID: UInt32

    private let allocator: ByteBufferAllocator

    private var childChannelInitializer: SSHChildChannel.Initializer?

    /// Whether new channels are allowed. Set to `false` once the parent channel is shut down at the TCP level.
    private var canCreateNewChannels: Bool

    internal let maximumPacketSize: Int
    internal let initialWindowSize: Int
    internal let channelOpenWindowSize: Int

    // MARK: - Aggregate Window Budget
    // Caps the total outstanding WindowAdjust credit across all child channels.
    // This prevents data from saturating the shared TCP pipe and blocking
    // control messages (ChannelOpenConfirmation) — the root cause of SSH VPN stalls.
    // OpenSSH avoids this by only sending WindowAdjust after downstream write() completes;
    // NIO SSH sends it on pipeline delivery (effectively immediate). This budget
    // re-introduces aggregate flow control without requiring per-handler changes.

    /// Maximum total outstanding WindowAdjust bytes across all channels (0 = unlimited).
    internal let aggregateWindowBudget: Int

    /// Total WindowAdjust bytes sent but not yet consumed by incoming ChannelData.
    private var aggregateOutstandingCredit: Int = 0

    /// Per-channel outstanding WindowAdjust credit, for accurate cleanup on channel close.
    private var perChannelCredit: [UInt32: Int] = [:]

    /// FIFO queue of channel IDs that have deferred WindowAdjust due to budget exhaustion.
    private var channelsNeedingAdjust: [UInt32] = []

    /// Tracks when each child channel was created (localID → timestamp in µs)
    /// so we can measure latency to ChannelOpenConfirmation.
    private var channelCreationTimestamps: [UInt32: Int64] = [:]

    /// Timestamp of the last successful WindowAdjust (for stall detection).
    private var lastWindowAdjustTimeUs: Int64 = 0

    /// Timestamp of the last state snapshot log (throttle to every 2s).
    private var lastSnapshotTimeUs: Int64 = 0

    /// Total WindowAdjust bytes granted since last snapshot (measures throughput).
    private var windowAdjustBytesSinceSnapshot: Int64 = 0

    /// Total ChannelData bytes consumed since last snapshot.
    private var channelDataBytesSinceSnapshot: Int64 = 0

    // MARK: - Per-snapshot inbound/outbound message accumulators
    // These track SSH message flow between snapshots (every 2s) to diagnose stalls.
    // Reset at the end of each snapshot.
    private var snapDataPkts: Int = 0          // ChannelData packets received from server
    private var snapDataBytes: Int64 = 0       // ChannelData bytes received from server
    private var snapWaIn: Int = 0              // WindowAdjust received (server granting us send credit)
    private var snapWaOut: Int = 0             // WindowAdjust sent (us granting server send credit)
    private var snapWaOutBytes: Int64 = 0      // Bytes granted via outbound WindowAdjust
    private var snapConfirms: Int = 0          // ChannelOpenConfirmation received
    private var snapFailures: Int = 0          // ChannelOpenFailure received
    private var snapCloses: Int = 0            // ChannelClose received
    private var snapEOFs: Int = 0              // ChannelEOF received
    private var snapTcpReads: Int = 0          // channelRead calls (TCP read batches)
    private var snapTcpBytes: Int64 = 0        // Raw TCP bytes received
    private var lastChannelReadUs: Int64 = 0   // Timestamp of last channelRead
    private var snapNonChannelMsgs: Int = 0    // Non-channel SSH messages (rekey, keepalive, etc.)
    private var snapSshPacketsParsed: Int = 0  // Total SSH packets parsed by state machine

    init(
        delegate: SSHMultiplexerDelegate,
        allocator: ByteBufferAllocator,
        childChannelInitializer: SSHChildChannel.Initializer?,
        maximumPacketSize: Int = 1 << 17,
        initialWindowSize: Int = SSHPacketParser.defaultMaximumPacketSize * 64,
        channelOpenWindowSize: Int = 0,
        aggregateWindowBudget: Int = 0
    ) {
        precondition(initialWindowSize > 0, "initialWindowSize must be positive")
        precondition(initialWindowSize <= Int(Int32.max), "initialWindowSize must fit in Int32")
        self.channels = [:]
        self.channels.reserveCapacity(8)
        self.erroredChannels = []
        self.delegate = delegate
        self.nextChannelID = 0
        self.allocator = allocator
        self.childChannelInitializer = childChannelInitializer
        self.canCreateNewChannels = true
        self.maximumPacketSize = maximumPacketSize
        self.initialWindowSize = initialWindowSize
        // 0 means use initialWindowSize (the default / backwards-compatible behavior).
        self.channelOpenWindowSize = channelOpenWindowSize > 0 ? channelOpenWindowSize : initialWindowSize
        self.aggregateWindowBudget = aggregateWindowBudget
    }

    // Time to clean up. We drop references to things that may be keeping us alive.
    // Note that we don't drop the child channels because we expect that they'll be cleaning themselves up.
    func parentHandlerRemoved() {
        self.delegate = nil
        self.childChannelInitializer = nil
        self.canCreateNewChannels = false
    }

    // MARK: - Inbound message recording for snapshot diagnostics

    /// Called by NIOSSHHandler for every message forwarded to the multiplexer.
    /// Accumulates per-snapshot stats before the message is dispatched.
    func recordInboundMessage(_ message: SSHMessage) {
        switch message {
        case .channelData(let msg):
            snapDataPkts += 1
            snapDataBytes += Int64(msg.data.readableBytes)
        case .channelExtendedData(let msg):
            snapDataPkts += 1
            snapDataBytes += Int64(msg.data.readableBytes)
        case .channelWindowAdjust:
            snapWaIn += 1
        case .channelOpenConfirmation:
            snapConfirms += 1
        case .channelOpenFailure:
            snapFailures += 1
        case .channelClose:
            snapCloses += 1
        case .channelEOF:
            snapEOFs += 1
        default:
            break
        }
    }

    /// Called by NIOSSHHandler on each channelRead (TCP data arrival).
    func recordChannelRead(tcpBytes: Int) {
        snapTcpReads += 1
        snapTcpBytes += Int64(tcpBytes)
        lastChannelReadUs = NIOSSHDebug.nowUs()
    }

    /// Called by NIOSSHHandler for every state machine result.
    /// `isChannel` is true for forwardToMultiplexer results, false for
    /// transport-level results (rekey, keepalive, global requests, etc.).
    func recordStateMachineResult(isChannel: Bool) {
        snapSshPacketsParsed += 1
        if !isChannel {
            snapNonChannelMsgs += 1
        }
    }
}

// MARK: Calls from child channels

extension SSHChannelMultiplexer {
    /// An `SSHChildChannel` has issued a write.
    func writeFromChannel(_ message: SSHMessage, _ promise: EventLoopPromise<Void>?) {
        guard let delegate = self.delegate else {
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }

        delegate.writeFromChildChannel(message, promise)
    }

    /// An `SSHChildChannel` has issued a flush.
    func childChannelFlush() {
        // Nothing to do.
        guard let delegate = self.delegate else {
            return
        }

        delegate.flushFromChildChannel()
    }

    func childChannelClosed(channelID: UInt32) {
        // This should never return `nil`, but we don't want to assert on it because
        // even if the object was never in the map, nothing bad will happen: it's gone!
        self.channels.removeValue(forKey: channelID)
        self.channelCreationTimestamps.removeValue(forKey: channelID)
        self.cleanupChannelCredit(channelID: channelID)
        NIOSSHDebug.shared.increment("niossh.multiplexer.childClosed")
        NIOSSHDebug.shared.tsLog("CHAN-CLOSED id=\(channelID) totalCh=\(self.channels.count) pendConfirm=\(self.channelCreationTimestamps.count)")
    }

    func childChannelErrored(channelID: UInt32, expectClose: Bool) {
        // This should never return `nil`, but we don't want to assert on it because
        // even if the object was never in the map, nothing bad will happen: it's gone!
        self.channels.removeValue(forKey: channelID)
        self.channelCreationTimestamps.removeValue(forKey: channelID)
        self.cleanupChannelCredit(channelID: channelID)
        NIOSSHDebug.shared.increment("niossh.multiplexer.childErrored")
        NIOSSHDebug.shared.tsLog("CHAN-ERRORED id=\(channelID) totalCh=\(self.channels.count) expectClose=\(expectClose)")

        if expectClose {
            // We keep track of the errored channel because we will tolerate receiving a close for it.
            self.erroredChannels.append(channelID)
        }
    }
    
    // The username which the server accepted in authorization
    var username: String? { delegate?.username }
}

// MARK: Calls from SSH handlers.

extension SSHChannelMultiplexer {
    func receiveMessage(_ message: SSHMessage) throws {
        let channel: SSHChildChannel?

        switch message {
        case .channelOpen:
            NIOSSHDebug.shared.increment("niossh.msg.channelOpen")
            channel = try self.openNewChannel(initializer: self.childChannelInitializer)

        case .channelOpenConfirmation(let message):
            NIOSSHDebug.shared.increment("niossh.msg.channelOpenConfirm")
            if let ts = self.channelCreationTimestamps.removeValue(forKey: message.recipientChannel) {
                let elapsed = NIOSSHDebug.nowUs() - ts
                NIOSSHDebug.shared.increment("niossh.channelOpenConfirm.latencyUs", by: elapsed)
                NIOSSHDebug.shared.event("channel-confirmed id=\(message.recipientChannel) latency=\(elapsed)us")
                NIOSSHDebug.shared.tsLog("CONFIRM id=\(message.recipientChannel) latency=\(elapsed/1000)ms totalCh=\(self.channels.count) pendConfirm=\(self.channelCreationTimestamps.count)")
            }
            channel = try self.existingChannel(localID: message.recipientChannel)
            // Late confirmation for a cancelled pre-activation channel:
            // send ChannelClose to clean up the server-side orphan.
            // Keep the ID in erroredChannels so the server's reply ChannelClose
            // is tolerated (the existing channelClose handler removes it).
            if channel == nil, self.erroredChannels.contains(message.recipientChannel) {
                NIOSSHDebug.shared.tsLog("LATE-CONFIRM-CLOSE id=\(message.recipientChannel) remoteCh=\(message.senderChannel)")
                let closeMsg = SSHMessage.ChannelCloseMessage(recipientChannel: message.senderChannel)
                self.delegate?.writeFromChildChannel(.channelClose(closeMsg), nil)
                self.delegate?.flushFromChildChannel()
            }

        case .channelOpenFailure(let message):
            NIOSSHDebug.shared.increment("niossh.msg.channelOpenFailure")
            self.channelCreationTimestamps.removeValue(forKey: message.recipientChannel)
            NIOSSHDebug.shared.tsLog("OPEN-FAIL id=\(message.recipientChannel) reason=\(message.reasonCode) totalCh=\(self.channels.count)")
            channel = try self.existingChannel(localID: message.recipientChannel)
            // Late failure for a cancelled pre-activation channel: just clean up.
            if channel == nil, let idx = self.erroredChannels.firstIndex(of: message.recipientChannel) {
                NIOSSHDebug.shared.tsLog("LATE-OPEN-FAIL id=\(message.recipientChannel)")
                self.erroredChannels.remove(at: idx)
            }

        case .channelEOF(let message):
            channel = try self.existingChannel(localID: message.recipientChannel)

        case .channelClose(let message):
            NIOSSHDebug.shared.tsLog("CHAN-CLOSE id=\(message.recipientChannel) totalCh=\(self.channels.count)")
            channel = try self.existingChannel(localID: message.recipientChannel)
            if channel == nil, let errorIndex = self.erroredChannels.firstIndex(of: message.recipientChannel) {
                // This is the end of our need to keep track of the channel.
                self.erroredChannels.remove(at: errorIndex)
            }

        case .channelWindowAdjust(let message):
            NIOSSHDebug.shared.increment("niossh.msg.windowAdjust")
            channel = try self.existingChannel(localID: message.recipientChannel)

        case .channelData(let message):
            NIOSSHDebug.shared.increment("niossh.msg.channelData")
            self.didReceiveChannelData(channelID: message.recipientChannel, bytes: message.data.readableBytes)
            channel = try self.existingChannel(localID: message.recipientChannel)

        case .channelExtendedData(let message):
            self.didReceiveChannelData(channelID: message.recipientChannel, bytes: message.data.readableBytes)
            channel = try self.existingChannel(localID: message.recipientChannel)

        case .channelRequest(let message):
            channel = try self.existingChannel(localID: message.recipientChannel)

        case .channelSuccess(let message):
            channel = try self.existingChannel(localID: message.recipientChannel)

        case .channelFailure(let message):
            channel = try self.existingChannel(localID: message.recipientChannel)

        default:
            // Not a channel message, we don't do anything more with this.
            return
        }

        if let channel = channel {
            channel.receiveInboundMessage(message)
        }
    }

    func createChildChannel(_ promise: EventLoopPromise<Channel>? = nil, channelType: SSHChannelType, _ channelInitializer: SSHChildChannel.Initializer?) {
        do {
            let channel = try self.openNewChannel(initializer: channelInitializer)
            // Record creation time for latency measurement
            // nextChannelID was incremented in openNewChannel, so the ID used is one less
            let createdID = self.nextChannelID == 0 ? UInt32(Int32.max) : self.nextChannelID - 1
            channelCreationTimestamps[createdID] = NIOSSHDebug.nowUs()
            NIOSSHDebug.shared.increment("niossh.multiplexer.createChild")
            NIOSSHDebug.shared.set("niossh.multiplexer.activeChannels", value: Int64(self.channels.count))
            NIOSSHDebug.shared.tsLog("CHAN-OPEN id=\(createdID) totalCh=\(self.channels.count) pendConfirm=\(self.channelCreationTimestamps.count)")
            channel.configure(userPromise: promise, channelType: channelType)
        } catch {
            promise?.fail(error)
        }
    }

    /// Maximum number of child channels to process per event-loop turn.
    /// Yielding between batches allows the SSH event loop to process
    /// control messages (e.g. ChannelOpenConfirmation) interleaved with
    /// data delivery, preventing starvation under high channel counts.
    private static let readCompleteBatchSize = 8

    func parentChannelReadComplete() {
        let channelCount = self.channels.count
        NIOSSHDebug.shared.set("niossh.multiplexer.channels", value: Int64(channelCount))
        NIOSSHDebug.shared.set("niossh.multiplexer.pendingConfirms", value: Int64(channelCreationTimestamps.count))

        // Periodic state snapshot (every 2 seconds) — unconditional
        let now = NIOSSHDebug.nowUs()
        if now - lastSnapshotTimeUs > 2_000_000 {
            let pendConfirm = channelCreationTimestamps.count
            let sinceReadMs = lastChannelReadUs > 0 ? (now - lastChannelReadUs) / 1000 : -1

            NIOSSHDebug.shared.tsLog(
                "SNAPSHOT ch=\(channelCount) pend=\(pendConfirm) " +
                "tcpR=\(snapTcpReads) tcpKB=\(snapTcpBytes/1024) " +
                "parsed=\(snapSshPacketsParsed) nonCh=\(snapNonChannelMsgs) " +
                "dPkt=\(snapDataPkts) dKB=\(snapDataBytes/1024) " +
                "waOut=\(snapWaOut) waOutKB=\(snapWaOutBytes/1024) waIn=\(snapWaIn) " +
                "conf=\(snapConfirms) fail=\(snapFailures) cls=\(snapCloses) eof=\(snapEOFs) " +
                "sinceRead=\(sinceReadMs)ms"
            )

            // Stall detection: pending confirms exist but none arrived this snapshot
            if pendConfirm > 0 && snapConfirms == 0 {
                let pendIDs = channelCreationTimestamps.keys.sorted().prefix(10)
                    .map { id -> String in
                        let age = (now - (channelCreationTimestamps[id] ?? now)) / 1000
                        return "id=\(id):\(age)ms"
                    }.joined(separator: " ")
                NIOSSHDebug.shared.tsLog("CONFIRM-STALL pend=\(pendConfirm) noConfirmThisWindow [\(pendIDs)]")
            }

            // Aggregate budget diagnostics (only if budget is active)
            if aggregateWindowBudget > 0 {
                let deferredCount = channelsNeedingAdjust.count
                NIOSSHDebug.shared.tsLog(
                    "BUDGET outstanding=\(aggregateOutstandingCredit)/\(aggregateWindowBudget) " +
                    "deferred=\(deferredCount) creditCh=\(perChannelCredit.count)"
                )
            }

            // Reset per-snapshot accumulators
            snapDataPkts = 0; snapDataBytes = 0
            snapWaIn = 0; snapWaOut = 0; snapWaOutBytes = 0
            snapConfirms = 0; snapFailures = 0; snapCloses = 0; snapEOFs = 0
            snapTcpReads = 0; snapTcpBytes = 0
            snapSshPacketsParsed = 0; snapNonChannelMsgs = 0
            windowAdjustBytesSinceSnapshot = 0
            channelDataBytesSinceSnapshot = 0
            lastSnapshotTimeUs = now
        }

        let channels = Array(self.channels.values)
        guard !channels.isEmpty else { return }

        if channels.count <= Self.readCompleteBatchSize {
            for channel in channels {
                channel.receiveParentChannelReadComplete()
            }
        } else {
            deliverReadCompleteBatch(channels: channels, from: 0)
        }
    }

    private func deliverReadCompleteBatch(channels: [SSHChildChannel], from index: Int) {
        let end = min(index + Self.readCompleteBatchSize, channels.count)
        for i in index..<end {
            channels[i].receiveParentChannelReadComplete()
        }
        if end < channels.count, let el = self.delegate?.channel?.eventLoop {
            el.execute {
                self.deliverReadCompleteBatch(channels: channels, from: end)
            }
        }
    }

    func parentChannelWritabilityChanged(newValue: Bool) {
        for channel in self.channels.values {
            channel.parentChannelWritabilityChanged(newValue: newValue)
        }
    }

    func parentChannelInactive() {
        self.canCreateNewChannels = false
        for channel in self.channels.values {
            channel.parentChannelInactive()
        }
    }

    /// Opens a new channel and adds it to the multiplexer.
    private func openNewChannel(initializer: SSHChildChannel.Initializer?) throws -> SSHChildChannel {
        guard let parentChannel = self.delegate?.channel else {
            throw NIOSSHError.protocolViolation(protocolName: "channel", violation: "Opening new channel after channel shutdown")
        }

        guard self.canCreateNewChannels else {
            throw NIOSSHError.tcpShutdown
        }

        // TODO: We need a better channel ID system. Maybe use indices into Arrays instead?
        let channelID = self.nextChannelID
        self.nextChannelID &+= 1

        // Int32.max isn't a spec-defined limit, but it's what OpenSSH uses as its upper bound. We will too.
        if self.nextChannelID > Int32.max {
            self.nextChannelID = 0
        }

        // Values can be safely cast; configuration guards enforce sensible bounds.
        let openWinSize: Int32? = (self.channelOpenWindowSize < self.initialWindowSize)
            ? Int32(self.channelOpenWindowSize) : nil
        let channel = SSHChildChannel(allocator: self.allocator,
                                      parent: parentChannel,
                                      multiplexer: self,
                                      initializer: initializer,
                                      localChannelID: channelID,
                                      targetWindowSize: Int32(self.initialWindowSize),
                                      channelOpenWindowSize: openWinSize,
                                      initialOutboundWindowSize: 0) // The initial outbound window size is presumed to be 0 until we're told otherwise.

        self.channels[channelID] = channel
        return channel
    }

    private func existingChannel(localID: UInt32) throws -> SSHChildChannel? {
        if let channel = self.channels[localID] {
            return channel
        } else if self.erroredChannels.contains(localID) {
            return nil
        } else {
            throw NIOSSHError.protocolViolation(protocolName: "channel", violation: "Unexpected request with local channel id \(localID)")
        }
    }
}

// MARK: Aggregate Window Budget

extension SSHChannelMultiplexer {
    /// Called by a child channel before sending a WindowAdjust.
    /// Returns true if the budget allows the adjustment, false if it should be deferred.
    func requestWindowAdjust(channelID: UInt32, bytes: Int) -> Bool {
        // Always track outbound WindowAdjusts for snapshot diagnostics
        snapWaOut += 1
        snapWaOutBytes += Int64(bytes)
        guard aggregateWindowBudget > 0 else { return true }

        if aggregateOutstandingCredit + bytes <= aggregateWindowBudget {
            aggregateOutstandingCredit += bytes
            perChannelCredit[channelID, default: 0] += bytes
            windowAdjustBytesSinceSnapshot += Int64(bytes)
            lastWindowAdjustTimeUs = NIOSSHDebug.nowUs()
            NIOSSHDebug.shared.set("niossh.aggWindow.outstanding", value: Int64(aggregateOutstandingCredit))
            return true
        }

        // Budget exhausted — register for deferred flush
        let wasEmpty = channelsNeedingAdjust.isEmpty
        if !channelsNeedingAdjust.contains(channelID) {
            channelsNeedingAdjust.append(channelID)
        }
        NIOSSHDebug.shared.increment("niossh.aggWindow.deferred")
        NIOSSHDebug.shared.set("niossh.aggWindow.outstanding", value: Int64(aggregateOutstandingCredit))
        NIOSSHDebug.shared.set("niossh.aggWindow.deferredCount", value: Int64(channelsNeedingAdjust.count))
        // Log the first deferral (transition from empty queue) as it may signal budget saturation
        if wasEmpty {
            NIOSSHDebug.shared.tsLog(
                "BUDGET-FULL id=\(channelID) req=\(bytes) outstanding=\(aggregateOutstandingCredit)/\(aggregateWindowBudget)"
            )
        }
        return false
    }

    /// Called when ChannelData is received, freeing aggregate budget for deferred WindowAdjusts.
    private func didReceiveChannelData(channelID: UInt32, bytes: Int) {
        guard aggregateWindowBudget > 0 else { return }

        let channelCredit = perChannelCredit[channelID] ?? 0
        let consumed = min(bytes, channelCredit)
        if consumed > 0 {
            perChannelCredit[channelID, default: 0] -= consumed
            aggregateOutstandingCredit -= consumed
        }
        channelDataBytesSinceSnapshot += Int64(bytes)

        // Try to flush deferred adjustments now that budget freed up
        if !channelsNeedingAdjust.isEmpty {
            let beforeCount = channelsNeedingAdjust.count
            let beforeOutstanding = aggregateOutstandingCredit
            processDeferredWindowAdjusts()
            let served = beforeCount - channelsNeedingAdjust.count
            if served > 0 {
                NIOSSHDebug.shared.tsLog(
                    "DEFERRED-SERVED freed=\(consumed) served=\(served)/\(beforeCount) " +
                    "outstanding=\(beforeOutstanding)→\(aggregateOutstandingCredit)"
                )
            }
        }
    }

    /// Remove a channel's credit from the aggregate when it closes.
    private func cleanupChannelCredit(channelID: UInt32) {
        if let credit = perChannelCredit.removeValue(forKey: channelID) {
            aggregateOutstandingCredit -= credit
            if aggregateOutstandingCredit < 0 { aggregateOutstandingCredit = 0 }
        }
        channelsNeedingAdjust.removeAll { $0 == channelID }
    }

    /// Process the FIFO queue of channels needing deferred WindowAdjust.
    private func processDeferredWindowAdjusts() {
        while !channelsNeedingAdjust.isEmpty {
            let channelID = channelsNeedingAdjust[0]
            guard let channel = channels[channelID] else {
                channelsNeedingAdjust.removeFirst()
                continue
            }
            if channel.flushDeferredWindowAdjust() {
                channelsNeedingAdjust.removeFirst()
            } else {
                break  // Budget still exhausted
            }
        }
        NIOSSHDebug.shared.set("niossh.aggWindow.outstanding", value: Int64(aggregateOutstandingCredit))
        NIOSSHDebug.shared.set("niossh.aggWindow.deferredCount", value: Int64(channelsNeedingAdjust.count))
    }
}

/// An internal protocol to encapsulate the object that owns the multiplexer.
protocol SSHMultiplexerDelegate {
    var channel: Channel? { get }

    var username: String? { get }

    func writeFromChildChannel(_: SSHMessage, _: EventLoopPromise<Void>?)

    func flushFromChildChannel()
}
