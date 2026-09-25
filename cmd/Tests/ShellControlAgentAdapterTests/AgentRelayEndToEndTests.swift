import XCTest
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient
import ShellControlBroker
@testable import ShellControlDaemon
@testable import ShellControlAgentAdapter

/// The whole relay in one process: a real broker, the real daemon, the real
/// hook runner, and a device that reviews, signs, and submits
/// (docs/specs/agent-relay.md section 20: A01, A02, A08, A12, A13, A14, A18, A31).
/// The native side is the fixture input and the hook's stdout; no provider
/// runs and nothing executes.
final class AgentRelayEndToEndTests: XCTestCase {
    /// Calls the broker's HTTP front end directly.
    struct InProcessTransport: ControlHTTPTransport {
        let service: BrokerService

        func send(_ request: ControlHTTPRequest, baseURL: URL) async throws -> ControlHTTPResponse {
            var query: [String: String] = [:]
            for (name, value) in request.query { query[name] = value }
            var headers: [String: String] = [:]
            for (name, value) in request.headers { headers[name.lowercased()] = value }
            headers["host"] = "127.0.0.1"
            let response = await service.handle(HTTPServer.Request(
                method: request.method, path: request.path, query: query, headers: headers, body: request.body ?? Data()
            ))
            return ControlHTTPResponse(status: response.status, headers: response.headers, body: response.body)
        }
    }

    /// Calls the daemon's IPC handler directly. Cancelling the caller
    /// cancels the handler, as a closed socket does in `shell-controld`.
    struct InProcessDaemon: AdapterDaemon {
        let core: DaemonCore

        func exchange(_ type: IPCMessageType, capability: String?, body: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
            let response = await core.handle(IPCRequest(messageID: .random(), type: type, runCapability: capability, body: body))
            guard response.ok else { throw AdapterDaemonError(code: response.errorCode ?? "unavailable", message: response.errorMessage ?? "") }
            return response.body
        }
    }

    final class Relay: @unchecked Sendable {
        let store: BrokerStore
        let core: DaemonCore
        let accountID = ControlID.random()
        let originID = ControlID.random()
        let directory: URL

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-e2e-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = BrokerStore(serviceIdentity: "e2e")
            let service = BrokerService(store: store, configuration: .init(
                verificationURI: "https://x", allowedAPNsTopics: [], adminSecret: "admin", adminAccountID: accountID
            ))
            let secret = "origin-secret-e2e"
            try await store.enrollOrigin(originID: originID, accountID: accountID, label: "Mac", secret: secret)
            var configuration = DaemonCore.Configuration(
                brokerURL: URL(string: "http://127.0.0.1:1")!, originID: originID, originSecret: secret,
                socketPath: directory.appendingPathComponent("control.sock").path,
                journalURL: directory.appendingPathComponent("journal.ndjson")
            )
            configuration.pollInterval = 0.05
            core = try DaemonCore(configuration: configuration, client: ControlAPIClient(
                baseURL: configuration.brokerURL, transport: InProcessTransport(service: service),
                credential: .origin(originID: originID, secret: secret)
            ))
        }

        func device(platform: PushRegistration.Platform = .iOS, grants: Set<DeviceGrant> = DeviceGrant.watchDefault.union(DeviceGrant.agentPhone)) async throws -> (id: ControlID, key: InMemoryDeviceKey, principal: Principal) {
            let key = InMemoryDeviceKey()
            let id = try await store.enrollDevice(accountID: accountID, publicJWK: key.publicJWK, platform: platform, label: "device", grants: grants)
            return (id, key, try await store.authenticateDevice(id))
        }

        func environment(_ provider: AgentProvider, build: String? = "2.1.281", attested: Bool = true, routes: [NativeRoute]? = nil,
                         elapsed: TimeInterval = 0, ownerAlive: @escaping @Sendable () -> Bool = { true }) -> HookEnvironment {
            var configuration = AdapterConfiguration(provider: provider, routes: routes)
            if attested, let build { configuration.userAttestedBuilds = [build] }
            let start = Date()
            return HookEnvironment(
                provider: provider, configuration: configuration, daemon: InProcessDaemon(core: core),
                detectBuild: { build }, ownerPID: getpid(), ownerAlive: ownerAlive, effectiveUserID: geteuid(),
                policyFingerprint: { _ in String(repeating: "f", count: 64) }, terminalLocation: { nil },
                fileSystem: LocalFileSystem(), elapsed: { elapsed + Date().timeIntervalSince(start) }, log: { _ in }
            )
        }

