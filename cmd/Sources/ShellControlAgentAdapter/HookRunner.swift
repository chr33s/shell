import Foundation
import ShellControlProtocol
import ShellControlHostSupport

/// What the hook process writes and how it exits. `stdout == nil` means no
/// decision: the provider's own terminal prompt applies.
public struct HookOutcome: Sendable, Equatable {
    public var stdout: Data?
    public var exitCode: Int32
    /// A short machine code for diagnostics (stderr only; never stdout).
    public var note: String

    public static func noDecision(_ note: String) -> HookOutcome { HookOutcome(stdout: nil, exitCode: 0, note: note) }
}

/// Everything the hook touches outside itself, injectable for tests.
public struct HookEnvironment: Sendable {
    public var provider: AgentProvider
    public var configuration: AdapterConfiguration
    public var daemon: any AdapterDaemon
    public var detectBuild: @Sendable () async -> String?
    /// The provider process: the hook's parent.
    public var ownerPID: Int32
    public var ownerAlive: @Sendable () -> Bool
    public var effectiveUserID: UInt32
    public var policyFingerprint: @Sendable (_ cwd: String) -> String
    public var terminalLocation: @Sendable () async -> TerminalLocation?
    public var fileSystem: any AdapterFileSystem
    /// Monotonic elapsed time since the hook started; a wall-clock jump can
    /// never lengthen the local deadline (docs/specs/agent-relay.md section 17).
    public var elapsed: @Sendable () -> TimeInterval
    public var now: @Sendable () -> ControlTimestamp
    public var log: @Sendable (String) -> Void

    public init(
        provider: AgentProvider,
        configuration: AdapterConfiguration,
        daemon: any AdapterDaemon,
        detectBuild: @escaping @Sendable () async -> String?,
        ownerPID: Int32,
        ownerAlive: @escaping @Sendable () -> Bool,
        effectiveUserID: UInt32,
        policyFingerprint: @escaping @Sendable (String) -> String,
        terminalLocation: @escaping @Sendable () async -> TerminalLocation?,
        fileSystem: any AdapterFileSystem,
        elapsed: @escaping @Sendable () -> TimeInterval,
        now: @escaping @Sendable () -> ControlTimestamp = { ControlTimestamp(Date()) },
        log: @escaping @Sendable (String) -> Void
    ) {
        self.provider = provider
        self.configuration = configuration
        self.daemon = daemon
        self.detectBuild = detectBuild
        self.ownerPID = ownerPID
        self.ownerAlive = ownerAlive
        self.effectiveUserID = effectiveUserID
        self.policyFingerprint = policyFingerprint
        self.terminalLocation = terminalLocation
        self.fileSystem = fileSystem
        self.elapsed = elapsed
        self.now = now
        self.log = log
    }
}

/// `shell-control agent hook claude-code|codex`: one synchronous native hook
/// invocation (docs/specs/agent-relay.md sections 9 and 10).
///
/// Before publication, anything unsupported or unavailable hands the prompt
/// back to the terminal. After publication, failure produces a native denial
/// while the hook is alive. A granted permission is written only after a
/// validated claim, a local recheck, and a journaled `dispatch_started`.
public struct HookRunner: Sendable {
    public let environment: HookEnvironment

    /// Review is at most 300 s, the hook stops waiting by 330 s after entry,
    /// and the tested outer timeout is 360 s. Setup time is subtracted, never
    /// added (docs/specs/agent-relay.md 9.2).
    public static let reviewWindow: TimeInterval = AgentPolicy.defaultLifetime
    public static let internalDeadline: TimeInterval = AgentPolicy.hookInternalDeadline
    /// Time kept back after the wait for recheck, write, and receipts.
    public static let dispatchMargin: TimeInterval = 10
    public static let minimumUsefulReview: TimeInterval = 15

    public init(environment: HookEnvironment) { self.environment = environment }

    private var env: HookEnvironment { environment }

