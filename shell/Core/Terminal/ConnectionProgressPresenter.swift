import Foundation

/// The view-side capabilities the connection-progress UI needs: a way to write
/// bytes into the terminal and the current terminal width. Mirrors the
/// `TerminalSessionHost` boundary pattern.
@MainActor
protocol ConnectionProgressHost: AnyObject {
    /// Write a string (escape sequences + spinner frames) into the terminal.
    func writeProgressOutput(_ string: String)
    /// Current terminal width in columns (for centering the spinner message).
    var progressTerminalWidth: Int { get }
}

/// Renders connection-progress UI — the animated `SpinnerAnimator` plus the
/// OSC 9;4 progress indicator — into the terminal while a session connects.
///
/// Each session type's state enum maps its own cases to these calls, but the
/// spinner mechanics and the exact escape-sequence writes live here in one
/// place, and the presenter owns the `SpinnerAnimator`.
@MainActor
final class ConnectionProgressPresenter {

    /// How a connection phase ends decides which cleanup sequence is written.
    /// The two modes capture the subtly different writes the SSH and local
    /// session paths need.
    enum FinishMode {
        /// Always write `progressClear + cleanup`, even when no spinner ran.
        /// SSH/local `.running` and `.terminated`/`.disconnected`.
        case clearAlways
        /// Write the spinner cleanup only (no progress-clear), and only if a
        /// spinner ran. SSH/local `.failed`.
        case cleanupOnly
    }

    // OSC 9;4 progress sequences + a CR/clear-line fallback. Kept local so the
    // presenter doesn't depend on TerminalView's nested TerminalSequence.
    private static let progressPulsing = "\u{1B}]9;4;3\u{07}"  // Indeterminate/pulsing
    private static let progressClear = "\u{1B}]9;4;0\u{07}"    // Clear progress
    private static let clearLine = "\r\u{1B}[K"                // CR + clear to EOL

    private unowned let host: ConnectionProgressHost
    private var spinner: SpinnerAnimator?

    init(host: ConnectionProgressHost) {
        self.host = host
    }

    /// A connection phase is in progress: lazily create the spinner (emitting
    /// the pulsing progress indicator the first time) and start/update it with
    /// the session's themed status. Was the `default` switch branch.
    func update(message: String, style: SpinnerAnimator.ColorStyle) {
        if spinner == nil {
            spinner = SpinnerAnimator()
            host.writeProgressOutput(Self.progressPulsing)
        }
        spinner?.start(
            message: message,
            style: style,
            terminalWidth: host.progressTerminalWidth
        ) { [weak host] output in
            // Spinner frames include their own cleanup sequences for multi-line support.
            host?.writeProgressOutput(output)
        }
    }

    /// A connection phase ended: stop the spinner and emit the cleanup sequence
    /// per `mode`. Was the `.running`/`.failed`/`.terminated`/`.disconnected`
    /// branches (the empty-string fallback matches those blocks).
    func finish(_ mode: FinishMode) {
        let cleanup = spinner?.getCleanupSequence() ?? ""
        spinner?.stop()
        spinner = nil
        switch mode {
        case .clearAlways:
            host.writeProgressOutput(Self.progressClear + cleanup)
        case .cleanupOnly:
            if !cleanup.isEmpty { host.writeProgressOutput(cleanup) }
        }
    }

    /// Force-clear the spinner and progress indicator (clear-line fallback when
    /// no spinner ran). Was `clearProgressAndSpinner`.
    func clear() {
        let cleanup = spinner?.getCleanupSequence() ?? Self.clearLine
        spinner?.stop()
        spinner = nil
        host.writeProgressOutput(Self.progressClear + cleanup)
    }

    /// Stop the spinner and return its cleanup sequence (clear-line fallback)
    /// WITHOUT writing it, so the caller can compose it into its own output.
    /// Was the spinner half of `handleSessionError`.
    func takeCleanupSequence() -> String {
        let cleanup = spinner?.getCleanupSequence() ?? Self.clearLine
        spinner?.stop()
        spinner = nil
        return cleanup
    }

    /// Stop and discard the spinner without emitting anything, for session
    /// teardown that writes its own output (or none at all).
    func reset() {
        spinner?.stop()
        spinner = nil
    }

    /// Keep the spinner's width in sync with the terminal (for responsive
    /// message truncation) while it's animating. No-op when no spinner runs.
    func updateTerminalWidth(_ width: Int) {
        spinner?.updateTerminalWidth(width)
    }
}
