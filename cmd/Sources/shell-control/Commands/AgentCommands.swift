import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import ShellControlAgentAdapter
import ShellControlHostSupport
import ShellControlManagement
import ShellControlProtocol

extension AgentProvider: ExpressibleByArgument {}

/// `shell-control agent …`: native Claude Code and Codex integrations
/// (spec.agent-relay.md section 19.7). These are the standalone CLI profile's
/// commands; nothing here installs executables anywhere.
struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Claude Code and Codex approvals and questions from iPhone and Apple Watch.",
        subcommands: [
            AgentInstallCommand.self, AgentUninstallCommand.self, AgentDoctorCommand.self, AgentHookCommand.self,
            AgentTestCommand.self, AgentLaunchCommand.self, AgentGrantCommand.self, AgentAllowBuildCommand.self
        ]
    )
    @ParentCommand var parent: ShellControlCommand
}

private func stateRoot(_ state: StateOptions, _ inherited: String?) throws -> URL { try state.root(inherited) }

/// The path providers should run: the published `~/.local/bin/shell-control`
/// when it is this executable, otherwise this executable's absolute path.
private func verifiedExecutablePath() throws -> String {
    // The running image's own path: argv[0] is only a PATH lookup name
    // when the command was started as `shell-control`.
    guard let image = Bundle.main.executableURL else {
        throw ManagementError.invalid("cannot determine this shell-control executable's absolute path")
    }
    let current = image.standardizedFileURL.resolvingSymlinksInPath().path
    let published = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/shell-control")
    if (published.path as NSString).resolvingSymlinksInPath == current { return published.path }
    guard current.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: current) else {
        throw ManagementError.invalid("cannot determine this shell-control executable's absolute path")
    }
    return current
}

struct AgentInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Add Shell's hook stanzas to the provider's hook settings.",
        discussion: """
        Merges only Shell's own stanzas; other hooks and settings are preserved, and the previous file is kept \
        as a timestamped backup. Codex runs a changed hook only after you review and trust it with /hooks in Codex; \
        this command never bypasses that review. An untested provider build stays informational until \
        release evidence covers it or you run `shell-control agent allow-build`.
        """
    )
    @ParentCommand var parent: AgentCommand
    @OptionGroup var state: StateOptions
    @Argument var provider: AgentProvider
    @Flag(help: "Print the change without writing it.") var dryRun = false
    @Flag(help: "Also route Claude Code Edit and Write permission requests (iPhone full review only).") var includeFileChanges = false
    @Flag(help: "Do not route Claude Code AskUserQuestion questions.") var noQuestions = false
    @Flag(help: "Allow Watch approval of short, single-line shell commands.") var watchShellApproval = false
    @Flag(help: "Codex only: also enable the experimental managed app-server routes used by `agent launch codex --managed`.") var enableManaged = false
    @Option(help: "Absolute path of the provider hook settings file.") var settings: String?

    mutating func run() async throws {
        let inherited = parent.parent.state.stateDirectory, state = state, provider = provider, dryRun = dryRun
        let includeFileChanges = includeFileChanges, noQuestions = noQuestions, watch = watchShellApproval, settings = settings
        let enableManaged = enableManaged
        try await execute {
            if let settings, !settings.hasPrefix("/") { throw ManagementError.invalid("--settings must be absolute") }
            let root = try stateRoot(state, inherited)
            var configuration = AdapterConfiguration.load(root: root, provider: provider) ?? AdapterConfiguration(provider: provider)
            var routes: [NativeRoute] = [.permissionShell]
            if includeFileChanges, provider == .claudeCode { routes.append(.permissionFileChange) }
            if !noQuestions, provider == .claudeCode { routes.append(.askUserQuestion) }
            if enableManaged {
                guard provider == .codex else { throw ManagementError.invalid("--enable-managed applies to codex only") }
                routes += [.appServerCommandApproval, .appServerFileChangeApproval, .appServerUserInput, .appServerTurnControl]
                stderr("managed Codex routes are experimental: they apply only to `shell-control agent launch codex --managed`")
            }
            configuration.routes = routes
            configuration.watchShellApproval = watch
            configuration.executablePath = ProviderBuildDetector.locate(provider.manifest.executable)
            let explicitRoot = inherited ?? state.stateDirectory
            let command = HookInstaller.command(executable: try verifiedExecutablePath(), provider: provider, stateDirectory: explicitRoot)
            let installer = HookInstaller(provider: provider, settingsURL: settings.map { URL(fileURLWithPath: $0) }, command: command)
            let plan = try installer.plan(routes: routes.filter { !$0.isManaged })
            stderr("settings: \(installer.settingsURL.path)")
            stderr("hook command: \(command)")
            for (event, matcher) in installer.stanzas(routes: routes.filter { !$0.isManaged }) {
                stderr("  \(event)\(matcher.isEmpty ? "" : " [\(matcher)]")")
            }
            guard plan.changed else { stderr("already installed"); if !dryRun { try configuration.save(root: root) }; return }
            if dryRun {
                try FileHandle.standardOutput.write(contentsOf: plan.after)
                return
            }
            try configuration.save(root: root)
            if let backup = try installer.apply(plan) { stderr("previous settings kept at \(backup.path)") }
            if provider == .codex {
                stderr("next: open Codex and run /hooks to review and trust the Shell hook; it does not run until you do")
            }
            stderr("next: shell-control agent grant <DEVICE-ID> for each iPhone or Watch that should answer questions")
        }
    }
}

