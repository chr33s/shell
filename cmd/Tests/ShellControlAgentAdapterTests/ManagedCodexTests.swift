import Foundation
import Testing
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient
import ShellControlBroker
@testable import ShellControlDaemon
@testable import ShellControlAgentAdapter

/// The experimental managed Codex profile against a scripted app-server and
/// the real in-process broker and daemon (docs/specs/agent-relay.md sections 10.2,
/// 11.3, 16; A15, A16, A35, A36).
@Suite
final class ManagedCodexTests {
    /// A scripted `codex app-server`: answers our requests as the documented
    /// protocol does, records everything we send, and emits server requests
    /// and notifications on demand.
    final class FakeAppServer: JSONRPCTransport, @unchecked Sendable {
        let incoming: AsyncThrowingStream<JSONValue, any Error>
        private let continuation: AsyncThrowingStream<JSONValue, any Error>.Continuation
        private let lock = NSLock()
        private var sent: [JSONValue] = []
        private var turns = 0
        var refuseSteer = false

        init() {
            var continuation: AsyncThrowingStream<JSONValue, any Error>.Continuation!
            incoming = AsyncThrowingStream { continuation = $0 }
            self.continuation = continuation
        }

        var messages: [JSONValue] { lock.withLock { sent } }

        func emit(_ value: JSONValue) { continuation.yield(value) }

        func send(_ message: JSONValue) async throws {
            lock.withLock { sent.append(message) }
            guard let method = message["method"]?.stringValue, let id = message["id"] else { return }
            switch method {
            case "initialize":
                emit(.object(["id": id, "result": .object(["userAgent": "codex/0.156.1"])]))
            case "thread/start", "thread/resume":
                emit(.object(["id": id, "result": .object(["thread": .object(["id": "thr_1"])])]))
            case "turn/start":
                let turn = lock.withLock { turns += 1; return "turn_\(turns)" }
                emit(.object(["id": id, "result": .object(["turn": .object(["id": .string(turn), "status": "inProgress"])])]))
                emit(.object(["method": "turn/started", "params": .object(["turn": .object(["id": .string(turn)])])]))
            case "turn/steer":
                if refuseSteer {
                    emit(.object(["id": id, "error": .object(["code": -32600, "message": "turn is not active"])]))
                } else {
                    emit(.object(["id": id, "result": .object(["turnId": message["params"]?["expectedTurnId"] ?? .null])]))
                }
            case "turn/interrupt":
                emit(.object(["id": id, "result": .object([:])]))
                emit(.object(["method": "turn/completed", "params": .object(["turn": .object([
                    "id": message["params"]?["turnId"] ?? .null, "status": "interrupted"
                ])])]))
            default:
                emit(.object(["id": id, "error": .object(["code": -32601, "message": "unknown method"])]))
            }
        }

        func close() async { continuation.finish() }

        func waitFor(_ predicate: (JSONValue) -> Bool) async throws -> JSONValue {
            for _ in 0..<500 {
                if let found = messages.first(where: predicate) { return found }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw ManagedCodexMessageTimeout()
        }
    }

    final class FakeTerminal: ManagedTerminal, @unchecked Sendable {
        let lines: AsyncStream<String>
        let input: AsyncStream<String>.Continuation
        private let lock = NSLock()
        private var output = ""

        init() {
            var continuation: AsyncStream<String>.Continuation!
            lines = AsyncStream { continuation = $0 }
            input = continuation
        }

        func write(_ text: String) { lock.withLock { output += text } }
        var text: String { lock.withLock { output } }
    }

    typealias Relay = AgentRelayEndToEndTests.Relay

