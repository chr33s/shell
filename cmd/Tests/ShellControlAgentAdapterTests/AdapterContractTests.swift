import Foundation
import Testing
import ShellControlProtocol
@testable import ShellControlAgentAdapter

/// Native contract fixtures for the Claude Code and Codex hook adapters
/// (docs/specs/agent-relay.md sections 3.3, 5, 6, 9, 10). The fixtures under
/// `adapters/<provider>/fixtures` follow the providers' documented shapes;
/// they are not captured from a provider binary, so they back `documented`
/// evidence only.
@Suite
final class AdapterContractTests {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func fixture(_ provider: AgentProvider, _ name: String) throws -> Data {
        try Data(contentsOf: Self.repository.appendingPathComponent("adapters/\(provider.rawValue)/fixtures/\(name)"))
    }

    func canonical(_ data: Data) throws -> Data { try JSONCanonicalization.canonicalize(try JSONValue.parse(data)) }

    private func context(_ build: String = "2.1.281") -> AdapterContext {
        AdapterContext(providerBuild: build, agentSessionID: .random(), nativeWaitID: .random(), effectiveUserID: 501, policyFingerprint: String(repeating: "e", count: 64))
    }

    // MARK: Manifests

    @Test
    func testCheckedInManifestsMatchTheShippedOnes() throws {
        for provider in AgentProvider.allCases {
            let url = Self.repository.appendingPathComponent("adapters/\(provider.rawValue)/manifest.json")
            if ProcessInfo.processInfo.environment["UPDATE_AGENT_MANIFESTS"] == "1" {
                try provider.manifest.json.write(to: url)
            }
            let checkedIn = try AdapterManifest.decode(try Data(contentsOf: url))
            #expect(checkedIn == provider.manifest, "\(url.path) is out of date")
        }
    }

    @Test
    func testUntestedBuildsAreInformationalUntilAttested() throws {
        var configuration = AdapterConfiguration(provider: .claudeCode)
        #expect(configuration.evidence(for: "2.1.281", route: .permissionShell) == .documented)
        #expect(!(configuration.evidence(for: "2.1.281", route: .permissionShell).permitsRemoteResponse))
        #expect(configuration.evidence(for: nil, route: .permissionShell) == AgentCompatibilityEvidence.none)
        configuration.userAttestedBuilds = ["2.1.281"]
        #expect(configuration.evidence(for: "2.1.281", route: .permissionShell) == .userAttested)
        #expect(configuration.evidence(for: "2.1.282", route: .permissionShell) == .documented)
    }

    @Test
    func testCapturedHeadlessInputsDecodeAndMap() throws {
        for name in ["permission-request.bash.allow.headless.input.json", "permission-request.bash.deny.headless.input.json"] {
            let input = try NativeHookInput.decode(try fixture(.claudeCode, "captured-2.1.281/\(name)"), provider: .claudeCode)
            #expect(input.route == .permissionShell)
            #expect((input.toolUseID) == nil, "the real PermissionRequest carries no tool_use_id")
            var context = context()
            let operation = try OperationMapper.operation(for: input, context: &context)
            #expect(operation.shellRequest?.command?.hasPrefix("touch shell-contract-") ?? false)
        }
        // Headless-only evidence is recorded but never counts at run time.
        #expect(AdapterManifest.claudeCode.evidence(for: "2.1.281", route: .permissionShell) == .documented)
        #expect(AdapterManifest.claudeCode.partialEvidence(for: "2.1.281", route: .permissionShell).first?.modes == ["headless"])
    }

