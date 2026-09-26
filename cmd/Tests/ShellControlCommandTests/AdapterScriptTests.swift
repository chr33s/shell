import Foundation
import Testing

/// Drives `adapters/git-pre-push/pre-push` against a scratch repository with a
/// stub `shell-control` that captures the request it would send.
@Suite
final class AdapterScriptTests {
    private var directory: URL!

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-control-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("repo"), withIntermediateDirectories: true)
        let stub = directory.appendingPathComponent("bin/shell-control")
        try Data("""
        #!/bin/sh
        while [ $# -gt 0 ]; do [ "$1" = "--spec-file" ] && cp "$2" "$CAPTURE"; shift; done
        exit 13

        """.utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private var hook: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("adapters/git-pre-push/pre-push")
    }

    private var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_NAME"] = "test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
        environment["CAPTURE"] = directory.appendingPathComponent("spec.json").path
        environment["PATH"] = directory.appendingPathComponent("bin").path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        return environment
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], input: String = "") throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = directory.appendingPathComponent("repo")
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func commit(_ message: String) throws -> String {
        try run("git", ["-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty", "-m", message])
        return try run("git", ["rev-parse", "HEAD"]).1
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "the hook needs /usr/bin/python3"))
    func testRefUpdatesAreVisibleToTheReviewer() throws {
        try run("git", ["init", "-q"])
        let base = try commit("one")
        let ahead = try commit("two")
        try run("git", ["checkout", "-q", "-b", "side", base])
        let diverged = try commit("three")
        let zero = String(repeating: "0", count: 40)
        let missing = String(repeating: "1", count: 40)
        let updates = [
            "refs/heads/main \(ahead) refs/heads/main \(base)",
            "refs/heads/side \(diverged) refs/heads/main \(ahead)",
            "(delete) \(zero) refs/heads/old \(base)",
            "refs/heads/new \(diverged) refs/heads/new \(zero)",
            "refs/heads/x \(diverged) refs/heads/x \(missing)"
        ].joined(separator: "\n") + "\n"

        let (status, _) = try run("sh", [hook.path, "origin", "https://example.invalid/r.git"], input: updates)
        #expect(status == 1, "a missing approval must block the push")

        let spec = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("spec.json"))
        ) as? [String: Any])
        let summary = try #require(spec["summary"] as? String)
        #expect(summary.unicodeScalars.count <= 200)
        #expect(summary.hasPrefix("Delete origin/old; Force-push side \u{2192} origin/main (non-fast-forward)"), "\(summary)")
        #expect(summary.contains("Possible force-push x \u{2192} origin/x"), "\(summary)")
        #expect(summary.contains("Create origin/new from new"), "\(summary)")
        #expect(summary.contains("Push main \u{2192} origin/main"), "\(summary)")

        let operation = try #require(spec["operation"] as? [String: Any])
        let argv = try #require(operation["argv"] as? [String])
        #expect(Array(argv.dropFirst()) == [
            "push", "origin",
            "refs/heads/main:refs/heads/main",
            "+refs/heads/side:refs/heads/main",
            ":refs/heads/old",
            "refs/heads/new:refs/heads/new",
            "+refs/heads/x:refs/heads/x"
        ])
        let context = try #require(operation["context_sha256"] as? String)
        #expect(context.count == 64)
    }
}
