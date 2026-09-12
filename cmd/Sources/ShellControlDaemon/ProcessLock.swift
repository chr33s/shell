import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Process-wide exclusive lock for a state/socket directory. A PID is an
/// observation, not this lock.
public struct ProcessLock: Sendable {
    public enum LockError: Error, Sendable {
        case openFailed(Int32)
        case alreadyHeld
    }

    public let path: String
    public let fd: Int32

    public static func acquire(path: String) throws -> ProcessLock {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw LockError.openFailed(errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw LockError.alreadyHeld
        }
        return ProcessLock(path: path, fd: fd)
    }

    public func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

public enum ServiceConfigFile {
    public static func load(_ path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        guard url.path.hasPrefix("/") else {
            throw NSError(domain: "shell-controld", code: 2, userInfo: [NSLocalizedDescriptionKey: "config path must be absolute"])
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "shell-controld", code: 2, userInfo: [NSLocalizedDescriptionKey: "config is not a JSON object"])
        }
        return object
    }

    public static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String, !value.isEmpty else { return nil }
        return value
    }
}
