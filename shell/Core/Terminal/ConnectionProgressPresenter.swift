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
/// This was ~500 lines of choreography duplicated across eight `onStateChange`
/// blocks in `setupPTYAndShell` (SSH / Kubernetes / Console / EC2 / Mosh /
/// Trzsz). Each session type's distinct state enum still maps its own cases to
/// these calls, but the spinner mechanics and the exact escape-sequence writes
/// now live here in one place. The presenter owns the `SpinnerAnimator`, so the
/// 68 `spinnerAnimator` touches in the view collapse to this one owner.
@MainActor
final class ConnectionProgressPresenter {

    /// How a connection phase ends decides which cleanup sequence is written.
    /// The three modes capture the exact (and subtly different) writes the
    /// per-session-type blocks used.
    enum FinishMode {
        /// Always write `progressClear + cleanup`, even when no spinner ran.
        /// SSH/K8s/Console/EC2 `.running` and `.terminated`/`.disconnected`.
        case clearAlways
        /// Write `progressClear + cleanup` only if a spinner actually ran.
        /// Mosh/Trzsz `.running` and `.failed`/`.disconnected`.
        case clearIfSpinnerRan
        /// Write the spinner cleanup only (no progress-clear), and only if a
        /// spinner ran. SSH/K8s/Console/EC2 `.failed`.
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
        case .clearIfSpinnerRan:
            if !cleanup.isEmpty { host.writeProgressOutput(Self.progressClear + cleanup) }
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

    /// Stop and discard the spinner without emitting anything. Was the
    /// `spinnerAnimator?.stop(); spinnerAnimator = nil` in `cleanup()` and the
    /// Trzsz-transfer `.running` handler.
    func reset() {
        spinner?.stop()
        spinner = nil
    }

    /// Keep the spinner's width in sync with the terminal (for responsive joke
    /// truncation) while it's animating. No-op when no spinner is running.
    func updateTerminalWidth(_ width: Int) {
        spinner?.updateTerminalWidth(width)
    }
}
