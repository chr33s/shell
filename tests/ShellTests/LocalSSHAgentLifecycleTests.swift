//
//  LocalSSHAgentLifecycleTests.swift
//  ShellTests
//
//  The local SSH agent over a real AF_UNIX socket: bind-before-publish,
//  permissions, stale-socket recovery, per-connection framing, oversized
//  frames, and stop/unlink (ssh-agent-bridge-spec.md §8.3, §9, §15).
//

import Foundation
import Testing

@testable import Shell

@Suite(.serialized)
final class LocalSSHAgentLifecycleTests {
    private let directory: URL
    private let service: LocalSSHAgentService

    init() throws {
        // The simulator's container TMPDIR is far longer than sun_path allows,
        // so these socket-level tests use a short private directory instead.
        let path = "/tmp/sa-t-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = URL(fileURLWithPath: path, isDirectory: true)
        service = Self.makeService(directory: directory)
    }

    private static func makeService(directory: URL, maxClients: Int = LocalSSHAgentClientRegistry.defaultClientLimit) -> LocalSSHAgentService {
        LocalSSHAgentService(
            delegate: ShellSSHAgentDelegate(source: FakeAgentKeySource(keys: [])),
            directory: directory,
            maxClients: maxClients
        )
    }

    deinit {
        let service = service
        let directory = directory
        Task {
            await service.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test
    func testStartBindsBeforeReturningAndIsIdempotent() async throws {
        let path = try await service.startIfNeeded()
        #expect(path == LocalSSHAgentService.socketPath(in: directory))
        #expect(await service.socketPath == path)

        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)

        #expect(try await service.startIfNeeded() == path)
        let client = try AgentSocketClient(path: path)
        #expect(try client.roundTrip(AgentWire.frame([11])) == [12, 0, 0, 0, 0])
        #expect(await service.isListening(at: path))
        await service.stop()
        #expect(await !service.isListening(at: path))
    }

    @Test
    func testConcurrentStartsShareOneListener() async throws {
        let service = service
        async let a = service.startIfNeeded()
        async let b = service.startIfNeeded()
        let paths = try await [a, b]
        #expect(paths[0] == paths[1])
    }

    @Test
    func testStaleSocketFromAPreviousProcessIsReplaced() async throws {
        let path = try #require(LocalSSHAgentService.socketPath(in: directory))
        try AgentSocketClient.leaveStaleSocket(at: path)
        #expect(FileManager.default.fileExists(atPath: path))

        #expect(try await service.startIfNeeded() == path)
        let client = try AgentSocketClient(path: path)
        #expect(try client.roundTrip(AgentWire.frame([11])) == [12, 0, 0, 0, 0])
    }

    @Test
    func testFragmentedAndPipelinedRequestsOnOneConnection() async throws {
        let path = try await service.startIfNeeded()
        let client = try AgentSocketClient(path: path)

        // Header split, then payload, then three requests in one write.
        let first = AgentWire.frame([11])
        try client.send(Array(first[0..<3]))
        usleep(20_000)
        try client.send(Array(first[3...]))
        #expect(try client.readFrame() == [12, 0, 0, 0, 0])

        try client.send(
            AgentWire.frame([17]) + AgentWire.frame([27] + AgentWire.string("x@example.com")) + AgentWire.frame([11])
        )
        #expect(try client.readFrame() == [5])
        #expect(try client.readFrame() == [28])
        #expect(try client.readFrame() == [12, 0, 0, 0, 0])
    }

    @Test
    func testOversizedFrameClosesOnlyThatClient() async throws {
        let path = try await service.startIfNeeded()
        let bad = try AgentSocketClient(path: path)
        try bad.send([0x7F, 0xFF, 0xFF, 0xFF])
        #expect(try bad.readToEOF().isEmpty)

        let good = try AgentSocketClient(path: path)
        #expect(try good.roundTrip(AgentWire.frame([11])) == [12, 0, 0, 0, 0])
    }

    @Test
    func testStopClosesTheListenerAndUnlinksTheSocket() async throws {
        let path = try await service.startIfNeeded()
        await service.stop()
        #expect(await service.socketPath == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: (any Error).self) { _ = try AgentSocketClient(path: path) }

        // Re-enabling binds the same per-process path again.
        #expect(try await service.startIfNeeded() == path)
        #expect(try AgentSocketClient(path: path).roundTrip(AgentWire.frame([11])) == [12, 0, 0, 0, 0])
    }

    @Test
    func testStopClosesLiveClientConnections() async throws {
        let path = try await service.startIfNeeded()
        let client = try AgentSocketClient(path: path)
        #expect(try client.roundTrip(AgentWire.frame([11])) == [12, 0, 0, 0, 0])

        await service.stop()
        #expect(try client.readToEOF().isEmpty)
    }

    @Test
    func testConcurrentClientLimitRefusesExtraClients() async throws {
        let limited = Self.makeService(directory: directory, maxClients: 2)
        defer { Task { await limited.stop() } }
        let path = try await limited.startIfNeeded()

        let a = try AgentSocketClient(path: path)
        var b: AgentSocketClient? = try AgentSocketClient(path: path)
        #expect(try a.roundTrip(AgentWire.frame([11])) == [12, 0, 0, 0, 0])
        #expect(try b?.roundTrip(AgentWire.frame([11])) == [12, 0, 0, 0, 0])

        let refused = try AgentSocketClient(path: path)
        try? refused.send(AgentWire.frame([11]))
        #expect(try refused.readToEOF().isEmpty)

        // The admitted clients are still served.
        #expect(try a.roundTrip(AgentWire.frame([11])) == [12, 0, 0, 0, 0])

        // A slot frees once a client leaves (released asynchronously).
        b = nil
        var admitted = false
        for _ in 0..<50 where !admitted {
            if let retry = try? AgentSocketClient(path: path) {
                admitted = (try? retry.roundTrip(AgentWire.frame([11]))) == [12, 0, 0, 0, 0]
            }
            if !admitted { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(admitted)
        #expect(b == nil)
    }

    @Test
    func testDirectoryTooLongForSunPathFailsClosed() async throws {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 120), isDirectory: true)
        #expect(LocalSSHAgentService.socketPath(in: long) == nil)
        let tooLong = Self.makeService(directory: long)
        await #expect(throws: LocalSSHAgentService.StartError.self) { _ = try await tooLong.startIfNeeded() }
        #expect(await tooLong.socketPath == nil)
    }

    @Test
    func testPrivateVarPathFallsBackToTheShorterVarSpelling() {
        let uuid = "00000000-0000-0000-0000-000000000000"
        let dir = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/\(uuid)/tmp", isDirectory: true)
        // 103 bytes with a 6-digit pid: fits as-is.
        let fits = LocalSSHAgentService.socketPath(in: dir, pid: 123_456)
        #expect(fits == "/private/var/mobile/Containers/Data/Application/\(uuid)/tmp/sa-123456.sock")
        // A 10-digit pid overflows sun_path; the /var spelling still fits.
        let fallback = LocalSSHAgentService.socketPath(in: dir, pid: .max)
        #expect(fallback == "/var/mobile/Containers/Data/Application/\(uuid)/tmp/sa-\(Int32.max).sock")
    }
}


/// Minimal blocking AF_UNIX client with a receive timeout.
final class AgentSocketClient {
    struct SocketError: Error { let errno: Int32 }

