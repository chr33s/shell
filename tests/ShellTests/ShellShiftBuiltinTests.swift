import Foundation
import XCTest

@testable import Shell

/// Pins that `shift` survives every count a user can type.
///
/// THE REGRESSION THIS EXISTS FOR: `shiftParams` computed
/// `min(n, positionalParams.count)` and handed it to `removeFirst(_:)`, whose
/// precondition is `k >= 0`. `shift -1` is a plausible typo and it trapped —
/// taking the app down rather than being the no-op bash makes of it.
@MainActor
final class ShellShiftBuiltinTests: XCTestCase {
    func testANegativeShiftIsANoOpRatherThanACrash() {
        let env = makeEnvironment(params: ["a", "b", "c"])
        env.shiftParams(-1)
        XCTAssertEqual(env.getAllPositionalParams(), ["a", "b", "c"])
        env.shiftParams(Int.min)
        XCTAssertEqual(env.getAllPositionalParams(), ["a", "b", "c"])
    }

    func testAShiftPastTheEndClearsTheParametersWithoutCrashing() {
        let env = makeEnvironment(params: ["a", "b"])
        env.shiftParams(99)
        XCTAssertEqual(env.getAllPositionalParams(), [])
        env.shiftParams(Int.max)
        XCTAssertEqual(env.getAllPositionalParams(), [])
    }

    func testOrdinaryShiftsStillWork() {
        let env = makeEnvironment(params: ["a", "b", "c"])
        env.shiftParams()
        XCTAssertEqual(env.getAllPositionalParams(), ["b", "c"])
        env.shiftParams(2)
        XCTAssertEqual(env.getAllPositionalParams(), [])
    }

    func testTheShiftBuiltinPassesANegativeCountThrough() throws {
        let env = makeEnvironment(params: ["a", "b"])
        let interpreter = ShellInterpreter(
            environment: env,
            cancellationToken: CancellationToken(),
            executeExternal: { _ in 0 },
            writeOutput: { _ in },
            readLine: { _, _ in nil }
        )
        let shift = try XCTUnwrap(ShellBuiltins.lookup("shift"))
        XCTAssertEqual(try shift(["-3"], env, interpreter), 0)
        XCTAssertEqual(env.getAllPositionalParams(), ["a", "b"])
    }

    private func makeEnvironment(params: [String]) -> ShellEnvironment {
        let env = ShellEnvironment(sessionID: UUID(), allowProcessEnvWrites: false, isIsolatedContext: true)
        env.setPositionalParams(params, scriptName: "sh")
        return env
    }
}
