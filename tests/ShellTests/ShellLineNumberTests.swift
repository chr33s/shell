import Foundation
import XCTest

@testable import Shell

/// Regression tests for `$LINENO` — the source line a simple command reports
/// while it runs.
///
/// The value threads through four places, and every test below is written to
/// fail if any one of them is undone:
///
/// * `ShellTokenizer.tokenStartLine` — re-assigned on every *re-entry* of
///   `readNextToken()`, so the innermost real token wins over the
///   line-continuation that preceded it (ShellTokenizer.swift:148). Note the
///   comment half of that comment's claim is not load-bearing: a `#` comment
///   always ends in a newline token, so the token after it gets a fresh
///   `readNextToken()` regardless. Only the continuation path needs the
///   re-assignment — see `testLineContinuation…` below, which is the test that
///   actually pins it.
/// * `ShellTokenizer.upcomingTokenLine` — where the *next* token begins, as
///   opposed to `currentLine`, which is the scanner's position and has already
///   moved past a peeked token.
/// * `ShellParser.parseCommand()` — captures that line before consuming any
///   token and stamps it onto `SimpleCommand.line`.
/// * `ShellInterpreter.publishLineNumber(_:)` — publishes it to the
///   environment, from both `executeSimple` and `renderExternalSimpleCommand`,
///   and deliberately *not* while an ERR trap is running.
///
/// `SimpleCommand` is the only AST node that carries a position, so `$LINENO`
/// read from a `[[ … ]]` operand, a `case` subject or a `for` word list
/// reports the previous simple command's line instead. That gap is documented
/// in `ShellAST.swift`; it is pinned at the bottom of this file with
/// `XCTExpectFailure`, which asserts the *correct* value and records that it
/// currently does not hold — so closing the gap turns those tests into
/// "unexpectedly passed" rather than leaving a stale assertion behind.
@MainActor
final class ShellLineNumberTests: XCTestCase {

    // MARK: - Correct behavior

    /// Each simple command reports its own line, and two commands sharing a
    /// line both report it — the number tracks token position, not a
    /// per-command counter.
    func testEachSimpleCommandReportsItsOwnSourceLine() throws {
        XCTAssertEqual(try runShell("echo $LINENO\necho $LINENO\necho $LINENO\n"),
                       "1\n2\n3\n")
        XCTAssertEqual(try runShell("echo $LINENO;echo $LINENO\n"),
                       "1\n1\n",
                       "two commands on one line both report that line")
        XCTAssertEqual(try runShell("true\necho ${LINENO}\n"),
                       "2\n",
                       "the braced form resolves through the same path")
    }

    /// Blank lines and comment lines occupy a line number, so a command after
    /// them is not reported several lines early.
    ///
    /// Every physical newline — including the ones ending a blank line and a
    /// comment line — has to run through `advance()`, which is the only place
    /// `line` increments. Skipping a run of blank lines by moving `index`
    /// directly (the obvious "collapse consecutive newlines" optimization in
    /// `readNewline()`) makes this report 3.
    func testBlankAndCommentLinesAreCountedAndDoNotClaimTheNextCommand() throws {
        XCTAssertEqual(try runShell("true\n\n# a comment\necho $LINENO\n"), "4\n")
    }

    /// A line continuation *before* a command moves that command onto the
    /// continued line; a continuation *inside* a command's arguments leaves the
    /// command on the line its first token started.
    ///
    /// The pair brackets where `tokenStartLine` must be assigned: remove the
    /// re-assignment on re-entry and the first case reports 1; assign it after
    /// the token is read instead of before, and the second reports 2.
    func testLineContinuationMovesTheFollowingCommandButNotTheCurrentOne() throws {
        XCTAssertEqual(try runShell("true; \\\necho $LINENO\n"), "2\n",
                       "the command after `\\<newline>` lives on the continued line")
        XCTAssertEqual(try runShell("echo \\\n$LINENO\n"), "1\n",
                       "a continuation between a command's own words does not move it")
        XCTAssertEqual(try runShell("true \\\n&& echo $LINENO\n"), "2\n",
                       "…including across an && operator")
    }

