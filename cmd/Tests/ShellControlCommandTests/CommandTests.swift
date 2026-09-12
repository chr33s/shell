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
}
