import Foundation
import Testing

private func commandExecutableURL() -> URL? {
    if let override = ProcessInfo.processInfo.environment["SHELL_CONTROL_UNDER_TEST"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("shell-control")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    let fromSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/shell-control")
    return FileManager.default.isExecutableFile(atPath: fromSource.path) ? fromSource : nil
}

@Suite(.enabled(if: commandExecutableURL() != nil, "build shell-control before running CommandTests"))
final class CommandTests {
    private func executable() throws -> URL {
        try #require(commandExecutableURL())
    }

    private func run(_ arguments: [String], environment: [String: String] = [:]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = try executable()
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    @Test
    func testNoArgumentsAndVersionHaveNoSideEffects() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let help = try run([], environment: ["SHELL_CONTROL_STATE_DIR": root.path])
        #expect(help.0 == 0)
        #expect(help.1.contains("USAGE:"))
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
        let version = try run(["--version"], environment: ["SHELL_CONTROL_STATE_DIR": root.path])
        #expect(version.0 == 0)
        #expect(version.1.contains("1.0.0"))
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
    }

    @Test
    func testReadOnlyStatusDoesNotCreateState() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        let result = try run(["status", "--state-dir", root.path])
        #expect(result.0 == 0)
        #expect(result.1.contains("shell-control.status/1"))
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
        let commonBeforeCommand = try run(["--state-dir", root.path, "status"])
        #expect(commonBeforeCommand.0 == 0)
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
    }

    @Test
    func testAdapterFlagsBelongToNativeSubcommands() throws {
        #expect(try run(["notify", "--help"]).0 == 0)
        #expect(try run(["request", "--help"]).1.contains("--spec-file"))
        #expect(try run(["receipt", "--help"]).1.contains("--run-capability"))
        #expect(try run(["confirm", "--help"]).1.contains("--yes"))
    }

    @Test
    func testInvalidInvocationFailsBeforeMutation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        let result = try run(["setup", "--state-dir", root.path, "--port", "0", "extra"])
        #expect(result.0 == 2)
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
    }

    @Test
    func testNonInteractiveConfirmRequiresYes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        let result = try run(["confirm", "--state-dir", root.path, "ABCD"])
        #expect(result.0 == 2)
        #expect(result.2.contains("--yes"))
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
    }

    @Test
    func testRelativeStateDirIsInvalid() throws {
        let result = try run(["logs", "--state-dir", "relative"])
        #expect(result.0 == 2)
        #expect(result.2.contains("absolute"))
        let beforeCommand = try run(["--state-dir", "relative", "status"])
        #expect(beforeCommand.0 == 2)
    }

    // MARK: Control companion setup

    @Test
    func testGuidedSetupRefusesANonInteractiveTerminalBeforeMutation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        let result = try run(["setup", "--guided", "--state-dir", root.path])
        #expect(result.0 == 2)
        #expect(result.2.contains("interactive terminal"), "\(result.2)")
        #expect(result.2.contains("shell-control pair"), "points at the explicit commands")
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
    }

    @Test
    func testWatchFlagsKeepTheirSeparateMeanings() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        #expect(try run(["setup", "--skip-watch-setup", "--state-dir", root.path]).0 == 2)
        let both = try run(["setup", "--guided", "--no-watch", "--state-dir", root.path])
        #expect(both.0 == 2)
        #expect(both.2.contains("--skip-watch-setup"))
        #expect(try run(["setup", "--guided", "--reset-origin-key", "--state-dir", root.path]).0 == 2)
        let help = try run(["setup", "--help"]).1
        #expect(help.contains("--no-watch") && help.contains("--skip-watch-setup") && help.contains("enrollment"))
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
    }

    @Test
    func testDoctorIsReadOnlyAndCheckFailsWithoutAHost() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        let text = try run(["doctor", "--state-dir", root.path])
        #expect(text.0 == 0)
        #expect(text.1.contains("checks the host only"))
        let json = try run(["doctor", "--json", "--state-dir", root.path])
        #expect(json.0 == 0)
        #expect(json.1.contains("shell-control-diagnostics/1"))
        #expect(json.1.contains("installation_missing"))
        #expect(try run(["doctor", "--check", "--state-dir", root.path]).0 == 1)
        let exportURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doctor-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        #expect(try run(["doctor", "--export", exportURL.path, "--state-dir", root.path]).0 == 0)
        let exported = try String(contentsOf: exportURL, encoding: .utf8)
        #expect(exported.contains("shell-control-diagnostics-export/1"))
        #expect(!(exported.contains(root.path)), "user paths are not exported")
        #expect(try run(["doctor", "--export", exportURL.path, "--state-dir", root.path]).0 != 0, "never overwrites")
        #expect(try run(["doctor", "--export", "relative.json"]).0 == 2)
        #expect(try run(["doctor", "--bogus"]).0 == 2)
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
    }

    @Test
    func testTestReviewValidatesItsReviewerBeforeTouchingAnything() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        #expect(try run(["test-review", "--help"]).1.contains("--device-id"))
        #expect(try run(["test-review", "--reviewer", "iphone", "--device-id", "nope", "--state-dir", root.path]).0 == 2)
        #expect(try run(["test-review", "--reviewer", "ipad", "--device-id", UUID().uuidString, "--state-dir", root.path]).0 == 2)
        #expect(!(FileManager.default.fileExists(atPath: root.path)))
    }
}
