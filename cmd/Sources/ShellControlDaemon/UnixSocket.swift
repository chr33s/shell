import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
import ShellControlProtocol

/// A per-user Unix-domain socket under a private state directory: directory
/// mode 0700, socket mode 0600, peer identity verified where supported
/// (spec.watch.md section 17).
public struct UnixSocketServer: Sendable {
    public enum SocketError: Error, Sendable {
        case pathTooLong
        case bind(Int32)
        case listen(Int32)
        case peerRejected
        case alreadyServing
    }

    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func isServedByLiveInstance() -> Bool {
        let client = UnixSocketClient(path: path)
        guard let fd = try? client.connect() else { return false }
        close(fd)
        return true
    }

    public func makeListener() throws -> Int32 {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Re-tighten in case the directory already existed with looser modes.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        if isServedByLiveInstance() {
            throw SocketError.alreadyServing
        }
        unlink(path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        try withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            guard pathBytes.count < buffer.count else { throw SocketError.pathTooLong }
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw SocketError.bind(errno) }
        // File modes prevent accidental cross-process routing and access by
        // other users; they do not make a malicious same-user process trusted
        // (spec.watch.md section 4).
        chmod(path, 0o600)
        guard listen(descriptor, 32) == 0 else { throw SocketError.listen(errno) }
        return descriptor
    }

    /// Rejects a peer running as a different user.
    public static func verifyPeer(_ descriptor: Int32) -> Bool {
        var euid: uid_t = 0
        var egid: gid_t = 0
        #if canImport(Darwin)
        guard getpeereid(descriptor, &euid, &egid) == 0 else { return false }
        return euid == getuid()
        #else
        var credentials = ucred()
        var length = socklen_t(MemoryLayout<ucred>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0 else { return false }
        euid = credentials.uid
        _ = egid
        return euid == getuid()
        #endif
    }
}

/// Blocking length-prefixed frame IO over a socket descriptor.
public enum FrameIO {
    public static func readFrame(_ descriptor: Int32, buffer: inout Data) throws -> JSONValue? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let value = try IPCFraming.decodeFrame(from: &buffer) { return value }
            let read = recv(descriptor, &chunk, chunk.count, 0)
            if read <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<read])
            if buffer.count > IPCFraming.maxFrameBytes * 2 {
                throw IPCFraming.FramingError.frameTooLarge(buffer.count)
            }
        }
    }

    public static func writeFrame(_ descriptor: Int32, _ value: JSONValue) throws {
        let framed = try IPCFraming.frame(value)
        try framed.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let written = send(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if written <= 0 { throw UnixSocketServer.SocketError.peerRejected }
                sent += written
            }
        }
    }
}

/// A client side for the CLI and adapters.
public struct UnixSocketClient: Sendable {
    public let path: String
    public init(path: String) { self.path = path }

    public func connect() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        try withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            guard pathBytes.count < buffer.count else { throw UnixSocketServer.SocketError.pathTooLong }
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // Qualified so the call is not shadowed by this method, and
                // spelled per-platform because the daemon runs on macOS or
                // Linux (spec.watch.md section 3).
                #if canImport(Glibc)
                return Glibc.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                return Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard connected == 0 else { throw UnixSocketServer.SocketError.bind(errno) }
        return descriptor
    }

    /// One request/response exchange. `timeout` bounds a long `approval.wait`.
    public func exchange(_ request: IPCRequest, timeout: TimeInterval = 600) throws -> IPCResponse {
        let descriptor = try connect()
        defer { close(descriptor) }
        var seconds = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &seconds, socklen_t(MemoryLayout<timeval>.size))
        try FrameIO.writeFrame(descriptor, request.json)
        var buffer = Data()
        guard let value = try FrameIO.readFrame(descriptor, buffer: &buffer) else {
            throw UnixSocketServer.SocketError.peerRejected
        }
        return try IPCResponse(json: value)
    }
}