    public func run(stdin data: Data) async -> HookOutcome {
        if let ended = await sessionEnd(data) { return ended }
        let input: NativeHookInput
        do {
            input = try NativeHookInput.decode(data, provider: env.provider)
        } catch {
            return .noDecision("\(error)")
        }
        guard let route = input.route, env.configuration.routes.contains(route) else {
            await attention(input, reason: "unsupported_operation")
            return .noDecision("unsupported_operation: \(input.toolName) is not an enabled route")
        }
        let build = await env.detectBuild()
        let evidence = env.configuration.evidence(for: build, route: route)
        guard let build, evidence.permitsRemoteResponse else {
            // Unknown or untested builds are informational only.
            await attention(input, reason: "unsupported_provider_version")
            return .noDecision("unsupported_provider_version: \(build ?? "unknown") has \(evidence.rawValue) evidence")
        }
        var run: AdapterRun
        do {
            run = try await AdapterRun.start(daemon: env.daemon, adapter: env.provider.rawValue,
                                             jobLabel: "\(env.provider.displayName): \(input.toolName)")
            try await run.register(registration(input: input, build: build))
        } catch {
            return .noDecision("control_unavailable: \(error)")
        }
        switch route {
        case .askUserQuestion:
            return await question(input, run: run, build: build)
        case .permissionShell, .permissionFileChange:
            return await permission(input, run: run, build: build)
        default:
            return .noDecision("unsupported_operation: managed routes are not hook routes")
        }
    }

    private func registration(input: NativeHookInput, build: String) async -> JSONValue {
        let operations = env.configuration.routes
            .filter { !$0.isManaged && env.configuration.evidence(for: build, route: $0).permitsRemoteResponse }
            .map(\.feature)
        return JSONWriter.object([
            "provider": .string(env.provider.wireName),
            "provider_build": .string(build),
            "adapter_build": .string(AdapterManifest.adapterBuild),
            "profile": .string(AgentIntegrationProfile.hook.rawValue),
            "evidence": .string(sessionEvidence(build: build).rawValue),
            "operations": JSONValue(strings: Array(Set(operations)).sorted()),
            "provider_session_id": input.sessionID.map { .string(String($0.prefix(256))) },
            "policy_fingerprint": .string(env.policyFingerprint(input.cwd)),
            "terminal_location": await env.terminalLocation()?.json,
            "owner_pid": .number(.int(Int64(env.ownerPID)))
        ])
    }

    /// One evidence level per session, identical for every invocation: the
    /// weakest among the routes it may answer.
    private func sessionEvidence(build: String) -> AgentCompatibilityEvidence {
        env.configuration.routes
            .filter { !$0.isManaged }
            .map { env.configuration.evidence(for: build, route: $0) }
            .filter(\.permitsRemoteResponse)
            .min() ?? .documented
    }

    private func remainingWait() -> TimeInterval {
        min(Self.reviewWindow, Self.internalDeadline - env.elapsed() - Self.dispatchMargin)
    }

    // MARK: Permission requests

