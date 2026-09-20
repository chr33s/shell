import Foundation
import XCTest

@testable import Shell

/// Pins the bounds on everything in the shell that recurses through Swift
/// frames.
///
/// THE REGRESSION THESE EXIST FOR: none of these paths had a limit, and a
/// stack overflow is not a catchable error — it is a SIGSEGV that takes the
/// whole app down, every other tab and SSH session with it. `f() { f; }; f` is
/// a one-line typo; a script that sources itself is a one-line mistake; deeply
/// nested `(` is a truncated file. Each now reports a shell error and leaves
/// the failure inside the script that caused it.
///
/// Every test asserts the *error*, not the depth: the limits themselves are
/// tuning, far above any real script, and are free to move.
@MainActor
final class ShellRecursionLimitTests: XCTestCase {

    func testInfiniteFunctionRecursionReportsAnErrorInsteadOfCrashing() {
        XCTAssertThrowsError(try runShell("f() { f; }\nf\n")) { error in
            guard case ShellError.recursionLimit = error else {
                return XCTFail("expected a recursion limit, got \(error)")
            }
        }
    }

    func testMutualFunctionRecursionIsAlsoBounded() {
        XCTAssertThrowsError(try runShell("a() { b; }\nb() { a; }\na\n")) { error in
            guard case ShellError.recursionLimit = error else {
                return XCTFail("expected a recursion limit, got \(error)")
            }
        }
    }

    /// The depth is per call chain, not a running total: a function called
    /// many times in sequence must not trip the limit.
    func testRepeatedNonRecursiveCallsDoNotTripTheLimit() throws {
        let script = "f() { :; }\n" + String(repeating: "f\n", count: 5_000) + "echo done\n"
        XCTAssertEqual(try runShell(script), "done\n")
    }

    func testOrdinaryRecursionWellInsideTheLimitStillWorks() throws {
        let script = """
        countdown() {
          if [ "$1" -le 0 ]; then echo done; return 0; fi
          countdown $(( $1 - 1 ))
        }
        countdown 50
        """
        XCTAssertEqual(try runShell(script), "done\n")
    }

    /// Spaced parens: `((` with no gap is the arithmetic command, which the
    /// tokenizer slurps as one word and never nests.
    func testDeeplyNestedSubshellsAreASyntaxErrorNotACrash() {
        let script = String(repeating: "( ", count: 5_000) + "true" + String(repeating: " )", count: 5_000)
        XCTAssertThrowsError(try runShell(script)) { error in
            guard case ShellError.syntaxError = error else {
                return XCTFail("expected a syntax error, got \(error)")
            }
        }
    }

    func testModestSubshellNestingStillParses() throws {
        let depth = 20
        let script = String(repeating: "( ", count: depth) + "echo hi" + String(repeating: " )", count: depth)
        XCTAssertEqual(try runShell(script), "hi\n")
    }

    func testDeeplyNestedCommandSubstitutionIsBounded() {
        let depth = 500
        let script = "echo " + String(repeating: "$(echo ", count: depth) + "hi" + String(repeating: ")", count: depth)
        XCTAssertThrowsError(try runShell(script)) { error in
            guard case ShellError.recursionLimit = error else {
                return XCTFail("expected a recursion limit, got \(error)")
            }
        }
    }

    func testModestCommandSubstitutionNestingStillWorks() throws {
        XCTAssertEqual(try runShell("echo $(echo $(echo $(echo hi)))\n"), "hi\n")
    }

    /// Two lines, no function frame: `eval` re-entering itself was invisible
    /// to the function-nesting counter.
    func testSelfReferentialEvalIsBounded() {
        XCTAssertThrowsError(try runShell("X='eval \"$X\"'\neval \"$X\"\n")) { error in
            guard case ShellError.recursionLimit = error else {
                return XCTFail("expected a recursion limit, got \(error)")
            }
        }
    }

    /// `[[ ((((…)))) ]]`: the tokenizer slurps the whole condition
    /// iteratively, so an arbitrarily deep one reached the recursive parser.
    func testDeeplyNestedDoubleBracketConditionsDoNotCrash() throws {
        let depth = 5_000
        let condition = String(repeating: "( ", count: depth) + "-n x" + String(repeating: " )", count: depth)
        // Reported as a `[[` usage error on stderr-as-stdout (exit 2), and the
        // script keeps running — never a crash.
        let output = try runShell("[[ \(condition) ]]\necho done\n")
        XCTAssertTrue(output.contains("sh: [[:"), output)
        XCTAssertTrue(output.contains("done"), output)
    }

    func testModestDoubleBracketNestingStillEvaluates() throws {
        XCTAssertEqual(try runShell("[[ ( ( -n x ) ) ]] && echo yes\n"), "yes\n")
    }

    func testOrdinaryEvalStillWorks() throws {
        XCTAssertEqual(try runShell("X='echo hi'\neval \"$X\"\n"), "hi\n")
        XCTAssertEqual(try runShell("eval 'eval \"eval \\\"echo deep\\\"\"'\n"), "deep\n")
    }

    // MARK: - Harness

    private func runShell(_ source: String) throws -> String {
        let output = CollectedOutput()
        let interpreter = ShellInterpreter(
            environment: ShellEnvironment(sessionID: UUID(),
                                          allowProcessEnvWrites: false,
                                          isIsolatedContext: true),
            cancellationToken: CancellationToken(),
            executeExternal: { _ in 0 },
            streamExternal: { _, _, _ in 0 },
            writeOutput: { output.append($0) },
            readLine: { _, _ in nil }
        )
        let ast = try ShellParser(tokenizer: ShellTokenizer(source: source)).parse()
        _ = try interpreter.execute(ast)
        return output.text
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
