import Foundation
import ShellControlProtocol

/// A provider adapter the CLI ships: Claude Code or Codex.
public enum AgentProvider: String, Sendable, CaseIterable, Codable {
    case claudeCode = "claude-code"
    case codex

    /// The `provider` value published in agent operations.
    public var wireName: String {
        switch self {
        case .claudeCode: return "claude_code"
        case .codex: return "codex"
        }
    }

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    public var manifest: AdapterManifest {
        switch self {
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        }
    }
}

/// One native event route an adapter decodes and answers.
public enum NativeRoute: String, Sendable, CaseIterable, Codable, Hashable {
    /// `PermissionRequest` for a shell tool, answered allow/deny.
    case permissionShell = "permission_request.shell"
    /// `PermissionRequest` for a file edit/write tool, answered allow/deny.
    case permissionFileChange = "permission_request.file_change"
    /// `PreToolUse` for `AskUserQuestion`, answered with typed answers.
    case askUserQuestion = "pre_tool_use.ask_user_question"
    /// Managed Codex app-server routes: experimental and opt-in
    /// (spec.agent-relay.md sections 4.2 and 11.2).
    case appServerCommandApproval = "app_server.command_execution_approval"
    case appServerFileChangeApproval = "app_server.file_change_approval"
    case appServerUserInput = "app_server.user_input"
    case appServerTurnControl = "app_server.turn_control"

    public var feature: String {
        switch self {
        case .permissionShell, .appServerCommandApproval: return AgentFeature.shell
        case .permissionFileChange, .appServerFileChangeApproval: return AgentFeature.fileChange
        case .askUserQuestion, .appServerUserInput: return AgentFeature.input
        case .appServerTurnControl: return AgentFeature.messages
        }
    }

    /// The features a route contributes to a session's negotiated operations.
    public var features: [String] {
        self == .appServerTurnControl ? [AgentFeature.messages, AgentFeature.turnCancel] : [feature]
    }

    public var isManaged: Bool { rawValue.hasPrefix("app_server.") }
}

/// A tested provider build range and the evidence behind it.
public struct TestedBuildRange: Sendable, Codable, Hashable {
    /// Inclusive lower bound, dotted numeric.
    public var minimum: String
    /// Exclusive upper bound, or nil for exactly `minimum`.
    public var maximumExclusive: String?
    public var evidence: AgentCompatibilityEvidence
    public var routes: [NativeRoute]
    /// Fixture files under `adapters/<provider>/fixtures/` that back the
    /// evidence.
    public var fixtures: [String]
    /// The execution modes exercised: `interactive`, `headless`. Support for
    /// one is never inferred from the other (spec.agent-relay.md 10.3).
    public var modes: [String]

    public static let allModes = ["headless", "interactive"]

    public init(minimum: String, maximumExclusive: String? = nil, evidence: AgentCompatibilityEvidence, routes: [NativeRoute],
                fixtures: [String], modes: [String] = TestedBuildRange.allModes) {
        self.minimum = minimum
        self.maximumExclusive = maximumExclusive
        self.evidence = evidence
        self.routes = routes
        self.fixtures = fixtures
        self.modes = modes
    }

    /// Whether the range covers every mode a hook might run in. A hook cannot
    /// tell headless from interactive execution, so partial coverage never
    /// counts at run time.
    public var coversAllModes: Bool { Set(Self.allModes).isSubset(of: modes) }

    public func contains(_ build: String) -> Bool {
        guard let version = BuildVersion(build), let lower = BuildVersion(minimum) else { return false }
        guard let maximumExclusive else { return version == lower }
        guard let upper = BuildVersion(maximumExclusive) else { return false }
        return version >= lower && version < upper
    }
}

/// A dotted numeric version, compared component by component.
public struct BuildVersion: Sendable, Comparable, Hashable {
    public let components: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            components.append(value)
        }
        self.components = components
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    public func hash(into hasher: inout Hasher) { hasher.combine(components.reversed().drop { $0 == 0 }.reversed() as [Int]) }
}

/// The checked-in compatibility manifest (spec.agent-relay.md section 4.3).
///
/// It distinguishes `documented`, `contract_tested`, and `device_validated`;
/// no minimum provider version is asserted, and an untested build defaults to
/// informational mode. Release engineering fills `testedBuilds` from tested
/// binaries and their fixtures.
public struct AdapterManifest: Sendable, Codable, Hashable {
    public static let schemaName = "shell-agent-adapter-manifest/1"
    public static let adapterBuild = "1.0.0"