    private func permission(_ input: NativeHookInput, run: AdapterRun, build: String) async -> HookOutcome {
        guard let sessionID = run.agentSessionID else { return .noDecision("control_unavailable: no agent session") }
        let fingerprint = env.policyFingerprint(input.cwd)
        var context = AdapterContext(providerBuild: build, agentSessionID: sessionID, nativeWaitID: .random(),
                                     effectiveUserID: env.effectiveUserID, policyFingerprint: fingerprint)
        let operation: AgentToolOperation
        do {
            operation = try OperationMapper.operation(for: input, context: &context, fileSystem: env.fileSystem)
        } catch {
            await attention(input, reason: "unsupported_operation", run: run)
            return .noDecision("\(error)")
        }
        let window = remainingWait()
        guard window >= Self.minimumUsefulReview else { return .noDecision("deadline: setup left no review time") }
        let review: MinimumReview = env.configuration.watchShellApproval && operation.isWatchEligible ? .watch : .full

        let published: (requestID: ControlID, requestHash: String)
        do {
            var reader = try JSONReader(try await run.send(.approvalRequest, .object([
                "summary": .string(Self.summary(for: operation)),
                "operation": operation.json,
                "lifetime_seconds": .number(.int(Int64(window))),
                "minimum_review": .string(review.rawValue)
            ])))
            published = (try reader.id("request_id"), try reader.string("request_hash", maxLength: 80))
        } catch {
            return .noDecision("control_unavailable: \(error)")
        }

        // Published: from here every failure is a native denial.
        let outcome: ApprovalWaitOutcome
        do {
            let waitSeconds = max(1, Int64(Self.internalDeadline - env.elapsed() - Self.dispatchMargin))
            let body = try await run.send(.approvalWait, .object([
                "request_id": JSONValue(published.requestID),
                "request_hash": .string(published.requestHash),
                "timeout_seconds": .number(.int(waitSeconds))
            ]), timeout: TimeInterval(waitSeconds) + 5)
            outcome = try ApprovalWaitOutcome(json: body)
        } catch {
            return await systemDenial(run: run, published: published, waitID: context.nativeWaitID,
                                      evidence: "broker_unavailable", message: "Shell Control could not complete the remote review.")
        }

        switch outcome {
        case .approved(let permit):
            return await allow(permit: permit, operation: operation, run: run, published: published, fingerprint: fingerprint, input: input)
        case .rejected(let decisionID):
            return await write(Self.permissionResponse(allow: false, message: "Denied by the reviewer in Shell Control.", provider: env.provider),
                               kind: .approval, run: run, published: published, waitID: context.nativeWaitID,
                               decisionID: decisionID, evidence: "hook_stdout_written")
        case .expired, .cancelled, .unavailable:
            return await systemDenial(run: run, published: published, waitID: context.nativeWaitID,
                                      evidence: "no_remote_decision", message: "No remote decision in Shell Control before the deadline.")
        }
    }

    private func allow(permit: ConsumePermit, operation: AgentToolOperation, run: AdapterRun,
                       published: (requestID: ControlID, requestHash: String), fingerprint: String,
                       input: NativeHookInput) async -> HookOutcome {
        let waitID = operation.nativeWaitID
        // The permit must name this run and request, carry an approval, and
        // still be inside its deadline; the signed decision must agree.
        guard permit.runID == run.runID, ContentDigest.matches(permit.requestHash, published.requestHash),
              permit.decision == .approve, Self.decisionApproves(permit.decisionJWS, requestHash: published.requestHash),
              permit.isApplicable(at: env.now()) else {
            return await refuseClaim(run: run, published: published, permit: permit, waitID: waitID,
                                     evidence: "permit_invalid", message: "Shell Control could not verify the approval.")
        }
        guard env.ownerAlive() else {
            await receipt(run: run, kind: .approval, published: published, waitID: waitID, decisionID: permit.decisionID,
                          consumeID: permit.consumeID, dispatch: .notApplied, evidence: "native_wait_gone")
            return .noDecision("native_wait_gone")
        }
        do {
            try OperationMapper.recheck(operation, fileSystem: env.fileSystem)
            guard env.policyFingerprint(input.cwd) == fingerprint else {
                throw AdapterRefusal("native_context_changed", "provider permission policy changed")
            }
        } catch {
            return await refuseClaim(run: run, published: published, permit: permit, waitID: waitID,
                                     evidence: "native_context_changed", message: "The operation changed after review; denied.")
        }
        // Journaled before the first possible write to the provider; without
        // it, no allow is written.
        do {
            _ = try await run.send(.agentReceipt, receiptBody(kind: .approval, published: published, waitID: waitID,
                                                             decisionID: permit.decisionID, consumeID: permit.consumeID,
                                                             dispatch: .dispatchStarted, evidence: "dispatch_journaled"))
        } catch {
            return HookOutcome(stdout: Self.permissionResponse(allow: false, message: "Shell Control could not record the dispatch; denied.", provider: env.provider),
                               exitCode: 0, note: "dispatch_not_journaled")
        }
        let response = Self.permissionResponse(allow: true, message: nil, provider: env.provider)
        await receipt(run: run, kind: .approval, published: published, waitID: waitID, decisionID: permit.decisionID,
                      consumeID: permit.consumeID, dispatch: .nativeResponseWritten, evidence: "hook_stdout_written")
        return HookOutcome(stdout: response, exitCode: 0, note: "allowed")
    }

