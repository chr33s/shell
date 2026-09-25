import ArgumentParser
import Foundation
import ShellControlClient
import ShellControlManagement
import ShellControlProtocol

/// `shell-control doctor`: read-only host diagnostics
/// (docs/specs/control-setup.md section 10). It checks this Mac only,
/// never whether an iPhone or Watch can reach it now.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose this Mac's Control host (read-only).",
        discussion: """
        Checks the installation, local services, Tailscale route and Serve privacy, the origin key, \
        enrolled devices, and remote-alert configuration. --export writes a redacted copy (no tokens, keys, \
        pairing links, paths, account or tailnet names) to a file you choose. It does not test iPhone or Watch reachability; \
        use shell-control test-review, or Settings → Control on the iPhone.

        --check exits 0 only when every required host check passed just now, 1 otherwise. An \
        unconfigured Apple Watch or disabled remote alerts do not fail it.
        """
    )
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Flag(help: "Emit the shell-control-diagnostics/1 JSON document.") var json = false
    @Flag(help: "Exit 1 unless every required host check passed with current evidence.") var check = false
    @Option(help: "Write a redacted, allowlisted report to this new absolute path. Nothing is uploaded.") var export: String?

    mutating func validate() throws {
        if let export, !export.hasPrefix("/") { throw ValidationError("--export must be an absolute path") }
    }

    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, json = json, check = check, export = export
        try await execute {
            let manager = try coordinator(state, inherited: inherited)
            let report = await manager.diagnose()
            if let export {
                let url = URL(fileURLWithPath: export)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw ManagementError.invalid("\(export) already exists; choose a new file")
                }
                let data = try DiagnosticExport.data(reports: [report], applicationVersion: "shell-control \(ShellControlVersion.current)",
                                                     osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
                try data.write(to: url, options: .withoutOverwriting)
                stderr("wrote a redacted diagnostic report to \(export); review it before sharing")
            }
            if json {
                try emitJSON(report.json)
            } else {
                try FileHandle.standardOutput.write(contentsOf: Data(DoctorText.render(report).utf8))
            }
            if check && !report.isReady(.host, at: Date(), maxAge: DiagnosticCheck.freshness) {
                throw ExitCode(1)
            }
        }
    }
}

/// `shell-control test-review`: one explicit live review of the fixed
/// no-operation setup test through the selected reviewer
/// (docs/specs/control-setup.md section 8).
struct TestReviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-review",
        abstract: "Send the harmless setup test to one enrolled reviewer.",
        discussion: """
        Publishes "Setup test — no operation will be executed" through the ordinary review, signed-decision, \
        consume, and receipt pipeline. Nothing is executed. It passes only when the selected device approves \
        and the host records the receipt. Exit status: 0 passed, 10 rejected, 11 expired, 12 cancelled, \
        13 unavailable or answered by another reviewer, 1 receipt not recorded.
        """
    )
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Option(help: "iphone or watch.") var reviewer: SetupReviewer
    @Option(name: .customLong("device-id"), help: "The enrolled device ID from shell-control status.") var deviceID: String
    @Option(help: "Seconds to wait for a decision.") var timeout = Int(SetupTestFixture.lifetimeSeconds) + 30

    mutating func validate() throws {
        guard UUID(uuidString: deviceID) != nil else { throw ValidationError("--device-id must be a UUID") }
        guard (10...900).contains(timeout) else { throw ValidationError("--timeout must be from 10 through 900") }
    }

    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state
        let reviewer = reviewer, deviceID = deviceID.lowercased(), timeout = timeout
        try await execute {
            let loaded = try InstallationStore(root: try state.root(inherited)).load()
            let test = SetupReviewTest(adapter: AdapterClient(stateDirectory: loaded.paths.root))
            let device = try await test.validateReviewer(reviewer, deviceID: deviceID, loaded: loaded)
            stderr("Testing review with \(device.label) (\(device.deviceID)).")
            let result = try await test.run(reviewer: reviewer, deviceID: deviceID, waitTimeout: timeout) { stderr($0) }
            stderr(result.description)
            if result.exitCode != 0 { throw ExitCode(result.exitCode) }
        }
    }
}

extension SetupReviewer: ExpressibleByArgument {}