        /// Waits until a pending approval with a live native wait appears.
        func pendingApproval(for principal: Principal) async throws -> ApprovalRecord {
            for _ in 0..<400 {
                let page = try await store.snapshot(principal: principal)
                if let record = page.approvals.first(where: { $0.projection.resolution == .pending && $0.projection.presence.isWaiting }) {
                    return record
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw XCTSkip("no pending approval appeared")
        }

        func pendingInput(for principal: Principal) async throws -> InputRecord {
            for _ in 0..<400 {
                let page = try await store.agentSnapshot(principal: principal, pageToken: nil, limit: 50)
                for item in page.inputs {
                    if case .supported(let record) = item, record.projection.resolution == .pending, record.projection.presence.isWaiting {
                        return record
                    }
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw XCTSkip("no pending input appeared")
        }

        func decide(_ decision: ControlDecision, record: ApprovalRecord, device: (id: ControlID, key: InMemoryDeviceKey, principal: Principal)) async throws {
            let challenge = try await store.createChallenge(principal: device.principal, request: try ReviewChallengeRequest(
                target: .approval(requestID: record.spec.requestID, requestHash: record.requestHash,
                                  expectedStateVersion: record.projection.stateVersion, policyVersion: record.projection.policyVersion),
                action: .approvalDecide
            ))
            let commandID = ControlID.random()
            let now = ControlTimestamp(Date())
            let command = try ApprovalDecideCommand(
                envelope: try ControlCommandEnvelope(type: .approvalDecide, commandID: commandID, deviceID: device.id,
                                                     audience: "shell-control:\(accountID.rawValue)", issuedAt: now, notAfter: challenge.expiresAt),
                requestID: record.spec.requestID, requestHash: record.requestHash,
                expectedStateVersion: record.projection.stateVersion, policyVersion: record.projection.policyVersion,
                decision: decision, challengeID: challenge.challengeID
            )
            let jws = try ControlJWS.sign(payload: command.json, deviceID: device.id, key: device.key)
            _ = try await store.submitCommand(principal: device.principal, signedCommand: jws, idempotencyKey: commandID)
        }
    }

    func fixture(_ provider: AgentProvider, _ name: String) throws -> Data {
        try Data(contentsOf: AdapterContractTests.repository.appendingPathComponent("adapters/\(provider.rawValue)/fixtures/\(name)"))
    }

    /// The fixture input with a working directory that exists here.
    func input(_ provider: AgentProvider, _ name: String) throws -> Data {
        var object = try XCTUnwrap(try JSONValue.parse(try fixture(provider, name)).objectValue)
        object["cwd"] = .string(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        return try JSONCanonicalization.canonicalize(.object(object))
    }

    func testClaudeShellApprovedOnIPhoneAllowsTheExactGate() async throws {
        // A01, A18.
        let relay = try await Relay()
        let phone = try await relay.device()
        let runner = HookRunner(environment: relay.environment(.claudeCode))
        let data = try input(.claudeCode, "permission-request.bash.input.json")
        async let outcome = runner.run(stdin: data)
        let record = try await relay.pendingApproval(for: phone.principal)
        guard case .agentTool(let operation) = record.spec.operation else { return XCTFail("not an agent operation") }
        XCTAssertEqual(operation.shellRequest?.command, "git status --short")
        XCTAssertEqual(record.spec.minimumReview, .full)
        try await relay.decide(.approve, record: record, device: phone)

        let result = await outcome
        XCTAssertEqual(result.stdout, HookRunner.permissionResponse(allow: true, message: nil, provider: .claudeCode), result.note)
        let final = try await relay.store.approval(record.spec.requestID, principal: phone.principal)
        XCTAssertEqual(final.projection.dispatch, .unknown, "written, but acceptance is not observable")
        let snapshot = try await relay.store.agentSnapshot(principal: phone.principal, pageToken: nil, limit: 50)
        XCTAssertEqual(snapshot.approvals.first?.dispatch, .nativeResponseWritten)
        XCTAssertEqual(snapshot.sessions.first?.registration.evidence, .userAttested)
    }

    func testCodexShellRejectedOnWatchDeniesTheGate() async throws {
        // A02: a Watch rejection, signed by the Watch.
        let relay = try await Relay()
        let watch = try await relay.device(platform: .watchOS, grants: DeviceGrant.watchDefault)
        let runner = HookRunner(environment: relay.environment(.codex, build: "0.44.0"))
        let native = try input(.codex, "permission-request.bash.input.json")
        async let outcome = runner.run(stdin: native)
        let record = try await relay.pendingApproval(for: watch.principal)
        try await relay.decide(.reject, record: record, device: watch)
        let result = await outcome
        XCTAssertEqual(result.stdout, try JSONCanonicalization.canonicalize(try JSONValue.parse(try fixture(.codex, "permission-request.bash.deny.expected.json"))))
        let final = try await relay.store.approval(record.spec.requestID, principal: watch.principal)
        XCTAssertEqual(final.projection.resolution, .rejected)
        XCTAssertEqual(final.projection.decidedByDeviceID, watch.id)
    }

    func testCapturedCodexHookInputRoundTripsTheWrittenDecisions() async throws {
        // The captured 0.156.1 input, answered from the phone: the hook
        // writes exactly the outputs Codex was observed to honour.
        for (name, decision, expected) in [
            ("hook.permission-request.bash.deny.input.json", ControlDecision.reject, "permission-request.bash.deny.expected.json"),
            ("hook.permission-request.bash.allow.input.json", ControlDecision.approve, "permission-request.bash.allow.expected.json")
        ] {
            let relay = try await Relay()
            let phone = try await relay.device()
            let runner = HookRunner(environment: relay.environment(.codex, build: "0.156.1"))
            let native = try input(.codex, "captured-0.156.1/\(name)")
            async let outcome = runner.run(stdin: native)
            let record = try await relay.pendingApproval(for: phone.principal)
            try await relay.decide(decision, record: record, device: phone)
            let result = await outcome
            XCTAssertEqual(result.stdout, try JSONCanonicalization.canonicalize(try JSONValue.parse(try fixture(.codex, expected))), "\(name): \(result.note ?? "")")
        }
    }

    func testWatchCannotApproveAFullReviewShellRequest() async throws {
        let relay = try await Relay()
        let watch = try await relay.device(platform: .watchOS, grants: DeviceGrant.watchDefault)
        let runner = HookRunner(environment: relay.environment(.claudeCode))
        let native = try input(.claudeCode, "permission-request.bash.input.json")
        let task = Task { await runner.run(stdin: native) }
        let record = try await relay.pendingApproval(for: watch.principal)
        do {
            try await relay.decide(.approve, record: record, device: watch)
            XCTFail("a Watch must not approve a full-review request")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .fullReviewRequired)
        }
        task.cancel()
        _ = await task.value
    }

    func testUntestedBuildIsInformationalAndPublishesNothing() async throws {
        // A04.
        let relay = try await Relay()
        let phone = try await relay.device()
        let result = await HookRunner(environment: relay.environment(.claudeCode, attested: false))
            .run(stdin: try input(.claudeCode, "permission-request.bash.input.json"))
        XCTAssertNil(result.stdout)
        XCTAssertTrue(result.note.hasPrefix("unsupported_provider_version"), result.note)
        let snapshot = try await relay.store.snapshot(principal: phone.principal)
        XCTAssertTrue(snapshot.approvals.isEmpty)
        XCTAssertEqual(snapshot.notifications.count, 1, "an attention hint only")
    }

    func testControlUnavailableHandsThePromptBackToTheTerminal() async throws {
        struct Down: AdapterDaemon {
            func exchange(_ type: IPCMessageType, capability: String?, body: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
                throw AdapterDaemonError(code: "unavailable", message: "no socket")
            }
        }
        let relay = try await Relay()
        var environment = relay.environment(.claudeCode)
        environment.daemon = Down()
        let result = await HookRunner(environment: environment).run(stdin: try input(.claudeCode, "permission-request.bash.input.json"))
        XCTAssertNil(result.stdout, "no denial before publication: the terminal prompt applies")
    }

    func testHookThatLosesItsWaitWithdrawsTheRequest() async throws {
        // A13, A14: the provider killed the hook; nothing stays answerable.
        let relay = try await Relay()
        let phone = try await relay.device()
        let runner = HookRunner(environment: relay.environment(.claudeCode))
        let data = try input(.claudeCode, "permission-request.bash.input.json")
        let task = Task { await runner.run(stdin: data) }
        let record = try await relay.pendingApproval(for: phone.principal)
        task.cancel()
        _ = await task.value
        var resolution = Resolution.pending
        for _ in 0..<200 where resolution == .pending {
            resolution = try await relay.store.approval(record.spec.requestID, principal: phone.principal).projection.resolution
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(resolution, .cancelled)
        do {
            try await relay.decide(.approve, record: record, device: phone)
            XCTFail("a withdrawn request must not be approvable")
        } catch let error as ControlError {
            XCTAssertTrue([.alreadyResolved, .staleVersion].contains(error.code), "\(error.code)")
        }
    }

    func testDeadAgentProcessDeniesInsteadOfWriting() async throws {
        let relay = try await Relay()
        let phone = try await relay.device()
        let alive = LockedFlag(true)
        let runner = HookRunner(environment: relay.environment(.claudeCode, ownerAlive: { alive.value }))
        let native = try input(.claudeCode, "permission-request.bash.input.json")
        async let outcome = runner.run(stdin: native)
        let record = try await relay.pendingApproval(for: phone.principal)
        alive.value = false
        try await relay.decide(.approve, record: record, device: phone)
        let result = await outcome
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.note, "native_wait_gone")
        let final = try await relay.store.approval(record.spec.requestID, principal: phone.principal)
        XCTAssertEqual(final.projection.dispatch, .notApplied)
    }

    func testSetupThatConsumedTheBudgetNeverPublishes() async throws {
        // A12: the internal deadline is measured from hook entry.
        let relay = try await Relay()
        let phone = try await relay.device()
        let result = await HookRunner(environment: relay.environment(.claudeCode, elapsed: 310))
            .run(stdin: try input(.claudeCode, "permission-request.bash.input.json"))
        XCTAssertNil(result.stdout)
        let snapshot = try await relay.store.snapshot(principal: phone.principal)
        XCTAssertTrue(snapshot.approvals.isEmpty)
    }

    func testClaudeQuestionAnsweredOnIPhoneReturnsTypedAnswers() async throws {
        let relay = try await Relay()
        let phone = try await relay.device()
        let runner = HookRunner(environment: relay.environment(.claudeCode))
        let native = try input(.claudeCode, "pre-tool-use.ask-user-question.input.json")
        async let outcome = runner.run(stdin: native)
        let record = try await relay.pendingInput(for: phone.principal)
        XCTAssertEqual(record.spec.questions.map(\.prompt), ["Which tests should run next?", "Which platforms?"])
        XCTAssertEqual(record.spec.allowedResponses, [.answer])
        XCTAssertTrue(record.spec.permitsWatchReview)

        let journal = CommandJournal()
        let response = InputResponse.answer([
            .singleChoice(questionID: "q1", choiceID: "c2"),
            .multiChoice(questionID: "q2", choiceIDs: ["c1", "c3"])
        ])
        let challenge = try await relay.store.createAgentChallenge(principal: phone.principal, request: try AgentReviewChallengeRequest(
            requestID: record.spec.requestID, requestHash: record.requestHash,
            expectedStateVersion: record.projection.stateVersion, policyVersion: record.projection.policyVersion
        ))
        let commandID = ControlID.random()
        let command = try InputRespondCommand(
            envelope: try AgentCommandEnvelope(type: .inputRespond, commandID: commandID, deviceID: phone.id,
                                               audience: "shell-control:\(relay.accountID.rawValue)", issuedAt: ControlTimestamp(Date()),
                                               notAfter: challenge.expiresAt),
            requestID: record.spec.requestID, requestHash: record.requestHash,
            expectedStateVersion: record.projection.stateVersion, policyVersion: record.projection.policyVersion,
            challengeID: challenge.challengeID, response: response
        )
        _ = journal
        _ = try await relay.store.submitAgentCommand(principal: phone.principal,
                                                     signedCommand: try ControlJWS.sign(payload: command.json, deviceID: phone.id, key: phone.key),
                                                     idempotencyKey: commandID)
        let result = await outcome
        XCTAssertEqual(result.stdout, try JSONCanonicalization.canonicalize(try JSONValue.parse(
            try fixture(.claudeCode, "pre-tool-use.ask-user-question.answer.expected.json")
        )), result.note)
        let final = try await relay.store.input(record.spec.requestID, principal: phone.principal)
        XCTAssertEqual(final.projection.resolution, .answered)
        XCTAssertEqual(final.projection.dispatch, .nativeResponseWritten)
    }

    func testUnansweredQuestionStaysWithTheTerminal() async throws {
        // A23: no default answer is ever generated.
        let relay = try await Relay()
        let phone = try await relay.device()
        let runner = HookRunner(environment: relay.environment(.claudeCode))
        let native = try input(.claudeCode, "pre-tool-use.ask-user-question.input.json")
        let task = Task { await runner.run(stdin: native) }
        let record = try await relay.pendingInput(for: phone.principal)
        try await relay.store.recordAgentEvent(principal: .origin(originID: relay.originID, accountID: relay.accountID), event: try AgentEvent(
            type: .sessionEnded, originID: relay.originID, agentSessionID: record.spec.source.agentSessionID,
            occurredAt: ControlTimestamp(Date()), observedAt: ControlTimestamp(Date())
        ))
        let result = await task.value
        XCTAssertNil(result.stdout)
        XCTAssertEqual(result.note, "no_remote_answer")
    }

    func testTwoIdenticalRequestsStaySeparate() async throws {
        // A08.
        let relay = try await Relay()
        let phone = try await relay.device()
        let data = try input(.claudeCode, "permission-request.bash.input.json")
        let first = Task { await HookRunner(environment: relay.environment(.claudeCode)).run(stdin: data) }
        let second = Task { await HookRunner(environment: relay.environment(.claudeCode)).run(stdin: data) }
        var records: [ApprovalRecord] = []
        for _ in 0..<400 where records.count < 2 {
            records = try await relay.store.snapshot(principal: phone.principal).approvals.filter { $0.projection.presence.isWaiting }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(records.count, 2)
        let waits = records.compactMap { record -> ControlID? in
            if case .agentTool(let operation) = record.spec.operation { return operation.nativeWaitID }
            return nil
        }
        XCTAssertEqual(Set(waits).count, 2)
        try await relay.decide(.approve, record: records[0], device: phone)
        try await relay.decide(.reject, record: records[1], device: phone)
        let outcomes = await [first.value, second.value].compactMap(\.stdout)
        XCTAssertEqual(Set(outcomes), [
            HookRunner.permissionResponse(allow: true, message: nil, provider: .claudeCode),
            HookRunner.permissionResponse(allow: false, message: "Denied by the reviewer in Shell Control.", provider: .claudeCode)
        ])
    }

    func testDeadAgentSessionIsEndedByTheHeartbeat() async throws {
        let relay = try await Relay()
        let phone = try await relay.device()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        var environment = relay.environment(.claudeCode)
        environment.ownerPID = child.processIdentifier
        let runner = HookRunner(environment: environment)
        let native = try input(.claudeCode, "permission-request.bash.input.json")
        let task = Task { await runner.run(stdin: native) }
        let record = try await relay.pendingApproval(for: phone.principal)
        guard case .agentTool(let operation) = record.spec.operation else { return XCTFail("operation") }
        child.terminate()
        child.waitUntilExit()
        await relay.core.heartbeatOnce()
        let session = try await relay.store.agentSession(operation.agentSessionID, principal: phone.principal)
        XCTAssertEqual(session.state, .ended, "a killed agent never runs SessionEnd; the daemon reports it")
        task.cancel()
        _ = await task.value
    }

    func testUnrecoverableInputRecoveryIsRetired() async throws {
        let relay = try await Relay()
        // A persisted input the broker never accepted: its withdrawal can
        // only ever be answered not_found.
        let journal = await relay.core.journal
        try journal.append(.inputPersisted(requestID: .random(), requestHash: "sha256:" + String(repeating: "c", count: 64), runID: .random()))
        let restarted = try DaemonCore(configuration: await relay.core.configuration, client: await relay.core.client)
        try await restarted.reconcileAfterRestart()
        let health = await restarted.health()
        XCTAssertEqual(health["recovery_pending"], .number(.int(0)))
        let queued = try journal.load().contains { if case .recoveryQueued(_, "input_withdraw", _, _) = $0 { return true }; return false }
        XCTAssertTrue(queued, "the withdrawal was attempted, then retired")
        XCTAssertTrue(try journal.pendingRecoveries().isEmpty)
    }

    func testSafeFixtureRunsThroughTheWholePipeline() async throws {
        let relay = try await Relay()
        let phone = try await relay.device()
        let task = Task { try await AgentFixtureDriver.run(daemon: InProcessDaemon(core: relay.core)) }
        let record = try await relay.pendingApproval(for: phone.principal)
        try await relay.decide(.approve, record: record, device: phone)
        let passed = try await task.value
        XCTAssertTrue(passed)
        let final = try await relay.store.approval(record.spec.requestID, principal: phone.principal)
        XCTAssertEqual(final.projection.dispatch, .notApplied, "the fixture never executes")
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The CLI's fixture logic lives in the executable; this mirrors it against
/// the library surface so the pipeline is covered here too.
enum AgentFixtureDriver {
    static func run(daemon: any AdapterDaemon) async throws -> Bool {
        var run = try await AdapterRun.start(daemon: daemon, adapter: "shell-agent-fixture", jobLabel: "Agent relay test")
        try await run.register(.object([
            "provider": "shell_fixture", "provider_build": "1.0.0", "adapter_build": "1.0.0",
            "profile": "hook", "evidence": "contract_tested", "operations": JSONValue(strings: [AgentFeature.shell])
        ]))
        let hex = ContentDigest.sha256Hex(Data("shell-agent-fixture/1".utf8))
        let operation = try AgentToolOperation(
            provider: "shell_fixture", providerBuild: "1.0.0", adapterBuild: "1.0.0", agentSessionID: try XCTUnwrap(run.agentSessionID),
            nativeWaitID: .random(), kind: .shell, toolName: "Bash", cwd: "/",
            shellRequest: try AgentShellRequest(representation: .commandString, command: "true"),
            nativeRequestSHA256: hex, contextSHA256: hex
        )
        var created = try JSONReader(try await run.send(.approvalRequest, .object([
            "summary": "Agent relay test — nothing will run", "operation": operation.json,
            "lifetime_seconds": 60, "minimum_review": "full"
        ])))
        let requestID = try created.id("request_id"), hash = try created.string("request_hash", maxLength: 80)
        let outcome = try ApprovalWaitOutcome(json: try await run.send(.approvalWait, .object([
            "request_id": JSONValue(requestID), "request_hash": .string(hash), "timeout_seconds": 60
        ]), timeout: 70))
        guard case .approved(let permit) = outcome else { return false }
        for dispatch in [AgentDispatch.dispatchStarted, .notApplied] {
            _ = try await run.send(.agentReceipt, .object([
                "request_kind": "approval", "request_id": JSONValue(requestID), "request_hash": .string(hash),
                "native_wait_id": JSONValue(operation.nativeWaitID), "decision_id": JSONValue(permit.decisionID),
                "consume_id": JSONValue(permit.consumeID), "dispatch": .string(dispatch.rawValue), "evidence": "fixture_noop"
            ]))
        }
        return true
    }
}
