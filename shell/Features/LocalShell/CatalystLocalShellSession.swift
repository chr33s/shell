//
//  CatalystLocalShellSession.swift
//  shell
//
//  Native PTY session for the Catalyst app
//  Creates PTYs through ShellMacSupport
//  Only available on Mac Catalyst
//

import Foundation
import os

#if targetEnvironment(macCatalyst)

/// Shell session for Catalyst using a native child process
/// This replaces LocalShellSession when running on Mac Catalyst
@MainActor
public class CatalystLocalShellSession: TerminalSession {

    private static let logFrequentLayout = ProcessInfo.processInfo.environment["GHOSTTY_LOG_FREQUENT_LAYOUT"] == "1"
    private static let resizeThrottleNs: UInt64 = 50_000_000  // 50ms

    private let sessionID: UUID
    private let masterFD: Int32

    // TerminalSession protocol requirements
    public let pty: TerminalPTY
    public var isRunning = true

    // Callback-based output pattern (matches SSHSession)
    // NOTE: These callbacks may be called from a background thread (PTY read queue).
    // Callers must ensure thread-safe handling.
    public var onOutput: (@Sendable (String) -> Void)?
    public var onOutputData: (@Sendable (Data) -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var onWorkingDirectoryChange: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onSessionEnd: (() -> Void)?
    public var onReady: (() -> Void)?
    public var onError: ((Error) -> Void)?

    // Reconnection support - local shell does not support reconnection
    public var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?
    public var supportsAutoReconnect: Bool { false }

    // Read queue for PTY polling (matches macOS Ghostty pattern)
    private let readQueue = DispatchQueue(label: "dev.chr33s.shell.catalyst.read", qos: .userInitiated)
    private var readSource: DispatchSourceRead?

    // Write queue for PTY writes (prevents main thread blocking during large pastes)
    private let writeQueue = DispatchQueue(label: "dev.chr33s.shell.catalyst.write", qos: .userInitiated)
    private var closeScheduled = false

    // Coalesced resize state (to avoid hammering the PTY during live resizing)
    private var lastSentGridSize: (rows: UInt16, cols: UInt16)?
    private var pendingGridSize: (rows: UInt16, cols: UInt16)?
    private var resizeTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a native PTY. Output monitoring starts after the caller installs callbacks.
    public static func create(rows: UInt16, cols: UInt16, workingDirectory: String? = nil,
                              shell: String? = nil, enableShellIntegration: Bool = true,
                              paneToken: String? = nil,
                              completion: @escaping (Result<CatalystLocalShellSession, Error>) -> Void) {
        do {
            let process = try MacLocalShellManager.create(rows: rows, columns: cols,
                directory: workingDirectory, shell: shell, integration: enableShellIntegration, paneToken: paneToken)
            do {
                let fd = process.duplicateMaster()
                guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                completion(.success(CatalystLocalShellSession(process: process, masterFD: fd,
                    size: TerminalPTY.TerminalSize(rows: rows, cols: cols))))
            } catch {
                process.terminate(signal: SIGHUP)
                throw error
            }
        } catch { completion(.failure(error)) }
    }

    private let process: any MacShellProcess
    private init(process: any MacShellProcess, masterFD: Int32, size: TerminalPTY.TerminalSize) {
        self.process = process
        self.sessionID = UUID()
        self.masterFD = masterFD
        let pty = TerminalPTY()
        pty.useExternalFd(masterFD)
        pty.windowSize = size
        self.pty = pty
    }

    // MARK: - I/O Operations

    /// Starts monitoring PTY output using callback pattern (matches SSHSession)
    func startMonitoring() {
        guard readSource == nil else { return }
        Ghostty.logger.info("Starting PTY monitoring with polling pattern for session \(self.sessionID)")

        // Set PTY master FD to non-blocking mode (critical for polling)
        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        let sessionID = self.sessionID
        let masterFD = self.masterFD
        let outputDataCallback = self.onOutputData
        let outputCallback = self.onOutput
        let handleExit: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleExit()
            }
        }
        let emitOutput: @Sendable (Data) -> Void = { data in
            if let outputDataCallback {
                outputDataCallback(data)
            } else if let outputCallback {
                outputCallback(String(decoding: data, as: UTF8.self))
            }
        }