struct AgentUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove only Shell's hook stanzas.")
    @ParentCommand var parent: AgentCommand
    @OptionGroup var state: StateOptions
    @Argument var provider: AgentProvider
    @Option(help: "Absolute path of the provider hook settings file.") var settings: String?

    mutating func run() async throws {
        let provider = provider, settings = settings
        try await execute {
            let installer = HookInstaller(provider: provider, settingsURL: settings.map { URL(fileURLWithPath: $0) }, command: "")
            let plan = try installer.uninstallPlan()
            guard plan.changed else { stderr("no Shell hook stanzas in \(installer.settingsURL.path)"); return }
            if let backup = try installer.apply(plan) { stderr("previous settings kept at \(backup.path)") }
            stderr("removed Shell hook stanzas from \(installer.settingsURL.path)")
        }
    }
}

/// `agent doctor`: honest, per-provider readiness. Documentation alone is
/// never "Ready" (spec.agent-relay.md sections 4.3 and 19.9).
struct AgentDoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Report agent integration readiness (read-only).")
    @ParentCommand var parent: AgentCommand
    @OptionGroup var state: StateOptions
    @Flag var json = false

    mutating func run() async throws {
        let inherited = parent.parent.state.stateDirectory, state = state, json = json
        try await execute {
            let root = try stateRoot(state, inherited)
            let daemonUp = UnixSocketServer(path: state.adapterSocketPath(inherited)).isServedByLiveInstance()
            var reports: [JSONValue] = []
            for provider in AgentProvider.allCases {
                reports.append(await AgentDoctor.report(provider: provider, root: root, daemonReachable: daemonUp))
            }
            let document = JSONValue.object(["schema": "shell-agent-doctor/1", "control_daemon_reachable": .bool(daemonUp), "providers": .array(reports)])
            if json { try emitJSON(document); return }
            var text = "Control daemon: \(daemonUp ? "reachable" : "not running")\n"
            for report in reports {
                text += "\n\(report["provider"]?.stringValue ?? "?"): \(report["readiness"]?.stringValue ?? "?")\n"
                text += "  build: \(report["build"]?.stringValue ?? "not found")\n"
                text += "  hook: \(report["hook_installed"]?.boolValue == true ? "installed" : "not installed")\n"
                for route in report["routes"]?.arrayValue ?? [] {
                    text += "  \(route["route"]?.stringValue ?? ""): \(route["enabled"]?.boolValue == true ? "enabled" : "off"), evidence \(route["evidence"]?.stringValue ?? "")\n"
                }
                for note in report["notes"]?.arrayValue ?? [] { text += "  note: \(note.stringValue ?? "")\n" }
            }
            try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
        }
    }
}

