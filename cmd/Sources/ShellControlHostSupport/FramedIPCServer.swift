import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import ShellControlProtocol
import Synchronization

/// The accept loop for per-user framed IPC, shared by `shell-controld` and the
/// bundled Control host (spec.agent-relay.md sections 3.1 and 19.2).
///
/// Every peer is checked to run as this user before a frame is read. Each
/// connection is served on its own queue item; a request whose adapter
/// disconnects mid-wait is cancelled, because the native wait left with it
/// (spec.agent-relay.md sections 5.2 and 10.2).
public final class FramedIPCServer: Sendable {
    public typealias Handler = @Sendable (IPCRequest) async -> IPCResponse

    private let listener: Int32
    private let queue: DispatchQueue
    private let handler: Handler
    private let maximumConnections: Int?
    private let running = Atomic(true)
    private let connections = Atomic(0)

    /// - Parameters:
    ///   - listener: a bound, listening Unix socket from ``UnixSocketServer``.
    ///   - maximumConnections: concurrent connections beyond which a new
    ///     peer is closed unserved; nil for no limit.
    public init(listener: Int32, queue: DispatchQueue, maximumConnections: Int? = nil, handler: @escaping Handler) {
        self.listener = listener
        self.queue = queue
        self.maximumConnections = maximumConnections
        self.handler = handler
    }

    public var isRunning: Bool { running.load(ordering: .acquiring) }

    /// Closes the listener, which unblocks ``acceptLoop()``. Idempotent.
    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        close(listener)
    }

    /// Blocks the calling thread until ``stop()``.
    public func acceptLoop() {
        while isRunning {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if !isRunning { return }
                FramedIPCServer.backOffAfterAcceptFailure()
                continue
            }
            guard UnixSocketServer.verifyPeer(client) else {
                close(client)
                continue
            }
            if let maximumConnections {
                guard connections.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue <= maximumConnections else {
                    connections.wrappingSubtract(1, ordering: .acquiringAndReleasing)
                    close(client)
                    continue
                }
            }
            queue.async { [self] in
                defer {
                    close(client)
                    if maximumConnections != nil { connections.wrappingSubtract(1, ordering: .acquiringAndReleasing) }
                }
                serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        var buffer = Data()
        while isRunning {
            guard let value = try? FrameIO.readFrame(client, buffer: &buffer) else { return }
            guard let request = try? IPCRequest(json: value) else {
                _ = try? FrameIO.writeFrame(client, IPCResponse(
                    messageID: .random(),
                    ok: false,
                    errorCode: ControlErrorCode.invalidPayload.rawValue,
                    errorMessage: "unreadable frame"
                ).json)
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var response = IPCResponse(messageID: request.messageID, ok: false)
            let work = Task { [handler] in
                response = await handler(request)
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now() + 1) == .timedOut {
                if SocketPeer.hasClosed(client) { work.cancel() }
            }
            try? FrameIO.writeFrame(client, response.json)
        }
    }

    /// A persistent failure such as EMFILE would otherwise spin the loop.
    static func backOffAfterAcceptFailure() {
        if errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM {
            usleep(50_000)
        }
    }
}

/// Serves one canonical-JSON health snapshot per connection, then closes it.
public final class HealthSocketServer: Sendable {
    private let listener: Int32
    private let snapshot: @Sendable () async -> JSONValue
    private let running = Atomic(true)

    public init(listener: Int32, snapshot: @escaping @Sendable () async -> JSONValue) {
        self.listener = listener
        self.snapshot = snapshot
    }

    public var isRunning: Bool { running.load(ordering: .acquiring) }

    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        close(listener)
    }

    /// Blocks the calling thread until ``stop()``.
    public func acceptLoop() {
        while isRunning {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if !isRunning { return }
                FramedIPCServer.backOffAfterAcceptFailure()
                continue
            }
            defer { close(client) }
            guard UnixSocketServer.verifyPeer(client) else { continue }
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var body = Data("{}".utf8)
            Task { [snapshot] in
                let json = await snapshot()
                body = (try? JSONCanonicalization.canonicalize(json)) ?? body
                done.signal()
            }
            done.wait()
            _ = body.withUnsafeBytes { raw in
                send(client, raw.baseAddress, raw.count, 0)
            }
        }
    }
}