    @Test
    func testCapturedCodexHookInputsDecodeAndMap() throws {
        for (name, file) in [("hook.permission-request.bash.deny.input.json", "hook-denied.txt"),
                             ("hook.permission-request.bash.allow.input.json", "hook-allowed.txt")] {
            let input = try NativeHookInput.decode(try fixture(.codex, "captured-0.156.1/\(name)"), provider: .codex)
            #expect(input.route == .permissionShell)
            #expect((input.toolUseID) == nil, "the real PermissionRequest carries no tool_use_id; PreToolUse does")
            var context = context("0.156.1")
            let operation = try OperationMapper.operation(for: input, context: &context)
            #expect(operation.shellRequest?.command == "touch \(file)")
        }
        // Codex PreToolUse is observed but never handled.
        #expect(throws: (any Error).self){ try NativeHookInput.decode(try fixture(.codex, "captured-0.156.1/hook.pre-tool-use.bash.input.json"), provider: .codex) }
        #expect(AdapterManifest.codex.evidence(for: "0.156.1", route: .permissionShell) == .documented)
        #expect(AdapterManifest.codex.partialEvidence(for: "0.156.1", route: .permissionShell).first?.modes == ["headless"])
    }

    @Test
    func testTestedRangesAreInclusiveExclusive() throws {
        let range = TestedBuildRange(minimum: "2.1.0", maximumExclusive: "2.2", evidence: .contractTested, routes: [.permissionShell], fixtures: [])
        #expect(range.contains("2.1.0"))
        #expect(range.contains("2.1.281"))
        #expect(!(range.contains("2.2.0")))
        #expect(!(range.contains("2.0.9")))
        #expect(!(range.contains("2.1.281-beta")))
        #expect(ProviderBuildDetector.parseBuild("2.1.281 (Claude Code)\n") == "2.1.281")
        #expect(ProviderBuildDetector.parseBuild("codex-cli 0.44.0") == "0.44.0")
        #expect((ProviderBuildDetector.parseBuild("unknown")) == nil)
    }

    // MARK: Claude Code permission requests

    @Test
    func testClaudeBashMapsToAnExactShellOperation() throws {
        let input = try NativeHookInput.decode(try fixture(.claudeCode, "permission-request.bash.input.json"), provider: .claudeCode)
        #expect(input.route == .permissionShell)
        #expect((input.toolUseID) == nil, "never fabricated")
        var context = context()
        let operation = try OperationMapper.operation(for: input, context: &context)
        #expect(operation.kind == .shell)
        #expect(operation.shellRequest?.representation == .commandString)
        #expect(operation.shellRequest?.command == "git status --short")
        #expect((operation.shellRequest?.argv) == nil, "a command string is never split")
        #expect((operation.shellRequest?.shellIdentity) == nil)
        #expect(operation.shellRequest?.options["timeout"] == .integer(120000))
        #expect(operation.shellRequest?.options["run_in_background"] == .bool(false))
        #expect(operation.reason == "Show working tree status")
        #expect(operation.unavailable == ["environment", "shell_identity"])
        #expect(operation.permissionScope == AgentPermissionScope.singleNativeGate)
        #expect(operation.nativeRequestSHA256 == input.nativeRequestSHA256)
        #expect(operation.contextSHA256 == context.contextSHA256(for: input))
        #expect(operation.requiredFeatures == ["agent.tool.v1", "agent.shell.v1", "consume.v1"])
    }

    @Test
    func testUnknownShellFieldsRefuseRemoteApproval() throws {
        // A7: a field that can widen the scope is never flattened away.
        let input = try NativeHookInput.decode(try fixture(.claudeCode, "permission-request.bash.sandbox-override.input.json"), provider: .claudeCode)
        var context = context()
        do { _ = try OperationMapper.operation(for: input, context: &context)
Issue.record("expected an error")
} catch let error {
            #expect((error as? AdapterRefusal)?.code == "unsupported_operation")
        }
    }

    @Test
    func testUnsupportedToolsHaveNoRoute() throws {
        let web = try NativeHookInput.decode(try fixture(.claudeCode, "permission-request.webfetch.input.json"), provider: .claudeCode)
        #expect((web.route) == nil)
        let patch = try NativeHookInput.decode(try fixture(.codex, "permission-request.apply-patch.input.json"), provider: .codex)
        #expect((patch.route) == nil)
        #expect(throws: (any Error).self){ try NativeHookInput.decode(try fixture(.codex, "pre-tool-use.bash.input.json"), provider: .codex) }
    }