enum AgentDoctor {
    static func report(provider: AgentProvider, root: URL, daemonReachable: Bool) async -> JSONValue {
        let configuration = AdapterConfiguration.load(root: root, provider: provider)
        let effective = configuration ?? AdapterConfiguration(provider: provider)
        let executable = effective.executablePath ?? ProviderBuildDetector.locate(provider.manifest.executable)
        let build = await ProviderBuildDetector(root: root).build(provider: provider, executable: executable)
        let installer = HookInstaller(provider: provider, command: "")
        let installed = installer.hasOwnedStanza()
        var notes: [String] = []
        let evidences = effective.routes.map { effective.evidence(for: build, route: $0) }
        let best = evidences.max() ?? AgentCompatibilityEvidence.none
        let readiness: String
        if let executable, build == nil {
            // A first launch parked on a Gatekeeper prompt never answers.
            notes.append("\(executable) --version did not answer within 3 s; if it is waiting on a macOS Gatekeeper prompt, run it once in Terminal and choose Open")
        }
        if executable == nil {
            readiness = "provider_not_found"
        } else if configuration == nil || !installed {
            readiness = "not_installed"
        } else if !daemonReachable {
            readiness = "control_unavailable"
        } else if best >= .contractTested {
            readiness = provider == .codex ? "installed_trust_unverified" : "ready_for_approvals"
        } else if best == .userAttested {
            readiness = "user_attested_not_ready"
            notes.append("this build has no contract evidence; approvals work but are not reported Ready")
        } else {
            readiness = "informational_only"
            notes.append("build \(build ?? "unknown") is not covered by a tested range; prompts stay in the terminal")
        }
        if let build {
            for route in effective.routes {
                for range in provider.manifest.partialEvidence(for: build, route: route) {
                    notes.append("\(route.rawValue): \(range.evidence.rawValue) for \(range.modes.joined(separator: ", ")) only; other modes untested")
                }
            }
        }
        if provider == .codex, installed {
            notes.append("Codex runs the hook only after you review and trust it with /hooks; Shell cannot verify that here")
        }
        notes.append(contentsOf: provider.manifest.coverageExclusions.prefix(3))
        return JSONWriter.object([
            "provider": .string(provider.rawValue),
            "executable": executable.map { .string($0) },
            "build": build.map { .string($0) },
            "hook_installed": .bool(installed),
            "configuration_present": .bool(configuration != nil),
            "readiness": .string(readiness),
            "routes": .array(provider.manifest.routes.map { route in
                .object([
                    "route": .string(route.route.rawValue),
                    "enabled": .bool(effective.routes.contains(route.route)),
                    "evidence": .string(effective.evidence(for: build, route: route.route).rawValue)
                ])
            }),
            "notes": JSONValue(strings: notes)
        ])
    }
}

/// `agent hook claude-code|codex`: invoked by the provider with the native
/// event on stdin. Its stdout is reserved for the provider's response format;
/// diagnostics go to stderr. It always exits 0: an exit status is never
/// authorization (spec.agent-relay.md sections 10.1 and 15.4).
struct AgentHookCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hook", abstract: "Run as a provider hook (reads the event on stdin).")
    @ParentCommand var parent: AgentCommand
    @OptionGroup var state: StateOptions
    @Argument var provider: AgentProvider

    mutating func run() async throws {
        let start = ContinuousClock.now
        let inherited = parent.parent.state.stateDirectory
        let provider = provider
        let root = (try? state.root(inherited)) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/shell-control")
        let input = FileHandle.standardInput.readData(ofLength: AgentPolicy.maximumNativeInputBytes + 1)
        let configuration = AdapterConfiguration.load(root: root, provider: provider) ?? AdapterConfiguration(provider: provider)
        let ownerPID = getppid()
        let detector = ProviderBuildDetector(root: root)
        let executable = configuration.executablePath
        let environment = HookEnvironment(
            provider: provider,
            configuration: configuration,
            daemon: SocketAdapterDaemon(socketPath: state.adapterSocketPath(inherited)),
            detectBuild: { await detector.build(provider: provider, executable: executable) },
            ownerPID: ownerPID,
            ownerAlive: { getppid() == ownerPID },
            effectiveUserID: geteuid(),
            policyFingerprint: { PolicyFingerprint.compute(for: provider, cwd: $0) },
            terminalLocation: { await TerminalLocator.locate() },
            fileSystem: LocalFileSystem(),
            elapsed: { let duration = start.duration(to: .now); return TimeInterval(duration.components.seconds) + TimeInterval(duration.components.attoseconds) / 1e18 },
            log: { message in try? FileHandle.standardError.write(contentsOf: Data("shell-control agent: \(message)\n".utf8)) }
        )
        let outcome: HookOutcome
        if input.count > AgentPolicy.maximumNativeInputBytes {
            outcome = .noDecision("limit_exceeded: native input exceeds the host parsing cap")
        } else {
            outcome = await HookRunner(environment: environment).run(stdin: input)
        }
        environment.log(outcome.note)
        if let stdout = outcome.stdout {
            var framed = stdout
            framed.append(0x0A)
            try? FileHandle.standardOutput.write(contentsOf: framed)
        }
        throw ExitCode(outcome.exitCode)
    }
}