    /// A claimed approval that is not written as an allow: the gate is
    /// denied, and the claim is reported not applied with positive evidence.
    private func refuseClaim(run: AdapterRun, published: (requestID: ControlID, requestHash: String), permit: ConsumePermit,
                             waitID: ControlID, evidence: String, message: String) async -> HookOutcome {
        await receipt(run: run, kind: .approval, published: published, waitID: waitID, decisionID: permit.decisionID,
                      consumeID: permit.consumeID, dispatch: .notApplied, evidence: evidence, systemOutcome: true)
        return HookOutcome(stdout: Self.permissionResponse(allow: false, message: message, provider: env.provider), exitCode: 0, note: evidence)
    }

    /// An adapter-generated denial: labelled a system outcome, never a user
    /// rejection (docs/specs/agent-relay.md 8.1).
    private func systemDenial(run: AdapterRun, published: (requestID: ControlID, requestHash: String), waitID: ControlID,
                              evidence: String, message: String) async -> HookOutcome {
        _ = try? await run.send(.approvalWithdraw, .object([
            "request_id": JSONValue(published.requestID), "request_hash": .string(published.requestHash)
        ]))
        return await write(Self.permissionResponse(allow: false, message: message, provider: env.provider),
                           kind: .approval, run: run, published: published, waitID: waitID,
                           evidence: evidence, systemOutcome: true)
    }

    private func write(_ response: Data, kind: AgentRequestKind, run: AdapterRun, published: (requestID: ControlID, requestHash: String),
                       waitID: ControlID, decisionID: ControlID? = nil, evidence: String, systemOutcome: Bool = false) async -> HookOutcome {
        await receipt(run: run, kind: kind, published: published, waitID: waitID, decisionID: decisionID,
                      dispatch: .dispatchStarted, evidence: "dispatch_journaled", systemOutcome: systemOutcome)
        await receipt(run: run, kind: kind, published: published, waitID: waitID, decisionID: decisionID,
                      dispatch: .nativeResponseWritten, evidence: evidence, systemOutcome: systemOutcome)
        return HookOutcome(stdout: response, exitCode: 0, note: evidence)
    }

    // MARK: Questions

