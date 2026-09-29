//
//  LocalShellBackend.swift
//
//  Which implementation backs a `.local` terminal session.
//

import Foundation

/// The two ways Shell runs a local shell. Both are `TerminalSession`s over
/// external I/O, so everything above the session (surface, output pipeline,
/// restore, splits, tmux) is unaware of the choice.
///
/// - `interpreter`: `LocalShellSession`, the in-process interpreter over
///   ios_system's bundled commands. The only backend on iOS and visionOS, and
///   the backend of the sandboxed Mac Catalyst build.
/// - `nativePTY`: `CatalystLocalShellSession`, a native PTY running the login
///   shell through the macOS support bundle. Only the unsandboxed Catalyst build:
///   inside App Sandbox the PTY slave can never become a controlling terminal
///   (docs/specs/shell.md section 9.6), so a real shell there has no job control
///   and no raw mode.
enum LocalShellBackend: Sendable {
    case interpreter
    case nativePTY

    /// Decided once per process from how the process was launched, not from a
    /// build setting: the same binary can ship sandboxed to the App Store and
    /// unsandboxed under Developer ID.
    nonisolated static let current: LocalShellBackend = {
        #if targetEnvironment(macCatalyst)
        // The kernel sets this for every process running under App Sandbox.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return .interpreter
        }
        return .nativePTY
        #else
        return .interpreter
        #endif
    }()

    /// The directory the local shell calls `~`. The interpreter's home is the
    /// app's Documents directory (the container's under App Sandbox); the native
    /// shell's is the user's real home.
    nonisolated static var homeDirectory: String {
        switch current {
        case .interpreter:
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        case .nativePTY:
            return NSHomeDirectory()
        }
    }
}