/// `agent test`: the safe end-to-end fixture. It exercises publication,
/// review, signature, claim, native-response encoding, and receipts without
/// executing anything and without a provider (spec.agent-relay.md 19.9).
struct AgentTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Run the safe agent relay fixture through a real reviewer.")
    @ParentCommand var parent: AgentCommand
    @OptionGroup var state: StateOptions
    @Argument var provider: AgentProvider
    @Option(help: "iphone or watch.") var reviewer = "iphone"
    @Option(help: "Seconds to wait for the review.") var timeout = 180

    mutating func validate() throws {
        guard ["iphone", "watch"].contains(reviewer) else { throw ValidationError("--reviewer must be iphone or watch") }
        guard (15...300).contains(timeout) else { throw ValidationError("--timeout must be from 15 through 300") }
    }

    mutating func run() async throws {
        let inherited = parent.parent.state.stateDirectory, state = state, provider = provider
        let forWatch = reviewer == "watch", timeout = timeout
        try await execute {
            let daemon = SocketAdapterDaemon(socketPath: state.adapterSocketPath(inherited))
            let result = try await AgentFixture.run(daemon: daemon, provider: provider, forWatch: forWatch, timeout: timeout)
            try emitJSON(result.document)
            if !result.passed { throw ExitCode(1) }
        }
    }
}

enum AgentFixture {
    static let summary = "Agent relay test — nothing will run"

    static func run(daemon: any AdapterDaemon, provider: AgentProvider, forWatch: Bool, timeout: Int) async throws -> (passed: Bool, document: JSONValue) {
        var run = try await AdapterRun.start(daemon: daemon, adapter: "shell-agent-fixture", jobLabel: "Agent relay test")
        try await run.register(.object([
            "provider": "shell_fixture",
            "provider_build": .string(AdapterManifest.adapterBuild),
            "adapter_build": .string(AdapterManifest.adapterBuild),
            "profile": .string(AgentIntegrationProfile.hook.rawValue),
            "evidence": .string(AgentCompatibilityEvidence.contractTested.rawValue),
            "operations": JSONValue(strings: [AgentFeature.shell])
        ]))
        guard let sessionID = run.agentSessionID else { throw ManagementError.unavailable("no agent session") }
        let hex = ContentDigest.sha256Hex(Data("shell-agent-fixture/1".utf8))
        let operation = try AgentToolOperation(
            provider: "shell_fixture", providerBuild: AdapterManifest.adapterBuild, adapterBuild: AdapterManifest.adapterBuild,
            agentSessionID: sessionID, nativeWaitID: .random(), kind: .shell, toolName: "Bash", cwd: "/",
            reason: "Shell Control agent relay test for \(provider.displayName); the command is never executed.",
            shellRequest: try AgentShellRequest(representation: .commandString, command: "true"),
            unavailable: ["environment", "shell_identity"], nativeRequestSHA256: hex, contextSHA256: hex
        )
        var created = try JSONReader(try await run.send(.approvalRequest, .object([
            "summary": .string(summary), "operation": operation.json,
            "lifetime_seconds": .number(.int(Int64(timeout))),
            "minimum_review": .string((forWatch ? MinimumReview.watch : .full).rawValue)
        ])))
        let requestID = try created.id("request_id"), requestHash = try created.string("request_hash", maxLength: 80)
        FileHandle.standardError.write(Data("published \(requestID.rawValue); approve or reject it on your \(forWatch ? "Watch" : "iPhone")\n".utf8))
        let waited = try ApprovalWaitOutcome(json: try await run.send(.approvalWait, .object([
            "request_id": JSONValue(requestID), "request_hash": .string(requestHash), "timeout_seconds": .number(.int(Int64(timeout)))
        ]), timeout: TimeInterval(timeout + 10)))
        func receipt(_ dispatch: AgentDispatch, decision: ControlID?, consume: ControlID?, evidence: String) async throws {
            _ = try await run.send(.agentReceipt, JSONWriter.object([
                "request_kind": "approval", "request_id": JSONValue(requestID), "request_hash": .string(requestHash),
                "native_wait_id": JSONValue(operation.nativeWaitID), "decision_id": decision.map { JSONValue($0) },
                "consume_id": consume.map { JSONValue($0) }, "dispatch": .string(dispatch.rawValue), "evidence": .string(evidence)
            ]))
        }
        switch waited {
        case .approved(let permit):
            let encoded = HookRunner.permissionResponse(allow: true, message: nil, provider: provider)
            try await receipt(.dispatchStarted, decision: permit.decisionID, consume: permit.consumeID, evidence: "fixture_dispatch_journaled")
            // The native response is encoded and checked, never sent to a
            // provider, and nothing is executed.
            let valid = (try? JSONValue.parse(encoded))?["hookSpecificOutput"]?["decision"]?["behavior"]?.stringValue == "allow"
            try await receipt(valid ? .notApplied : .unknown, decision: permit.decisionID, consume: permit.consumeID, evidence: "fixture_noop")
            return (valid, .object(["result": "approved", "request_id": JSONValue(requestID), "native_response_valid": .bool(valid)]))
        case .rejected(let decisionID):
            try await receipt(.dispatchStarted, decision: decisionID, consume: nil, evidence: "fixture_dispatch_journaled")
            try await receipt(.notApplied, decision: decisionID, consume: nil, evidence: "fixture_noop")
            return (true, .object(["result": "rejected", "request_id": JSONValue(requestID)]))
        case .expired, .cancelled, .unavailable:
            return (false, .object(["result": waited.json, "request_id": JSONValue(requestID)]))
        }
    }
}

