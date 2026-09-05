import Foundation

/// Protocol for terminal session types (local shell, SSH, etc.)
/// Implementations handle command execution and I/O management
@MainActor
protocol TerminalSession: AnyObject {
    /// The PTY associated with this session
    var pty: TerminalPTY { get }

    /// Whether the session is currently running
    var isRunning: Bool { get }

    /// Starts the session (begins processing input/output)
    func start() async throws

    /// Stops the session gracefully
    func stop()

    /// Sends input data to the session
    /// - Parameter data: Raw input data from user
    func sendInput(_ data: Data)

    /// Sets the terminal window size
    /// - Parameter size: New terminal size
    func setSize(_ size: TerminalPTY.TerminalSize) throws

    /// Callback for output to display (instead of writing to PTY)
    /// NOTE: May be called from a background thread. Must be thread-safe.
    var onOutput: (@Sendable (String) -> Void)? { get set }

    /// Callback for raw output bytes to display (preferred when available)
    /// NOTE: May be called from a background thread. Must be thread-safe.
    var onOutputData: (@Sendable (Data) -> Void)? { get set }

    /// Callback for title changes (e.g., from OSC sequences)
    var onTitleChange: ((String) -> Void)? { get set }

    /// Callback for working directory changes
    var onWorkingDirectoryChange: ((String) -> Void)? { get set }

    /// Callback for bell/beep requests
    var onBell: (() -> Void)? { get set }

    /// Callback for when session ends (shell exits)
    var onSessionEnd: (() -> Void)? { get set }

    /// Callback for when session is fully initialized and ready for input
    /// This fires after async initialization completes (e.g., SSH connection established)
    var onReady: (() -> Void)? { get set }

    /// Callback for errors during session lifecycle
    var onError: ((Error) -> Void)? { get set }

    /// Callback for unexpected disconnection (separate from normal session end).
    /// This is used to trigger reconnection logic. Normal session termination
    /// (e.g., user typed 'exit') should use onSessionEnd instead.
    var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)? { get set }

    /// Connection info for the Connection Info sheet.
    /// Returns detailed metadata about the active connection.
    var connectionInfo: ConnectionInfo? { get }

    /// Whether this session type supports automatic reconnection.
    /// Local shell sessions return false since they don't have network connections.
    var supportsAutoReconnect: Bool { get }

    /// Notifies the session that its tab visibility changed.
    /// Sessions can use this to reduce CPU usage when not visible (e.g., throttle Mosh tick rate).
    /// - Parameter visible: true if the tab is visible, false if hidden/background
    func setTabVisible(_ visible: Bool)

    /// Called when the app enters the background. Sessions should:
    /// - Cancel any periodic Tasks they own (so they don't keep waking the
    ///   main actor at 1 Hz while the OS is trying to suspend us).
    /// - Force-abort any pending blocking calls into the network/Go layer
    ///   that would otherwise leave a goroutine or NIO thread parked on a
    ///   dead FD — that's the cascade trigger for the watchdog kill on
    ///   resume.
    /// Default is a no-op. Sessions opt in.
    func pauseForBackground()

    /// Called when the app returns to the foreground. Sessions should
    /// re-arm the periodic work they paused in `pauseForBackground()`.
    /// Default is a no-op.
    func resumeForForeground()
}

@MainActor
protocol EmbeddedConnectionConfigProviding: AnyObject {
    var activeEmbeddedConnectionConfig: ConnectionConfig? { get }
}

/// Default implementations for TerminalSession
extension TerminalSession {
    /// Default: no connection info available
    var connectionInfo: ConnectionInfo? { nil }

    /// Default: sessions don't support auto-reconnect unless explicitly implemented
    var supportsAutoReconnect: Bool { false }

    /// Notifies the session that its tab visibility changed.
    /// Sessions can use this to reduce CPU usage when not visible.
    /// Default implementation does nothing.
    func setTabVisible(_ visible: Bool) {
        // Default no-op - sessions that support throttling override this
    }

    /// Default: no special background handling.
    func pauseForBackground() {}

    /// Default: no special foreground handling.
    func resumeForForeground() {}
}

/// Protocol extension for SSH-specific functionality
protocol SSHTerminalSession: TerminalSession {
    /// Callback for host key validation
    var onHostKeyValidation: ((HostKeyValidationRequest) async -> HostKeyValidationResult)? { get set }

    /// Callback for state changes (for progress indicators)
    var onStateChange: ((SSHSessionState) -> Void)? { get set }

    /// Key-exchange algorithm negotiated with the server, once known.
    /// Used to warn when the connection is not post-quantum secure.
    var negotiatedKeyExchange: String? { get }

    /// Returns (and clears) the server auth banners (`SSH_MSG_USERAUTH_BANNER`)
    /// captured during authentication, in arrival order. Called on the main
    /// actor at the `.running` emit site so banners display after the
    /// connecting spinner is cleaned up. Default implementation returns `[]`.
    func consumeAuthBanners() -> [String]
}

extension SSHTerminalSession {
    func consumeAuthBanners() -> [String] { [] }
}
