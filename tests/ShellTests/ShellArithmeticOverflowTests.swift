import Foundation
import Testing

@testable import Shell

/// Pins that shell arithmetic wraps rather than traps.
///
/// THE REGRESSION THESE EXIST FOR: the evaluator used Swift's trapping `+`,
/// `-`, `*`, `/`, `%` and unary `-` on `Int64`. Every one of them is a hard
/// crash at the range boundary — `$(( 9223372036854775807 + 1 ))` is a single
/// line at a prompt, and it took down the app with every other tab, split and
/// live SSH session. C arithmetic (and so bash) wraps; so does this now.
///
/// `Int64.min / -1` and `Int64.min % -1` are the two that overflow *division*,
/// which the divide-by-zero guard does not cover.
@MainActor
@Suite
final class ShellArithmeticOverflowTests {
    private let intMax = "9223372036854775807"
    private let intMin = "-9223372036854775808"
    /// `Int64.min` has no literal form here: the lexer reads the digits before
    /// unary minus applies, and `9223372036854775808` alone is out of range.
    private var intMinExpr: String { "(0 - \(intMax) - 1)" }

    @Test
    func testAdditionAndSubtractionWrap() throws {
        #expect((try eval("\(intMax) + 1")) == Int64.min)
        #expect((try eval("\(intMinExpr) - 1")) == Int64.max)
    }

    @Test
    func testMultiplicationWraps() throws {
        #expect((try eval("\(intMax) * 2")) == -2)
    }

    @Test
    func testDivisionAndRemainderAtTheOverflowingCaseDoNotTrap() throws {
        #expect((try eval("\(intMinExpr) / -1")) == Int64.min)
        #expect((try eval("\(intMinExpr) % -1")) == 0)
    }

    @Test
    func testUnaryNegationOfTheMinimumDoesNotTrap() throws {
        #expect((try eval("-\(intMinExpr)")) == Int64.min)
    }

    /// A literal outside `Int64` is reported, not wrapped and not fatal.
    @Test
    func testAnOutOfRangeLiteralIsAnError() throws {
        do { _ = try eval("9223372036854775808")
Issue.record("expected an error")
} catch let error {
            guard case ShellError.arithmeticError = error else {
                Issue.record("expected an arithmetic error, got \(error)")
return
            }
        }
        do { _ = try eval("\(intMin)")
Issue.record("expected an error")
} catch let error {
            guard case ShellError.arithmeticError = error else {
                Issue.record("expected an arithmetic error, got \(error)")
return
            }
        }
    }

    @Test
    func testCompoundAssignmentWraps() throws {
        let env = makeEnvironment()
        env.setVariable("x", value: intMax)
        #expect((try ShellArithmeticEvaluator.evaluate("x += 1", environment: env)) == Int64.min)
        env.setVariable("y", value: intMin)
        #expect((try ShellArithmeticEvaluator.evaluate("y -= 1", environment: env)) == Int64.max)
        env.setVariable("z", value: intMin)
        #expect((try ShellArithmeticEvaluator.evaluate("z /= -1", environment: env)) == Int64.min)
    }

    @Test
    func testIncrementAndDecrementWrapAtTheBoundaries() throws {
        let env = makeEnvironment()
        env.setVariable("a", value: intMax)
        #expect((try ShellArithmeticEvaluator.evaluate("++a", environment: env)) == Int64.min)
        env.setVariable("b", value: intMin)
        #expect((try ShellArithmeticEvaluator.evaluate("b--", environment: env)) == Int64.min)
        #expect(env.variable("b") == String(Int64.max))
    }

    @Test
    func testDivisionByZeroIsStillAnError() throws {
        do { _ = try eval("1 / 0")
Issue.record("expected an error")
} catch let error {
            guard case ShellError.divisionByZero = error else {
                Issue.record("expected divisionByZero, got \(error)")
return
            }
        }
        do { _ = try eval("1 % 0")
Issue.record("expected an error")
} catch let error {
            guard case ShellError.divisionByZero = error else {
                Issue.record("expected divisionByZero, got \(error)")
return
            }
        }
    }

    @Test
    func testDeeplyNestedParenthesesAreAnErrorNotACrash() throws {
        let depth = 5_000
        let expr = String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
        do { _ = try eval(expr)
Issue.record("expected an error")
} catch let error {
            guard case ShellError.arithmeticError = error else {
                Issue.record("expected an arithmetic error, got \(error)")
return
            }
        }
    }

    @Test
    func testOrdinaryArithmeticIsUnchanged() throws {
        #expect((try eval("2 + 3 * 4")) == 14)
        #expect((try eval("(2 + 3) * 4")) == 20)
        #expect((try eval("-7 / 2")) == -3)
        #expect((try eval("-7 % 2")) == -1)
        #expect((try eval("1 << 10")) == 1024)
    }

    // MARK: - Harness

    private func makeEnvironment() -> ShellEnvironment {
        ShellEnvironment(sessionID: UUID(), allowProcessEnvWrites: false, isIsolatedContext: true)
    }

    private func eval(_ expr: String) throws -> Int64 {
        try ShellArithmeticEvaluator.evaluate(expr, environment: makeEnvironment())
    }
}
