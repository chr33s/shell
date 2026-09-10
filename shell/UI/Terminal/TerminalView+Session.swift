//
//  TerminalView+Session.swift
//  shell
//
//  Session setup, callbacks, and monitoring for SSH, Kubernetes, Console, EC2, and Local sessions
//  Extracted from TerminalView.swift for build parallelization
//

import UIKit
import GhosttyKit

// MARK: - Session Setup

extension Ghostty.TerminalView {

    func setupPTYAndShell() {
        // Every connection kind this fork supports is started by
        // `TerminalSessionController`.
        guard !sessionController.startSession() else { return }
        assertionFailure("Unhandled session config after TerminalSessionController declined startup")
    }

    /// Start a restored session after the terminal was loaded from persistence
    /// This is called when the user initiates reconnection for a restored terminal
    func startRestoredSession(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(sessionController.startRestoredSession())
    }
}

// MARK: - Deferred Scrollback Restore

extension Ghostty.TerminalView {

    /// Restores deferred scrollback after connection animation completes.
    /// Called from `.running` state handlers. Idempotent — safe to call multiple times.
    ///
    /// - Parameter trailer: Optional bytes to write **immediately after** the saved
    ///   scrollback content and **before** the gate releases buffered live output.
    ///   Used to atomically restore terminal modes (mouse capture, alt screen,
    ///   etc.) that the resumed remote TUI expects to be active. The trailer is
    ///   processed by ghostty in-order with the scrollback, so no live data can
    ///   race ahead of it.
    ///
    /// When no scrollback restore is pending (e.g. the layout-deferred restore
    /// already ran), the trailer is still written
    /// directly to the buffered writer so resumed sessions don't silently lose
    /// their mode-restore sequences. The post-drain render+mouse-capture sync
    /// is also scheduled in that fallback path.
    func restoreScrollbackAfterAnimation(trailer: Data? = nil) {
        if restoredWasTmuxGateway {
            // The gateway is hidden while its projected panes are rebuilt from
            // authoritative tmux captures. Do not replay its saved ANSI or mode
            // trailer: pipe drain does not acknowledge parser consumption, so
            // those bytes could cross the asynchronous control-mode boundary.
            pendingScrollbackRestore = false
            releaseRestoredTmuxOutputGateWhenViewerIsArmed()
            return
        }
        if pendingScrollbackRestore {
            pendingScrollbackRestore = false
            ScrollbackPersistenceManager.shared.restoreScrollback(
                for: self,
                trailer: trailer
            )
            return
        }
        if let trailer, !trailer.isEmpty {
            outputPipeline.writeDirect(trailer)
            didQueueScrollbackRestoreReplay()
        }
    }

    /// Run the layout-deferred scrollback restore for this terminal. Called
    /// from `sizeDidChange` and the timeout fallback.
    func runLayoutDeferredScrollbackRestore() {
        let trailer = pendingResumeTrailer
        pendingResumeTrailer = nil

        if restoredWasTmuxGateway {
            // Projected panes own the useful persisted content. Keep remote
            // control records gated and skip the hidden gateway's ANSI replay.
            releaseRestoredTmuxOutputGateWhenViewerIsArmed()
            return
        }

        ScrollbackPersistenceManager.shared.restoreScrollback(
            for: self,
            trailer: trailer,
            keepGateOpen: false
        )
    }

    /// Ensures the restore replay's final cursor positioning is rendered after
    /// the saved bytes and any gated live output have reached Ghostty.
    func didQueueScrollbackRestoreReplay() {
        outputPipeline.notifyWhenOutputDrained { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flushPostScrollbackRestoreRender()
                await Task.yield()
                guard !Task.isCancelled else { return }
                self.flushPostScrollbackRestoreRender()
            }
        }
    }

    private func flushPostScrollbackRestoreRender() {
        guard !Ghostty.isAppBackgroundedAtomic,
              !Ghostty.isSecureDrawProhibitedAtomic else { return }
        ghosttyApp?.appTick()
        if let surface {
            ghostty_surface_draw(surface)
        }
        // Sync the cached `@Published isMouseCaptured` mirror against ghostty's
        // C state once the scrollback replay (and any restore-time trailer
        // bytes such as DECSET 1000h for mouse mode) have been parsed.
        updateMouseCaptureState()
    }
}

// MARK: - Session Error Handling

extension Ghostty.TerminalView {

    /// Handles session errors with consistent spinner cleanup and error display.
    /// - Parameters:
    ///   - error: The error to store and display
    ///   - prefix: Optional prefix for the error message (e.g., "SSH Error")
    func handleSessionError(_ error: Error, prefix: String? = nil) {
        self.error = error
        outputPipeline.cancelScrollbackRestoreGate()

        // If we were connecting from restore, show failure overlay
        if restorationState == .connectingFromRestore {
            restorationState = .failed(error.localizedDescription)
        }

        // Stop any running spinner animation and grab its cleanup sequence
        // (for multi-line spinner support), then clear the spinner first.
        let spinnerCleanup = connectionProgress.takeCleanupSequence()
        writeToGhostty(string: spinnerCleanup)

        showFinalError(error, prefix: prefix)
    }

    /// Shows the error message once the spinner has been cleared.
    private func showFinalError(_ error: Error, prefix: String?) {
        // Build error message (without prefix for cleaner look)
        let errorMessage = error.localizedDescription

        // Center the error message like the animation and quip
        let terminalWidth = Int(surfaceSize?.columns ?? 80)
        let padding = max(0, (terminalWidth - errorMessage.count) / 2)
        let centeredError = String(repeating: " ", count: padding) + errorMessage

        // Show error below the quip in the same dimmed style (no emoji, seamless with animation)
        let dimColor = "\u{1B}[2m"  // ANSI dim
        let reset = "\u{1B}[0m"

        writeToGhostty(string:
            "\r\n" +
            dimColor + centeredError + reset + "\r\n\r\n" +
            TerminalSequence.progressClear
        )
    }

    /// Clears the progress indicator and status line without displaying an error.
    /// Used when handling auth errors that trigger re-authentication flow.
    func clearProgressAndSpinner() {
        connectionProgress.clear()
    }
}

// MARK: - Session Monitoring

extension Ghostty.TerminalView {

    func manualReconnect() {
        sessionController.manualReconnect()
    }

    func cancelReconnection() {
        sessionController.cancelReconnection()
    }

    /// Handle a button on the native recovery strip. Recovery actions are
    /// always user-initiated: nothing here fires on its own.
    func performRecoveryAction(_ action: RecoveryStatusAction) {
        sessionController.performRecoveryAction(action)
    }

    /// Monitors Ghostty's response pipe for terminal responses (e.g., cursor position queries)
    /// and forwards them back to the session for bidirectional terminal communication.
    /// Works with both SSH and Catalyst local shell sessions.
    ///
    /// Uses event-driven DispatchSource instead of polling for better performance.
    /// This helps drain the termio mailbox faster during heavy I/O from apps like zellij,
    /// reducing the chance of queue saturation that can cause main thread deadlocks.
    func startTerminalResponseMonitoring(for session: TerminalSession) {
        sessionController.startTerminalResponseMonitoring(for: session)
    }
}
