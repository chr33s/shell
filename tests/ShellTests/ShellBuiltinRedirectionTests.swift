import Foundation
import XCTest

@testable import Shell

/// Pins how redirections on shell builtins and function calls are honoured.
///
/// THE REGRESSION THIS EXISTS FOR: builtins learned `>` / `>>`, but every
/// other redirection threw `ShellError.unsupported`, which unwound the whole
/// `execute(ast)` — so a single `echo "warn" >&2` or
/// `cd "$d" 2>/dev/null || return` in an rc file abandoned the rest of it.
/// Before that, the redirections were silently ignored. Now the common forms
/// route the builtin's stdout/stderr/stdin, and anything else is ignored with
/// a warning while the script carries on.
@MainActor
final class ShellBuiltinRedirectionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin-redirection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - stderr routing

    func testEchoToStderrGoesToTheErrorSinkAndTheScriptContinues() throws {
        let run = try runShell("echo warn >&2\necho after\n")
        XCTAssertEqual(run.stdout, "after\n")
        XCTAssertEqual(run.stderr, "warn\n")
    }

    func testExplicitFdOneDuplicatesToStderr() throws {
        let run = try runShell("echo warn 1>&2\necho after\n")
        XCTAssertEqual(run.stdout, "after\n")
        XCTAssertEqual(run.stderr, "warn\n")
    }

    func testStderrToDevNullSilencesABuiltinsDiagnostic() throws {
        let missing = directory.appendingPathComponent("missing").path
        let run = try runShell("cd '\(missing)' 2>/dev/null || echo fallback\necho after\n")
        XCTAssertEqual(run.stdout, "fallback\nafter\n")
        XCTAssertEqual(run.stderr, "")
    }

    func testBuiltinDiagnosticsGoToStderrByDefault() throws {
        let missing = directory.appendingPathComponent("missing").path
        let run = try runShell("cd '\(missing)'\necho after\n")
        XCTAssertEqual(run.stdout, "after\n")
        XCTAssertTrue(run.stderr.contains("No such file or directory"), run.stderr)
    }

    func testStderrToFileAndAppend() throws {
        let log = directory.appendingPathComponent("err.log").path
        let missing = directory.appendingPathComponent("missing").path
        _ = try runShell("cd '\(missing)' 2>'\(log)'\ncd '\(missing)' 2>>'\(log)'\n")
        let text = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "No such file or directory").count - 1, 2, text)
    }

    // MARK: - stdout + stderr together

    func testOutputToFileWithStderrMergedLandsBothInTheFile() throws {
        let out = directory.appendingPathComponent("out").path
        let missing = directory.appendingPathComponent("missing").path
        let run = try runShell("echo x > '\(out)' 2>&1\ncd '\(missing)' > '\(out)' 2>&1\necho after\n")
        XCTAssertEqual(run.stdout, "after\n")
        XCTAssertEqual(run.stderr, "")
        let text = try String(contentsOfFile: out, encoding: .utf8)
        XCTAssertTrue(text.contains("No such file or directory"), text)
    }

    func testMergeBeforeFileRedirectKeepsStderrOnTheOldStdout() throws {
        let out = directory.appendingPathComponent("out").path
        let missing = directory.appendingPathComponent("missing").path
        // `2>&1 > f`: stderr copies the *old* stdout (the terminal).
        let run = try runShell("cd '\(missing)' 2>&1 > '\(out)'\n")
        XCTAssertTrue(run.stdout.contains("No such file or directory"), run.stdout)
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "")
    }

    func testAmpersandGreaterSendsBothStreamsToTheFile() throws {
        let out = directory.appendingPathComponent("both").path
        let run = try runShell("echo hi &> '\(out)'\necho after\n")
        XCTAssertEqual(run.stdout, "after\n")
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "hi\n")
    }

    func testPlainOutputAndAppendStillWork() throws {
        let out = directory.appendingPathComponent("plain").path
        _ = try runShell("echo one > '\(out)'\necho two >> '\(out)'\necho three 1>> '\(out)'\n")
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "one\ntwo\nthree\n")
    }

    // MARK: - stdin

    func testReadFromAFile() throws {
        let input = directory.appendingPathComponent("in")
        try "first line\nsecond\n".write(to: input, atomically: true, encoding: .utf8)
        let run = try runShell("read -r line < '\(input.path)'\necho \"got $line\"\n")
        XCTAssertEqual(run.stdout, "got first line\n")
    }

    func testReadFromAHereDocument() throws {
        let run = try runShell("read -r a b <<EOF\nhello world\nEOF\necho \"$b $a\"\n")
        XCTAssertEqual(run.stdout, "world hello\n")
    }

    func testMissingInputFileFailsTheBuiltinButNotTheScript() throws {
        let missing = directory.appendingPathComponent("missing").path
        let run = try runShell("read -r line < '\(missing)' || echo failed\necho after\n")
        XCTAssertEqual(run.stdout, "failed\nafter\n")
        XCTAssertTrue(run.stderr.contains("No such file or directory"), run.stderr)
    }

    // MARK: - Nesting and fallbacks

    func testRedirectionsApplyOnlyToTheirOwnCommand() throws {
        let out = directory.appendingPathComponent("scoped").path
        let run = try runShell("echo in > '\(out)'\necho out\necho err >&2\n")
        XCTAssertEqual(run.stdout, "out\n")
        XCTAssertEqual(run.stderr, "err\n")
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "in\n")
    }

    func testEvalInheritsItsRedirections() throws {
        let out = directory.appendingPathComponent("eval").path
        let run = try runShell("eval 'echo a; echo b >&2' > '\(out)'\n")
        XCTAssertEqual(run.stdout, "")
        XCTAssertEqual(run.stderr, "b\n")
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "a\n")
    }

    func testStderrInsideCommandSubstitutionIsNotCaptured() throws {
        let run = try runShell("x=$(echo value; echo noise >&2)\necho \"[$x]\"\n")
        XCTAssertEqual(run.stdout, "[value]\n")
        XCTAssertEqual(run.stderr, "noise\n")
    }

    func testUnsupportedRedirectionIsIgnoredWithAWarningNotAnAbort() throws {
        let run = try runShell("echo kept >&3\necho after\n")
        XCTAssertEqual(run.stdout, "kept\nafter\n")
        XCTAssertTrue(run.stderr.contains("ignored"), run.stderr)
    }

    // MARK: - Shell functions

    func testFunctionOutputFollowsItsRedirection() throws {
        let out = directory.appendingPathComponent("fn").path
        let run = try runShell("f() { echo a; echo b >&2; }\nf > '\(out)'\necho after\n")
        XCTAssertEqual(run.stdout, "after\n")
        XCTAssertEqual(run.stderr, "b\n")
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "a\n")
    }

    func testFunctionToStderr() throws {
        let run = try runShell("usage() { echo 'usage: x'; }\nusage >&2\necho after\n")
        XCTAssertEqual(run.stdout, "after\n")
        XCTAssertEqual(run.stderr, "usage: x\n")
    }

    func testFunctionReadsItsInputRedirection() throws {
        let input = directory.appendingPathComponent("in").path
        try "first\nsecond\n".write(toFile: input, atomically: true, encoding: .utf8)
        let run = try runShell("both() { read -r a; read -r b; echo \"$b $a\"; }\nboth < '\(input)'\n")
        XCTAssertEqual(run.stdout, "second first\n")
    }

    func testExternalStdoutInsideARedirectedFunctionIsRouted() throws {
        let out = directory.appendingPathComponent("ext").path
        let run = try runShell(
            "f() { ls; }\nf > '\(out)'\nls\n",
            captureExternal: { command in (0, "captured:\(command)\n") }
        )
        XCTAssertFalse(run.stdout.contains("captured"), "only the redirected call is captured")
        // An isolated context may prefix the command with its exported env.
        let text = try String(contentsOfFile: out, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("captured:") && text.hasSuffix("ls\n"), text)
    }

    // MARK: - Harness

    private struct Run {
        let stdout: String
        let stderr: String
    }

    /// Tokenize, parse and interpret `source`, splitting what the shell wrote
    /// to its stdout and stderr sinks. Externals are stubbed.
    private func runShell(
        _ source: String,
        captureExternal: (@Sendable (String) -> (Int32, String))? = nil
    ) throws -> Run {
        let stdout = CollectedOutput()
        let stderr = CollectedOutput()
        let interpreter = ShellInterpreter(
            environment: ShellEnvironment(sessionID: UUID(),
                                          allowProcessEnvWrites: false,
                                          isIsolatedContext: true),
            cancellationToken: CancellationToken(),
            executeExternal: { _ in 0 },
            captureExternal: captureExternal,
            streamExternal: { _, _, _ in 0 },
            writeOutput: { stdout.append($0) },
            writeErrorOutput: { stderr.append($0) },
            readLine: { _, _ in nil }
        )
        let ast = try ShellParser(tokenizer: ShellTokenizer(source: source)).parse()
        _ = try interpreter.execute(ast)
        return Run(stdout: stdout.text, stderr: stderr.text)
    }

    private nonisolated final class CollectedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            buffer.append(data)
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self)
        }
    }
}