    @Test
    func testCodexBashIsDecodedIndependently() throws {
        let input = try NativeHookInput.decode(try fixture(.codex, "permission-request.bash.input.json"), provider: .codex)
        #expect(input.turnID == "turn-7")
        var context = context("0.44.0")
        let operation = try OperationMapper.operation(for: input, context: &context)
        #expect(operation.provider == "codex")
        #expect(operation.shellRequest?.command == "swift test --package-path cmd")
        #expect(operation.providerTurnID == "turn-7")
        // A Claude-only member is unknown to the Codex decoder.
        var claudeShaped = try #require(try JSONValue.parse(try fixture(.codex, "permission-request.bash.input.json")).objectValue)
        claudeShaped["tool_input"] = .object(["command": "ls", "run_in_background": true])
        let odd = try NativeHookInput.decode(try JSONCanonicalization.canonicalize(.object(claudeShaped)), provider: .codex)
        var second = context
        #expect(throws: (any Error).self){ try OperationMapper.operation(for: odd, context: &second) }
    }

    @Test
    func testNativeInputIsBoundedAndStrict() throws {
        #expect(throws: (any Error).self){ try NativeHookInput.decode(Data(repeating: 0x20, count: AgentPolicy.maximumNativeInputBytes + 1), provider: .claudeCode) }
        #expect(throws: (any Error).self){ try NativeHookInput.decode(Data(#"{"hook_event_name":"PermissionRequest","hook_event_name":"x"}"#.utf8), provider: .claudeCode) }
        #expect(throws: (any Error).self){ try NativeHookInput.decode(Data(#"{"hook_event_name":"PermissionRequest","cwd":"relative","tool_name":"Bash","tool_input":{}}"#.utf8), provider: .claudeCode) }
    }

    @Test
    func testResponseEncodingsMatchTheFixtures() throws {
        for provider in AgentProvider.allCases {
            #expect(HookRunner.permissionResponse(allow: true, message: nil, provider: provider) == (try canonical(try fixture(provider, "permission-request.bash.allow.expected.json"))))
            #expect(HookRunner.permissionResponse(allow: false, message: "Denied by the reviewer in Shell Control.", provider: provider) == (try canonical(try fixture(provider, "permission-request.bash.deny.expected.json"))))
        }
        // No permission updates, rules, modified input, or interrupt.
        let allow = try JSONValue.parse(HookRunner.permissionResponse(allow: true, message: "ignored", provider: .claudeCode))
        #expect(allow["hookSpecificOutput"]?["decision"]?.objectValue?.keys.sorted() == ["behavior"])
    }

    // MARK: File changes

    struct MemoryFileSystem: AdapterFileSystem {
        var files: [String: Data]
        func contents(of path: String, limit: Int) throws -> Data? { files[path] }
        func isDirectory(_ path: String) -> Bool { path == "/Users/example/src/shell" || path == "/" }
    }

    @Test
    func testEditMapsToACompleteDiffWithABaseHash() throws {
        let input = try NativeHookInput.decode(try fixture(.claudeCode, "permission-request.edit.input.json"), provider: .claudeCode)
        let original = Data("# Shell\n\nA terminal.\n".utf8)
        let files = MemoryFileSystem(files: ["/Users/example/src/shell/README.md": original])
        var context = context()
        let operation = try OperationMapper.operation(for: input, context: &context, fileSystem: files)
        let change = try #require(operation.fileChanges?.first)
        #expect(change.change == .modify)
        #expect(change.baseSHA256 == ContentDigest.sha256Hex(original))
        #expect(change.diff.contains("-# Shell\n+# Shell Terminal\n"), "\(change.diff)")
        #expect(!(operation.isWatchEligible))
        do { _ = try OperationMapper.recheck(operation, fileSystem: files) } catch { Issue.record("unexpected error: \(error)") }
        // A change after review is caught before the gate is answered.
        let edited = MemoryFileSystem(files: ["/Users/example/src/shell/README.md": Data("# Shell!\n".utf8)])
        #expect(throws: (any Error).self){ try OperationMapper.recheck(operation, fileSystem: edited) }
    }

