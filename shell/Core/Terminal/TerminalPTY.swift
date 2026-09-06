import Foundation

/// Wraps the PTY master file descriptor used for terminal I/O
/// The descriptor is created by the platform owner (Ghostty on iOS, the Catalyst shell helper
/// on macOS) and adopted through `useExternalFd(_:)`; this type carries the terminal size and
/// moves bytes across that descriptor for the command execution layer (ShellSession/SSHSession)
@MainActor
public final class TerminalPTY {
    /// File descriptor for the PTY master (Swift side for reading input, writing output)
    /// Adopted from its external owner via `useExternalFd(_:)`
    nonisolated(unsafe) private(set) var masterFd: Int32 = -1

    /// Current terminal window size
    var windowSize: TerminalSize = TerminalSize(rows: 24, cols: 80)

    /// Whether this PTY owns the file descriptor (should close it on teardown)
    nonisolated(unsafe) private var ownsFds: Bool = true

    /// Creates a new uninitialized PTY wrapper
    /// Use `useExternalFd(_:)` to wrap an existing FD
    public init() {}

    /// Terminal size structure
    public struct TerminalSize: Sendable {
        public var rows: UInt16
        public var cols: UInt16
        public var pixelWidth: UInt16 = 0
        public var pixelHeight: UInt16 = 0

        public nonisolated init(rows: UInt16, cols: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
            self.rows = rows
            self.cols = cols
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    enum PTYError: Error, LocalizedError {
        case failedToSetWindowSize
        case notOpen

        var errorDescription: String? {
            switch self {
            case .failedToSetWindowSize: return "Failed to set terminal window size"
            case .notOpen: return "PTY is not open"
            }
        }
    }

    /// Updates the terminal window size
    /// - Parameter size: New terminal size
    /// - Throws: PTYError if update fails
    func setWindowSize(_ size: TerminalSize) throws {
        guard masterFd >= 0 else {
            throw PTYError.notOpen
        }

        var ws = winsize()
        ws.ws_row = size.rows
        ws.ws_col = size.cols
        ws.ws_xpixel = size.pixelWidth
        ws.ws_ypixel = size.pixelHeight

        guard ioctl(masterFd, TIOCSWINSZ, &ws) == 0 else {
            throw PTYError.failedToSetWindowSize
        }

        windowSize = size
    }

    /// Reads data from the PTY master (user input from Ghostty)
    /// - Parameter maxLength: Maximum bytes to read
    /// - Returns: Data read from PTY, or nil if no data available
    func read(maxLength: Int = 4096) -> Data? {
        guard masterFd >= 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: maxLength)
        let bytesRead = Darwin.read(masterFd, &buffer, maxLength)

        guard bytesRead > 0 else { return nil }

        return Data(buffer[0..<bytesRead])
    }

    /// Writes data to the PTY master (command output to Ghostty)
    /// - Parameter data: Data to write
    /// - Returns: Number of bytes written, or -1 on error
    @discardableResult
    func write(_ data: Data) -> Int {
        guard masterFd >= 0 else { return -1 }

        return data.withUnsafeBytes { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress else { return -1 }
            return Darwin.write(masterFd, baseAddress, data.count)
        }
    }

    /// Writes a string to the PTY master (convenience method)
    /// - Parameter string: String to write (will be converted to UTF-8)
    /// - Returns: Number of bytes written, or -1 on error
    @discardableResult
    func write(_ string: String) -> Int {
        guard let data = string.data(using: .utf8) else { return -1 }
        return write(data)
    }

    /// Closes the PTY master descriptor, unless it belongs to an external owner
    /// External descriptors are closed by whoever opened them (see CatalystLocalShellSession)
    nonisolated func close() {
        guard ownsFds, masterFd >= 0 else { return }

        Darwin.close(masterFd)
        masterFd = -1
    }

    /// Mark this PTY as using an external file descriptor (e.g., from Ghostty)
    /// When using an external FD, this PTY won't close it
    public func useExternalFd(_ fd: Int32) {
        self.masterFd = fd
        self.ownsFds = false
    }
}
