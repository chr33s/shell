@testable import Citadel
import Crypto
import NIO
import NIOConcurrencyHelpers
import NIOSSH
import XCTest

final class RemotePortForwardTests: XCTestCase {
    /// Test that remote port forward request is sent correctly
    func testRemotePortForwardRequest() async throws {
        // This test requires an SSH server that supports remote port forwarding
        // Check if we have the environment variables set for SSH testing
        guard let host = ProcessInfo.processInfo.environment["SSH_HOST"],
              let portString = ProcessInfo.processInfo.environment["SSH_PORT"],
              let port = Int(portString),
              let username = ProcessInfo.processInfo.environment["SSH_USERNAME"],
              let password = ProcessInfo.processInfo.environment["SSH_PASSWORD"] else {
            throw XCTSkip("SSH environment variables not set (SSH_HOST, SSH_PORT, SSH_USERNAME, SSH_PASSWORD)")
        }

        print("Connecting to SSH server at \(host):\(port)...")

        // Connect to SSH server
        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        defer {
            Task {
                try? await client.close()
            }
        }

        print("Connected. Requesting remote port forward...")

        // Request remote port forward on a random high port
        // Use port 0 to let the server choose
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await client.withRemotePortForward(
                    host: "127.0.0.1",
                    port: 0 // Let server choose port
                ) { forward in
                    XCTAssertGreaterThan(forward.boundPort, 0, "Server should have bound to a port")
                    XCTAssertEqual(forward.host, "127.0.0.1")
                } handleChannel: { channel, forwardedInfo in
                    print("Received forwarded connection from \(forwardedInfo.originatorAddress)")

                    // Just close the channel for this test
                    return channel.close()
                }
            }