    private let fd: Int32

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(errno: errno) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = Self.address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            close(fd)
            throw SocketError(errno: error)
        }
    }

    private static func makeService(directory: URL, maxClients: Int = LocalSSHAgentClientRegistry.defaultClientLimit) -> LocalSSHAgentService {
        LocalSSHAgentService(
            delegate: ShellSSHAgentDelegate(source: FakeAgentKeySource(keys: [])),
            directory: directory,
            maxClients: maxClients
        )
    }

    deinit { close(fd) }

    /// Binds a socket at `path` and closes it without unlinking — what a
    /// terminated process leaves behind.
    static func leaveStaleSocket(at path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        guard result == 0 else { throw SocketError(errno: errno) }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: bytes)
        }
        return address
    }

    func send(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { throw SocketError(errno: errno) }
            offset += written
        }
    }

    private func read(exactly count: Int) throws -> [UInt8]? {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, count - out.count) }
            // A peer close can surface as EOF or as a reset.
            if n == 0 || (n < 0 && errno == ECONNRESET) { return out.isEmpty ? nil : out }
            guard n > 0 else { throw SocketError(errno: errno) }
            out += chunk[0..<n]
        }
        return out
    }

    /// One response payload (length prefix stripped).
    func readFrame() throws -> [UInt8] {
        guard let header = try read(exactly: 4), header.count == 4 else { throw SocketError(errno: 0) }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        return try read(exactly: length) ?? []
    }

    func roundTrip(_ frame: [UInt8]) throws -> [UInt8] {
        try send(frame)
        return try readFrame()
    }

    /// Everything until the peer closes.
    func readToEOF() throws -> [UInt8] {
        var out: [UInt8] = []
        while let bytes = try read(exactly: 1) {
            out += bytes
        }
        return out
    }
}
