//
//  SSHCancellationBoxes.swift
//  shell
//
//  Sendable wrappers used by withTaskCancellationHandler's @Sendable onCancel
//  closure to reach into Citadel/NIO types that aren't Sendable-by-design.
//  Both `Channel.close()` and `SSHClient.close()` dispatch the actual work
//  onto an event loop, so passing the reference across actor isolation just
//  to fire the close is safe in practice.
//
//  Used by CitadelSSHSession and SSHConnectionHelper to interrupt SSH
//  handshake/auth awaits on Swift Task cancellation. Citadel's NIO→async
//  bridge (`EventLoopFuture.get()`) does not observe Swift cancellation, so
//  the only Swift-level interrupt lever is to close the underlying channel
//  or client.
//

import Foundation
import Citadel
import NIOCore

/// Sendable wrapper around a NIO `Channel`. Used to close a raw TCP channel
/// from `onCancel` when the SSH handshake (`SSHClient.connect(on:settings:)`)
/// hasn't completed yet.
final class CancellationChannelBox: @unchecked Sendable {
    let channel: Channel
    init(_ channel: Channel) { self.channel = channel }
}

/// Sendable wrapper around an `SSHClient`. Closing the client cascades into
/// its session channel and any child DirectTCPIP channels, which is the only
/// way to interrupt `SSHClient.jump(to:)` mid-handshake.
final class CancellationSSHClientBox: @unchecked Sendable {
    let client: SSHClient
    init(_ client: SSHClient) { self.client = client }
}
