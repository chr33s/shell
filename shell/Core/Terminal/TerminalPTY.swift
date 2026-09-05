import Foundation

/// Manages a POSIX PTY (pseudo-terminal) pair for terminal I/O
/// This provides the low-level file descriptors needed for bidirectional communication
/// between the terminal emulator (Ghostty) and command execution layer (ShellSession/SSHSession)
@MainActor
public final class TerminalPTY {
    /// File descriptor for the PTY master (Swift side for reading input, writing output)
    /// Can be set externally when using Ghostty's PTY
    nonisolated(unsafe) var masterFd: Int32 = -1

    /// File descriptor for the PTY slave (passed to Ghostty for terminal emulation)
    nonisolated(unsafe) private(set) var slaveFd: Int32 = -1

    /// Path to the PTY slave device (e.g., "/dev/ttys001")
    private(set) var slavePath: String?

    /// Current terminal window size
    var windowSize: TerminalSize = TerminalSize(rows: 24, cols: 80)

    /// Whether this PTY owns the file descriptors (should close them on deinit)
    nonisolated(unsafe) private var ownsFds: Bool = true

    /// Creates a new uninitialized PTY wrapper
    /// Use `open(size:)` to create a new PTY, or `useExternalFd(_:)` to wrap an existing FD
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
        case failedToOpenMaster
        case failedToGrantAccess
        case failedToUnlock
        case failedToGetSlaveName
        case failedToOpenSlave
        case failedToSetWindowSize
        case failedToSetTerminalAttributes
        case alreadyOpen
        case notOpen

        var errorDescription: String? {
            switch self {
            case .failedToOpenMaster: return "Failed to open PTY master"
            case .failedToGrantAccess: return "Failed to grant PTY access"
            case .failedToUnlock: return "Failed to unlock PTY"
            case .failedToGetSlaveName: return "Failed to get PTY slave name"
            case .failedToOpenSlave: return "Failed to open PTY slave"
            case .failedToSetWindowSize: return "Failed to set terminal window size"
            case .failedToSetTerminalAttributes: return "Failed to set terminal attributes"
            case .alreadyOpen: return "PTY is already open"
            case .notOpen: return "PTY is not open"
            }
        }
    }

    /// Creates and opens a new PTY pair
    /// - Parameter size: Initial terminal size (default 24x80)
    /// - Throws: PTYError if PTY creation fails
    func open(size: TerminalSize = TerminalSize(rows: 24, cols: 80)) throws {
        guard masterFd == -1 else {
            throw PTYError.alreadyOpen
        }

        // 1. Open PTY master
        masterFd = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFd >= 0 else {
            throw PTYError.failedToOpenMaster
        }

        // 2. Grant access to slave
        guard grantpt(masterFd) == 0 else {
            Darwin.close(masterFd)
            masterFd = -1
            throw PTYError.failedToGrantAccess
        }

        // 3. Unlock the slave
        guard unlockpt(masterFd) == 0 else {
            Darwin.close(masterFd)
            masterFd = -1
            throw PTYError.failedToUnlock
        }

        // 4. Get slave device name
        guard let slaveNamePtr = ptsname(masterFd) else {
            Darwin.close(masterFd)
            masterFd = -1
            throw PTYError.failedToGetSlaveName
        }
        slavePath = String(cString: slaveNamePtr)

        // 5. Open slave
        guard let path = slavePath else {
            Darwin.close(masterFd)
            masterFd = -1
            throw PTYError.failedToGetSlaveName
        }

        slaveFd = Darwin.open(path, O_RDWR | O_NOCTTY)
        guard slaveFd >= 0 else {
            Darwin.close(masterFd)
            masterFd = -1
            slavePath = nil
            throw PTYError.failedToOpenSlave
        }

        // 6. Configure terminal attributes
        try setupTerminalAttributes()

        // 7. Set initial window size
        windowSize = size
        try setWindowSize(size)

        print("✅ PTY opened: master=\(masterFd), slave=\(slaveFd), path=\(path)")
    }

    /// Configures terminal attributes (termios) for the PTY
    private func setupTerminalAttributes() throws {
        var term = termios()

        // Get current attributes
        guard tcgetattr(slaveFd, &term) == 0 else {
            throw PTYError.failedToSetTerminalAttributes
        }

        // Configure for raw mode with UTF-8 support
        // Input flags
        term.c_iflag = tcflag_t(ICRNL | IXON | IXANY | IMAXBEL | IUTF8)

        // Output flags - enable post-processing
        term.c_oflag = tcflag_t(OPOST | ONLCR)

        // Control flags - 8-bit, enable receiver
        term.c_cflag = tcflag_t(CS8 | CREAD | HUPCL)

        // Local flags - canonical mode, echo, signals
        term.c_lflag = tcflag_t(ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | ISIG | IEXTEN)

        // Control characters
        term.c_cc.0 = cc_t(VINTR);    term.c_cc.1 = 0x03    // Ctrl-C
        term.c_cc.2 = cc_t(VQUIT);    term.c_cc.3 = 0x1C    // Ctrl-\
        term.c_cc.4 = cc_t(VERASE);   term.c_cc.5 = 0x7F    // DEL
        term.c_cc.6 = cc_t(VKILL);    term.c_cc.7 = 0x15    // Ctrl-U
        term.c_cc.8 = cc_t(VEOF);     term.c_cc.9 = 0x04    // Ctrl-D

        // Apply attributes
        guard tcsetattr(slaveFd, TCSANOW, &term) == 0 else {
            throw PTYError.failedToSetTerminalAttributes
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

    /// Closes the PTY pair (only if we own the FDs)
    nonisolated func close() {
        print("🔒 close() called, ownsFds = \(ownsFds)")
        guard ownsFds else {
            print("🔒 PTY not owned, skipping close (external FD)")
            return
        }

        print("🔒 Closing PTY (we own the FDs)")

        if slaveFd >= 0 {
            Darwin.close(slaveFd)
            // Note: Can't set to -1 in nonisolated context, but that's okay
            // since this is only called from deinit
        }

        if masterFd >= 0 {
            Darwin.close(masterFd)
        }

        print("🔒 PTY closed")
    }

    /// Mark this PTY as using external file descriptors (e.g., from Ghostty)
    /// When using external FDs, this PTY won't close them on deinit
    public func useExternalFd(_ fd: Int32) {
        print("📎 Setting external PTY master FD: \(fd), setting ownsFds = false")
        self.masterFd = fd
        self.ownsFds = false
        // The helper opened the pair, but the master fd names its slave here too.
        if let name = ptsname(fd) {
            slavePath = String(cString: name)
        }
        print("📎 ownsFds is now: \(self.ownsFds)")
    }

    nonisolated deinit {
        close()
    }
}