            try await Task.sleep(for: .seconds(1))
            group.cancelAll()
        }
    }

    /// Test that we can create and cancel multiple forwards
    func testMultipleRemotePortForwards() async throws {
        guard let host = ProcessInfo.processInfo.environment["SSH_HOST"],
              let portString = ProcessInfo.processInfo.environment["SSH_PORT"],
              let port = Int(portString),
              let username = ProcessInfo.processInfo.environment["SSH_USERNAME"],
              let password = ProcessInfo.processInfo.environment["SSH_PASSWORD"] else {
            throw XCTSkip("SSH environment variables not set")
        }

        let client = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: .passwordBased(username: username, password: password),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        defer {
            Task {
                try? await client.close()
            }
        }

        // TODO: Confirmation from swift-testing
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await client.withRemotePortForward(
                        host: "127.0.0.1",
                        port: 0
                    ) { forward in
                        XCTAssertGreaterThan(forward.boundPort, 0, "Server should have bound to a port")
                        XCTAssertEqual(forward.host, "127.0.0.1")
                    } handleChannel: { channel, forwardedInfo in
                        print("Received forwarded connection from \(forwardedInfo.originatorAddress)")

                        // Just close the channel for this test
                        return channel.close()
                    }
                }
            }

            try await Task.sleep(for: .seconds(1))
            group.cancelAll()
        }
    }

    /// Test that the SSHRemotePortForward struct works correctly
    func testSSHRemotePortForwardStruct() {
        let forward = SSHRemotePortForward(host: "0.0.0.0", boundPort: 8080)

        XCTAssertEqual(forward.host, "0.0.0.0")
        XCTAssertEqual(forward.boundPort, 8080)
    }

    // MARK: - Forwarded channel lifetime
    //
    // A NIOAsyncChannel released without `executeThenClose` traps in
    // NIOAsyncWriter.deinit ("Deinited NIOAsyncWriter without calling finish()").
    // Neither test can fail as an assertion: a preconditionFailure takes the whole
    // test process with it, so a crashed runner IS the failure and reaching the end
    // of the test is the pass.

    /// The local target refuses the connection, so `onAccept` throws before it ever
    /// reaches `executeThenClose` and the channel is released un-finished.
    ///
    /// This is the reproducer: it traps the test runner without the fix.
    func testForwardedConnectionSurvivesLocalConnectFailure() async throws {
        let deadPort = try Self.reserveThenReleasePort()

        try await Self.withForwardingServer(port: 2224) { client in
            let (forward, task) = try await Self.startForward(
                on: client,
                forwardingTo: deadPort
            )

            try await Self.connectAndDisconnect(port: forward.boundPort)
            // Let the client's failed local connect unwind and release the channel.
            try await Task.sleep(for: .milliseconds(500))

            task.cancel()
            _ = await task.result
        }
    }

    /// The forward is torn down while a forwarded connection is still open, so the
    /// accept task is cancelled with the channel still in hand.
    ///
    /// A regression guard, not a reproducer: once `executeThenClose` has started, its
    /// own catch already finishes the writer, so this passes with or without the fix.
    /// It is here to keep the teardown path covered as that code changes.
    func testForwardTeardownWithOpenConnection() async throws {
        let group = MultiThreadedEventLoopGroup.singleton

        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in channel.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { listener.close(promise: nil) }

        let localPort = listener.localAddress!.port!

        try await Self.withForwardingServer(port: 2225) { client in
            let (forward, task) = try await Self.startForward(
                on: client,
                forwardingTo: localPort
            )

            let connection = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connect(host: "127.0.0.1", port: forward.boundPort)
                .get()
            // Let the forwarded channel establish on both ends before tearing down.
            try await Task.sleep(for: .milliseconds(500))

            task.cancel()
            _ = await task.result
            try? await connection.close().get()
        }
    }

    /// A burst of accepts racing a teardown - many connections landing while the
    /// forward is being cancelled, which is how this showed up in the wild.
    ///
    /// The sharpest reproducer of the three: it traps the runner on unfixed source
    /// every time, where the single-connection case needs the local target to refuse.
    func testBurstAcceptsDuringTeardown() async throws {
        let deadPort = try Self.reserveThenReleasePort()

        for round in 0..<25 {
            let sshPort = try Self.reserveThenReleasePort()
            try await Self.withForwardingServer(port: sshPort) { client in
                let (forward, task) = try await Self.startForward(
                    on: client,
                    forwardingTo: deadPort
                )

                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<30 {
                        group.addTask {
                            try? await Self.connectAndDisconnect(port: forward.boundPort)
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(round % 5))
                        task.cancel()
                    }
                }

                _ = await task.result
            }
        }
    }

    /// Dropping a `PendingChannel` nobody claimed must finish the underlying writer.
    ///
    /// This is the safety net for a channel that reaches the `AsyncStream` buffer and
    /// is never handed to a consumer: without the box's `deinit`, releasing the last
    /// reference here traps the runner instead of failing.
    func testUnclaimedPendingChannelIsAbandonedOnRelease() throws {
        let embedded = EmbeddedChannel()
        try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        XCTAssertTrue(embedded.isActive)

        // Built in a scope of its own so the box holds the only reference to the
        // channel's writer - otherwise nothing is released and nothing is proven.
        func makeBox() throws -> PendingChannel<ByteBuffer, ByteBuffer> {
            PendingChannel(try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: embedded
            ))
        }

        // Deliberately never claimed - that is the case under test.
        var box: PendingChannel<ByteBuffer, ByteBuffer>? = try makeBox()
        XCTAssertNotNil(box)
        box = nil

        embedded.embeddedEventLoop.run()
        XCTAssertFalse(embedded.isActive, "abandon() should have closed the channel")
    }

    // MARK: - Harness

    /// Hosts an SSH server that actually opens `forwarded-tcpip` channels back to the
    /// client, connects a client to it, and tears both down afterwards.
    private static func withForwardingServer(
        port: Int,
        _ body: (SSHClient) async throws -> Void
    ) async throws {
        let authDelegate = AuthDelegate(supportedAuthenticationMethods: .password) { request, promise in
            switch request.request {
            case .password(.init(password: "test")) where request.username == "citadel":
                promise.succeed(.success)
            default:
                promise.succeed(.failure)
            }
        }

        let server = try await SSHServer.host(
            host: "localhost",
            port: port,
            hostKeys: [.init(p521Key: .init())],
            authenticationDelegate: authDelegate
        )
        server.enableRemotePortForward(withDelegate: ForwardingTestDelegate())

        let client = try await SSHClient.connect(
            host: "localhost",
            port: port,
            authenticationMethod: .passwordBased(username: "citadel", password: "test"),
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )

        do {
            try await body(client)
        } catch {
            try? await client.close()
            try? await server.close()
            throw error
        }

        try? await client.close()
        try await server.close()
    }

    /// Starts `runRemotePortForward` in a task and returns once the server has bound.
    private static func startForward(
        on client: SSHClient,
        forwardingTo localPort: Int
    ) async throws -> (SSHRemotePortForward, Task<Void, Never>) {
        let (opened, continuation) = AsyncStream<SSHRemotePortForward>.makeStream()

        // An explicit bind port, not 0: the client keys its forwarded-channel
        // handler on the port it *asked* for (`ClientSession.registerForwardedTCPIP`),
        // so a server-assigned port never matches and no channel is ever delivered.
        let bindPort = try reserveThenReleasePort()

        let task = Task {
            try? await client.runRemotePortForward(
                host: "127.0.0.1",
                port: bindPort,
                forwardingTo: "127.0.0.1",
                port: localPort
            ) { forward in
                continuation.yield(forward)
            }
            continuation.finish()
        }

        var iterator = opened.makeAsyncIterator()
        guard let forward = await iterator.next() else {
            task.cancel()
            throw XCTSkip("Server did not accept the remote port forward request")
        }

        XCTAssertGreaterThan(forward.boundPort, 0)
        return (forward, task)
    }

    /// Opens and immediately drops a TCP connection, which makes the server open a
    /// `forwarded-tcpip` channel to the client.
    private static func connectAndDisconnect(port: Int) async throws {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: port)
            .get()
        try await channel.close().get()
    }

    /// Binds port 0, notes what it got, and releases it - a port nothing is listening on.
    private static func reserveThenReleasePort() throws -> Int {
        let channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        let port = channel.localAddress!.port!
        try channel.close().wait()
        return port
    }
}