        // Create a dispatch source to monitor PTY for readability
        // This mimics poll() in macOS Ghostty's threadMainPosix
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: readQueue)

        source.setEventHandler {
            let (output, didExit) = Self.readFromPTY(masterFD: masterFD)
            if !output.isEmpty {
                // Emit directly without batching for immediate response
                emitOutput(output)
            }
            if didExit {
                handleExit()
            }
        }

        source.setCancelHandler {
            Ghostty.logger.info("PTY read source canceled for session \(sessionID.uuidString)")
        }

        source.resume()
        self.readSource = source

        // Session is now ready for input
        Ghostty.logger.info("Catalyst session monitoring started, firing onReady callback")
        onReady?()
    }

    /// Reads from PTY in a hot loop until EAGAIN (matches macOS Ghostty pattern)
    /// Returns raw bytes for direct terminal rendering.
    private nonisolated static func readFromPTY(masterFD: Int32) -> (Data, Bool) {
        guard masterFD >= 0 else { return (Data(), false) }

        let bufferSize = 4096 // Larger buffer reduces callback churn during heavy repaints
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var output = Data()
        var didExit = false

        // Hot loop: read as much as available (until EAGAIN)
        while true {
            let bytesRead = read(masterFD, &buffer, bufferSize)

            if bytesRead > 0 {
                output.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                // EOF - PTY closed
                didExit = true
                break
            } else {
                // Error occurred
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // No more data available - exit hot loop
                    // DispatchSource will call us again when more data arrives
                    break
                } else if err == EINTR {
                    // Interrupted by signal - retry
                    continue
                } else {
                    // Fatal error
                    Ghostty.logger.error("PTY read error: \(String(cString: strerror(err)))")
                    didExit = true
                    break
                }
            }
        }

        return (output, didExit)
    }


    // MARK: - TerminalSession Protocol Implementation

    public func start() async throws {
        // Session is already started in create()
        // This is called by the framework to begin processing
        Ghostty.logger.info("Session \(self.sessionID) start() called")
    }

    public func stop() {
        terminate(signal: SIGHUP)
    }

    public func sendInput(_ data: Data) {
        // Dispatch writes to background queue to prevent main thread blocking
        // during large pastes that may require retries when PTY buffer fills.
        guard isRunning, masterFD >= 0 else {
            Ghostty.logger.warning("Cannot write - session not running or no FD")
            return
        }

        // Capture fd as value type for async dispatch
        let fd = masterFD

        writeQueue.async {
            Self.writeAll(fd: fd, data: data)
        }
    }

    /// Writes `data` to `fd`, retrying on EAGAIN/EINTR/buffer-full. Actor-agnostic
    /// and thread-safe so it can be shared by `sendInput` and the tmux
    /// control-mode gateway fast path. Always invoked on `writeQueue` so writes
    /// stay serialized regardless of which path enqueued them.
    private nonisolated static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { bufferPtr in
            guard let baseAddress = bufferPtr.baseAddress else { return }
            var totalWritten = 0
            var retryCount = 0
            let maxRetries = 1000  // Allow up to ~1 second of retries

            while totalWritten < data.count {
                let remaining = data.count - totalWritten
                let currentPtr = baseAddress.advanced(by: totalWritten)
                let bytesWritten = Darwin.write(fd, currentPtr, remaining)

                if bytesWritten > 0 {
                    totalWritten += bytesWritten
                    retryCount = 0  // Reset retry counter on successful write
                } else if bytesWritten < 0 {
                    let err = errno
                    if err == EINTR {
                        // Interrupted by signal - retry without counting as backoff
                        continue
                    }
                    if err == EAGAIN || err == EWOULDBLOCK {
                        // PTY buffer full - retry with backoff
                        if retryCount < maxRetries {
                            retryCount += 1
                            usleep(1000)  // 1ms sleep to let PTY drain
                            continue
                        } else {
                            Ghostty.logger.error("PTY write failed after \(maxRetries) retries (buffer full)")
                            break
                        }
                    } else {
                        Ghostty.logger.error("Failed to write to PTY: \(String(cString: strerror(err)))")
                        break
                    }
                } else {
                    // bytesWritten == 0 shouldn't happen for PTY, but handle it
                    Ghostty.logger.warning("PTY write returned 0")
                    break
                }
            }

            if totalWritten < data.count {
                Ghostty.logger.error("Partial PTY write: \(totalWritten)/\(data.count) bytes")
            }
        }
    }

    /// Builds a `@Sendable` sink that writes input to the PTY off the main
    /// actor, used by the tmux control-mode gateway response path to skip a
    /// per-keystroke main-actor hop. Captures the write fd and queue by value
    /// (both `Sendable`); the fd is stable for the session's lifetime, so the
    /// sink stays valid until the session ends (writes to a closed fd fail
    /// harmlessly via `writeAll`). Returns nil if not running.
    /// See `TerminalResponsePipeline.configureGatewayFastPath`.
    func makeNonisolatedInputSink() -> (@Sendable (Data) -> Void)? {
        guard isRunning, masterFD >= 0 else { return nil }
        let fd = masterFD
        let q = writeQueue
        return { data in q.async { Self.writeAll(fd: fd, data: data) } }
    }

    public func setSize(_ size: TerminalPTY.TerminalSize) throws {
        pty.windowSize = size
        scheduleResize(rows: size.rows, cols: size.cols)
    }

    /// Interrupts the running command (CTRL-C handler)
    /// Uses in-band signaling (sends \x03 through PTY) like SSH and macOS Ghostty
    public func interrupt() {
        Ghostty.logger.info("Sending CTRL-C to shell")

        // Send CTRL-C (\x03) directly to the PTY
        // The shell receives it, sends SIGINT to the process, and output stops naturally
        // The polling read pattern handles this gracefully with no special logic needed
        let ctrlC = Data([0x03])
        sendInput(ctrlC)
    }

    /// Resizes the PTY (coalesced during live resizing)
    private func scheduleResize(rows: UInt16, cols: UInt16) {
        guard isRunning else { return }

        let gridSize = (rows: rows, cols: cols)
        if let pendingGridSize, pendingGridSize == gridSize { return }
        pendingGridSize = gridSize

        if resizeTask == nil {
            resizeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.resizeTask = nil }

                while true {
                    guard let pending = self.pendingGridSize else { break }
                    self.pendingGridSize = nil

                    if let lastSentGridSize = self.lastSentGridSize, lastSentGridSize == pending {
                        // Already sent this exact size; no-op.
                    } else {
                        self.lastSentGridSize = pending
                        if Self.logFrequentLayout {
                            let sessionID = self.sessionID
                            let rows = pending.rows
                            let cols = pending.cols
                            Ghostty.logger.debug("Resizing session \(sessionID) to \(rows)x\(cols)")
                        }
                        do {
                            var size = self.pty.windowSize
                            size.rows = pending.rows
                            size.cols = pending.cols
                            try self.pty.setWindowSize(size)
                        } catch {
                            self.lastSentGridSize = nil
                        }
                    }

                    try? await Task.sleep(nanoseconds: Self.resizeThrottleNs)
                }
            }
        }
    }

    // MARK: - Lifecycle

    /// Terminates the shell
    private func terminate(signal: Int32 = SIGTERM) {
        guard isRunning else { return }

        Ghostty.logger.info("Terminating session \(self.sessionID) with signal \(signal)")

        process.terminate(signal: signal)

        cleanup()
    }

    private func handleExit() {
        guard isRunning else { return }
        isRunning = false

        Ghostty.logger.info("Session \(self.sessionID) exited, querying status")

        onSessionEnd?()
        cleanup()
    }

    private func cleanup() {
        isRunning = false

        // Cancel any pending tasks
        resizeTask?.cancel()
        resizeTask = nil
        pendingGridSize = nil

        // Cancel read source
        readSource?.cancel()
        readSource = nil

        // Close master FD
        if masterFD >= 0, !closeScheduled {
            closeScheduled = true
            let fd = masterFD
            writeQueue.async {
                close(fd)
            }
        }
    }
}

#endif // targetEnvironment(macCatalyst)
