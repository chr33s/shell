import Foundation
import Testing

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
@Suite
final class ShellBuiltinRedirectionTests {
    private var directory: URL!

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin-redirection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - stderr routing

    @Test
    func testEchoToStderrGoesToTheErrorSinkAndTheScriptContinues() throws {
        let run = try runShell("echo warn >&2\necho after\n")
        #expect(run.stdout == "after\n")
        #expect(run.stderr == "warn\n")
    }

    @Test
    func testExplicitFdOneDuplicatesToStderr() throws {
        let run = try runShell("echo warn 1>&2\necho after\n")
        #expect(run.stdout == "after\n")
        #expect(run.stderr == "warn\n")
    }

    @Test
    func testStderrToDevNullSilencesABuiltinsDiagnostic() throws {
        let missing = directory.appendingPathComponent("missing").path
        let run = try runShell("cd '\(missing)' 2>/dev/null || echo fallback\necho after\n")
        #expect(run.stdout == "fallback\nafter\n")
        #expect(run.stderr == "")
    }

    @Test
    func testBuiltinDiagnosticsGoToStderrByDefault() throws {
        let missing = directory.appendingPathComponent("missing").path
        let run = try runShell("cd '\(missing)'\necho after\n")
        #expect(run.stdout == "after\n")
        #expect(run.stderr.contains("No such file or directory"), "\(run.stderr)")
    }

    @Test
    func testStderrToFileAndAppend() throws {
        let log = directory.appendingPathComponent("err.log").path
        let missing = directory.appendingPathComponent("missing").path
        _ = try runShell("cd '\(missing)' 2>'\(log)'\ncd '\(missing)' 2>>'\(log)'\n")
        let text = try String(contentsOfFile: log, encoding: .utf8)
        #expect(text.components(separatedBy: "No such file or directory").count - 1 == 2, "\(text)")
    }

    // MARK: - stdout + stderr together

    @Test
    func testOutputToFileWithStderrMergedLandsBothInTheFile() throws {
        let out = directory.appendingPathComponent("out").path
        let missing = directory.appendingPathComponent("missing").path
        let run = try runShell("echo x > '\(out)' 2>&1\ncd '\(missing)' > '\(out)' 2>&1\necho after\n")
        #expect(run.stdout == "after\n")
        #expect(run.stderr == "")
        let text = try String(contentsOfFile: out, encoding: .utf8)
        #expect(text.contains("No such file or directory"), "\(text)")
    }

    @Test
    func testMergeBeforeFileRedirectKeepsStderrOnTheOldStdout() throws {
        let out = directory.appendingPathComponent("out").path
        let missing = directory.appendingPathComponent("missing").path
        // `2>&1 > f`: stderr copies the *old* stdout (the terminal).
        let run = try runShell("cd '\(missing)' 2>&1 > '\(out)'\n")
        #expect(run.stdout.contains("No such file or directory"), "\(run.stdout)")
        #expect((try String(contentsOfFile: out, encoding: .utf8)) == "")
    }

    @Test
    func testAmpersandGreaterSendsBothStreamsToTheFile() throws {
        let out = directory.appendingPathComponent("both").path
        let run = try runShell("echo hi &> '\(out)'\necho after\n")
        #expect(run.stdout == "after\n")
        #expect((try String(contentsOfFile: out, encoding: .utf8)) == "hi\n")
    }

    @Test
    func testPlainOutputAndAppendStillWork() throws {
        let out = directory.appendingPathComponent("plain").path
        _ = try runShell("echo one > '\(out)'\necho two >> '\(out)'\necho three 1>> '\(out)'\n")
        #expect((try String(contentsOfFile: out, encoding: .utf8)) == "one\ntwo\nthree\n")
    }

    // MARK: - stdin

    @Test
    func testReadFromAFile() throws {
        let input = directory.appendingPathComponent("in")
        try "first line\nsecond\n".write(to: input, atomically: true, encoding: .utf8)
        let run = try runShell("read -r line < '\(input.path)'\necho \"got $line\"\n")
        #expect(run.stdout == "got first line\n")
    }