    /// The line is captured from where the command's first token *begins*, not
    /// from where the scanner sits after peeking it.
    ///
    /// `X='a\nb' echo $LINENO` starts on line 1 with a pre-command assignment
    /// whose quoted value runs to line 2. `ShellParser.parseCommand()` reads
    /// `tokenizer.upcomingTokenLine` (1); the scanner's own `currentLine` is
    /// already 2. Swapping `upcomingTokenLine` back to `currentLine` makes this
    /// report 2.
    func testCommandLineComesFromTokenStartNotScannerPosition() throws {
        XCTAssertEqual(try runShell("X='a\nb' echo $LINENO\n"), "1\n")
    }

    /// Newlines inside multi-line tokens are counted, so commands *after* them
    /// are not off by the number of lines those tokens spanned.
    ///
    /// Each case fails with a too-small number if the corresponding scanner
    /// path stops advancing `line`: quoted-string bodies, here-document bodies
    /// (consumed wholesale when the newline token is read), and continuations.
    func testLineCountAdvancesThroughMultiLineTokens() throws {
        XCTAssertEqual(try runShell("X='a\nb'\necho $LINENO\n"), "3\n",
                       "single-quoted body")
        XCTAssertEqual(try runShell("X=\"a\nb\"\necho $LINENO\n"), "3\n",
                       "double-quoted body")
        XCTAssertEqual(try runShell("true <<EOF\nx\ny\nEOF\necho $LINENO\n"), "5\n",
                       "here-document body")
        XCTAssertEqual(try runShell("echo one \\\n two\necho $LINENO\n"), "one two\n3\n",
                       "line continuation inside an argument list")
    }

    /// Commands nested in compound constructs report their own line, and a loop
    /// body re-publishes on every iteration rather than latching the first.
    ///
    /// Fails if `parseCommand()`'s line capture is applied only to top-level
    /// list elements, or if `publishLineNumber` is hoisted out of
    /// `executeSimple` to fire once per AST node.
    func testCommandsInsideCompoundConstructsReportTheirOwnLine() throws {
        XCTAssertEqual(try runShell("if true; then\n  echo $LINENO\nfi\n"), "2\n")
        XCTAssertEqual(try runShell("if true\nthen\n echo $LINENO\nfi\n"), "3\n")
        XCTAssertEqual(try runShell("while true; do\n echo $LINENO\n break\ndone\n"), "2\n")
        XCTAssertEqual(try runShell("true\n{\n echo $LINENO\n}\n"), "3\n")
        XCTAssertEqual(try runShell("f() {\n echo $LINENO\n}\ntrue\nf\n"), "2\n",
                       "a function body reports where it was defined, not where it was called")
        XCTAssertEqual(try runShell("for i in a b; do\n echo A$LINENO\n echo B$LINENO\ndone\n"),
                       "A2\nB3\nA2\nB3\n",
                       "each iteration re-publishes each body command's line")
    }

    /// A `( … )` subshell body is part of the enclosing source unit, so its
    /// commands keep the outer line numbering instead of restarting at 1.
    func testSubshellBodyKeepsTheEnclosingScriptLineNumbering() throws {
        XCTAssertEqual(try runShell("(\n echo $LINENO\n)\n"), "2\n")
        XCTAssertEqual(try runShell("true\n(\n true\n echo $LINENO\n)\n"), "4\n")
    }

    /// An isolated environment copy — what a non-final pipeline stage and a
    /// background job run against — starts out holding the parent's `$LINENO`,
    /// matching how `$?` is carried across.
    ///
    /// Deleting `copy.setCurrentLineNumber(getCurrentLineNumber())` from
    /// `ShellEnvironment.makeIsolatedCopy()` makes both assertions report 0.
    /// The second goes through `resolveSpecialVariable`, so the test pins the
    /// value users actually see rather than just the backing field.
    func testIsolatedEnvironmentCopyInheritsTheCurrentLineNumber() throws {
        let env = ShellEnvironment(sessionID: UUID(),
                                   allowProcessEnvWrites: false,
                                   isIsolatedContext: true)
        env.setCurrentLineNumber(42)

        let copy = env.makeIsolatedCopy()

        XCTAssertEqual(copy.getCurrentLineNumber(), 42)
        XCTAssertEqual(copy.resolveSpecialVariable("LINENO"), "42")
    }

