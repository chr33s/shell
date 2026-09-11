import NIOCore
import NIOSSH

extension SSHClient {
    /// Creates a `direct-streamlocal@openssh.com` channel — a client-initiated
    /// connection to a Unix-domain socket on the server, the streamlocal
    /// analogue of a direct TCP/IP channel. Requires the server to permit
    /// stream-local forwarding (`AllowStreamLocalForwarding`, on by default
    /// in OpenSSH).
    public func createDirectStreamLocalChannel(
        using settings: SSHChannelType.DirectStreamLocal,
        initialize: @escaping (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        return try await eventLoop.flatSubmit { [eventLoop, sshHandler = self.session.sshHandler] in
            let createdChannel = eventLoop.makePromise(of: Channel.self)
            sshHandler.value.createChannel(
                createdChannel,
                channelType: .directStreamLocal(settings)
            ) { channel, type in
                guard case .directStreamLocal = type else {
                    return channel.eventLoop.makeFailedFuture(SSHClientError.channelCreationFailed)
                }

                do {
                    try channel.pipeline.syncOperations.addHandler(DataToBufferCodec())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }

                return initialize(channel)
            }

            return createdChannel.futureResult
        }.get()
    }
}