    public var schema: String
    public var provider: AgentProvider
    public var providerWireName: String
    public var adapterBuild: String
    public var profile: AgentIntegrationProfile
    public var executable: String
    public var versionArguments: [String]
    /// The events and tools this adapter decodes, and the response encoding
    /// it writes for each.
    public var routes: [RouteDescription]
    /// What is deliberately not covered, so no one reads the integration as
    /// complete permission coverage (spec.agent-relay.md 10.2).
    public var coverageExclusions: [String]
    public var failureBehavior: [String]
    /// Documentation checked on `documentationCheckedOn`; this alone never
    /// makes a build "Ready".
    public var documentationSources: [String]
    public var documentationCheckedOn: String
    public var testedBuilds: [TestedBuildRange]

    public struct RouteDescription: Sendable, Codable, Hashable {
        public var route: NativeRoute
        public var hookEvent: String
        public var tools: [String]
        public var response: String
        public var enabledByDefault: Bool
    }

    public func evidence(for build: String, route: NativeRoute) -> AgentCompatibilityEvidence {
        testedBuilds
            .filter { $0.routes.contains(route) && $0.contains(build) && $0.coversAllModes }
            .map(\.evidence)
            .max() ?? .documented
    }

    /// Tested ranges that cover `build` for `route` in only some modes, for
    /// honest reporting.
    public func partialEvidence(for build: String, route: NativeRoute) -> [TestedBuildRange] {
        testedBuilds.filter { $0.routes.contains(route) && $0.contains(build) && !$0.coversAllModes }
    }

    public var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) throws -> AdapterManifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(AdapterManifest.self, from: data)
    }
}

extension AgentIntegrationProfile: Codable {}
extension AgentCompatibilityEvidence: Codable {}

extension AdapterManifest {
    static let sharedFailureBehavior = [
        "Before a request is published (Control disabled, daemon unavailable, unsupported build or tool), the hook writes no decision and the provider's own terminal prompt applies.",
        "After publication, broker failure, a malformed internal result, expiry, or changed native context produce a native denial while the hook is alive, labelled a system outcome.",
        "If the hook never starts, is killed, or reaches the provider's timeout, no Shell decision is written; this is a hook-profile limitation, not mandatory enforcement.",
        "Delivery is reported native_response_written; acceptance is unobservable through a hook and is never reported as applied."
    ]

    public static let claudeCode = AdapterManifest(
        schema: schemaName,
        provider: .claudeCode,
        providerWireName: AgentProvider.claudeCode.wireName,
        adapterBuild: adapterBuild,
        profile: .hook,
        executable: "claude",
        versionArguments: ["--version"],
        routes: [
            RouteDescription(route: .permissionShell, hookEvent: "PermissionRequest", tools: ["Bash"],
                             response: "hookSpecificOutput.decision.behavior allow|deny (no updatedInput, updatedPermissions, or mode change)",
                             enabledByDefault: true),
            RouteDescription(route: .permissionFileChange, hookEvent: "PermissionRequest", tools: ["Edit", "Write"],
                             response: "hookSpecificOutput.decision.behavior allow|deny", enabledByDefault: false),
            RouteDescription(route: .askUserQuestion, hookEvent: "PreToolUse", tools: ["AskUserQuestion"],
                             response: "hookSpecificOutput.permissionDecision allow with updatedInput {questions (preserved), answers}",
                             enabledByDefault: true)
        ],
        coverageExclusions: [
            "PermissionRequest carries no tool_use_id; acceptance of a written decision is not correlated.",
            "Sandbox network prompts and other native prompts not listed in routes stay in the terminal.",
            "Tool calls auto-approved by provider rules or modes never reach the hook and were not reviewed by Shell.",
            "Bash inputs with authorization-relevant fields beyond command, description, timeout, and run_in_background are refused remotely.",
            "MultiEdit, NotebookEdit, MCP tools, and permission-rule suggestions are not remotely approvable.",
            "AskUserQuestion free-text (Other) answers, option previews, and duplicate question text disable the question route.",
            "Interactive and headless (-p) execution are validated separately."
        ],
        failureBehavior: sharedFailureBehavior,
        documentationSources: [
            "https://code.claude.com/docs/en/hooks",
            "https://code.claude.com/docs/en/agent-sdk/user-input"
        ],
        documentationCheckedOn: "2026-09-24",
        testedBuilds: [
            // Captured from the real binary; headless only (see the fixtures'
            // README). Interactive execution and the question route remain
            // untested, so at run time this build stays documented.
            TestedBuildRange(
                minimum: "2.1.281", evidence: .contractTested, routes: [.permissionShell],
                fixtures: [
                    "captured-2.1.281/permission-request.bash.allow.headless.input.json",
                    "captured-2.1.281/permission-request.bash.deny.headless.input.json",
                    "permission-request.bash.allow.expected.json",
                    "permission-request.bash.deny.expected.json"
                ],
                modes: ["headless"]
            )
        ]
    )

