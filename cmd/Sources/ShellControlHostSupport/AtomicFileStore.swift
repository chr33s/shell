import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum HostIOError: Error, CustomStringConvertible, Sendable {
    case unsafePath(String)
    case invalidPath(String)
    case lockTimeout
    case io(String)

    public var description: String {
        switch self {
        case .unsafePath(let path): "unsafe path or ownership: \(path)"
        case .invalidPath(let path): "path must be absolute and free of traversal: \(path)"
        case .lockTimeout: "another management command holds the installation lock"
        case .io(let message): message
        }
    }
}

public enum SecureFileSystem {
    public static func validateAbsolute(_ path: String) throws {
        guard path.hasPrefix("/"), !(path as NSString).pathComponents.contains("..") else {
            throw HostIOError.invalidPath(path)
        }
    }

    public static func validateOwnedPath(_ path: String, type: FileAttributeType? = nil) throws {
        try validateAbsolute(path)
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw HostIOError.unsafePath(path) }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw HostIOError.unsafePath(path)
        }
        if let type, attributes[.type] as? FileAttributeType != type { throw HostIOError.unsafePath(path) }
    }

    public static func ensureDirectory(_ url: URL, permissions: Int = 0o700) throws {
        try validateAbsolute(url.path)
        if FileManager.default.fileExists(atPath: url.path) {
            try validateOwnedPath(url.path, type: .typeDirectory)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: permissions])
        }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    public static func atomicWrite<T: Encodable>(_ value: T, to url: URL, permissions: Int = 0o600) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        try atomicWrite(data, to: url, permissions: permissions)
    }

    public static func atomicWrite(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        try ensureDirectory(directory)
        var info = stat()
        if lstat(url.path, &info) == 0 { try validateOwnedPath(url.path, type: .typeRegular) }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(permissions))
        guard descriptor >= 0 else { throw HostIOError.io("cannot create \(temporary.path): \(String(cString: strerror(errno)))") }
        var closed = false
        func closeOnce() {
            guard !closed else { return }
            close(descriptor)
            closed = true
        }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let amount = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw HostIOError.io("write failed: \(String(cString: strerror(errno)))") }
                    offset += amount
                }
            }
            guard fsync(descriptor) == 0 else { throw HostIOError.io("fsync failed") }
            closeOnce()
            guard rename(temporary.path, url.path) == 0 else { throw HostIOError.io("rename failed: \(String(cString: strerror(errno)))") }
            chmod(url.path, mode_t(permissions))
            let directoryFD = open(directory.path, O_RDONLY)
            if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
        } catch {
            closeOnce()
            unlink(temporary.path)
            throw error
        }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try validateOwnedPath(url.path, type: .typeRegular)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

public final class FileLock: @unchecked Sendable {
    private let descriptor: Int32
    private var released = false
    private let mutex = NSLock()

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(path: String, timeout: TimeInterval = 30,
                               cancelled: @escaping @Sendable () -> Bool = { false }) throws -> FileLock {
        try SecureFileSystem.validateAbsolute(path)
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HostIOError.io("cannot open lock \(path): \(String(cString: strerror(errno)))") }
        let deadline = ContinuousClock.now + .seconds(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EAGAIN { close(fd); throw HostIOError.io("flock failed") }
            if cancelled() { close(fd); throw CancellationError() }
            if ContinuousClock.now >= deadline { close(fd); throw HostIOError.lockTimeout }
            usleep(50_000)
        }
        return FileLock(descriptor: fd)
    }

    public func release() {
        mutex.lock(); defer { mutex.unlock() }
        guard !released else { return }
        _ = flock(descriptor, LOCK_UN); close(descriptor); released = true
    }

    deinit { release() }
}