    /// An external command reports its own line — both on its own and as a
    /// pipeline stage, which is rendered by `renderExternalSimpleCommand`
    /// rather than executed by `executeSimple`.
    ///
    /// The pipeline case is the one that regressed historically: remove the
    /// `publishLineNumber(cmd)` call from `renderExternalSimpleCommand` and the
    /// rendered string becomes `ext 1 | ext2` — the *previous* command's line.
    func testExternalCommandsAndPipelineStagesReportTheirOwnLine() throws {
        let single = RecordedExternals()
        _ = try runShell("true\next $LINENO\n", externals: single)
        XCTAssertEqual(single.commands, ["ext 2"])

        let piped = RecordedExternals()
        _ = try runShell("true\next $LINENO | ext2\n", externals: piped)
        XCTAssertEqual(piped.commands, ["ext 2 | ext2"])
    }

    /// Inside an ERR trap, `$LINENO` is the line of the command that *failed*,
    /// not line 1 of the trap body.
    ///
    /// The trap string is parsed as its own source unit, so its `echo` carries
    /// line 1. `publishLineNumber` refuses to publish while `inErrTrap` is set,
    /// which is what preserves bash's semantics. Drop the `!inErrTrap` guard
    /// and this reports `ERR_AT_1`.
    func testErrTrapReportsTheFailingCommandsLineNotTheTrapBodys() throws {
        XCTAssertEqual(try runShell("trap 'echo ERR_AT_$LINENO' ERR\ntrue\nfalse\n"),
                       "ERR_AT_3\n")
    }

    // MARK: - Documented gap: non-simple-command operands

    // `SimpleCommand` is the only node carrying a position. These three assert
    // the value bash produces; each currently fails because the operand is
    // evaluated before any simple command on its own line has published.
    // Giving `doubleBracket`, `CaseClause` and `ForClause` positions fixes all
    // three at once — at which point `XCTExpectFailure` reports them as
    // unexpectedly passing and these blocks should be unwrapped.

    func testKnownGap_forWordListReportsPreviousCommandsLine() throws {
        XCTExpectFailure("$LINENO in a `for` word list reports the previous simple command's line (1) because ForClause carries no position") {
            XCTAssertEqual(try? runShell("true\nfor x in $LINENO; do echo LINE=$x; done\n"),
                           "LINE=2\n")
        }
    }

    func testKnownGap_caseSubjectReportsPreviousCommandsLine() throws {
        XCTExpectFailure("$LINENO in a `case` subject reports the previous simple command's line (1) because CaseClause carries no position") {
            XCTAssertEqual(
                try? runShell("true\ncase $LINENO in\n  2) echo OWN_LINE ;;\n  *) echo PREVIOUS_LINE ;;\nesac\n"),
                "OWN_LINE\n")
        }
    }

    func testKnownGap_doubleBracketOperandReportsPreviousCommandsLine() throws {
        XCTExpectFailure("$LINENO in a `[[ … ]]` operand reports the previous simple command's line (1) because doubleBracket carries no position") {
            XCTAssertEqual(try? runShell("true\n[[ $LINENO = 2 ]] && echo OWN_LINE\n"),
                           "OWN_LINE\n")
        }
    }

    // MARK: - Harness

    /// Tokenize, parse and interpret `source`, returning everything the shell
    /// wrote to stdout.
    ///
    /// `allowProcessEnvWrites: false` and `isIsolatedContext: true` keep the
    /// run off `ios_setenv` and off the real session's working directory, so
    /// nothing leaks between tests or into the host app's container.
    /// Externals are stubbed: nothing is spawned, and `externals` records the
    /// command strings the interpreter rendered.
    private func runShell(_ source: String,
                          externals: RecordedExternals? = nil) throws -> String {
        let output = CollectedOutput()
        let interpreter = ShellInterpreter(
            environment: ShellEnvironment(sessionID: UUID(),
                                          allowProcessEnvWrites: false,
                                          isIsolatedContext: true),
            cancellationToken: CancellationToken(),
            executeExternal: { command in
                externals?.record(command)
                return 0
            },
            streamExternal: { command, _, _ in
                externals?.record(command)
                return 0
            },
            writeOutput: { output.append($0) },
            readLine: { _, _ in nil }
        )
        let ast = try ShellParser(tokenizer: ShellTokenizer(source: source)).parse()
        _ = try interpreter.execute(ast)
        return output.text
    }

    /// Pipeline stages run on their own dispatch queues, so both sinks have to
    /// be safe to call off the main actor.
    private nonisolated final class CollectedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    private nonisolated final class RecordedExternals: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []

        func record(_ command: String) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(command)
        }

        var commands: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }
}