    @Test
    func testReadFromAHereDocument() throws {
        let run = try runShell("read -r a b <<EOF\nhello world\nEOF\necho \"$b $a\"\n")
        #expect(run.stdout == "world hello\n")
    }

    @Test
    func testMissingInputFileFailsTheBuiltinButNotTheScript() throws {
        let missing = directory.appendingPathComponent("missing").path
        let run = try runShell("read -r line < '\(missing)' || echo failed\necho after\n")
        #expect(run.stdout == "failed\nafter\n")
        #expect(run.stderr.contains("No such file or directory"), "\(run.stderr)")
    }

    // MARK: - Nesting and fallbacks

    @Test
    func testRedirectionsApplyOnlyToTheirOwnCommand() throws {
        let out = directory.appendingPathComponent("scoped").path
        let run = try runShell("echo in > '\(out)'\necho out\necho err >&2\n")
        #expect(run.stdout == "out\n")
        #expect(run.stderr == "err\n")
        #expect((try String(contentsOfFile: out, encoding: .utf8)) == "in\n")
    }

    @Test
    func testEvalInheritsItsRedirections() throws {
        let out = directory.appendingPathComponent("eval").path
        let run = try runShell("eval 'echo a; echo b >&2' > '\(out)'\n")
        #expect(run.stdout == "")
        #expect(run.stderr == "b\n")
        #expect((try String(contentsOfFile: out, encoding: .utf8)) == "a\n")
    }

    @Test
    func testStderrInsideCommandSubstitutionIsNotCaptured() throws {
        let run = try runShell("x=$(echo value; echo noise >&2)\necho \"[$x]\"\n")
        #expect(run.stdout == "[value]\n")
        #expect(run.stderr == "noise\n")
    }

    @Test
    func testUnsupportedRedirectionIsIgnoredWithAWarningNotAnAbort() throws {
        let run = try runShell("echo kept >&3\necho after\n")
        #expect(run.stdout == "kept\nafter\n")
        #expect(run.stderr.contains("ignored"), "\(run.stderr)")
    }

    // MARK: - Shell functions

    @Test
    func testFunctionOutputFollowsItsRedirection() throws {
        let out = directory.appendingPathComponent("fn").path
        let run = try runShell("f() { echo a; echo b >&2; }\nf > '\(out)'\necho after\n")
        #expect(run.stdout == "after\n")
        #expect(run.stderr == "b\n")
        #expect((try String(contentsOfFile: out, encoding: .utf8)) == "a\n")
    }

    @Test
    func testFunctionToStderr() throws {
        let run = try runShell("usage() { echo 'usage: x'; }\nusage >&2\necho after\n")
        #expect(run.stdout == "after\n")
        #expect(run.stderr == "usage: x\n")
    }

    @Test
    func testFunctionReadsItsInputRedirection() throws {
        let input = directory.appendingPathComponent("in").path
        try "first\nsecond\n".write(toFile: input, atomically: true, encoding: .utf8)
        let run = try runShell("both() { read -r a; read -r b; echo \"$b $a\"; }\nboth < '\(input)'\n")
        #expect(run.stdout == "second first\n")
    }

    @Test
    func testExternalStdoutInsideARedirectedFunctionIsRouted() throws {
        let out = directory.appendingPathComponent("ext").path
        let run = try runShell(
            "f() { ls; }\nf > '\(out)'\nls\n",
            captureExternal: { command in (0, "captured:\(command)\n") }
        )
        #expect(!(run.stdout.contains("captured")), "only the redirected call is captured")
        // An isolated context may prefix the command with its exported env.
        let text = try String(contentsOfFile: out, encoding: .utf8)
        #expect(text.hasPrefix("captured:") && text.hasSuffix("ls\n"), "\(text)")
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