    private func question(_ input: NativeHookInput, run: AdapterRun, build: String) async -> HookOutcome {
        let mapping: QuestionMapping
        do {
            mapping = try QuestionMapping.make(from: input)
        } catch {
            await attention(input, reason: "unsupported_input_schema", run: run)
            return .noDecision("\(error)")
        }
        guard let sessionID = run.agentSessionID else { return .noDecision("control_unavailable: no agent session") }
        let waitID = ControlID.random()
        let context = AdapterContext(providerBuild: build, agentSessionID: sessionID, nativeWaitID: waitID,
                                     effectiveUserID: env.effectiveUserID, policyFingerprint: env.policyFingerprint(input.cwd))
        let window = remainingWait()
        guard window >= Self.minimumUsefulReview else { return .noDecision("deadline: setup left no review time") }
        let watchSized = mapping.questions.count <= AgentPolicy.watchMaximumQuestions
            && mapping.questions.allSatisfy { $0.kind.choices.count <= AgentPolicy.watchMaximumChoices }
        let published: (requestID: ControlID, requestHash: String)
        do {
            var reader = try JSONReader(try await run.send(.inputRequest, JSONWriter.object([
                "summary": .string(Self.questionSummary(mapping, provider: env.provider)),
                "questions": .array(mapping.questions.map(\.json)),
                // No tested native decline mapping: only answers are offered,
                // and expiry never invents one (docs/specs/agent-relay.md 6.3).
                "allowed_responses": JSONValue(strings: [InputAllowedResponse.answer.rawValue]),
                "minimum_review": .string((watchSized ? MinimumReview.watch : .full).rawValue),
                "lifetime_seconds": .number(.int(Int64(window))),
                "native_request_sha256": .string(input.nativeRequestSHA256),
                "context_sha256": .string(context.contextSHA256(for: input)),
                "answer_mapping_sha256": .string(mapping.mapping.sha256Hex),
                "native_wait_id": JSONValue(waitID),
                "provider_turn_id": input.turnID.map { .string($0) }
            ])))
            published = (try reader.id("request_id"), try reader.string("request_hash", maxLength: 80))
        } catch {
            return .noDecision("control_unavailable: \(error)")
        }

        let body: JSONValue
        do {
            let waitSeconds = max(1, Int64(Self.internalDeadline - env.elapsed() - Self.dispatchMargin))
            body = try await run.send(.inputWait, .object([
                "request_id": JSONValue(published.requestID),
                "request_hash": .string(published.requestHash),
                "timeout_seconds": .number(.int(min(waitSeconds, Int64(AgentPolicy.maximumLifetime))))
            ]), timeout: TimeInterval(waitSeconds) + 5)
        } catch {
            _ = try? await run.send(.inputWithdraw, .object(["request_id": JSONValue(published.requestID), "request_hash": .string(published.requestHash)]))
            return .noDecision("no_remote_answer: \(error)")
        }
        var reader: JSONReader
        do { reader = try JSONReader(body) } catch { return .noDecision("response_invalid") }
        guard (try? reader.string("outcome", maxLength: 24)) == "answered",
              let permitValue = reader.optionalValue("permit"), let specValue = reader.optionalValue("spec"),
              let permit = try? InputConsumePermit(json: permitValue), let spec = try? InputSpec(json: specValue) else {
            // Expired, withdrawn, declined, or unavailable: the question
            // stays with the terminal; no answer is invented.
            _ = try? await run.send(.inputWithdraw, .object(["request_id": JSONValue(published.requestID), "request_hash": .string(published.requestHash)]))
            return .noDecision("no_remote_answer")
        }
        let updated: JSONValue
        do {
            try InputPermitBinding.validate(
                permit, spec: spec, requestID: published.requestID, requestHash: published.requestHash,
                runID: run.runID, nativeWaitID: waitID, answerMappingSHA256: mapping.mapping.sha256Hex,
                now: env.now(), ownerAlive: env.ownerAlive()
            )
            updated = try mapping.updatedInput(for: permit.response, committedMappingSHA256: spec.source.answerMappingSHA256)
        } catch {
            await inputReceipt(run: run, published: published, waitID: waitID, permit: permit, dispatch: .notApplied, evidence: "response_not_dispatched")
            return .noDecision("\(error)")
        }
        do {
            _ = try await run.send(.agentReceipt, inputReceiptBody(published: published, waitID: waitID, permit: permit,
                                                                  dispatch: .dispatchStarted, evidence: "dispatch_journaled"))
        } catch {
            return .noDecision("dispatch_not_journaled")
        }
        let response = Self.questionResponse(updatedInput: updated)
        await inputReceipt(run: run, published: published, waitID: waitID, permit: permit, dispatch: .nativeResponseWritten, evidence: "hook_stdout_written")
        return HookOutcome(stdout: response, exitCode: 0, note: "answered")
    }

    // MARK: Session end