    func makeSession(_ relay: Relay, server: FakeAppServer, terminal: FakeTerminal,
                     daemon: (any AdapterDaemon)? = nil) -> CodexManagedSession {
        let configuration = AdapterConfiguration(
            provider: .codex,
            routes: [.appServerCommandApproval, .appServerFileChangeApproval, .appServerUserInput, .appServerTurnControl],
            userAttestedBuilds: ["0.156.1"]
        )
        let environment = ManagedEnvironment(
            configuration: configuration, build: "0.156.1",
            daemon: daemon ?? AgentRelayEndToEndTests.InProcessDaemon(core: relay.core),
            cwd: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path, ownerPID: getpid(), ownerAlive: { true },
            effectiveUserID: geteuid(), policyFingerprint: { _ in String(repeating: "c", count: 64) }, terminalLocation: { nil },
            fileSystem: LocalFileSystem(), log: { _ in }, commandWaitSeconds: 1
        )
        return CodexManagedSession(environment: environment, terminal: terminal, transport: server)
    }

    func session(_ relay: Relay, for principal: Principal) async throws -> AgentSessionProjection {
        let page = try await relay.store.agentSnapshot(principal: principal, pageToken: nil, limit: 50)
        return try #require(page.sessions.first { $0.registration.profile == .managed })
    }

    func sendCommand(_ relay: Relay, action: AgentSessionAction, device: (id: ControlID, key: InMemoryDeviceKey, principal: Principal)) async throws -> ControlID {
        let challenge = try await relay.store.createAgentChallenge(principal: device.principal, request: try AgentReviewChallengeRequest(sessionAction: action))
        let commandID = ControlID.random()
        let command = try AgentSessionCommand(
            envelope: try AgentCommandEnvelope(type: action.commandType, commandID: commandID, deviceID: device.id,
                                               audience: "shell-control:\(relay.accountID.rawValue)", issuedAt: ControlTimestamp(Date()),
                                               notAfter: challenge.expiresAt),
            action: action, challengeID: challenge.challengeID
        )
        _ = try await relay.store.submitAgentCommand(principal: device.principal,
                                                     signedCommand: try ControlJWS.sign(payload: command.json, deviceID: device.id, key: device.key),
                                                     idempotencyKey: commandID)
        return commandID
    }