/// Server-side remote-forward delegate that binds a real listening socket and opens a
/// `forwarded-tcpip` channel to the client for each accepted connection.
///
/// Citadel's shipped `AsyncRemotePortForwardDelegate` hands the accepted socket to its
/// caller and never touches the SSH session, so it cannot drive the client's forwarded
/// channel path. This one can.
private final class ForwardingTestDelegate: RemotePortForwardDelegate, Sendable {
    private let listeners = NIOLockedValueBox<[String: Channel]>([:])

    func startListening(
        host: String,
        port: Int,
        handler: NIOSSHHandler,
        eventLoop: EventLoop,
        context: SSHContext
    ) -> EventLoopFuture<Int?> {
        // Bind on the SSH connection's own loop so the accepted sockets and the SSH
        // child channels share it and no hop is needed to reach the handler.
        let handler = NIOLoopBound(handler, eventLoop: eventLoop)
        let boundPort = NIOLockedValueBox(0)

        return ServerBootstrap(group: eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { local in
                let originator = local.remoteAddress ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                let promise = local.eventLoop.makePromise(of: Channel.self)
                handler.value.createChannel(
                    promise,
                    channelType: .forwardedTCPIP(
                        .init(
                            listeningHost: host,
                            listeningPort: boundPort.withLockedValue { $0 },
                            originatorAddress: originator
                        )
                    )
                ) { _, _ in local.eventLoop.makeSucceededVoidFuture() }
                // The test never pipes bytes; opening the channel is what exercises
                // the client. Failing to open just leaves the socket idle.
                return promise.futureResult.map { _ in }.recover { _ in }
            }
            .bind(host: host.isEmpty ? "0.0.0.0" : host, port: port)
            .map { channel in
                guard let actualPort = channel.localAddress?.port else {
                    _ = channel.close()
                    return nil
                }
                boundPort.withLockedValue { $0 = actualPort }
                self.listeners.withLockedValue { $0["\(host):\(actualPort)"] = channel }
                return actualPort
            }
            .recover { _ in nil }
    }

    func stopListening(
        host: String,
        port: Int,
        eventLoop: EventLoop,
        context: SSHContext
    ) -> EventLoopFuture<Void> {
        let channel = listeners.withLockedValue { $0.removeValue(forKey: "\(host):\(port)") }
        guard let channel else { return eventLoop.makeSucceededVoidFuture() }
        return channel.close().recover { _ in }.hop(to: eventLoop)
    }
}
