import Foundation
import Testing
import ShellControlProtocol
@testable import ShellControlAgentAdapter
@testable import ShellControlDaemon

/// Setup merges only Shell's stanzas and keeps a backup; uninstall removes
/// only Shell's stanzas (docs/specs/agent-relay.md sections 9.1 and 18.7). Restart
/// recovery never replays an input response (section 9.3).
@Suite
final class HookInstallerTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hook-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func testInstallPreservesOtherHooksAndSettings() throws {
        let directory = try temporary()
        let settings = directory.appendingPathComponent("settings.json")
        let existing = """
        {"model": "opus", "hooks": {"PermissionRequest": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/usr/local/bin/policy-check"}]}],
         "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}
        """
        try Data(existing.utf8).write(to: settings)
        let command = HookInstaller.command(executable: "/Users/me/.local/bin/shell-control", provider: .claudeCode, stateDirectory: nil)
        #expect(command == "/Users/me/.local/bin/shell-control agent hook claude-code")
        let installer = HookInstaller(provider: .claudeCode, settingsURL: settings, command: command)
        let plan = try installer.plan(routes: [.permissionShell, .askUserQuestion])
        let backup = try #require(try installer.apply(plan))
        #expect((try Data(contentsOf: backup)) == Data(existing.utf8))

        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        #expect(written["model"] as? String == "opus")
        let hooks = try #require(written["hooks"] as? [String: Any])
        let permission = try #require(hooks["PermissionRequest"] as? [[String: Any]])
        #expect(permission.count == 2, "the other policy hook stays")
        let ours = try #require(permission.last)
        #expect(ours["matcher"] as? String == "Bash")
        let hook = try #require((ours["hooks"] as? [[String: Any]])?.first)
        #expect(hook["timeout"] as? Int == 360)
        #expect((hooks["PreToolUse"] as? [[String: Any]])?.first?["matcher"] as? String == "AskUserQuestion")
        #expect((hooks["Stop"]) != nil)
        #expect(installer.isInstalled(routes: [.permissionShell, .askUserQuestion]))

        // Reinstalling is a no-op, not a second stanza.
        #expect(!(try installer.plan(routes: [.permissionShell, .askUserQuestion]).changed))

        let uninstall = HookInstaller(provider: .claudeCode, settingsURL: settings, command: "")
        try uninstall.apply(try uninstall.uninstallPlan())
        let after = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let remaining = try #require(after["hooks"] as? [String: Any])
        #expect((remaining["PermissionRequest"] as? [[String: Any]])?.count == 1)
        #expect((remaining["PreToolUse"]) == nil)
        #expect((remaining["SessionEnd"]) == nil)
        #expect(!(uninstall.hasOwnedStanza()))
    }

    @Test
    func testInstallRefusesANonObjectSettingsFile() throws {
        let directory = try temporary()
        let settings = directory.appendingPathComponent("hooks.json")
        try Data("[1, 2]".utf8).write(to: settings)
        let installer = HookInstaller(provider: .codex, settingsURL: settings, command: "shell-control agent hook codex")
        #expect(throws: (any Error).self) { try installer.plan(routes: [.permissionShell]) }
    }

    @Test
    func testCommandQuotingIsSafe() throws {
        #expect(HookInstaller.command(executable: "/Applications/My Tools/shell-control", provider: .codex, stateDirectory: "/tmp/it's") == "'/Applications/My Tools/shell-control' --state-dir '/tmp/it'\\''s' agent hook codex")
    }

    @Test
    func testConfigurationRoundTrips() throws {
        let root = try temporary()
        let configuration = AdapterConfiguration(provider: .claudeCode, executablePath: "/usr/local/bin/claude",
                                                 routes: [.permissionShell], watchShellApproval: true, userAttestedBuilds: ["2.1.281"])
        try configuration.save(root: root)
        #expect(AdapterConfiguration.load(root: root, provider: .claudeCode) == configuration)
    }

    @Test
    func testInputRecoveryWithdrawsPendingAndReportsClaimedUnknown() throws {
        let journal = try DispatchJournal(url: try temporary().appendingPathComponent("journal.ndjson"))
        let run = ControlID.random()
        let pending = ControlID.random(), claimed = ControlID.random(), delivered = ControlID.random(), answered = ControlID.random()
        let hash = "sha256:" + String(repeating: "a", count: 64)
        for id in [pending, claimed, delivered, answered] {
            try journal.append(.inputPersisted(requestID: id, requestHash: hash, runID: run))
        }
        try journal.append(.inputResolved(requestID: answered, resolution: "answered"))
        for id in [claimed, delivered] {
            try journal.append(.inputResolved(requestID: id, resolution: "answered"))
            try journal.append(.inputConsumeIntent(requestID: id, mutationID: .random(), commandID: .random()))
            try journal.append(.inputClaimed(requestID: id, permitID: .random(), applyBefore: ControlTimestamp(Date())))
        }
        try journal.append(.inputDelivery(requestID: delivered, receiptID: .random(), dispatch: "native_response_written"))
        let recovery = journal.recoverInputs(at: try journal.load())
        #expect(Set(recovery.pending.keys) == [pending])
        #expect(Set(recovery.uncertain.keys) == [claimed])
        // Approval recovery ignores input records entirely.
        let approvals = try journal.recover()
        #expect(approvals.unresolved.isEmpty)
        #expect(approvals.uncertain.isEmpty)
    }

    @Test
    func testUnreadableSettingsAreNeverReplaced() throws {
        let directory = try temporary()
        let settings = directory.appendingPathComponent("settings.json")
        try Data(#"{"model":"opus"}"#.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path) }
        let installer = HookInstaller(provider: .claudeCode, settingsURL: settings, command: "shell-control agent hook claude-code")
        #expect(throws: (any Error).self) { try installer.plan(routes: [.permissionShell]) }
        #expect(throws: (any Error).self) { try installer.uninstallPlan() }
    }

    @Test
    func testStrandedClaimIsRecoveredNotForgotten() throws {
        let journal = try DispatchJournal(url: try temporary().appendingPathComponent("journal.ndjson"))
        let stranded = ControlID.random(), mutation = ControlID.random()
        try journal.append(.inputPersisted(requestID: stranded, requestHash: "sha256:" + String(repeating: "b", count: 64), runID: .random()))
        try journal.append(.inputResolved(requestID: stranded, resolution: "answered"))
        try journal.append(.inputConsumeIntent(requestID: stranded, mutationID: mutation, commandID: .random()))
        let recovery = journal.recoverInputs(at: try journal.load())
        #expect(recovery.stranded[stranded]?.consumeMutationID == mutation)
        #expect(recovery.pending.isEmpty && recovery.uncertain.isEmpty)
    }
}
