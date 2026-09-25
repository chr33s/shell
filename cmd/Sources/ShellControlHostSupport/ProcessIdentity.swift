import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A process identified by its PID *and* start time, so a recycled PID is
/// never mistaken for the process that owned a native wait
/// (docs/specs/agent-relay.md sections 4.1 and 13.3).
public struct ProcessIdentity: Sendable, Hashable, Codable {
    public let pid: Int32
    /// Microseconds since the epoch at which the process started.
    public let startTime: Int64

    public init(pid: Int32, startTime: Int64) {
        self.pid = pid
        self.startTime = startTime
    }

    /// The identity of a live process, or nil when it does not exist.
    public static func of(pid: Int32) -> ProcessIdentity? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        let start = info.kp_proc.p_starttime
        return ProcessIdentity(pid: pid, startTime: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec))
        #else
        return nil
        #endif
    }

    /// Whether this exact process is still running.
    public var isAlive: Bool { Self.of(pid: pid) == self }
}

/// Whether the peer of a connected stream socket has closed its end: a
/// hook killed by its provider, or exited, can no longer receive an answer.
public enum SocketPeer {
    public static func hasClosed(_ descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        let read = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if read == 0 { return true }
        if read < 0 { return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR }
        return false
    }
}
