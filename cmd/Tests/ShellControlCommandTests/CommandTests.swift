import XCTest

final class CommandTests: XCTestCase {
    private func executable() throws -> URL {
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
        if FileManager.default.isExecutableFile(atPath: fromSource.path) { return fromSource }
        throw XCTSkip("shell-control executable was not built; build the shell-control product before running CommandTests")
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

    func testNoArgumentsAndVersionHaveNoSideEffects() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let help = try run([], environment: ["SHELL_CONTROL_STATE_DIR": root.path])
        XCTAssertEqual(help.0, 0)
        XCTAssertTrue(help.1.contains("USAGE:"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let version = try run(["--version"], environment: ["SHELL_CONTROL_STATE_DIR": root.path])
        XCTAssertEqual(version.0, 0)
        XCTAssertTrue(version.1.contains("1.0.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testReadOnlyStatusDoesNotCreateState() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        let result = try run(["status", "--state-dir", root.path])
        XCTAssertEqual(result.0, 0)
        XCTAssertTrue(result.1.contains("shell-control.status/1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let commonBeforeCommand = try run(["--state-dir", root.path, "status"])
        XCTAssertEqual(commonBeforeCommand.0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testAdapterFlagsBelongToNativeSubcommands() throws {
        XCTAssertEqual(try run(["notify", "--help"]).0, 0)
        XCTAssertTrue(try run(["request", "--help"]).1.contains("--spec-file"))
        XCTAssertTrue(try run(["receipt", "--help"]).1.contains("--run-capability"))
        XCTAssertTrue(try run(["confirm", "--help"]).1.contains("--yes"))
    }

    func testInvalidInvocationFailsBeforeMutation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        let result = try run(["setup", "--state-dir", root.path, "--port", "0", "extra"])
        XCTAssertEqual(result.0, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testNonInteractiveConfirmRequiresYes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        let result = try run(["confirm", "--state-dir", root.path, "ABCD"])
        XCTAssertEqual(result.0, 2)
        XCTAssertTrue(result.2.contains("--yes"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRelativeStateDirIsInvalid() throws {
        let result = try run(["logs", "--state-dir", "relative"])
        XCTAssertEqual(result.0, 2)
        XCTAssertTrue(result.2.contains("absolute"))
        let beforeCommand = try run(["--state-dir", "relative", "status"])
        XCTAssertEqual(beforeCommand.0, 2)
    }

    // MARK: Control companion setup

    func testGuidedSetupRefusesANonInteractiveTerminalBeforeMutation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        let result = try run(["setup", "--guided", "--state-dir", root.path])
        XCTAssertEqual(result.0, 2)
        XCTAssertTrue(result.2.contains("interactive terminal"), result.2)
        XCTAssertTrue(result.2.contains("shell-control pair"), "points at the explicit commands")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testWatchFlagsKeepTheirSeparateMeanings() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        XCTAssertEqual(try run(["setup", "--skip-watch-setup", "--state-dir", root.path]).0, 2)
        let both = try run(["setup", "--guided", "--no-watch", "--state-dir", root.path])
        XCTAssertEqual(both.0, 2)
        XCTAssertTrue(both.2.contains("--skip-watch-setup"))
        XCTAssertEqual(try run(["setup", "--guided", "--reset-origin-key", "--state-dir", root.path]).0, 2)
        let help = try run(["setup", "--help"]).1
        XCTAssertTrue(help.contains("--no-watch") && help.contains("--skip-watch-setup") && help.contains("enrollment"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDoctorIsReadOnlyAndCheckFailsWithoutAHost() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        let text = try run(["doctor", "--state-dir", root.path])
        XCTAssertEqual(text.0, 0)
        XCTAssertTrue(text.1.contains("checks the host only"))
        let json = try run(["doctor", "--json", "--state-dir", root.path])
        XCTAssertEqual(json.0, 0)
        XCTAssertTrue(json.1.contains("shell-control-diagnostics/1"))
        XCTAssertTrue(json.1.contains("installation_missing"))
        XCTAssertEqual(try run(["doctor", "--check", "--state-dir", root.path]).0, 1)
        let exportURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doctor-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        XCTAssertEqual(try run(["doctor", "--export", exportURL.path, "--state-dir", root.path]).0, 0)
        let exported = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(exported.contains("shell-control-diagnostics-export/1"))
        XCTAssertFalse(exported.contains(root.path), "user paths are not exported")
        XCTAssertNotEqual(try run(["doctor", "--export", exportURL.path, "--state-dir", root.path]).0, 0, "never overwrites")
        XCTAssertEqual(try run(["doctor", "--export", "relative.json"]).0, 2)
        XCTAssertEqual(try run(["doctor", "--bogus"]).0, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testTestReviewValidatesItsReviewerBeforeTouchingAnything() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shell-command-tests-\(UUID())")
        XCTAssertTrue(try run(["test-review", "--help"]).1.contains("--device-id"))
        XCTAssertEqual(try run(["test-review", "--reviewer", "iphone", "--device-id", "nope", "--state-dir", root.path]).0, 2)
        XCTAssertEqual(try run(["test-review", "--reviewer", "ipad", "--device-id", UUID().uuidString, "--state-dir", root.path]).0, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