    @Test
    func testAmbiguousOrMissingEditIsRefused() throws {
        let input = try NativeHookInput.decode(try fixture(.claudeCode, "permission-request.edit.input.json"), provider: .claudeCode)
        var first = context()
        #expect(throws: (any Error).self){ try OperationMapper.operation(for: input, context: &first, fileSystem: MemoryFileSystem(files: [:])) }
        var second = context()
        let twice = MemoryFileSystem(files: ["/Users/example/src/shell/README.md": Data("Shell Shell\n".utf8)])
        #expect(throws: (any Error).self){ try OperationMapper.operation(for: input, context: &second, fileSystem: twice) }
    }

    @Test
    func testUnifiedDiffShowsEveryChangedLine() throws {
        let diff = UnifiedDiff.make(path: "/a", before: "1\n2\n3\n4\n5\n6\n7\n8\n", after: "1\n2\nthree\n4\n5\n6\nseven\n8\n", context: 1)
        #expect(diff == "--- a/a\n+++ b/a\n@@ -2,7 +2,7 @@\n 2\n-3\n-4\n-5\n-6\n-7\n+three\n+4\n+5\n+6\n+seven\n 8\n")
        #expect(UnifiedDiff.make(path: "/a", before: "x", after: "x\n").contains("final newline added"))
        #expect(UnifiedDiff.make(path: "/n", before: nil, after: "new\n").hasPrefix("--- /dev/null\n+++ b/n\n"))
    }

    // MARK: Questions

    @Test
    func testAskUserQuestionMapsToTypedQuestionsAndBack() throws {
        let input = try NativeHookInput.decode(try fixture(.claudeCode, "pre-tool-use.ask-user-question.input.json"), provider: .claudeCode)
        #expect(input.route == .askUserQuestion)
        let mapping = try QuestionMapping.make(from: input)
        #expect(mapping.questions.map(\.id) == ["q1", "q2"])
        #expect(mapping.questions[0].prompt == "Which tests should run next?")
        guard case .multiChoice(let choices, 1, 3) = mapping.questions[1].kind else { Issue.record("multi choice")
return }
        #expect(choices.map(\.label) == ["iOS", "watchOS", "macOS"])
        let response = InputResponse.answer([
            .singleChoice(questionID: "q1", choiceID: "c2"),
            .multiChoice(questionID: "q2", choiceIDs: ["c1", "c3"])
        ])
        let updated = try mapping.updatedInput(for: response, committedMappingSHA256: mapping.mapping.sha256Hex)
        #expect(HookRunner.questionResponse(updatedInput: updated) == (try canonical(try fixture(.claudeCode, "pre-tool-use.ask-user-question.answer.expected.json"))))
        // The committed mapping is rechecked before dispatch.
        #expect(throws: (any Error).self){ try mapping.updatedInput(for: response, committedMappingSHA256: String(repeating: "0", count: 64)) }
        #expect(throws: (any Error).self){ try mapping.updatedInput(for: .decline, committedMappingSHA256: mapping.mapping.sha256Hex) }
    }

    @Test
    func testAmbiguousOrUnknownQuestionShapesDisableTheRoute() throws {
        for name in ["pre-tool-use.ask-user-question.duplicate.input.json", "pre-tool-use.ask-user-question.preview.input.json"] {
            let input = try NativeHookInput.decode(try fixture(.claudeCode, name), provider: .claudeCode)
            #expect(throws: (any Error).self, "\(name)") { try QuestionMapping.make(from: input) }
        }
    }
}
