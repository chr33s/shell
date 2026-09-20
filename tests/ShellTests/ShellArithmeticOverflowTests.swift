import Foundation
import XCTest

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
final class ShellArithmeticOverflowTests: XCTestCase {
    private let intMax = "9223372036854775807"
    private let intMin = "-9223372036854775808"
    /// `Int64.min` has no literal form here: the lexer reads the digits before
    /// unary minus applies, and `9223372036854775808` alone is out of range.
    private var intMinExpr: String { "(0 - \(intMax) - 1)" }

    func testAdditionAndSubtractionWrap() throws {
        XCTAssertEqual(try eval("\(intMax) + 1"), Int64.min)
        XCTAssertEqual(try eval("\(intMinExpr) - 1"), Int64.max)
    }

    func testMultiplicationWraps() throws {
        XCTAssertEqual(try eval("\(intMax) * 2"), -2)
    }

    func testDivisionAndRemainderAtTheOverflowingCaseDoNotTrap() throws {
        XCTAssertEqual(try eval("\(intMinExpr) / -1"), Int64.min)
        XCTAssertEqual(try eval("\(intMinExpr) % -1"), 0)
    }

    func testUnaryNegationOfTheMinimumDoesNotTrap() throws {
        XCTAssertEqual(try eval("-\(intMinExpr)"), Int64.min)
    }

    /// A literal outside `Int64` is reported, not wrapped and not fatal.
    func testAnOutOfRangeLiteralIsAnError() {
        XCTAssertThrowsError(try eval("9223372036854775808")) { error in
            guard case ShellError.arithmeticError = error else {
                return XCTFail("expected an arithmetic error, got \(error)")
            }
        }
        XCTAssertThrowsError(try eval("\(intMin)")) { error in
            guard case ShellError.arithmeticError = error else {
                return XCTFail("expected an arithmetic error, got \(error)")
            }
        }
    }

    func testCompoundAssignmentWraps() throws {
        let env = makeEnvironment()
        env.setVariable("x", value: intMax)
        XCTAssertEqual(try ShellArithmeticEvaluator.evaluate("x += 1", environment: env), Int64.min)
        env.setVariable("y", value: intMin)
        XCTAssertEqual(try ShellArithmeticEvaluator.evaluate("y -= 1", environment: env), Int64.max)
        env.setVariable("z", value: intMin)
        XCTAssertEqual(try ShellArithmeticEvaluator.evaluate("z /= -1", environment: env), Int64.min)
    }

    func testIncrementAndDecrementWrapAtTheBoundaries() throws {
        let env = makeEnvironment()
        env.setVariable("a", value: intMax)
        XCTAssertEqual(try ShellArithmeticEvaluator.evaluate("++a", environment: env), Int64.min)
        env.setVariable("b", value: intMin)
        XCTAssertEqual(try ShellArithmeticEvaluator.evaluate("b--", environment: env), Int64.min)
        XCTAssertEqual(env.getVariable("b"), String(Int64.max))
    }

    func testDivisionByZeroIsStillAnError() {
        XCTAssertThrowsError(try eval("1 / 0")) { error in
            guard case ShellError.divisionByZero = error else {
                return XCTFail("expected divisionByZero, got \(error)")
            }
        }
        XCTAssertThrowsError(try eval("1 % 0")) { error in
            guard case ShellError.divisionByZero = error else {
                return XCTFail("expected divisionByZero, got \(error)")
            }
        }
    }

    func testDeeplyNestedParenthesesAreAnErrorNotACrash() {
        let depth = 5_000
        let expr = String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
        XCTAssertThrowsError(try eval(expr)) { error in
            guard case ShellError.arithmeticError = error else {
                return XCTFail("expected an arithmetic error, got \(error)")
            }
        }
    }

    func testOrdinaryArithmeticIsUnchanged() throws {
        XCTAssertEqual(try eval("2 + 3 * 4"), 14)
        XCTAssertEqual(try eval("(2 + 3) * 4"), 20)
        XCTAssertEqual(try eval("-7 / 2"), -3)
        XCTAssertEqual(try eval("-7 % 2"), -1)
        XCTAssertEqual(try eval("1 << 10"), 1024)
    }

    // MARK: - Harness

    private func makeEnvironment() -> ShellEnvironment {
        ShellEnvironment(sessionID: UUID(), allowProcessEnvWrites: false, isIsolatedContext: true)
    }

    private func eval(_ expr: String) throws -> Int64 {
        try ShellArithmeticEvaluator.evaluate(expr, environment: makeEnvironment())
    }
}
