import Foundation
import Testing

@testable import Shell

/// Pins that `shift` survives every count a user can type.
///
/// THE REGRESSION THIS EXISTS FOR: `shiftParams` computed
/// `min(n, positionalParams.count)` and handed it to `removeFirst(_:)`, whose
/// precondition is `k >= 0`. `shift -1` is a plausible typo and it trapped —
/// taking the app down rather than being the no-op bash makes of it.
@MainActor
@Suite
final class ShellShiftBuiltinTests {
    @Test
    func testANegativeShiftIsANoOpRatherThanACrash() throws {
        let env = makeEnvironment(params: ["a", "b", "c"])
        env.shiftParams(-1)
        #expect(env.allPositionalParams() == ["a", "b", "c"])
        env.shiftParams(Int.min)
        #expect(env.allPositionalParams() == ["a", "b", "c"])
    }

    @Test
    func testAShiftPastTheEndClearsTheParametersWithoutCrashing() throws {
        let env = makeEnvironment(params: ["a", "b"])
        env.shiftParams(99)
        #expect(env.allPositionalParams() == [])
        env.shiftParams(Int.max)
        #expect(env.allPositionalParams() == [])
    }

    @Test
    func testOrdinaryShiftsStillWork() throws {
        let env = makeEnvironment(params: ["a", "b", "c"])
        env.shiftParams()
        #expect(env.allPositionalParams() == ["b", "c"])
        env.shiftParams(2)
        #expect(env.allPositionalParams() == [])
    }

    @Test
    func testTheShiftBuiltinPassesANegativeCountThrough() throws {
        let env = makeEnvironment(params: ["a", "b"])
        let interpreter = ShellInterpreter(
            environment: env,
            cancellationToken: CancellationToken(),
            executeExternal: { _ in 0 },
            writeOutput: { _ in },
            readLine: { _, _ in nil }
        )
        let shift = try #require(ShellBuiltins.lookup("shift"))
        #expect((try shift(["-3"], env, interpreter)) == 0)
        #expect(env.allPositionalParams() == ["a", "b"])
    }

    private func makeEnvironment(params: [String]) -> ShellEnvironment {
        let env = ShellEnvironment(sessionID: UUID(), allowProcessEnvWrites: false, isIsolatedContext: true)
        env.setPositionalParams(params, scriptName: "sh")
        return env
    }
}