    func dispatch(_ relay: Relay, _ commandID: ControlID, device: Principal, until state: AgentDispatch) async throws -> AgentDispatch {
        var current = AgentDispatch.none
        for _ in 0..<400 {
            current = try await relay.store.agentCommandResult(commandID, principal: device).dispatch ?? .none
            if current == state || current.isTerminal { return current }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return current
    }

    var phoneGrants: Set<DeviceGrant> {
        DeviceGrant.watchDefault.union(DeviceGrant.agentPhone).union([.agentMessagesSend, .agentTurnsCancel])
    }

    @Test
    func testManagedSessionRegistersAndRunsMobileTurnsSteeringAndCancellation() async throws {
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        defer { Task { await managed.stop() } }

        var projection = try await session(relay, for: phone.principal)
        #expect(projection.turnState == .idle)
        #expect(projection.offers(AgentFeature.messages))
        #expect(projection.offers(AgentFeature.turnCancel))
        // Approvals must reach the gate.
        #expect(server.messages.first { $0["method"] == "thread/start" }?["params"]?["approvalPolicy"] == "untrusted", "a value the 0.156.1 enum accepts")

        // A new instruction from the phone starts a turn with exactly the text.
        let start = try await sendCommand(relay, action: try AgentSessionCoordinator.messageAction("Run the tests", session: projection), device: phone)
        let started = try await server.waitFor { $0["method"] == "turn/start" }
        #expect(started["params"]?["input"]?.arrayValue?.first?["text"] == "Run the tests")
        #expect(started["params"]?.objectValue?.keys.sorted() == ["input", "threadId"], "no caller overrides")
        let startDispatch = try await dispatch(relay, start, device: phone.principal, until: .accepted)
        #expect(startDispatch == .accepted)

        // The session now reports the active turn; a second new turn is refused.
        for _ in 0..<200 {
            projection = try await session(relay, for: phone.principal)
            if projection.turnState == .active { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(projection.activeTurnID == "turn_1")
        await assertControlError(.staleVersion) {
            _ = try await self.sendCommand(relay, action: .message(
                agentSessionID: projection.registration.agentSessionID, runID: projection.registration.runID,
                expectedSessionVersion: projection.sessionVersion, mode: .newTurn, expectedTurnID: nil, text: "again"
            ), device: phone)
        }

        // Steering names the exact active turn (A35).
        let steer = try await sendCommand(relay, action: try AgentSessionCoordinator.messageAction("Only unit tests", session: projection), device: phone)
        let steered = try await server.waitFor { $0["method"] == "turn/steer" }
        #expect(steered["params"]?["expectedTurnId"] == "turn_1")
        let steerDispatch = try await dispatch(relay, steer, device: phone.principal, until: .accepted)
        #expect(steerDispatch == .accepted)

        // Cancellation is acknowledged, not proof of termination (A36).
        projection = try await session(relay, for: phone.principal)
        let cancel = try await sendCommand(relay, action: try AgentSessionCoordinator.cancelAction(session: projection), device: phone)
        let interrupted = try await server.waitFor { $0["method"] == "turn/interrupt" }
        #expect(interrupted["params"]?["turnId"] == "turn_1")
        let cancelDispatch = try await dispatch(relay, cancel, device: phone.principal, until: .accepted)
        #expect(cancelDispatch == .accepted)
        for _ in 0..<200 {
            projection = try await session(relay, for: phone.principal)
            if projection.turnState == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(projection.turnState == .idle)
    }

    @Test
    func testDevicesWithoutTheGrantCannotCommandASession() async throws {
        let relay = try await Relay()
        let phone = try await relay.device()
        let server = FakeAppServer(), terminal = FakeTerminal()
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        defer { Task { await managed.stop() } }
        let projection = try await session(relay, for: phone.principal)
        await assertControlError(.notAuthorized) {
            _ = try await self.sendCommand(relay, action: try AgentSessionCoordinator.messageAction("hi", session: projection), device: phone)
        }
    }

    @Test
    func testRemoteApprovalAnswersTheExactRPCRequestAndCorrelatesAcceptance() async throws {
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        defer { Task { await managed.stop() } }
        let cwd = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        // The 0.156.1 shape: a command string, no decision list.
        server.emit(.object(["method": "item/commandExecution/requestApproval", "id": 100, "params": .object([
            "threadId": "thr_1", "turnId": "turn_9", "itemId": "item_1", "command": "npm test", "startedAtMs": 1790000000000,
            "cwd": .string(cwd), "reason": "Run tests", "commandActions": [], "proposedExecpolicyAmendment": ["npm", "test"],
            "approvalId": .null, "networkApprovalContext": .null
        ])]))
        let record = try await relay.pendingApproval(for: phone.principal)
        guard case .agentTool(let operation) = record.spec.operation else { Issue.record("operation")
return }
        #expect(operation.shellRequest?.representation == .commandString, "one command string, never split")
        #expect(operation.shellRequest?.command == "npm test")
        #expect(operation.providerRequestID == .integer(100), "native id type preserved")
        #expect(operation.connectionEpoch == managed.connectionEpoch)
        try await relay.decide(.approve, record: record, device: phone)
        let response = try await server.waitFor { $0["id"] == 100 && $0["result"] != nil }
        #expect(response["result"] == .object(["decision": "accept"]), "never acceptForSession")
        // Resolution names only the request; acceptance comes from the item.
        server.emit(.object(["method": "serverRequest/resolved", "params": .object(["requestId": 100, "threadId": "thr_1"])]))
        server.emit(.object(["method": "item/started", "params": .object([
            "threadId": "thr_1", "turnId": "turn_9", "startedAtMs": 1790000000001,
            "item": .object(["type": "commandExecution", "id": "item_1", "command": "npm test", "status": "inProgress"])
        ])]))
        var dispatch = Dispatch.none
        for _ in 0..<200 {
            dispatch = try await relay.store.approval(record.spec.requestID, principal: phone.principal).projection.dispatch
            if dispatch == .applied { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(dispatch == .applied, "correlated acceptance is the only path to applied")
    }

    @Test
    func testLocalDecisionWithdrawsTheRemoteRequest() async throws {
        // A16: the local terminal answers first; the phone cannot revive it.
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        let runner = Task { await managed.runTerminal() }
        defer { Task { await managed.stop(); runner.cancel() } }
        server.emit(.object(["method": "item/commandExecution/requestApproval", "id": "req-a", "params": .object([
            "threadId": "thr_1", "turnId": "turn_9", "itemId": "item_1", "command": "make", "startedAtMs": 1790000000000,
            "cwd": .string(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        ])]))
        let record = try await relay.pendingApproval(for: phone.principal)
        terminal.input.yield("/deny 1")
        let response = try await server.waitFor { $0["id"] == "req-a" && $0["result"] != nil }
        #expect(response["result"] == .object(["decision": "decline"]))
        let final = try await relay.store.approval(record.spec.requestID, principal: phone.principal)
        #expect(final.projection.resolution == .cancelled)
        do {
            try await relay.decide(.approve, record: record, device: phone)
            Issue.record("a locally answered request must not be approvable")
        } catch is ControlError {}
    }

    @Test
    func testInvalidLocalAnswerLeavesRemoteInputOpen() async throws {
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        let runner = Task { await managed.runTerminal() }
        defer { Task { await managed.stop(); runner.cancel() } }
        server.emit(.object(["method": "item/tool/requestUserInput", "id": 103, "params": .object([
            "threadId": "thr_1", "turnId": "turn_4", "itemId": "item_6", "isBlocking": true,
            "questions": [
                .object(["id": "first", "question": "First?", "options": .null]),
                .object(["id": "second", "question": "Second?", "options": .null])
            ]
        ])]))
        let record = try await relay.pendingInput(for: phone.principal)
        terminal.input.yield("/deny 1")
        terminal.input.yield("/answer 1 only-one")
        for _ in 0..<100 where !terminal.text.contains("give 2 answers") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(terminal.text.contains("that command does not answer #1"))
        #expect(terminal.text.contains("give 2 answers"))
        let open = try await relay.store.input(record.spec.requestID, principal: phone.principal)
        #expect(open.projection.resolution == .pending)
        #expect(!(server.messages.contains { $0["id"] == 103 && $0["result"] != nil }))
        terminal.input.yield("/answer 1 first || second")
        let response = try await server.waitFor { $0["id"] == 103 && $0["result"] != nil }
        #expect(response["result"] == .object(["answers": .object([
            "first": .object(["answers": ["first"]]), "second": .object(["answers": ["second"]])
        ])]))
    }

    /// Delays the dispatch_started receipt so a local answer can race it.
    struct SlowReceiptDaemon: AdapterDaemon {
        let inner: any AdapterDaemon
        func exchange(_ type: IPCMessageType, capability: String?, body: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
            if type == .agentReceipt, body["dispatch"] == "dispatch_started" { try await Task.sleep(nanoseconds: 300_000_000) }
            return try await inner.exchange(type, capability: capability, body: body, timeout: timeout)
        }
    }

    @Test
    func testLocalAnswerDuringRemoteDispatchNeverAnswersTwice() async throws {
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        var configuration = AdapterConfiguration(provider: .codex, routes: [.appServerCommandApproval], userAttestedBuilds: ["0.156.1"])
        configuration.watchShellApproval = false
        let environment = ManagedEnvironment(
            configuration: configuration, build: "0.156.1",
            daemon: SlowReceiptDaemon(inner: AgentRelayEndToEndTests.InProcessDaemon(core: relay.core)),
            cwd: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path, ownerPID: getpid(), ownerAlive: { true },
            effectiveUserID: geteuid(), policyFingerprint: { _ in String(repeating: "c", count: 64) }, terminalLocation: { nil },
            fileSystem: LocalFileSystem(), log: { _ in }, commandWaitSeconds: 1
        )
        let managed = CodexManagedSession(environment: environment, terminal: terminal, transport: server)
        try await managed.start()
        let runner = Task { await managed.runTerminal() }
        defer { Task { await managed.stop(); runner.cancel() } }
        server.emit(.object(["method": "item/commandExecution/requestApproval", "id": 44, "params": .object([
            "threadId": "thr_1", "turnId": "t", "itemId": "i", "command": "make", "startedAtMs": 1,
            "cwd": .string(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        ])]))
        let record = try await relay.pendingApproval(for: phone.principal)
        try await relay.decide(.reject, record: record, device: phone)
        // While the remote denial journals dispatch_started, the terminal
        // tries to approve the same request.
        try await Task.sleep(nanoseconds: 150_000_000)
        terminal.input.yield("/approve 1")
        _ = try await server.waitFor { $0["id"] == 44 && $0["result"] != nil }
        try await Task.sleep(nanoseconds: 600_000_000)
        let answers = server.messages.filter { $0["id"] == 44 && $0["result"] != nil }
        #expect(answers.count == 1, "one native request, one answer")
        #expect(answers.first?["result"] == .object(["decision": "decline"]))
    }

    @Test
    func testScopeWideningApprovalsStayLocal() async throws {
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        defer { Task { await managed.stop() } }
        let base: [String: JSONValue] = ["threadId": "thr_1", "turnId": "t", "itemId": "i", "command": "curl example.com", "cwd": "/", "startedAtMs": 1]
        var network = base; network["networkApprovalContext"] = .object(["host": "example.com", "protocol": "https"])
        var stdin = base; stdin["kind"] = "writeStdin"
        var environment = base; environment["environmentId"] = "remote-1"
        for (id, params) in [(1, network), (2, stdin), (3, environment)] {
            server.emit(.object(["method": "item/commandExecution/requestApproval", "id": .number(.int(Int64(id))), "params": .object(params)]))
        }
        // A directory-wide write grant and changes never observed stay local.
        server.emit(.object(["method": "item/fileChange/requestApproval", "id": 4, "params": .object([
            "threadId": "thr_1", "turnId": "t", "itemId": "unseen", "startedAtMs": 1
        ])]))
        server.emit(.object(["method": "item/fileChange/requestApproval", "id": 5, "params": .object([
            "threadId": "thr_1", "turnId": "t", "itemId": "i2", "grantRoot": "/", "startedAtMs": 1
        ])]))
        // A request this client cannot answer is refused at once, not left hanging.
        server.emit(.object(["method": "item/permissions/requestApproval", "id": 6, "params": .object([:])]))
        let refused = try await server.waitFor { $0["id"] == 6 && $0["error"] != nil }
        #expect(refused["error"]?["code"] == -32601)
        try await Task.sleep(nanoseconds: 200_000_000)
        let snapshot = try await relay.store.snapshot(principal: phone.principal)
        #expect(snapshot.approvals.isEmpty)
    }

    @Test
    func testCapturedLiveApprovalShapeIsRemotelyAnswerable() async throws {
        // Captured from codex-cli 0.156.1: environmentId "local", a zsh
        // command string, and availableDecisions without "decline".
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        defer { Task { await managed.stop() } }
        let captured = try JSONValue.parse(try Data(contentsOf: AdapterContractTests.repository
            .appendingPathComponent("adapters/codex/fixtures/captured-0.156.1/app-server.command-approval.json")))
        var params = try #require(captured["params"]?.objectValue)
        params["threadId"] = "thr_1"
        params["cwd"] = .string(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path)
        server.emit(.object(["method": "item/commandExecution/requestApproval", "id": 0, "params": .object(params)]))
        let record = try await relay.pendingApproval(for: phone.principal)
        guard case .agentTool(let operation) = record.spec.operation else { Issue.record("operation")
return }
        #expect(operation.shellRequest?.command == "/bin/zsh -lc 'touch codex-denied.txt'")
        try await relay.decide(.reject, record: record, device: phone)
        let response = try await server.waitFor { $0["id"] == 0 && $0["result"] != nil }
        #expect(response["result"] == .object(["decision": "cancel"]), "decline was not offered, so the offered denial is used")
    }

    @Test
    func testFileChangeApprovalJoinsTheObservedItem() async throws {
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        defer { Task { await managed.stop() } }
        let path = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("managed-\(UUID().uuidString).txt").path
        server.emit(.object(["method": "item/started", "params": .object([
            "threadId": "thr_1", "turnId": "t", "startedAtMs": 1,
            "item": .object(["type": "fileChange", "id": "fc_1", "status": "inProgress",
                             "changes": [.object(["path": .string(path), "diff": "+hello\n", "kind": .object(["type": "add"])])]])
        ])]))
        server.emit(.object(["method": "item/fileChange/requestApproval", "id": 9, "params": .object([
            "threadId": "thr_1", "turnId": "t", "itemId": "fc_1", "reason": "Create a file", "startedAtMs": 2
        ])]))
        let record = try await relay.pendingApproval(for: phone.principal)
        guard case .agentTool(let operation) = record.spec.operation else { Issue.record("operation")
return }
        #expect(operation.kind == .fileChange)
        #expect(operation.fileChanges?.first?.change == .create)
        #expect(operation.fileChanges?.first?.diff == "+hello\n")
        #expect(record.spec.minimumReview == .full)
        try await relay.decide(.reject, record: record, device: phone)
        let response = try await server.waitFor { $0["id"] == 9 && $0["result"] != nil }
        #expect(response["result"] == .object(["decision": "decline"]))
        server.emit(.object(["method": "serverRequest/resolved", "params": .object(["requestId": 9, "threadId": "thr_1"])]))
        server.emit(.object(["method": "item/completed", "params": .object([
            "threadId": "thr_1", "turnId": "t", "completedAtMs": 3,
            "item": .object(["type": "fileChange", "id": "fc_1", "status": "declined", "changes": []])
        ])]))
        var dispatch = Dispatch.none
        for _ in 0..<200 {
            dispatch = try await relay.store.approval(record.spec.requestID, principal: phone.principal).projection.dispatch
            if dispatch == .applied { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(dispatch == .applied, "the declined status correlates the decline")
    }

    @Test
    func testUnknownApprovalFieldsStayLocal() async throws {
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        defer { Task { await managed.stop() } }
        server.emit(.object(["method": "item/commandExecution/requestApproval", "id": 7, "params": .object([
            "threadId": "thr_1", "turnId": "t", "itemId": "i", "command": "curl x", "cwd": "/", "startedAtMs": 1,
            "futureScopeField": .object(["host": "example.com"])
        ])]))
        try await Task.sleep(nanoseconds: 200_000_000)
        let snapshot = try await relay.store.snapshot(principal: phone.principal)
        #expect(snapshot.approvals.isEmpty)
        #expect(terminal.text.contains("stays local"))
    }

    @Test
    func testRemoteAnswerToRequestUserInput() async throws {
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        defer { Task { await managed.stop() } }
        #expect(server.messages.first { $0["method"] == "initialize" }?["params"]?["capabilities"]?["experimentalApi"] == true)
        server.emit(.object(["method": "item/tool/requestUserInput", "id": 102, "params": .object([
            "threadId": "thr_1", "turnId": "turn_4", "itemId": "item_5", "isBlocking": true, "autoResolutionMs": 120000,
            "questions": [
                .object(["id": "target", "header": "Version", "question": "Target version?", "isOther": false, "isSecret": false,
                         "options": [.object(["label": "1.5.0", "description": "Next minor"]), .object(["label": "2.0.0", "description": "Next major"])]]),
                .object(["id": "notes", "header": "Notes", "question": "Notes?", "isOther": true, "isSecret": false, "options": .null])
            ]
        ])]))
        let record = try await relay.pendingInput(for: phone.principal)
        #expect(record.spec.source.providerRequestID == .integer(102))
        #expect(record.spec.expiresAt.date.timeIntervalSince(record.spec.createdAt.date) <= 115, "the native auto-resolution shortens the deadline")
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
            challengeID: challenge.challengeID,
            response: .answer([.singleChoice(questionID: "q1", choiceID: "c1"), .text(questionID: "q2", text: "Keep compat")])
        )
        _ = try await relay.store.submitAgentCommand(principal: phone.principal,
                                                     signedCommand: try ControlJWS.sign(payload: command.json, deviceID: phone.id, key: phone.key),
                                                     idempotencyKey: commandID)
        let response = try await server.waitFor { $0["id"] == 102 && $0["result"] != nil }
        #expect(response["result"] == .object(["answers": .object([
            "target": .object(["answers": ["1.5.0"]]), "notes": .object(["answers": ["Keep compat"]])
        ])]))
    }