    public static let codex = AdapterManifest(
        schema: schemaName,
        provider: .codex,
        providerWireName: AgentProvider.codex.wireName,
        adapterBuild: adapterBuild,
        profile: .hook,
        executable: "codex",
        versionArguments: ["--version"],
        routes: [
            RouteDescription(route: .permissionShell, hookEvent: "PermissionRequest", tools: ["Bash"],
                             response: "hookSpecificOutput.decision.behavior allow|deny (updatedInput, updatedPermissions, interrupt unsupported)",
                             enabledByDefault: true),
            // Managed profile: `codex app-server` over stdio, owned by
            // `shell-control agent launch codex --managed`. Experimental.
            RouteDescription(route: .appServerCommandApproval, hookEvent: "item/commandExecution/requestApproval", tools: ["commandExecution"],
                             response: "result.decision accept|decline (never acceptForSession or an exec-policy amendment)",
                             enabledByDefault: false),
            RouteDescription(route: .appServerFileChangeApproval, hookEvent: "item/fileChange/requestApproval", tools: ["fileChange"],
                             response: "result.decision accept|decline", enabledByDefault: false),
            RouteDescription(route: .appServerUserInput, hookEvent: "item/tool/requestUserInput", tools: ["requestUserInput"],
                             response: "result.answers {<question id>: {answers: [text]}} (experimentalApi)", enabledByDefault: false),
            RouteDescription(route: .appServerTurnControl, hookEvent: "turn/start, turn/steer, turn/interrupt", tools: [],
                             response: "turn/start result.turn.id; turn/steer result.turnId; turn/interrupt {} (acknowledgement only)",
                             enabledByDefault: false)
        ],
        coverageExclusions: [
            "Hooks run only after the user trusts them in Codex (/hooks); Shell never bypasses trust review.",
            "apply_patch, MCP tools, managed-network grants, and permission tools are not remotely approvable.",
            "Codex questions, new instructions, steering, and cancellation need the experimental managed app-server profile.",
            "A shell-shaped request whose scope cannot be distinguished is refused remotely.",
            "Managed: approval requests with fields beyond threadId, turnId, itemId, command/changes, cwd, reason, and availableDecisions stay local.",
            "Managed: a native remote TUI is not supported; the managed adapter owns the only app-server connection."
        ],
        failureBehavior: sharedFailureBehavior + [
            "Managed: a remote approval or question that expires stays with the local terminal session; no default answer is generated.",
            "Managed: accepted is reported only from the app-server's correlated RPC result or serverRequest/resolved; a lost connection is unknown."
        ],
        documentationSources: ["https://learn.chatgpt.com/docs/hooks", "https://learn.chatgpt.com/docs/app-server"],
        documentationCheckedOn: "2026-09-24",
        testedBuilds: [
            // Captured from a live `codex app-server` session (see the
            // fixtures' README): command approvals, decline and accept, with
            // item-status correlation. The managed adapter owns the process,
            // so there is no separate interactive mode. File-change
            // approvals, user input, steering, and interrupts were not
            // exercised and stay documented.
            TestedBuildRange(
                minimum: "0.156.1", evidence: .contractTested, routes: [.appServerCommandApproval],
                fixtures: [
                    "captured-0.156.1/app-server.command-approval.json",
                    "captured-0.156.1/app-server.server-request-resolved.json",
                    "captured-0.156.1/app-server.item-completed.declined.json",
                    "captured-0.156.1/app-server.item-completed.completed.json"
                ]
            ),
            // The hook route, captured through a scripted `codex app-server`
            // client in a trusted scratch project with trusted hooks: the
            // written deny blocked the command, the written allow ran it, and
            // no approval reached the client either time. The interactive
            // TUI was not exercised, so at run time this stays documented.
            TestedBuildRange(
                minimum: "0.156.1", evidence: .contractTested, routes: [.permissionShell],
                fixtures: [
                    "captured-0.156.1/hook.permission-request.bash.deny.input.json",
                    "captured-0.156.1/hook.permission-request.bash.allow.input.json",
                    "captured-0.156.1/hook.permission-request.completed.blocked.json",
                    "captured-0.156.1/hook.permission-request.completed.completed.json",
                    "permission-request.bash.allow.expected.json",
                    "permission-request.bash.deny.expected.json"
                ],
                modes: ["headless"]
            )
        ]
    )
}