    /// `SessionEnd`: the provider session is over, so anything still pending
    /// for it is withdrawn. Informational; it never decides anything.
    private func sessionEnd(_ data: Data) async -> HookOutcome? {
        guard data.count <= AgentPolicy.maximumNativeInputBytes,
              let raw = try? JSONValue.parse(data, limits: NativeHookInput.limits),
              raw["hook_event_name"]?.stringValue == "SessionEnd" else { return nil }
        guard let build = await env.detectBuild() else { return .noDecision("session_end: unknown build") }
        let routes = env.configuration.routes.filter { !$0.isManaged && env.configuration.evidence(for: build, route: $0).permitsRemoteResponse }
        guard !routes.isEmpty else { return .noDecision("session_end: informational build") }
        do {
            var run = try await AdapterRun.start(daemon: env.daemon, adapter: env.provider.rawValue, jobLabel: "\(env.provider.displayName) session")
            let cwd = raw["cwd"]?.stringValue ?? "/"
            try await run.register(JSONWriter.object([
                "provider": .string(env.provider.wireName),
                "provider_build": .string(build),
                "adapter_build": .string(AdapterManifest.adapterBuild),
                "profile": .string(AgentIntegrationProfile.hook.rawValue),
                "evidence": .string(sessionEvidence(build: build).rawValue),
                "operations": JSONValue(strings: Array(Set(routes.map(\.feature))).sorted()),
                "provider_session_id": raw["session_id"]?.stringValue.map { .string(String($0.prefix(256))) },
                "policy_fingerprint": .string(env.policyFingerprint(cwd.hasPrefix("/") ? cwd : "/")),
                "terminal_location": await env.terminalLocation()?.json,
                "owner_pid": .number(.int(Int64(env.ownerPID)))
            ]))
            _ = try await run.send(.agentEvent, .object(["type": .string(AgentEventType.sessionEnded.rawValue)]))
            return .noDecision("session_end: reported")
        } catch {
            return .noDecision("session_end: \(error)")
        }
    }

    // MARK: Receipts and attention

    private func receiptBody(kind: AgentRequestKind, published: (requestID: ControlID, requestHash: String), waitID: ControlID,
                             decisionID: ControlID? = nil, consumeID: ControlID? = nil, dispatch: AgentDispatch,
                             evidence: String, systemOutcome: Bool = false) -> JSONValue {
        JSONWriter.object([
            "request_kind": .string(kind.rawValue),
            "request_id": JSONValue(published.requestID),
            "request_hash": .string(published.requestHash),
            "native_wait_id": JSONValue(waitID),
            "decision_id": decisionID.map { JSONValue($0) },
            "consume_id": consumeID.map { JSONValue($0) },
            "dispatch": .string(dispatch.rawValue),
            "evidence": .string(evidence),
            "system_outcome": .bool(systemOutcome)
        ])
    }

    private func receipt(run: AdapterRun, kind: AgentRequestKind, published: (requestID: ControlID, requestHash: String), waitID: ControlID,
                         decisionID: ControlID? = nil, consumeID: ControlID? = nil, dispatch: AgentDispatch,
                         evidence: String, systemOutcome: Bool = false) async {
        do {
            _ = try await run.send(.agentReceipt, receiptBody(kind: kind, published: published, waitID: waitID, decisionID: decisionID,
                                                             consumeID: consumeID, dispatch: dispatch, evidence: evidence,
                                                             systemOutcome: systemOutcome))
        } catch {
            env.log("receipt \(dispatch.rawValue) not recorded: \(error)")
        }
    }

    private func inputReceiptBody(published: (requestID: ControlID, requestHash: String), waitID: ControlID, permit: InputConsumePermit,
                                  dispatch: AgentDispatch, evidence: String) -> JSONValue {
        .object([
            "request_kind": .string(AgentRequestKind.input.rawValue),
            "request_id": JSONValue(published.requestID),
            "request_hash": .string(published.requestHash),
            "native_wait_id": JSONValue(waitID),
            "command_id": JSONValue(permit.commandID),
            "permit_id": JSONValue(permit.permitID),
            "dispatch": .string(dispatch.rawValue),
            "evidence": .string(evidence)
        ])
    }

