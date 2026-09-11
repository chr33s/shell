//===----------------------------------------------------------------------===//
//
// This source file is part of the Citadel open source project
//
// Copyright (c) 2026 Citadel contributors
// Licensed under Apache License v2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOSSH
import Logging

extension SSHClient {

    /// Establishes a remote Unix-domain socket forward.
    ///
    /// Sends a `streamlocal-forward@openssh.com` global request asking
    /// the SSH server to bind the given Unix socket on the remote and
    /// forward every accepted connection back to this client as a
    /// `forwarded-streamlocal@openssh.com` channel. This is the
    /// mechanism `ssh -R /remote.sock:/local.sock` uses; the canonical
    /// caller is GPG agent forwarding, where the remote `gpg` client
    /// connects to the forwarded socket and the iPad-side
    /// implementation answers Assuan-protocol commands.
    ///
    /// The method keeps the forward active for the full lifetime of the
    /// supplied `body` closure. When `body` returns (or throws), a
    /// `cancel-streamlocal-forward@openssh.com` request is sent to tear
    /// down the remote socket. If the SSH connection drops first, the
    /// remote socket goes with it; no explicit cancellation is required
    /// in that case.
    ///
    /// - Parameters:
    ///   - remotePath: Path on the remote where the Unix socket should
    ///     be bound. The server must have permission to bind there.
    ///   - handleChannel: Called for each accepted connection. The
    ///     channel arrives without any byte-level codec attached — for
    ///     a typical use case you'll add ``StreamLocalChannelHandler``
    ///     to translate `SSHChannelData` into plain `ByteBuffer`s,
    ///     then wire your own consumer downstream.
    ///   - body: Scope of the forward. Until this closure returns the
    ///     remote socket stays bound. Throwing from `body` aborts the
    ///     forward and propagates the error after cleanup.
    /// - Throws: If the server rejects the forwarding request, if the
    ///   socket path is already forwarded on this connection, or if
    ///   `body` throws.
    public func forwardRemoteUnixSocket(
        remotePath: String,
        handleChannel: @escaping @Sendable (Channel) -> EventLoopFuture<Void>,
        body: @escaping @Sendable () async throws -> Void
    ) async throws {
        // 1. Register the per-path handler BEFORE sending the global
        // request — the server may open the first channel back to us
        // arbitrarily soon after acknowledging the request, and we
        // can't afford to lose the race.
        let registrationResult = session.inboundChannelHandler.registerStreamLocalForwardHandler(
            path: remotePath,
            handler: handleChannel
        )
        switch registrationResult {
        case .success:
            ()
        case .alreadyRegistered:
            throw SSHClientError.channelCreationFailed
        }

        // 2. Build the `streamlocal-forward@openssh.com` payload: a
        // single SSH string holding the remote socket path. (Unlike
        // `forwarded-streamlocal@openssh.com`, the *request* form has
        // no trailing `reserved` field — that one only appears on the
        // channel-open message.)
        var payload = ByteBufferAllocator().buffer(capacity: remotePath.utf8.count + 4)
        payload.writeInteger(UInt32(remotePath.utf8.count))
        payload.writeString(remotePath)

        do {
            _ = try await eventLoop.flatSubmit { [eventLoop, sshHandler = self.session.sshHandler, payload] in
                let promise = eventLoop.makePromise(of: ByteBuffer?.self)
                sshHandler.value.sendCustomGlobalRequest(
                    name: "streamlocal-forward@openssh.com",
                    wantReply: true,
                    data: payload,
                    promise: promise
                )
                return promise.futureResult
            }.get()
        } catch {
            // Server rejected the forward — unregister so we don't leak
            // a dangling handler and propagate.
            session.inboundChannelHandler.unregisterStreamLocalForwardHandler(path: remotePath)
            throw error
        }

        logger.info("Server accepted streamlocal forward", metadata: ["socket": "\(remotePath)"])

        // 3. Run the caller's scope, cleaning up either way.
        do {
            try await body()
            try? await sendCancelStreamLocalForwarding(remotePath: remotePath)
            session.inboundChannelHandler.unregisterStreamLocalForwardHandler(path: remotePath)
        } catch {
            try? await sendCancelStreamLocalForwarding(remotePath: remotePath)
            session.inboundChannelHandler.unregisterStreamLocalForwardHandler(path: remotePath)
            throw error
        }
    }

    /// Send `cancel-streamlocal-forward@openssh.com`. Best-effort —
    /// failures are logged but not surfaced, because by the time this
    /// runs we're already tearing down the forward.
    private func sendCancelStreamLocalForwarding(remotePath: String) async throws {
        var payload = ByteBufferAllocator().buffer(capacity: remotePath.utf8.count + 4)
        payload.writeInteger(UInt32(remotePath.utf8.count))
        payload.writeString(remotePath)

        _ = try await eventLoop.flatSubmit { [eventLoop, sshHandler = self.session.sshHandler, payload] in
            let promise = eventLoop.makePromise(of: ByteBuffer?.self)
            sshHandler.value.sendCustomGlobalRequest(
                name: "cancel-streamlocal-forward@openssh.com",
                wantReply: true,
                data: payload,
                promise: promise
            )
            return promise.futureResult
        }.get()
    }
}