    struct WrongInputPermitDaemon: AdapterDaemon {
        let inner: any AdapterDaemon

        func exchange(_ type: IPCMessageType, capability: String?, body: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
            let response = try await inner.exchange(type, capability: capability, body: body, timeout: timeout)
            guard type == .inputWait, response["outcome"] == "answered",
                  var fields = response.objectValue, var permit = fields["permit"]?.objectValue else { return response }
            permit["request_id"] = JSONValue(ControlID.random())
            permit["request_hash"] = .string(String(repeating: "0", count: 64))
            fields["permit"] = .object(permit)
            return .object(fields)
        }
    }

    @Test
    func testManagedInputRejectsPermitForAnotherRequest() async throws {
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        let daemon = WrongInputPermitDaemon(inner: AgentRelayEndToEndTests.InProcessDaemon(core: relay.core))
        let managed = makeSession(relay, server: server, terminal: terminal, daemon: daemon)
        try await managed.start()
        defer { Task { await managed.stop() } }
        server.emit(.object(["method": "item/tool/requestUserInput", "id": 104, "params": .object([
            "threadId": "thr_1", "turnId": "turn_4", "itemId": "item_7", "isBlocking": true,
            "questions": [.object(["id": "notes", "question": "Notes?", "options": .null])]
        ])]))
        let record = try await relay.pendingInput(for: phone.principal)
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
            challengeID: challenge.challengeID, response: .answer([.text(questionID: "q1", text: "answer")])
        )
        _ = try await relay.store.submitAgentCommand(principal: phone.principal,
                                                     signedCommand: try ControlJWS.sign(payload: command.json, deviceID: phone.id, key: phone.key),
                                                     idempotencyKey: commandID)
        for _ in 0..<100 where !terminal.text.contains("no remote answer") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(terminal.text.contains("no remote answer"))
        #expect(!(server.messages.contains { $0["id"] == 104 && $0["result"] != nil }))
    }

    @Test
    func testRefusedSteeringIsNotApplied() async throws {
        let relay = try await Relay()
        let phone = try await relay.device(grants: phoneGrants)
        let server = FakeAppServer(), terminal = FakeTerminal()
        server.refuseSteer = true
        let managed = makeSession(relay, server: server, terminal: terminal)
        try await managed.start()
        defer { Task { await managed.stop() } }
        var projection = try await session(relay, for: phone.principal)
        _ = try await sendCommand(relay, action: try AgentSessionCoordinator.messageAction("go", session: projection), device: phone)
        for _ in 0..<200 {
            projection = try await session(relay, for: phone.principal)
            if projection.turnState == .active { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let steer = try await sendCommand(relay, action: try AgentSessionCoordinator.messageAction("more", session: projection), device: phone)
        let result = try await dispatch(relay, steer, device: phone.principal, until: .notApplied)
        #expect(result == .notApplied, "an explicit provider refusal is not applied, never retried")
    }
}

private struct ManagedCodexMessageTimeout: Error, CustomStringConvertible {
    var description: String { "expected message never sent" }
}

func assertControlError(
    _ expected: ControlErrorCode,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        Issue.record("expected \(expected.rawValue)", sourceLocation: sourceLocation)
    } catch let error as ControlError {
        #expect(error.code == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected \(expected.rawValue), got \(error)", sourceLocation: sourceLocation)
    }
}