/// `agent launch`: runs the ordinary provider CLI with the hook profile, or —
/// only with an explicit `--managed` — the experimental managed Codex
/// profile. It never silently converts one into the other (spec 19.7).
struct AgentLaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Start the provider CLI with Shell's hooks in place, or a managed Codex session.",
        discussion: """
        --managed (Codex only, experimental) runs `codex app-server` owned by this command: approvals and questions \
        go to Shell Control and can also be answered here, and enrolled devices with agent.messages.send or \
        agent.turns.cancel can start, steer, or interrupt turns. There is no Codex TUI in this mode.
        """
    )
    @ParentCommand var parent: AgentCommand
    @OptionGroup var state: StateOptions
    @Argument var provider: AgentProvider
    @Flag(help: "Codex only: run the experimental managed app-server profile.") var managed = false
    @Option(help: "Managed only: resume this Codex thread.") var thread: String?
    @Argument(parsing: .postTerminator) var arguments: [String] = []

    mutating func run() async throws {
        let inherited = parent.parent.state.stateDirectory
        let root = try state.root(inherited)
        let configuration = AdapterConfiguration.load(root: root, provider: provider)
        guard let executable = configuration?.executablePath ?? ProviderBuildDetector.locate(provider.manifest.executable) else {
            throw ManagementError.unavailable("\(provider.manifest.executable) was not found on PATH")
        }
        if managed {
            guard provider == .codex else { throw ManagementError.invalid("--managed applies to codex only") }
            try await ManagedLaunch.run(root: root, socketPath: state.adapterSocketPath(inherited),
                                        configuration: configuration ?? AdapterConfiguration(provider: .codex),
                                        executable: executable, thread: thread)
            return
        }
        if !HookInstaller(provider: provider, command: "").hasOwnedStanza() {
            stderr("note: Shell's hooks are not installed for \(provider.displayName); run shell-control agent install \(provider.rawValue)")
        }
        let argv = [executable] + arguments
        var cArguments = argv.map { strdup($0) } + [nil]
        execv(executable, &cArguments)
        throw ManagementError.unavailable("could not start \(executable): \(String(cString: strerror(errno)))")
    }
}

