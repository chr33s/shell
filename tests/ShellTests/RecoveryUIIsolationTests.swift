//
//  RecoveryUIIsolationTests.swift
//  ShellTests
//
//  AC-18: the native recovery overlay must leave terminal content and cursor
//  bytes unchanged.
//
//  This is a source-text tripwire, tier 3 in `SourceTree`'s hierarchy, and it
//  is labelled as such. The thing being guarded — "no recovery code path
//  writes escape sequences into the surface" — is the *absence* of a call,
//  and an absence cannot be observed at runtime. A behavioral test would
//  need a live Ghostty surface, a real disconnection, and a byte-level
//  comparison of the alternate screen, which this target cannot build.
//
//  The regression it exists for is concrete and was real: recovery status
//  used to be an `InlineSpinnerAnimator` driving a 0.08s timer that wrote
//  `\u{1B}[…m` runs straight into the terminal, plus a countdown timer
//  rewriting the same line ten times a second. On the alternate screen that
//  is unrecoverable corruption of whatever the remote program is drawing.
//

import XCTest
@testable import Shell

final class RecoveryUIIsolationTests: XCTestCase {

    /// Lint: the recovery controller must not write to the terminal stream.
    func testLint_recoveryControllerNeverWritesToTheTerminalStream() throws {
        try SourceTree.requireSources()

        let file = SourceTree.appSources
            .appendingPathComponent("Core/Terminal/Reconnect/TerminalReconnectionController.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        XCTAssertFalse(
            source.contains("terminalWriteToGhostty"),
            """
            TerminalReconnectionController writes to the terminal stream again. \
            Recovery status belongs in RecoveryStatusStrip, outside the surface \
            (spec.connectivity.md §12, AC-18).
            """
        )

        XCTAssertFalse(
            source.contains("InlineSpinnerAnimator"),
            "An inline spinner animates escape sequences into the terminal again."
        )

        XCTAssertFalse(
            source.contains("\\u{1B}"),
            "An escape sequence is being constructed on a recovery path."
        )
    }

    /// Lint: the strip renders through SwiftUI, so it cannot reach the stream
    /// even by accident.
    func testLint_recoveryStatusStripIsNative() throws {
        try SourceTree.requireSources()

        let file = SourceTree.appSources
            .appendingPathComponent("UI/Overlays/RecoveryStatusStrip.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        XCTAssertTrue(source.contains("import SwiftUI"))
        XCTAssertFalse(source.contains("terminalWriteToGhostty"))
        XCTAssertFalse(source.contains("ghostty_surface_"))
    }

    /// Lint: the recovery path must never build a create-or-attach tmux
    /// command. `new-session -A` is correct on a user-initiated connect and
    /// catastrophic on a reconnect, where it hands back an empty session
    /// while the UI says "reattaching" (CON-05).
    func testLint_recoveryTmuxPathNeverUsesCreateOrAttach() throws {
        try SourceTree.requireSources()

        let file = SourceTree.appSources
            .appendingPathComponent("Features/Tmux/TmuxRecoveryIdentity.swift")
        let source = try String(contentsOf: file, encoding: .utf8)

        // The doc comment explains why the fallback is absent, so allow the
        // words in comments but not in a command string.
        let commandLines = source
            .split(separator: "\n")
            .filter { $0.contains("tmux ") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        for line in commandLines {
            XCTAssertFalse(line.contains("new-session"),
                           "recovery command construction can create a session: \(line)")
        }
    }
}
