import Foundation
import ShellControlProtocol

/// The local terminal of a managed session: agent output is written here and
/// typed lines are read from here. It is the managed profile's own console,
/// not a PTY Shell controls (docs/specs/agent-relay.md sections 10.3 and 13.2).
public protocol ManagedTerminal: Sendable {
    func write(_ text: String)
    var lines: AsyncStream<String> { get }
}

/// Everything a managed Codex session touches outside itself.
public struct ManagedEnvironment: Sendable {
    public var configuration: AdapterConfiguration
    public var build: String
    public var daemon: any AdapterDaemon
    public var cwd: String
    public var resumeThreadID: String?
    /// The app-server process that owns the native waits.
    public var ownerPID: Int32
    public var ownerAlive: @Sendable () -> Bool
    public var effectiveUserID: UInt32
    public var policyFingerprint: @Sendable (_ cwd: String) -> String
    public var terminalLocation: @Sendable () async -> TerminalLocation?
    public var fileSystem: any AdapterFileSystem
    public var now: @Sendable () -> ControlTimestamp
    public var log: @Sendable (String) -> Void
    /// How long a mobile session-command wait lasts before it is renewed.
    public var commandWaitSeconds: Int64

    public init(configuration: AdapterConfiguration, build: String, daemon: any AdapterDaemon, cwd: String, resumeThreadID: String? = nil,
                ownerPID: Int32, ownerAlive: @escaping @Sendable () -> Bool, effectiveUserID: UInt32,
                policyFingerprint: @escaping @Sendable (String) -> String, terminalLocation: @escaping @Sendable () async -> TerminalLocation?,
                fileSystem: any AdapterFileSystem, now: @escaping @Sendable () -> ControlTimestamp = { ControlTimestamp(Date()) },
                log: @escaping @Sendable (String) -> Void, commandWaitSeconds: Int64 = 30) {
        self.configuration = configuration
        self.build = build
        self.daemon = daemon
        self.cwd = cwd
        self.resumeThreadID = resumeThreadID
        self.ownerPID = ownerPID
        self.ownerAlive = ownerAlive
        self.effectiveUserID = effectiveUserID
        self.policyFingerprint = policyFingerprint
        self.terminalLocation = terminalLocation
        self.fileSystem = fileSystem
        self.now = now
        self.log = log
        self.commandWaitSeconds = commandWaitSeconds
    }
}