enum ManagedLaunch {
    static func run(root: URL, socketPath: String, configuration: AdapterConfiguration, executable: String, thread: String?) async throws {
        guard configuration.routes.contains(where: \.isManaged) else {
            throw ManagementError.invalid("run `shell-control agent install codex --enable-managed` first")
        }
        guard let build = await ProviderBuildDetector(root: root).build(provider: .codex, executable: executable) else {
            throw ManagementError.unavailable("could not read the Codex build; managed mode needs a known build")
        }
        let cwd = FileManager.default.currentDirectoryPath
        let transport = try ProcessJSONRPCTransport(executable: executable, arguments: ["app-server"], currentDirectory: cwd)
        let pid = transport.process.processIdentifier
        let owner = ProcessIdentity.of(pid: pid)
        let environment = ManagedEnvironment(
            configuration: configuration, build: build,
            daemon: SocketAdapterDaemon(socketPath: socketPath),
            cwd: cwd, resumeThreadID: thread, ownerPID: pid, ownerAlive: { owner?.isAlive ?? false },
            effectiveUserID: geteuid(), policyFingerprint: { PolicyFingerprint.compute(for: .codex, cwd: $0) },
            terminalLocation: { await TerminalLocator.locate() }, fileSystem: LocalFileSystem(),
            log: { stderr("shell-control agent: \($0)") }
        )
        let session = CodexManagedSession(environment: environment, terminal: StandardManagedTerminal(), transport: transport)
        do {
            try await session.start()
        } catch {
            await session.stop()
            throw ManagementError.unavailable("managed Codex could not start: \(error)")
        }
        await session.runTerminal()
        await session.stop()
    }
}

struct AgentGrantCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grant",
        abstract: "Let one enrolled iPhone or Watch read and answer agent questions.",
        discussion: "Agent grants are separate from approval grants and revocable with --revoke."
    )
    @ParentCommand var parent: AgentCommand
    @OptionGroup var state: StateOptions
    @Argument(help: "The device ID from shell-control status.") var deviceID: String
    @Flag(help: "Remove the agent grants instead.") var revoke = false
    @Flag(help: "iPhone only: also allow sending instructions to managed sessions (agent.messages.send).") var messages = false
    @Flag(help: "iPhone only: also allow interrupting managed-session turns (agent.turns.cancel).") var cancel = false

    mutating func validate() throws {
        guard UUID(uuidString: deviceID) != nil else { throw ValidationError("device ID must be a UUID") }
    }

    mutating func run() async throws {
        let inherited = parent.parent.state.stateDirectory, state = state, id = deviceID.lowercased(), revoke = revoke
        let messages = messages, cancel = cancel
        try await execute {
            let loaded = try InstallationStore(root: try state.root(inherited)).load()
            let admin = ControlAdminClient(port: loaded.installation.port, adminSecret: loaded.secrets.adminSecret)
            let result = try await admin.send(method: "POST", path: "/v1/admin/devices/\(id)/agent-grants", body: .object([
                "enabled": .bool(!revoke), "messages": .bool(messages), "cancel": .bool(cancel)
            ]))
            let grants = result["grants"]?.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? ""
            stderr("\(revoke ? "revoked agent grants from" : "granted agent access to") \(id): \(grants)")
        }
    }
}

/// `agent allow-build`: an explicit, visible user attestation for an untested
/// provider build. It never makes the integration "Ready".
struct AgentAllowBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "allow-build",
        abstract: "Allow remote answers for an untested provider build (user-attested, not Ready)."
    )
    @ParentCommand var parent: AgentCommand
    @OptionGroup var state: StateOptions
    @Argument var provider: AgentProvider
    @Argument(help: "The exact provider build, e.g. 2.1.281.") var build: String
    @Flag(help: "Confirm without prompting.") var yes = false
    @Flag(help: "Remove the attestation.") var remove = false

    mutating func validate() throws {
        guard BuildVersion(build) != nil else { throw ValidationError("build must be a dotted version") }
    }

    mutating func run() async throws {
        let inherited = parent.parent.state.stateDirectory, state = state, provider = provider, build = build
        let yes = yes, remove = remove
        try await execute {
            let root = try stateRoot(state, inherited)
            var configuration = AdapterConfiguration.load(root: root, provider: provider) ?? AdapterConfiguration(provider: provider)
            if remove {
                configuration.userAttestedBuilds.removeAll { $0 == build }
            } else {
                stderr("""
                \(provider.displayName) \(build) has no contract evidence in this release. Remote approvals will use \
                decoders built from provider documentation, and the integration will be reported user_attested, not Ready.
                """)
                if !yes {
                    guard let answer = try await TerminalPrompt.ask("Allow \(provider.displayName) \(build)? [y/N] "),
                          ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                        stderr("not changed")
                        throw ExitCode(1)
                    }
                }
                if !configuration.userAttestedBuilds.contains(build) { configuration.userAttestedBuilds.append(build) }
            }
            try configuration.save(root: root)
            stderr("\(remove ? "removed" : "recorded") user attestation for \(provider.displayName) \(build)")
        }
    }
}
