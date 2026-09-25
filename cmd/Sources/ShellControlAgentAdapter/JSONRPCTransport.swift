import Foundation
import ShellControlProtocol

/// One JSON-RPC peer, framed as newline-delimited JSON without the
/// `"jsonrpc"` member, as the Codex app-server speaks it over stdio
/// (docs/specs/agent-relay.md section 10.2).
public protocol JSONRPCTransport: Sendable {
    func send(_ message: JSONValue) async throws
    /// Every message the peer sends, in order. Finishes when the peer closes.
    var incoming: AsyncThrowingStream<JSONValue, any Error> { get }
    func close() async
}

public struct JSONRPCError: Error, Sendable, CustomStringConvertible {
    public let code: Int64
    public let message: String
    public var description: String { "JSON-RPC error \(code): \(message)" }
}

/// Correlates our requests with the peer's responses and hands everything
/// else — the peer's requests and notifications — to one handler. Writes are
/// serialized; reading never stops while a request waits.
public actor JSONRPCConnection {
    public enum Inbound: Sendable {
        case request(id: NativeIdentifier, method: String, params: JSONValue)
        case notification(method: String, params: JSONValue)
    }

    public enum ConnectionError: Error, Sendable, Equatable {
        case closed
    }

    private let transport: any JSONRPCTransport
    private var nextID: Int64 = 1
    private var waiting: [Int64: CheckedContinuation<JSONValue, any Error>] = [:]
    private var closed = false
    private var reader: Task<Void, Never>?

    public init(transport: any JSONRPCTransport) {
        self.transport = transport
    }

    /// Starts reading; `handler` receives the peer's requests and
    /// notifications in arrival order.
    public func start(_ handler: @escaping @Sendable (Inbound) async -> Void) {
        let transport = self.transport
        reader = Task { [weak self] in
            do {
                for try await message in transport.incoming {
                    guard let self else { return }
                    if let inbound = await self.route(message) { await handler(inbound) }
                }
            } catch {}
            await self?.finish()
        }
    }

    private func route(_ message: JSONValue) -> Inbound? {
        guard let members = message.objectValue else { return nil }
        if let method = members["method"]?.stringValue {
            let params = members["params"] ?? .object([:])
            if let rawID = members["id"], let id = try? NativeIdentifier(json: rawID) {
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }
        guard let id = members["id"]?.int64Value, let continuation = waiting.removeValue(forKey: id) else { return nil }
        if let error = members["error"], !error.isNull {
            continuation.resume(throwing: JSONRPCError(
                code: error["code"]?.int64Value ?? -1,
                message: error["message"]?.stringValue ?? "error"
            ))
        } else {
            continuation.resume(returning: members["result"] ?? .null)
        }
        return nil
    }

    private func finish() {
        closed = true
        for continuation in waiting.values { continuation.resume(throwing: ConnectionError.closed) }
        waiting.removeAll()
    }

    public var isClosed: Bool { closed }

    /// Sends a request and waits for its result.
    public func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard !closed else { throw ConnectionError.closed }
        let id = nextID
        nextID += 1
        let message = JSONValue.object(["method": .string(method), "id": .number(.int(id)), "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            Task {
                do {
                    try await transport.send(message)
                } catch {
                    self.fail(id, error)
                }
            }
        }
    }

    private func fail(_ id: Int64, _ error: any Error) {
        waiting.removeValue(forKey: id)?.resume(throwing: error)
    }

    public func notify(_ method: String, _ params: JSONValue = .object([:])) async throws {
        guard !closed else { throw ConnectionError.closed }
        try await transport.send(.object(["method": .string(method), "params": params]))
    }

    /// Answers the peer's request `id` exactly once, with its native type.
    public func respond(to id: NativeIdentifier, result: JSONValue) async throws {
        guard !closed else { throw ConnectionError.closed }
        try await transport.send(.object(["id": id.json, "result": result]))
    }

    /// Refuses the peer's request `id` with a JSON-RPC error.
    public func respondError(to id: NativeIdentifier, code: Int64, message: String) async throws {
        guard !closed else { throw ConnectionError.closed }
        try await transport.send(.object(["id": id.json, "error": .object(["code": .number(.int(code)), "message": .string(message)])]))
    }

    public func close() async {
        reader?.cancel()
        await transport.close()
        finish()
    }
}

/// `codex app-server` over stdio: a host-owned child process whose pipes are
/// the only route to it. No listener is exposed to any other process.
public final class ProcessJSONRPCTransport: JSONRPCTransport, @unchecked Sendable {
    public let process: Process
    private let input: FileHandle
    private let lock = NSLock()
    public let incoming: AsyncThrowingStream<JSONValue, any Error>

    /// The largest single message accepted from the peer.
    public static let maximumMessageBytes = 4 << 20

    public init(executable: String, arguments: [String], environment: [String: String]? = nil, currentDirectory: String? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        self.process = process
        self.input = stdin.fileHandleForWriting
        let output = stdout.fileHandleForReading
        var continuation: AsyncThrowingStream<JSONValue, any Error>.Continuation!
        incoming = AsyncThrowingStream { continuation = $0 }
        let sink = continuation!
        try process.run()
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard !line.isEmpty else { continue }
                    let limits = JSONLimits(maxDocumentBytes: Self.maximumMessageBytes, maxStringCharacters: Self.maximumMessageBytes,
                                            maxNestingDepth: 64, maxCollectionElements: 1 << 16)
                    if let value = try? JSONValue.parse(Data(line), limits: limits) { sink.yield(value) }
                }
                if buffer.count > Self.maximumMessageBytes { buffer.removeAll() }
            }
            sink.finish()
        }
    }

    public func send(_ message: JSONValue) async throws {
        var line = try JSONCanonicalization.canonicalize(message)
        line.append(0x0A)
        try lock.withLock { try input.write(contentsOf: line) }
    }

    public func close() async {
        try? input.close()
        if process.isRunning { process.terminate() }
    }
}