    private func inputReceipt(run: AdapterRun, published: (requestID: ControlID, requestHash: String), waitID: ControlID,
                              permit: InputConsumePermit, dispatch: AgentDispatch, evidence: String) async {
        do {
            _ = try await run.send(.agentReceipt, inputReceiptBody(published: published, waitID: waitID, permit: permit, dispatch: dispatch, evidence: evidence))
        } catch {
            env.log("receipt \(dispatch.rawValue) not recorded: \(error)")
        }
    }

    /// A generic, non-authorizing attention hint for a prompt that stays in
    /// the terminal. Best effort, bounded, and never carrying the command.
    private func attention(_ input: NativeHookInput, reason: String, run: AdapterRun? = nil) async {
        let title = "\(env.provider.displayName) is waiting in the terminal"
        let body = "\(input.toolName) needs review on the Mac (\(reason))."
        do {
            let active: AdapterRun
            if let run { active = run } else {
                active = try await AdapterRun.start(daemon: env.daemon, adapter: env.provider.rawValue, jobLabel: title)
            }
            _ = try await active.send(.notify, .object([
                "kind": "attention", "title": .string(title), "body": .string(String(body.unicodeScalars.prefix(1000)))
            ]), timeout: 2)
        } catch {
            env.log("attention hint not sent: \(error)")
        }
    }

    // MARK: Encodings

    /// The native `PermissionRequest` decision. No permission updates, rules,
    /// modified arguments, or mode changes are ever included: they would alter
    /// what the reviewer approved (docs/specs/agent-relay.md 9.1, 10.1).
    public static func permissionResponse(allow: Bool, message: String?, provider: AgentProvider) -> Data {
        var decision: [String: JSONValue] = ["behavior": .string(allow ? "allow" : "deny")]
        if !allow, let message { decision["message"] = .string(String(message.prefix(200))) }
        let value = JSONValue.object(["hookSpecificOutput": .object([
            "hookEventName": "PermissionRequest",
            "decision": .object(decision)
        ])])
        return (try? JSONCanonicalization.canonicalize(value)) ?? Data()
    }

    /// The native `PreToolUse` answer for `AskUserQuestion`.
    public static func questionResponse(updatedInput: JSONValue) -> Data {
        let value = JSONValue.object(["hookSpecificOutput": .object([
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": updatedInput
        ])])
        return (try? JSONCanonicalization.canonicalize(value)) ?? Data()
    }

    static func summary(for operation: AgentToolOperation) -> String {
        let detail: String
        switch operation.kind {
        case .shell: detail = operation.shellRequest?.command ?? ""
        case .fileChange: detail = operation.fileChanges?.map(\.path).joined(separator: ", ") ?? ""
        default: detail = ""
        }
        let text = "\(operation.toolName): \(detail.replacingOccurrences(of: "\n", with: " "))"
        return String(text.unicodeScalars.prefix(AgentPolicy.maximumSummaryScalars - 1)) + (text.unicodeScalars.count >= AgentPolicy.maximumSummaryScalars ? "…" : "")
    }

    static func questionSummary(_ mapping: QuestionMapping, provider: AgentProvider) -> String {
        let first = mapping.questions.first?.prompt ?? ""
        let text = "\(provider.displayName) asks: \(first.replacingOccurrences(of: "\n", with: " "))"
        return String(text.unicodeScalars.prefix(AgentPolicy.maximumSummaryScalars))
    }

    /// The device's signed decision must itself approve this exact request.
    static func decisionApproves(_ jws: String, requestHash: String) -> Bool {
        guard let payload = try? SignedPayloadReader.payload(ofCompactJWS: jws),
              let command = try? ApprovalDecideCommand(json: payload) else { return false }
        return command.decision == .approve && ContentDigest.matches(command.requestHash, requestHash)
    }
}