/// The experimental managed Codex profile: this adapter owns the only
/// `codex app-server` connection and therefore the request-routing path
/// (docs/specs/agent-relay.md sections 3.1, 10.2, 10.3, and 15).
///
/// Native approval and input requests are published to Shell with their
/// exact JSON-RPC identity and connection epoch, and answered at most once —
/// from a validated Shell permit or locally in this terminal, whichever wins
/// the withdraw/claim race. Mobile instructions, steering, and cancellation
/// arrive as claimed, signed session commands. A remote question that is not
/// answered stays local; no answer is ever invented.
public actor CodexManagedSession {
    enum Pending {
        case approval(approve: String, decline: String, operation: AgentToolOperation)
        case input([QuestionBinding])
        /// A request this client cannot answer remotely or locally.
        case unsupported
    }

    /// One native `requestUserInput` question: its native ID and, for a
    /// choice question, the exact labels behind Shell's choice IDs.
    struct QuestionBinding {
        let shellID: String
        let nativeID: String
        let labels: [String: String]
    }

    struct NativeRequest {
        let index: Int
        let id: NativeIdentifier
        let pending: Pending
        /// The thread item the request is about, for correlation.
        var itemID: String?
        var published: (requestID: ControlID, requestHash: String)?
        var waitTask: Task<Void, Never>?
        /// Set once the native request has been answered, by anyone.
        var answered = false
        /// Our own write and its claim, awaiting correlated resolution.
        var dispatched: (decision: JSONValue, receipt: ReceiptTarget)?
        /// Set when `serverRequest/resolved` arrived after our write.
        var resolvedAfterWrite = false
    }

    struct ReceiptTarget {
        let kind: AgentRequestKind
        let requestID: ControlID
        let requestHash: String
        let waitID: ControlID
        var decisionID: ControlID?
        var consumeID: ControlID?
        var commandID: ControlID?
        var permitID: ControlID?
    }

    private let env: ManagedEnvironment
    private let terminal: any ManagedTerminal
    private let connection: JSONRPCConnection
    public nonisolated let connectionEpoch = ControlID.random()
    private var run: AdapterRun?
    private var threadID: String?
    private var activeTurnID: String?
    private var requests: [String: NativeRequest] = [:]
    private var nextIndex = 1
    /// The proposed changes of each `fileChange` item, from `item/started`;
    /// a file-change approval names only the item (Codex 0.156.1 schema).
    private var fileChangeItems: [String: [JSONValue]] = [:]
    private var commandTask: Task<Void, Never>?
    private var stopped = false

    public init(environment: ManagedEnvironment, terminal: any ManagedTerminal, transport: any JSONRPCTransport) {
        self.env = environment
        self.terminal = terminal
        self.connection = JSONRPCConnection(transport: transport)
    }

    public var thread: String? { threadID }
    public var turn: String? { activeTurnID }

    // MARK: Lifecycle

    /// Initializes the app-server, starts or resumes the thread, and
    /// registers the managed session. It refuses to start when a required
    /// capability is unavailable (docs/specs/agent-relay.md 3.1).
    public func start() async throws {
        await connection.start { [weak self] inbound in await self?.handle(inbound) }
        _ = try await connection.request("initialize", .object([
            "clientInfo": .object(["name": "shell_control", "title": "Shell Control", "version": .string(AdapterManifest.adapterBuild)]),
            "capabilities": .object(["experimentalApi": .bool(env.configuration.routes.contains(.appServerUserInput))])
        ]))
        try await connection.notify("initialized")
        let thread: JSONValue
        if let resume = env.resumeThreadID {
            thread = try await connection.request("thread/resume", .object(["threadId": .string(resume)]))
        } else {
            // Approvals must reach the gate: never the "never" policy.
            thread = try await connection.request("thread/start", .object([
                "cwd": .string(env.cwd), "approvalPolicy": "untrusted", "serviceName": "shell_control"
            ]))
        }
        guard let id = thread["thread"]?["id"]?.stringValue else {
            throw AdapterRefusal("unsupported_input_schema", "thread/start returned no thread id")
        }
        threadID = id

        var run = try await AdapterRun.start(daemon: env.daemon, adapter: "codex-managed", jobLabel: "Codex (managed)")
        let routes = env.configuration.routes.filter { $0.isManaged && env.configuration.evidence(for: env.build, route: $0).permitsRemoteResponse }
        guard !routes.isEmpty else {
            throw AdapterRefusal("unsupported_provider_version", "Codex \(env.build) has no evidence for a managed route; run agent allow-build")
        }
        let evidence = routes.map { env.configuration.evidence(for: env.build, route: $0) }.min() ?? .documented
        try await run.register(JSONWriter.object([
            "provider": .string(AgentProvider.codex.wireName),
            "provider_build": .string(env.build),
            "adapter_build": .string(AdapterManifest.adapterBuild),
            "profile": .string(AgentIntegrationProfile.managed.rawValue),
            "evidence": .string(evidence.rawValue),
            "operations": JSONValue(strings: Array(Set(routes.flatMap(\.features))).sorted()),
            "provider_session_id": .string(String(id.prefix(256))),
            "policy_fingerprint": .string(env.policyFingerprint(env.cwd)),
            "terminal_location": await env.terminalLocation()?.json,
            "owner_pid": .number(.int(Int64(env.ownerPID)))
        ]))
        self.run = run
        terminal.write("[shell] managed Codex thread \(id) (experimental). Type a message to start a turn; /interrupt, /approve N, /deny N, /answer N text, /quit.\n")
        if routes.contains(.appServerTurnControl) {
            let task = Task { [weak self] in _ = await self?.commandLoop() }
            commandTask = task
        }
    }

    /// Reads the local terminal until `/quit` or the connection closes.
    public func runTerminal() async {
        for await line in terminal.lines {
            if stopped { break }
            await local(line)
            if stopped { break }
        }
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        commandTask?.cancel()
        for request in requests.values { request.waitTask?.cancel() }
        if let run { _ = try? await run.send(.agentEvent, .object(["type": .string(AgentEventType.sessionEnded.rawValue)])) }
        await connection.close()
    }

    // MARK: Inbound

    private func handle(_ inbound: JSONRPCConnection.Inbound) async {
        switch inbound {
        case .request(let id, let method, let params):
            await nativeRequest(id: id, method: method, params: params)
        case .notification(let method, let params):
            await notification(method: method, params: params)
        }
    }

    private func notification(method: String, params: JSONValue) async {
        switch method {
        case "turn/started":
            guard let turn = params["turn"]?["id"]?.stringValue else { return }
            activeTurnID = turn
            await event(.turnStarted, turn: turn, summary: nil)
        case "turn/completed":
            let turn = params["turn"]?["id"]?.stringValue
            let status = params["turn"]?["status"]?.stringValue ?? "completed"
            if turn == nil || turn == activeTurnID { activeTurnID = nil }
            terminal.write("\n[shell] turn \(status)\n")
            await event(status == "completed" ? .turnCompleted : .turnFailed, turn: turn, summary: "Turn \(status)")
        case "item/agentMessage/delta":
            // Streamed text is shown locally only; it is never pushed or
            // persisted token by token (docs/specs/agent-relay.md 11.2).
            if let delta = params["delta"]?.stringValue { terminal.write(delta) }
        case "serverRequest/resolved":
            // It names the request only; who answered it is not included.
            guard let rawID = params["requestId"], let id = try? NativeIdentifier(json: rawID) else { return }
            await resolved(id)
        case "item/started", "item/completed":
            guard let item = params["item"], let itemID = item["id"]?.stringValue else { return }
            if item["type"]?.stringValue == "fileChange", let changes = item["changes"]?.arrayValue {
                fileChangeItems[itemID] = changes
            }
            if let status = item["status"]?.stringValue, status != "inProgress" || method == "item/started" {
                await correlate(itemID: itemID, status: status)
            }
        default:
            break
        }
    }

    private func event(_ type: AgentEventType, turn: String?, summary: String?) async {
        guard let run else { return }
        _ = try? await run.send(.agentEvent, JSONWriter.object([
            "type": .string(type.rawValue),
            "provider_turn_id": turn.map { .string(String($0.prefix(256))) },
            "summary": summary.map { .string(String($0.unicodeScalars.prefix(AgentPolicy.maximumSummaryScalars))) }
        ]))
    }

    private func key(_ id: NativeIdentifier) -> String {
        switch id {
        case .integer(let value): return "i:\(value)"
        case .string(let text): return "s:\(text)"
        }
    }

    // MARK: Native requests

    private func nativeRequest(id: NativeIdentifier, method: String, params: JSONValue) async {
        let index = nextIndex
        nextIndex += 1
        let itemID = params["itemId"]?.stringValue
        do {
            switch method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
                let (operation, approve, decline) = try approvalOperation(id: id, method: method, params: params)
                requests[key(id)] = NativeRequest(index: index, id: id, pending: .approval(approve: approve, decline: decline, operation: operation), itemID: itemID)
                terminal.write("\n[shell] #\(index) \(Self.describe(operation)) — sent to Shell Control; /approve \(index) or /deny \(index) here\n")
                try await publishApproval(key(id), operation: operation)
            case "item/tool/requestUserInput":
                let (questions, bindings, lifetime) = try inputQuestions(params)
                requests[key(id)] = NativeRequest(index: index, id: id, pending: .input(bindings), itemID: itemID)
                terminal.write("\n[shell] #\(index) question: \(questions.map(\.prompt).joined(separator: " / ")) — sent to Shell Control; /answer \(index) a || b\n")
                try await publishInput(key(id), questions: questions, bindings: bindings, lifetime: lifetime, params: params)
            default:
                // Nothing here can answer it; replying at once keeps the turn
                // from waiting forever on a request no one will see.
                requests[key(id)] = NativeRequest(index: index, id: id, pending: .unsupported, itemID: itemID, answered: true)
                terminal.write("\n[shell] \(method) is not supported by this client; declined\n")
                try? await connection.respondError(to: id, code: -32601, message: "\(method) is not supported by shell-control")
            }
        } catch {
            if requests[key(id)] == nil {
                requests[key(id)] = NativeRequest(index: index, id: id, pending: .unsupported, itemID: itemID)
            }
            terminal.write("[shell] #\(index) stays local: \(error)\n")
        }
    }

    /// `item/commandExecution/requestApproval` and `item/fileChange/requestApproval`,
    /// as the Codex 0.156.1 schema defines them, map to `agent.tool.v1` with
    /// the exact native identity and epoch. A member this adapter does not
    /// understand, or one that widens the scope (network, stdin to a running
    /// terminal, another environment, a directory grant), keeps it local
    /// (docs/specs/agent-relay.md sections 5.3 and 10.2).
    func approvalOperation(id: NativeIdentifier, method: String, params: JSONValue) throws -> (AgentToolOperation, String, String) {
        guard let members = params.objectValue, let threadID, members["threadId"]?.stringValue == threadID else {
            throw AdapterRefusal("native_context_changed", "request is not for this thread")
        }
        let isCommand = method == "item/commandExecution/requestApproval"
        let allowed: Set<String> = isCommand
            ? ["approvalId", "availableDecisions", "command", "commandActions", "cwd", "environmentId", "itemId", "kind",
               "networkApprovalContext", "proposedExecpolicyAmendment", "proposedNetworkPolicyAmendments", "reason",
               "startedAtMs", "threadId", "turnId"]
            : ["availableDecisions", "grantRoot", "itemId", "reason", "startedAtMs", "threadId", "turnId"]
        let unknown = Set(members.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw AdapterRefusal("unsupported_operation", "unrecognized fields \(unknown.sorted().joined(separator: ", "))")
        }
        func present(_ name: String) -> Bool {
            guard let value = members[name], !value.isNull else { return false }
            if let array = value.arrayValue { return !array.isEmpty }
            return true
        }
        let route: NativeRoute = isCommand ? .appServerCommandApproval : .appServerFileChangeApproval
        guard env.configuration.routes.contains(route), env.configuration.evidence(for: env.build, route: route).permitsRemoteResponse,
              let run, let sessionID = run.agentSessionID else {
            throw AdapterRefusal("unsupported_provider_version", "\(route.rawValue) is not enabled with evidence")
        }
        let waitID = ControlID.random()
        var context = AdapterContext(providerBuild: env.build, agentSessionID: sessionID, nativeWaitID: waitID,
                                     effectiveUserID: env.effectiveUserID, policyFingerprint: env.policyFingerprint(env.cwd))
        let itemID = members["itemId"]?.stringValue
        let kind: AgentToolKind
        var shellRequest: AgentShellRequest?
        var fileChanges: [AgentFileChange]?
        var cwd = env.cwd
        if isCommand {
            if let requested = members["kind"]?.stringValue, requested != "command" {
                throw AdapterRefusal("unsupported_operation", "\(requested) approvals stay local")
            }
            for widening in ["networkApprovalContext", "proposedNetworkPolicyAmendments", "approvalId"] where present(widening) {
                throw AdapterRefusal("unsupported_operation", "\(widening) widens the scope beyond one command")
            }
            // Codex 0.156.1 names the local environment on every request;
            // any other environment is not this Mac's context.
            if let environment = members["environmentId"]?.stringValue, environment != "local" {
                throw AdapterRefusal("unsupported_operation", "environment \(environment) is not the local one")
            }
            guard let command = members["command"]?.stringValue, !command.isEmpty else {
                throw AdapterRefusal("unsupported_input_schema", "command is missing")
            }
            if let requested = members["cwd"]?.stringValue {
                guard requested.hasPrefix("/") else { throw AdapterRefusal("unsupported_input_schema", "cwd is not absolute") }
                cwd = requested
            }
            // The server sends one command string; it is never split.
            shellRequest = try AgentShellRequest(representation: .commandString, command: command)
            kind = .shell
            context.unavailable = ["environment", "shell_identity"]
        } else {
            guard !present("grantRoot") else {
                throw AdapterRefusal("unsupported_operation", "a session-wide write grant is not a single change")
            }
            guard let itemID, let changes = fileChangeItems[itemID], !changes.isEmpty, changes.count <= 32 else {
                throw AdapterRefusal("native_context_changed", "the item's proposed changes were not observed")
            }
            var mapped: [AgentFileChange] = []
            for change in changes {
                guard let rawPath = change["path"]?.stringValue, let diff = change["diff"]?.stringValue,
                      let kindText = change["kind"]?["type"]?.stringValue else {
                    throw AdapterRefusal("unsupported_input_schema", "a change is not path, kind, and diff")
                }
                let path = rawPath.hasPrefix("/") ? rawPath : URL(fileURLWithPath: env.cwd).appendingPathComponent(rawPath).standardizedFileURL.path
                let current = try env.fileSystem.contents(of: path, limit: OperationMapper.maximumFileBytes)
                let changeKind: AgentFileChange.Change
                switch kindText {
                case "add":
                    guard current == nil else { throw AdapterRefusal("native_context_changed", "\(path) already exists") }
                    changeKind = .create
                case "update":
                    // A rename is not a single-path change v1 can show.
                    guard change["kind"]?["move_path"]?.stringValue == nil else {
                        throw AdapterRefusal("unsupported_operation", "moves stay local")
                    }
                    changeKind = .modify
                case "delete": changeKind = .delete
                default: throw AdapterRefusal("unsupported_operation", "change kind \(kindText)")
                }
                if changeKind != .create, current == nil { throw AdapterRefusal("native_context_changed", "\(path) does not exist") }
                let base = current.map { ContentDigest.sha256Hex($0) }
                context.fileBases[path] = base
                mapped.append(try AgentFileChange(path: path, change: changeKind, diff: diff, baseSHA256: base))
            }
            fileChanges = mapped
            kind = .fileChange
            context.unavailable = ["environment"]
        }
        let input = NativeHookInput(provider: .codex, event: .permissionRequest, sessionID: threadID,
                                    turnID: members["turnId"]?.stringValue, cwd: cwd, permissionMode: nil,
                                    toolName: isCommand ? "commandExecution" : "fileChange",
                                    toolInput: params, toolUseID: itemID, raw: params)
        let operation = try AgentToolOperation(
            provider: AgentProvider.codex.wireName, providerBuild: env.build, adapterBuild: AdapterManifest.adapterBuild,
            agentSessionID: sessionID, nativeWaitID: waitID, connectionEpoch: connectionEpoch,
            providerSessionID: threadID, providerTurnID: members["turnId"]?.stringValue, providerRequestID: id,
            providerToolUseID: itemID, kind: kind, toolName: input.toolName,
            cwd: cwd, reason: members["reason"]?.stringValue.map { String($0.unicodeScalars.prefix(2048)) },
            shellRequest: shellRequest, fileChanges: fileChanges, unavailable: context.unavailable.sorted(),
            nativeRequestSHA256: input.nativeRequestSHA256, contextSHA256: context.contextSHA256(for: input)
        )
        // Only offered decisions are sent, and only one-time ones: never
        // acceptForSession or an amendment. When the server lists its
        // decisions (0.156.1 does, outside its schema) a rejection uses
        // `decline` if offered, else `cancel`, which also ends the turn.
        var decline = "decline"
        if let offered = members["availableDecisions"]?.arrayValue {
            let simple = Set(offered.compactMap(\.stringValue))
            guard simple.contains("accept") else {
                throw AdapterRefusal("unsupported_operation", "the gate does not offer a one-time accept")
            }
            if !simple.contains("decline") {
                guard simple.contains("cancel") else { throw AdapterRefusal("unsupported_operation", "the gate offers no denial") }
                decline = "cancel"
            }
        }
        return (operation, "accept", decline)
    }

    private func publishApproval(_ key: String, operation: AgentToolOperation) async throws {
        guard let run else { return }
        let review: MinimumReview = env.configuration.watchShellApproval && operation.isWatchEligible ? .watch : .full
        var reader = try JSONReader(try await run.send(.approvalRequest, .object([
            "summary": .string(HookRunner.summary(for: operation)),
            "operation": operation.json,
            "lifetime_seconds": .number(.int(Int64(AgentPolicy.defaultLifetime))),
            "minimum_review": .string(review.rawValue)
        ])))
        let published = (try reader.id("request_id"), try reader.string("request_hash", maxLength: 80))
        requests[key]?.published = published
        let task = Task { [weak self] in _ = await self?.awaitApproval(key, published: published, operation: operation) }
        requests[key]?.waitTask = task
    }

    private func awaitApproval(_ key: String, published: (ControlID, String), operation: AgentToolOperation) async {
        guard let run else { return }
        let outcome: ApprovalWaitOutcome
        do {
            outcome = try ApprovalWaitOutcome(json: try await run.send(.approvalWait, .object([
                "request_id": JSONValue(published.0), "request_hash": .string(published.1),
                "timeout_seconds": .number(.int(Int64(AgentPolicy.defaultLifetime)))
            ]), timeout: AgentPolicy.defaultLifetime + 10))
        } catch {
            if let request = requests[key], !request.answered {
                terminal.write("[shell] #\(request.index) no remote decision; decide here\n")
            }
            return
        }
        guard var request = requests[key], !request.answered, case .approval(let approve, let decline, _) = request.pending else { return }
        var target = ReceiptTarget(kind: .approval, requestID: published.0, requestHash: published.1, waitID: operation.nativeWaitID)
        let decision: String
        switch outcome {
        case .approved(let permit):
            guard permit.runID == run.runID, ContentDigest.matches(permit.requestHash, published.1), permit.decision == .approve,
                  HookRunner.decisionApproves(permit.decisionJWS, requestHash: published.1), permit.isApplicable(at: env.now()),
                  env.ownerAlive(), (try? OperationMapper.recheck(operation, fileSystem: env.fileSystem)) != nil else {
                await receipt(ReceiptTarget(kind: .approval, requestID: published.0, requestHash: published.1, waitID: operation.nativeWaitID,
                                            decisionID: permit.decisionID, consumeID: permit.consumeID),
                              .notApplied, evidence: "native_context_changed")
                terminal.write("[shell] #\(request.index) remote approval could not be verified; decide here\n")
                return
            }
            target.decisionID = permit.decisionID
            target.consumeID = permit.consumeID
            decision = approve
        case .rejected(let decisionID):
            target.decisionID = decisionID
            decision = decline
        case .expired, .cancelled, .unavailable:
            terminal.write("[shell] #\(request.index) no remote decision; decide here\n")
            return
        }
        // Claimed before the first suspension point: a local /approve,
        // /deny, or a resolution arriving while the dispatch is journaled
        // sees the request as answered and cannot answer it a second time.
        request.answered = true
        request.dispatched = (.object(["decision": .string(decision)]), target)
        requests[key] = request
        // Journaled before the first write to the provider.
        guard await receipt(target, .dispatchStarted, evidence: "dispatch_journaled") else {
            releaseClaim(key)
            terminal.write("[shell] #\(request.index) dispatch could not be recorded; decide here\n")
            return
        }
        guard requests[key]?.dispatched != nil else { return }
        do {
            try await connection.respond(to: request.id, result: .object(["decision": .string(decision)]))
            await receipt(target, .nativeResponseWritten, evidence: "rpc_response_written")
            let outcome = decision == approve ? "approved" : (decision == "cancel" ? "denied (the turn is interrupted: decline was not offered)" : "denied")
            terminal.write("[shell] #\(request.index) \(outcome) in Shell Control\n")
        } catch {
            await receipt(target, .unknown, evidence: "connection_lost")
        }
    }

    /// `item/tool/requestUserInput`, as the Codex 0.156.1 schema defines it:
    /// a question with options becomes a single choice over those exact
    /// labels, one without becomes text. Secret entry stays local, and an
    /// auto-resolution interval shortens the deadline (docs/specs/agent-relay.md
    /// sections 7.1 and 11.2).
    func inputQuestions(_ params: JSONValue) throws -> ([InputQuestion], [QuestionBinding], TimeInterval) {
        guard let members = params.objectValue, members["threadId"]?.stringValue == threadID else {
            throw AdapterRefusal("native_context_changed", "request is not for this thread")
        }
        let unknown = Set(members.keys).subtracting(["autoResolutionMs", "isBlocking", "itemId", "questions", "threadId", "turnId"])
        guard unknown.isEmpty else { throw AdapterRefusal("unsupported_input_schema", "unrecognized fields \(unknown.sorted().joined(separator: ", "))") }
        guard env.configuration.routes.contains(.appServerUserInput),
              env.configuration.evidence(for: env.build, route: .appServerUserInput).permitsRemoteResponse else {
            throw AdapterRefusal("unsupported_provider_version", "user input is not enabled with evidence")
        }
        var lifetime = AgentPolicy.defaultLifetime
        if let milliseconds = members["autoResolutionMs"]?.int64Value {
            // The native expiry wins, with a margin for the write.
            lifetime = min(lifetime, TimeInterval(milliseconds) / 1000 - 5)
        }
        guard lifetime >= HookRunner.minimumUsefulReview else {
            throw AdapterRefusal("request_expired", "the question resolves too soon for remote review")
        }
        guard let items = members["questions"]?.arrayValue, !items.isEmpty, items.count <= AgentPolicy.maximumQuestions else {
            throw AdapterRefusal("unsupported_input_schema", "questions are missing")
        }
        var questions: [InputQuestion] = []
        var bindings: [QuestionBinding] = []
        for (index, item) in items.enumerated() {
            guard let fields = item.objectValue,
                  Set(fields.keys).isSubset(of: ["header", "id", "isOther", "isSecret", "options", "question"]),
                  let nativeID = fields["id"]?.stringValue, let text = fields["question"]?.stringValue, !text.isEmpty else {
                throw AdapterRefusal("unsupported_input_schema", "question \(index) is not a documented question")
            }
            // No secret-entry workflow exists remotely (spec 7.1).
            guard fields["isSecret"]?.boolValue != true else { throw AdapterRefusal("unsupported_input_schema", "secret questions stay local") }
            let shellID = "q\(index + 1)"
            var labels: [String: String] = [:]
            let kind: InputQuestion.Kind
            if let options = fields["options"]?.arrayValue, !options.isEmpty {
                var choices: [InputChoice] = []
                for (optionIndex, option) in options.enumerated() {
                    guard let label = option["label"]?.stringValue, !label.isEmpty else {
                        throw AdapterRefusal("unsupported_input_schema", "an option has no label")
                    }
                    let id = "c\(optionIndex + 1)"
                    labels[id] = label
                    choices.append(try InputChoice(id: id, label: label, description: option["description"]?.stringValue))
                }
                guard Set(labels.values).count == labels.count else { throw AdapterRefusal("unsupported_input_schema", "option labels repeat") }
                kind = .singleChoice(choices: choices)
            } else {
                kind = .text(maximumBytes: 1024, hint: fields["header"]?.stringValue.map { String($0.prefix(200)) })
            }
            do {
                questions.append(try InputQuestion(id: shellID, prompt: text, kind: kind, required: true))
            } catch {
                throw AdapterRefusal("limit_exceeded", "\(error)")
            }
            bindings.append(QuestionBinding(shellID: shellID, nativeID: nativeID, labels: labels))
        }
        return (questions, bindings, lifetime)
    }

    private func publishInput(_ key: String, questions: [InputQuestion], bindings: [QuestionBinding], lifetime: TimeInterval, params: JSONValue) async throws {
        guard let run, let sessionID = run.agentSessionID, let request = requests[key] else { return }
        let waitID = ControlID.random()
        let mapping = InputAnswerMapping(questions: Dictionary(uniqueKeysWithValues: bindings.map {
            ($0.shellID, InputAnswerMapping.Question(nativeKey: $0.nativeID, choices: $0.labels))
        }))
        let input = NativeHookInput(provider: .codex, event: .preToolUse, sessionID: threadID, turnID: params["turnId"]?.stringValue,
                                    cwd: env.cwd, permissionMode: nil, toolName: "requestUserInput", toolInput: params,
                                    toolUseID: params["itemId"]?.stringValue, raw: params)
        let context = AdapterContext(providerBuild: env.build, agentSessionID: sessionID, nativeWaitID: waitID,
                                     effectiveUserID: env.effectiveUserID, policyFingerprint: env.policyFingerprint(env.cwd))
        let watchSized = questions.count <= AgentPolicy.watchMaximumQuestions
            && questions.allSatisfy { $0.kind.choices.count <= AgentPolicy.watchMaximumChoices }
        var reader = try JSONReader(try await run.send(.inputRequest, JSONWriter.object([
            "summary": .string(String("Codex asks: \(questions[0].prompt)".unicodeScalars.prefix(AgentPolicy.maximumSummaryScalars))),
            "questions": .array(questions.map(\.json)),
            "allowed_responses": JSONValue(strings: ["answer"]),
            "minimum_review": .string((watchSized ? MinimumReview.watch : .full).rawValue),
            "lifetime_seconds": .number(.int(Int64(lifetime))),
            "native_request_sha256": .string(input.nativeRequestSHA256),
            "context_sha256": .string(context.contextSHA256(for: input)),
            "answer_mapping_sha256": .string(mapping.sha256Hex),
            "native_wait_id": JSONValue(waitID),
            "connection_epoch": JSONValue(connectionEpoch),
            "provider_turn_id": params["turnId"]?.stringValue.map { .string($0) },
            "provider_request_id": request.id.json
        ])))
        let published = (try reader.id("request_id"), try reader.string("request_hash", maxLength: 80))
        requests[key]?.published = published
        let task = Task { [weak self] in _ = await self?.awaitInput(key, published: published, waitID: waitID, mapping: mapping, lifetime: lifetime) }
        requests[key]?.waitTask = task
    }

    /// The native answer object: `{answers: {<question id>: {answers: [..]}}}`.
    static func nativeAnswers(_ answers: [InputAnswer], mapping: InputAnswerMapping) throws -> JSONValue {
        var result: [String: JSONValue] = [:]
        for answer in answers {
            guard let question = mapping.questions[answer.questionID] else { throw AdapterRefusal("response_invalid", "unknown question") }
            let value: String
            switch answer {
            case .singleChoice(_, let choice):
                guard let label = question.choices[choice] else { throw AdapterRefusal("response_invalid", "unknown choice") }
                value = label
            case .text(_, let text):
                value = text
            case .multiChoice:
                throw AdapterRefusal("response_invalid", "multiple choice is not offered")
            }
            result[question.nativeKey] = .object(["answers": [.string(value)]])
        }
        return .object(["answers": .object(result)])
    }

    private func awaitInput(_ key: String, published: (ControlID, String), waitID: ControlID, mapping: InputAnswerMapping, lifetime: TimeInterval) async {
        guard let run else { return }
        let body: JSONValue
        do {
            body = try await run.send(.inputWait, .object([
                "request_id": JSONValue(published.0), "request_hash": .string(published.1),
                "timeout_seconds": .number(.int(Int64(lifetime)))
            ]), timeout: lifetime + 10)
        } catch {
            return
        }
        guard var request = requests[key], !request.answered, case .input = request.pending else { return }
        guard body["outcome"]?.stringValue == "answered", let permitValue = body["permit"], let specValue = body["spec"],
              let permit = try? InputConsumePermit(json: permitValue), let spec = try? InputSpec(json: specValue),
              permit.nativeWaitID == waitID, permit.runID == run.runID, permit.isApplicable(at: env.now()),
              spec.source.answerMappingSHA256 == mapping.sha256Hex, (try? permit.response.validate(against: spec)) != nil,
              case .answer(let answers) = permit.response,
              let result = try? Self.nativeAnswers(answers, mapping: mapping) else {
            terminal.write("[shell] #\(request.index) no remote answer; answer here\n")
            return
        }
        let target = ReceiptTarget(kind: .input, requestID: published.0, requestHash: published.1, waitID: waitID,
                                   commandID: permit.commandID, permitID: permit.permitID)
        // Claimed before suspending, as for approvals.
        request.answered = true
        request.dispatched = (result, target)
        requests[key] = request
        guard await receipt(target, .dispatchStarted, evidence: "dispatch_journaled") else {
            releaseClaim(key)
            return
        }
        guard requests[key]?.dispatched != nil else { return }
        do {
            try await connection.respond(to: request.id, result: result)
            await receipt(target, .nativeResponseWritten, evidence: "rpc_response_written")
            terminal.write("[shell] #\(request.index) answered in Shell Control\n")
        } catch {
            await receipt(target, .unknown, evidence: "connection_lost")
        }
    }

    /// Undoes a remote claim whose dispatch could not be journaled, so the
    /// request can still be answered here. A resolution that arrived in the
    /// meantime keeps it closed.
    private func releaseClaim(_ key: String) {
        guard var request = requests[key], request.dispatched != nil else { return }
        request.dispatched = nil
        request.answered = request.resolvedAfterWrite
        requests[key] = request
    }

    /// `serverRequest/resolved` names the request but not who answered it or
    /// how. If this connection had not answered, someone else did and the
    /// remote request is withdrawn (spec 9.4). If it had, acceptance still
    /// waits for the item's own final status (spec 9.2).
    private func resolved(_ id: NativeIdentifier) async {
        let key = key(id)
        guard var request = requests[key] else { return }
        request.waitTask?.cancel()
        if request.dispatched != nil {
            request.resolvedAfterWrite = true
        } else if !request.answered, let published = request.published {
            switch request.pending {
            case .approval:
                _ = try? await run?.send(.approvalWithdraw, .object(["request_id": JSONValue(published.requestID), "request_hash": .string(published.requestHash)]))
            case .input:
                _ = try? await run?.send(.inputWithdraw, .object(["request_id": JSONValue(published.requestID), "request_hash": .string(published.requestHash)]))
            case .unsupported:
                break
            }
        }
        request.answered = true
        requests[key] = request
    }

    /// Correlated acceptance: the item our answer was about reached a status
    /// that matches it — `declined` for a decline, anything else for an
    /// accept — after the request was resolved.
    private func correlate(itemID: String, status: String) async {
        guard let (key, request) = requests.first(where: { $0.value.itemID == itemID && $0.value.dispatched != nil }),
              let dispatched = request.dispatched, case .approval = request.pending else { return }
        let declined = ["decline", "cancel"].contains(dispatched.decision["decision"]?.stringValue ?? "")
        let matches = declined == (status == "declined")
        await receipt(dispatched.receipt, matches ? .accepted : .notApplied,
                      evidence: matches ? "item_status_\(status)" : "item_status_mismatch")
        requests[key]?.dispatched = nil
    }

    // MARK: Local terminal

    private func local(_ line: String) async {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parts = text.split(separator: " ", maxSplits: 2).map(String.init)
        switch parts[0] {
        case "/quit":
            await stop()
        case "/interrupt":
            guard let threadID, let turn = activeTurnID else { terminal.write("[shell] no active turn\n"); return }
            _ = try? await connection.request("turn/interrupt", .object(["threadId": .string(threadID), "turnId": .string(turn)]))
        case "/approve", "/deny", "/answer":
            guard parts.count >= 2, let index = Int(parts[1]),
                  let (key, request) = requests.first(where: { $0.value.index == index }), !request.answered else {
                terminal.write("[shell] no open request with that number\n")
                return
            }
            await localAnswer(key: key, request: request, command: parts[0], text: parts.count > 2 ? parts[2] : "")
        default:
            guard let threadID else { return }
            // A locally typed message starts a turn or steers the active one.
            if let turn = activeTurnID {
                _ = try? await connection.request("turn/steer", .object([
                    "threadId": .string(threadID), "input": [.object(["type": "text", "text": .string(text)])], "expectedTurnId": .string(turn)
                ]))
            } else {
                _ = try? await connection.request("turn/start", .object([
                    "threadId": .string(threadID), "input": [.object(["type": "text", "text": .string(text)])]
                ]))
            }
        }
    }

    /// A local decision wins only if the remote request can still be
    /// withdrawn; a remote claim that already happened wins instead.
    private func localAnswer(key: String, request: NativeRequest, command: String, text: String) async {
        if let published = request.published, let run {
            guard !{ if case .unsupported = request.pending { return true } else { return false } }() else { return }
            let type: IPCMessageType = { if case .approval = request.pending { return .approvalWithdraw } else { return .inputWithdraw } }()
            do {
                _ = try await run.send(type, .object(["request_id": JSONValue(published.requestID), "request_hash": .string(published.requestHash)]))
            } catch {
                terminal.write("[shell] #\(request.index) was already answered remotely\n")
                return
            }
        }
        guard var current = requests[key], !current.answered else { return }
        current.waitTask?.cancel()
        current.answered = true
        requests[key] = current
        let result: JSONValue
        switch (current.pending, command) {
        case (.approval(let approve, _, _), "/approve"): result = .object(["decision": .string(approve)])
        case (.approval(_, let decline, _), "/deny"): result = .object(["decision": .string(decline)])
        case (.input(let bindings), "/answer"):
            let answers = text.components(separatedBy: " || ")
            guard answers.count == bindings.count else {
                terminal.write("[shell] give \(bindings.count) answers separated by ' || '\n")
                current.answered = false
                requests[key] = current
                return
            }
            var native: [String: JSONValue] = [:]
            for (binding, answer) in zip(bindings, answers) { native[binding.nativeID] = .object(["answers": [.string(answer)]]) }
            result = .object(["answers": .object(native)])
        default:
            current.answered = false
            requests[key] = current
            terminal.write("[shell] that command does not answer #\(current.index)\n")
            return
        }
        try? await connection.respond(to: current.id, result: result)
    }

    // MARK: Session commands

    /// Waits for claimed, signed session commands and performs each once on
    /// this connection. Only the provider's RPC result counts as acceptance;
    /// acknowledging an interrupt proves nothing about termination.
    private func commandLoop() async {
        while !Task.isCancelled, !stopped {
            guard let run else { return }
            let body: JSONValue
            do {
                body = try await run.send(.sessionCommandWait, .object([
                    "connection_epoch": JSONValue(connectionEpoch),
                    "timeout_seconds": .number(.int(env.commandWaitSeconds))
                ]), timeout: TimeInterval(env.commandWaitSeconds) + 10)
            } catch {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            guard body["outcome"]?.stringValue == "command", let raw = body["permit"],
                  let permit = try? AgentSessionPermit(json: raw) else { continue }
            await perform(permit)
        }
    }

    func perform(_ permit: AgentSessionPermit) async {
        guard let threadID, let run, let sessionID = run.agentSessionID else { return }
        let target = ReceiptTarget(kind: .sessionCommand, requestID: permit.commandID, requestHash: permit.actionDigest,
                                   waitID: permit.connectionEpoch, permitID: permit.permitID)
        guard (try? permit.validate(connectionEpoch: connectionEpoch, agentSessionID: sessionID)) != nil,
              permit.isApplicable(at: env.now()) else {
            await receipt(target, .notApplied, evidence: "permit_invalid")
            return
        }
        let method: String
        let params: JSONValue
        switch permit.action {
        case .message(_, _, _, .newTurn, _, let text):
            // Refused, never queued, when the session is no longer idle.
            guard activeTurnID == nil else { await receipt(target, .notApplied, evidence: "turn_active"); return }
            method = "turn/start"
            params = .object(["threadId": .string(threadID), "input": [.object(["type": "text", "text": .string(text)])]])
        case .message(_, _, _, .steer, let expected, let text):
            guard let expected, activeTurnID == expected else { await receipt(target, .notApplied, evidence: "turn_changed"); return }
            method = "turn/steer"
            params = .object(["threadId": .string(threadID), "input": [.object(["type": "text", "text": .string(text)])],
                              "expectedTurnId": .string(expected)])
        case .cancel(_, _, _, let turn):
            guard activeTurnID == turn else { await receipt(target, .notApplied, evidence: "turn_changed"); return }
            method = "turn/interrupt"
            params = .object(["threadId": .string(threadID), "turnId": .string(turn)])
        }
        guard await receipt(target, .dispatchStarted, evidence: "dispatch_journaled") else { return }
        do {
            let result = try await connection.request(method, params)
            if method == "turn/start", let turn = result["turn"]?["id"]?.stringValue, activeTurnID == nil {
                activeTurnID = turn
                await event(.turnStarted, turn: turn, summary: nil)
            }
            terminal.write("[shell] \(Self.describe(permit.action)) from Shell Control\n")
            await receipt(target, .accepted, evidence: "rpc_result")
        } catch let error as JSONRPCError {
            terminal.write("[shell] Codex refused \(method): \(error.message)\n")
            await receipt(target, .notApplied, evidence: "rpc_error")
        } catch {
            await receipt(target, .unknown, evidence: "connection_lost")
        }
    }

    // MARK: Receipts

    @discardableResult
    private func receipt(_ target: ReceiptTarget, _ dispatch: AgentDispatch, evidence: String) async -> Bool {
        guard let run else { return false }
        do {
            _ = try await run.send(.agentReceipt, JSONWriter.object([
                "request_kind": .string(target.kind.rawValue),
                "request_id": JSONValue(target.requestID),
                "request_hash": .string(target.requestHash),
                "native_wait_id": JSONValue(target.waitID),
                "decision_id": target.decisionID.map { JSONValue($0) },
                "consume_id": target.consumeID.map { JSONValue($0) },
                "command_id": target.commandID.map { JSONValue($0) },
                "permit_id": target.permitID.map { JSONValue($0) },
                "dispatch": .string(dispatch.rawValue),
                "evidence": .string(evidence)
            ]))
            return true
        } catch {
            env.log("receipt \(dispatch.rawValue) not recorded: \(error)")
            return false
        }
    }

    // MARK: Display

    static func describe(_ operation: AgentToolOperation) -> String {
        if let shell = operation.shellRequest {
            return "run: " + (shell.command ?? shell.argv?.joined(separator: " ") ?? "")
        }
        return "change: " + (operation.fileChanges?.map(\.path).joined(separator: ", ") ?? "")
    }

    static func describe(_ action: AgentSessionAction) -> String {
        switch action {
        case .message(_, _, _, .newTurn, _, _): return "new instruction"
        case .message(_, _, _, .steer, _, _): return "steering"
        case .cancel: return "interrupt"
        }
    }
}

/// The process's own stdin/stdout as the managed console.
public struct StandardManagedTerminal: ManagedTerminal {
    public let lines: AsyncStream<String>

    public init() {
        lines = AsyncStream { continuation in
            Thread.detachNewThread {
                while let line = Swift.readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
        }
    }

    public func write(_ text: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
    }
}
