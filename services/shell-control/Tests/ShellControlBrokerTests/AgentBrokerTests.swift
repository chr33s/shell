import Foundation
import Testing
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlBroker

/// Broker rules for `shell-agent/1` (docs/specs/agent-relay.md section 20).
@Suite
final class AgentBrokerTests {
    private let hex = String(repeating: "b", count: 64)

    struct Agent {
        let runID: ControlID
        let jobID: ControlID
        let sessionID: ControlID
    }

    private func phone(_ harness: BrokerHarness, grants: Set<DeviceGrant> = DeviceGrant.watchDefault.union(DeviceGrant.agentPhone)) async throws -> BrokerHarness.Device {
        let key = InMemoryDeviceKey()
        let id = try await harness.store.enrollDevice(accountID: harness.accountID, publicJWK: key.publicJWK, platform: .iOS, label: "iPhone", grants: grants)
        return .init(id: id, key: key, principal: try await harness.store.authenticateDevice(id))
    }

    private func startAgent(_ harness: BrokerHarness, operations: [String] = [AgentFeature.shell, AgentFeature.fileChange, AgentFeature.input]) async throws -> Agent {
        let runID = ControlID.random(), jobID = ControlID.random(), sessionID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        _ = try await harness.store.registerAgentSession(principal: harness.originPrincipal, registration: try AgentSessionRegistration(
            agentSessionID: sessionID, runID: runID, provider: "claude_code", providerBuild: "2.1.281", adapterBuild: "1.0.0",
            profile: .hook, evidence: .contractTested, operations: operations, providerSessionID: "s", startedAt: harness.timestamp
        ))
        return Agent(runID: runID, jobID: jobID, sessionID: sessionID)
    }

    private func shellApproval(_ harness: BrokerHarness, agent: Agent, scope: String = AgentPermissionScope.singleNativeGate, waitID: ControlID = .random()) throws -> ApprovalSpec {
        let operation = try AgentToolOperation(
            provider: "claude_code", providerBuild: "2.1.281", adapterBuild: "1.0.0",
            agentSessionID: agent.sessionID, nativeWaitID: waitID, kind: .shell, toolName: "Bash", cwd: "/tmp",
            permissionScope: scope,
            shellRequest: try AgentShellRequest(representation: .commandString, command: "git status"),
            nativeRequestSHA256: hex, contextSHA256: hex
        )
        return try ApprovalSpec(
            requestID: .random(), originID: harness.originID, jobID: agent.jobID, runID: agent.runID,
            createdAt: harness.timestamp, expiresAt: harness.timestamp.adding(300), summary: "Bash: git status",
            operation: .agentTool(operation), minimumReview: .full, requiredFeatures: operation.requiredFeatures
        )
    }

    private func inputSpec(_ harness: BrokerHarness, agent: Agent, review: MinimumReview = .watch, lifetime: TimeInterval = 300, allowDecline: Bool = false) throws -> InputSpec {
        try InputSpec(
            requestID: .random(), originID: harness.originID, jobID: agent.jobID, runID: agent.runID,
            createdAt: harness.timestamp, expiresAt: harness.timestamp.adding(lifetime), summary: "Choose the test scope",
            source: try InputSource(
                provider: "claude_code", providerBuild: "2.1.281", adapterBuild: "1.0.0",
                nativeRequestSHA256: hex, contextSHA256: hex, answerMappingSHA256: hex,
                agentSessionID: agent.sessionID, nativeWaitID: .random()
            ),
            questions: [try InputQuestion(id: "scope", prompt: "Which tests?", kind: .singleChoice(choices: [
                try InputChoice(id: "focused", label: "Changed modules"), try InputChoice(id: "all", label: "Everything")
            ]), required: true)],
            allowedResponses: allowDecline ? [.answer, .decline] : [.answer],
            minimumReview: review
        )
    }

    private func publishInput(_ harness: BrokerHarness, _ spec: InputSpec) async throws -> InputRecord {
        let record = try await harness.store.createInput(principal: harness.originPrincipal, spec: spec)
        try await harness.store.heartbeat(principal: harness.originPrincipal, runIDs: [spec.runID], waitingRequestIDs: [spec.requestID])
        return try await harness.store.input(spec.requestID, principal: harness.originPrincipal)
            .withResponse(record.response)
    }

    private func respond(
        _ harness: BrokerHarness, device: BrokerHarness.Device, record: InputRecord,
        response: InputResponse, commandID: ControlID = .random(), principal: Principal? = nil
    ) async throws -> (result: AgentCommandResult, isReplay: Bool) {
        let actor = principal ?? device.principal
        let challenge = try await harness.store.createAgentChallenge(principal: actor, request: try AgentReviewChallengeRequest(
            requestID: record.spec.requestID, requestHash: record.requestHash,
            expectedStateVersion: record.projection.stateVersion, policyVersion: record.projection.policyVersion
        ))
        let jws = try sign(harness, device: device, record: record, response: response, challengeID: challenge.challengeID, commandID: commandID)
        return try await harness.store.submitAgentCommand(principal: actor, signedCommand: jws, idempotencyKey: commandID)
    }

    private func sign(_ harness: BrokerHarness, device: BrokerHarness.Device, record: InputRecord, response: InputResponse, challengeID: String, commandID: ControlID) throws -> String {
        let command = try InputRespondCommand(
            envelope: try AgentCommandEnvelope(
                type: .inputRespond, commandID: commandID, deviceID: device.id,
                audience: "shell-control:\(harness.accountID.rawValue)", issuedAt: harness.timestamp,
                notAfter: min(harness.timestamp.adding(60), record.spec.expiresAt)
            ),
            requestID: record.spec.requestID, requestHash: record.requestHash,
            expectedStateVersion: record.projection.stateVersion, policyVersion: record.projection.policyVersion,
            challengeID: challengeID, response: response
        )
        return try ControlJWS.sign(payload: command.json, deviceID: device.id, key: device.key)
    }

    private func consume(_ harness: BrokerHarness, record: InputRecord, commandID: ControlID, response: InputResponse, mutationID: ControlID = .random()) async throws -> InputConsumePermit {
        try await harness.store.consumeInput(principal: harness.originPrincipal, requestID: record.spec.requestID, request: InputConsumeRequest(
            mutationID: mutationID, runID: record.spec.runID, nativeWaitID: record.spec.source.nativeWaitID,
            requestHash: record.requestHash, commandID: commandID, responseHash: response.responseHash
        ))
    }

    // MARK: Approvals

    @Test
    func testAgentApprovalFlowsThroughTheBaseLedgerWithDetailedDelivery() async throws {
        // A01: approve, claim, write, and a conservative legacy receipt.
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let spec = try shellApproval(harness, agent: agent)
        let record = try await harness.publish(spec)
        let decided = try await harness.decide(.approve, device: device, record: record)
        #expect(decided.result.resolution == .approved)

        let consumeID = ControlID.random()
        let permit = try await harness.store.consumeApproval(principal: harness.originPrincipal, requestID: spec.requestID, request: ConsumeRequest(
            consumeID: consumeID, decisionID: try #require(decided.result.decisionID), requestHash: record.requestHash, runID: agent.runID
        ))
        guard case .agentTool(let operation) = spec.operation else { Issue.record("operation")
return }
        for dispatch in [AgentDispatch.dispatchStarted, .nativeResponseWritten] {
            try await harness.store.recordAgentReceipt(principal: harness.originPrincipal, receipt: try AgentDeliveryReceipt(
                requestKind: .approval, requestID: spec.requestID, requestHash: record.requestHash, runID: agent.runID,
                nativeWaitID: operation.nativeWaitID, decisionID: permit.decisionID, consumeID: consumeID,
                dispatch: dispatch, evidence: "hook_stdout_written", occurredAt: harness.timestamp
            ))
        }
        let approval = try await harness.store.approval(spec.requestID, principal: device.principal)
        // Written but acceptance unobservable: unknown, never "applied" (A18).
        #expect(approval.projection.dispatch == .unknown)
        let snapshot = try await harness.store.agentSnapshot(principal: device.principal, pageToken: nil, limit: 50)
        #expect(snapshot.approvals.first?.dispatch == .nativeResponseWritten)
        #expect(snapshot.sessions.count == 1)
    }

    @Test
    func testAgentApprovalRequiresANegotiatedSessionAndKind() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let agent = try await startAgent(harness, operations: [AgentFeature.input])
        await assertControlError(.unsupportedOperation) {
            try await harness.publish(try self.shellApproval(harness, agent: agent))
        }
    }

    @Test
    func testBroadScopeIsRecordedButNeverApprovable() async throws {
        // A07.
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let record = try await harness.publish(try shellApproval(harness, agent: agent, scope: "directory"))
        await assertControlError(.unsupportedOperation) {
            try await harness.decide(.approve, device: device, record: record)
        }
        let rejected = try await harness.decide(.reject, device: device, record: record)
        #expect(rejected.result.resolution == .rejected)
    }

    @Test
    func testOneNativeWaitAnswersOneRequest() async throws {
        // A08: identical arguments stay separate; a reused wait conflicts.
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let agent = try await startAgent(harness)
        let wait = ControlID.random()
        try await harness.publish(try shellApproval(harness, agent: agent))
        try await harness.publish(try shellApproval(harness, agent: agent))
        try await harness.publish(try shellApproval(harness, agent: agent, waitID: wait))
        await assertControlError(.idempotencyConflict) {
            try await harness.publish(try self.shellApproval(harness, agent: agent, waitID: wait))
        }
    }

    @Test
    func testSessionEndCancelsPendingRequests() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let approval = try await harness.publish(try shellApproval(harness, agent: agent))
        let input = try await publishInput(harness, try inputSpec(harness, agent: agent))
        try await harness.store.recordAgentEvent(principal: harness.originPrincipal, event: try AgentEvent(
            type: .sessionEnded, originID: harness.originID, agentSessionID: agent.sessionID,
            occurredAt: harness.timestamp, observedAt: harness.timestamp
        ))
        let cancelled = try await harness.store.approval(approval.spec.requestID, principal: device.principal)
        #expect(cancelled.projection.resolution == .cancelled)
        let withdrawn = try await harness.store.input(input.spec.requestID, principal: device.principal)
        #expect(withdrawn.projection.resolution == .withdrawn)
        await assertControlError(.requestResolved) {
            _ = try await self.respond(harness, device: device, record: input, response: .answer([.singleChoice(questionID: "scope", choiceID: "all")]))
        }
    }

    // MARK: Inputs

    @Test
    func testInputAnswerClaimAndReceipt() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let record = try await publishInput(harness, try inputSpec(harness, agent: agent))
        let response = InputResponse.answer([.singleChoice(questionID: "scope", choiceID: "focused")])
        let commandID = ControlID.random()
        let first = try await respond(harness, device: device, record: record, response: response, commandID: commandID)
        #expect(first.result.resolution == .answered)
        #expect(!(first.isReplay))

        let mutationID = ControlID.random()
        let permit = try await consume(harness, record: record, commandID: commandID, response: response, mutationID: mutationID)
        #expect(permit.response == response)
        try permit.validate(request: InputConsumeRequest(
            mutationID: mutationID, runID: agent.runID, nativeWaitID: record.spec.source.nativeWaitID,
            requestHash: record.requestHash, commandID: commandID, responseHash: response.responseHash
        ), originID: harness.originID, requestID: record.spec.requestID)
        // The same mutation returns the same permit; another claim fails.
        let again = try await consume(harness, record: record, commandID: commandID, response: response, mutationID: mutationID)
        #expect(again == permit)
        await assertControlError(.alreadyClaimed) {
            _ = try await self.consume(harness, record: record, commandID: commandID, response: response)
        }
        try await harness.store.recordAgentReceipt(principal: harness.originPrincipal, receipt: try AgentDeliveryReceipt(
            requestKind: .input, requestID: record.spec.requestID, requestHash: record.requestHash, runID: agent.runID,
            nativeWaitID: record.spec.source.nativeWaitID, commandID: commandID, permitID: permit.permitID,
            dispatch: .dispatchStarted, evidence: "dispatch_journaled", occurredAt: harness.timestamp
        ))
        let result = try await harness.store.agentCommandResult(commandID, principal: device.principal)
        #expect(result.dispatch == .dispatchStarted)
    }

    @Test
    func testFirstResponseWinsAndRetriesReplay() async throws {
        // A09, A10, A11.
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let first = try await phone(harness)
        let second = try await phone(harness)
        let agent = try await startAgent(harness)
        let record = try await publishInput(harness, try inputSpec(harness, agent: agent))
        let response = InputResponse.answer([.singleChoice(questionID: "scope", choiceID: "all")])
        let commandID = ControlID.random()

        let challenge = try await harness.store.createAgentChallenge(principal: first.principal, request: try AgentReviewChallengeRequest(
            requestID: record.spec.requestID, requestHash: record.requestHash, expectedStateVersion: 1, policyVersion: record.projection.policyVersion
        ))
        let jws = try sign(harness, device: first, record: record, response: response, challengeID: challenge.challengeID, commandID: commandID)
        let challenge2 = try await harness.store.createAgentChallenge(principal: second.principal, request: try AgentReviewChallengeRequest(
            requestID: record.spec.requestID, requestHash: record.requestHash, expectedStateVersion: 1, policyVersion: record.projection.policyVersion
        ))
        _ = try await harness.store.submitAgentCommand(principal: first.principal, signedCommand: jws, idempotencyKey: commandID)
        let replay = try await harness.store.submitAgentCommand(principal: first.principal, signedCommand: jws, idempotencyKey: commandID)
        #expect(replay.isReplay)

        let loser = try sign(harness, device: second, record: record, response: .answer([.singleChoice(questionID: "scope", choiceID: "focused")]),
                             challengeID: challenge2.challengeID, commandID: .random())
        await assertControlError(.requestResolved) {
            let id = try #require(ControlJWS.verifyAgent(compactSerialization: loser) { _ in second.key.publicJWK }.command.envelope.commandID)
            _ = try await harness.store.submitAgentCommand(principal: second.principal, signedCommand: loser, idempotencyKey: id)
        }
        let changed = try sign(harness, device: first, record: record, response: .answer([.singleChoice(questionID: "scope", choiceID: "focused")]),
                               challengeID: challenge.challengeID, commandID: commandID)
        await assertControlError(.idempotencyConflict) {
            _ = try await harness.store.submitAgentCommand(principal: first.principal, signedCommand: changed, idempotencyKey: commandID)
        }
    }

    @Test
    func testInvalidAnswersAreRejectedBeforeRecording() async throws {
        // A21.
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let record = try await publishInput(harness, try inputSpec(harness, agent: agent))
        await assertControlError(.responseInvalid) {
            _ = try await self.respond(harness, device: device, record: record, response: .answer([.singleChoice(questionID: "scope", choiceID: "Everything")]))
        }
        await assertControlError(.responseInvalid) {
            _ = try await self.respond(harness, device: device, record: record, response: .decline)
        }
        let current = try await harness.store.input(record.spec.requestID, principal: device.principal)
        #expect(current.projection.resolution == .pending)
    }

    @Test
    func testAnswerNeedsTheLiveNativeWait() async throws {
        // A14: the agent exited; the daemon stopped reporting the wait.
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let record = try await publishInput(harness, try inputSpec(harness, agent: agent, allowDecline: true))
        try await harness.store.heartbeat(principal: harness.originPrincipal, runIDs: [agent.runID], waitingRequestIDs: [])
        await assertControlError(.originUnavailable) {
            _ = try await self.respond(harness, device: device, record: record, response: .answer([.singleChoice(questionID: "scope", choiceID: "all")]))
        }
        let declined = try await respond(harness, device: device, record: record, response: .decline)
        #expect(declined.result.resolution == .declined)
    }

    @Test
    func testWithdrawnInputCannotBeRevived() async throws {
        // A16, A23.
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let record = try await publishInput(harness, try inputSpec(harness, agent: agent))
        let mutationID = ControlID.random()
        let withdrawn = try await harness.store.withdrawInput(principal: harness.originPrincipal, requestID: record.spec.requestID,
                                                               mutationID: mutationID, runID: agent.runID, requestHash: record.requestHash)
        #expect(withdrawn.projection.resolution == .withdrawn)
        let replayed = try await harness.store.withdrawInput(principal: harness.originPrincipal, requestID: record.spec.requestID,
                                                              mutationID: mutationID, runID: agent.runID, requestHash: record.requestHash)
        #expect(replayed == withdrawn)
        await assertControlError(.requestResolved) {
            _ = try await self.respond(harness, device: device, record: record, response: .answer([.singleChoice(questionID: "scope", choiceID: "all")]))
        }
    }

    @Test
    func testChangedQuestionCannotBeAnsweredWithAnOldReview() async throws {
        // A20, A34: the signed hash must be the current spec's.
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let record = try await publishInput(harness, try inputSpec(harness, agent: agent))
        await assertControlError(.hashMismatch) {
            _ = try await harness.store.createAgentChallenge(principal: device.principal, request: try AgentReviewChallengeRequest(
                requestID: record.spec.requestID, requestHash: "sha256:" + String(repeating: "c", count: 64),
                expectedStateVersion: 1, policyVersion: record.projection.policyVersion
            ))
        }
        await assertControlError(.idempotencyConflict) {
            let changed = try InputSpec(
                requestID: record.spec.requestID, originID: record.spec.originID, jobID: record.spec.jobID, runID: record.spec.runID,
                createdAt: record.spec.createdAt, expiresAt: record.spec.expiresAt, summary: "Different question",
                source: record.spec.source, questions: record.spec.questions, minimumReview: .watch
            )
            _ = try await harness.store.createInput(principal: harness.originPrincipal, spec: changed)
        }
    }

    @Test
    func testExpiryAndRevocationStopClaims() async throws {
        // A26, A23.
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let record = try await publishInput(harness, try inputSpec(harness, agent: agent))
        let response = InputResponse.answer([.singleChoice(questionID: "scope", choiceID: "all")])
        let commandID = ControlID.random()
        _ = try await respond(harness, device: device, record: record, response: response, commandID: commandID)
        try await harness.store.revokeDevice(device.id)
        await assertControlError(.deviceRevoked) {
            _ = try await self.consume(harness, record: record, commandID: commandID, response: response)
        }

        let other = try await phone(harness)
        let expiring = try await publishInput(harness, try inputSpec(harness, agent: agent, lifetime: 30))
        let otherCommand = ControlID.random()
        _ = try await respond(harness, device: other, record: expiring, response: response, commandID: otherCommand)
        harness.clock.advance(31)
        await assertControlError(.requestResolved) {
            _ = try await self.consume(harness, record: expiring, commandID: otherCommand, response: response)
        }
        let expired = try await harness.store.input(expiring.spec.requestID, principal: other.principal)
        #expect(expired.projection.dispatch == .notApplied)
    }

    @Test
    func testWatchReviewPolicyAndGrants() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let watch = try await harness.enrollDevice(grants: DeviceGrant.watchDefault.union([.agentInputsRespond]))
        let ungranted = try await phone(harness, grants: DeviceGrant.watchDefault)
        let agent = try await startAgent(harness)
        let full = try await publishInput(harness, try inputSpec(harness, agent: agent, review: .full))
        let response = InputResponse.answer([.singleChoice(questionID: "scope", choiceID: "all")])
        await assertControlError(.fullReviewRequired) {
            _ = try await self.respond(harness, device: watch, record: full, response: response)
        }
        await assertControlError(.notAuthorized) {
            _ = try await self.respond(harness, device: ungranted, record: full, response: response)
        }
        let small = try await publishInput(harness, try inputSpec(harness, agent: agent))
        let answered = try await respond(harness, device: watch, record: small, response: response)
        #expect(answered.result.resolution == .answered)
    }

    @Test
    func testCursorNamespacesAreSeparateAndChangesAreComplete() async throws {
        // A33.
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let snapshot = try await harness.store.agentSnapshot(principal: device.principal, pageToken: nil, limit: 50)
        let base = try await harness.store.snapshot(principal: device.principal)
        await assertControlError(.cursorExpired) {
            _ = try await harness.store.changes(principal: device.principal, cursor: snapshot.cursor)
        }
        await assertControlError(.cursorExpired) {
            _ = try await harness.store.agentChanges(principal: device.principal, cursor: base.cursor, limit: 10)
        }
        let record = try await publishInput(harness, try inputSpec(harness, agent: agent))
        let changes = try await harness.store.agentChanges(principal: device.principal, cursor: snapshot.cursor, limit: 10)
        #expect(changes.events.map(\.type) == [.inputCreated])
        #expect(changes.events.first?.resourceID == record.spec.requestID)
        // A device without agent read grants sees nothing of sessions.
        let plain = try await phone(harness, grants: DeviceGrant.watchDefault.union([.agentInputsRead]))
        let plainSnapshot = try await harness.store.agentSnapshot(principal: plain.principal, pageToken: nil, limit: 50)
        #expect(plainSnapshot.sessions.isEmpty)
        #expect(plainSnapshot.inputs.count == 1)
    }

    @Test
    func testLedgerRestoresAgentState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let persistence = try FileBrokerPersistence(url: directory.appendingPathComponent("broker.json"))
        let harness = BrokerHarness(persistence: persistence)
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        let record = try await publishInput(harness, try inputSpec(harness, agent: agent))
        let response = InputResponse.answer([.singleChoice(questionID: "scope", choiceID: "all")])
        let commandID = ControlID.random()
        _ = try await respond(harness, device: device, record: record, response: response, commandID: commandID)
        let permit = try await consume(harness, record: record, commandID: commandID, response: response)

        let clock = harness.clock
        let restored = BrokerStore(serviceIdentity: "test-broker", cursorSecret: Data(repeating: 7, count: 32),
                                   persistence: persistence, now: { clock.now })
        try await restored.restore()
        let input = try await restored.input(record.spec.requestID, principal: device.principal)
        #expect(input.projection.dispatch == .claimed)
        #expect(input.response == response)
        // A restored ledger returns the same claim, never a second one.
        let again = try await restored.consumeInput(principal: harness.originPrincipal, requestID: record.spec.requestID, request: InputConsumeRequest(
            mutationID: permit.mutationID, runID: agent.runID, nativeWaitID: record.spec.source.nativeWaitID,
            requestHash: record.requestHash, commandID: commandID, responseHash: response.responseHash
        ))
        #expect(again == permit)
    }

    @Test
    func testHTTPRoutesAndGatewayAllowlist() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let service = BrokerService(store: harness.store, configuration: .init(
            verificationURI: "https://x", allowedAPNsTopics: [], adminSecret: "admin", adminAccountID: harness.accountID
        ))
        let origin = HTTPServer.Request(
            method: "GET", path: "/v1/agent/capabilities", query: [:],
            headers: ["authorization": "Origin \(harness.originID.rawValue):\(harness.originSecret)"], body: Data()
        )
        let response = await service.handle(origin)
        #expect(response.status == 200)
        let capabilities = try AgentCapabilities(json: try JSONValue.parse(response.body))
        #expect(capabilities.isCompatible)
        #expect(capabilities.commandTypes.contains("agent.message"), "advertised; still gated by grants and managed sessions")
    }
}

extension AgentBrokerTests {
    func managedSession(_ harness: BrokerHarness) async throws -> (Agent, AgentSessionProjection) {
        let runID = ControlID.random(), jobID = ControlID.random(), sessionID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        let projection = try await harness.store.registerAgentSession(principal: harness.originPrincipal, registration: try AgentSessionRegistration(
            agentSessionID: sessionID, runID: runID, provider: "codex", providerBuild: "0.156.1", adapterBuild: "1.0.0",
            profile: .managed, evidence: .userAttested, operations: [AgentFeature.messages, AgentFeature.turnCancel], startedAt: harness.timestamp
        ))
        return (Agent(runID: runID, jobID: jobID, sessionID: sessionID), projection)
    }

    func sign(_ harness: BrokerHarness, _ action: AgentSessionAction, device: BrokerHarness.Device, challengeID: String, commandID: ControlID = .random()) throws -> String {
        let command = try AgentSessionCommand(
            envelope: try AgentCommandEnvelope(type: action.commandType, commandID: commandID, deviceID: device.id,
                                               audience: "shell-control:\(harness.accountID.rawValue)", issuedAt: harness.timestamp,
                                               notAfter: harness.timestamp.adding(60)),
            action: action, challengeID: challengeID
        )
        return try ControlJWS.sign(payload: command.json, deviceID: device.id, key: device.key)
    }

    @Test
    func testSessionCommandIsBoundToItsChallengeDigestAndClaimedOnce() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness, grants: DeviceGrant.agentPhone.union([.agentMessagesSend]))
        let (agent, projection) = try await managedSession(harness)
        #expect(projection.turnState == .idle)
        let action = AgentSessionAction.message(agentSessionID: agent.sessionID, runID: agent.runID, expectedSessionVersion: projection.sessionVersion,
                                                mode: .newTurn, expectedTurnID: nil, text: "Run the tests")
        let challenge = try await harness.store.createAgentChallenge(principal: device.principal, request: try AgentReviewChallengeRequest(sessionAction: action))
        // A different text under the reviewed challenge is refused.
        let other = AgentSessionAction.message(agentSessionID: agent.sessionID, runID: agent.runID, expectedSessionVersion: projection.sessionVersion,
                                               mode: .newTurn, expectedTurnID: nil, text: "Delete the repo")
        let forged = ControlID.random()
        await assertControlError(.staleVersion) {
            _ = try await harness.store.submitAgentCommand(principal: device.principal,
                                                           signedCommand: try self.sign(harness, other, device: device, challengeID: challenge.challengeID, commandID: forged),
                                                           idempotencyKey: forged)
        }
        let commandID = ControlID.random()
        _ = try await harness.store.submitAgentCommand(principal: device.principal,
                                                       signedCommand: try sign(harness, action, device: device, challengeID: challenge.challengeID, commandID: commandID),
                                                       idempotencyKey: commandID)
        let pending = try await harness.store.pendingSessionCommands(principal: harness.originPrincipal, sessionID: agent.sessionID)
        #expect(pending.map(\.commandID) == [commandID])
        let epoch = ControlID.random(), mutation = ControlID.random()
        let permit = try await harness.store.claimSessionCommand(principal: harness.originPrincipal, sessionID: agent.sessionID, request: AgentSessionClaimRequest(
            mutationID: mutation, commandID: commandID, actionDigest: action.digest, connectionEpoch: epoch
        ))
        do { _ = try permit.validate(connectionEpoch: epoch, agentSessionID: agent.sessionID) } catch { Issue.record("unexpected error: \(error)") }
        await assertControlError(.alreadyClaimed) {
            _ = try await harness.store.claimSessionCommand(principal: harness.originPrincipal, sessionID: agent.sessionID, request: AgentSessionClaimRequest(
                mutationID: .random(), commandID: commandID, actionDigest: action.digest, connectionEpoch: .random()
            ))
        }
    }

    @Test
    func testUnclaimedSessionCommandExpiresNotApplied() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness, grants: DeviceGrant.agentPhone.union([.agentMessagesSend]))
        let (agent, projection) = try await managedSession(harness)
        let action = AgentSessionAction.message(agentSessionID: agent.sessionID, runID: agent.runID, expectedSessionVersion: projection.sessionVersion,
                                                mode: .newTurn, expectedTurnID: nil, text: "go")
        let challenge = try await harness.store.createAgentChallenge(principal: device.principal, request: try AgentReviewChallengeRequest(sessionAction: action))
        let commandID = ControlID.random()
        _ = try await harness.store.submitAgentCommand(principal: device.principal,
                                                       signedCommand: try sign(harness, action, device: device, challengeID: challenge.challengeID, commandID: commandID),
                                                       idempotencyKey: commandID)
        harness.clock.advance(61)
        let result = try await harness.store.agentCommandResult(commandID, principal: device.principal)
        #expect(result.dispatch == .awaitingOrigin)
        let pending = try await harness.store.pendingSessionCommands(principal: harness.originPrincipal, sessionID: agent.sessionID)
        #expect(pending.isEmpty, "a command past its signed deadline is never delivered")
        let expired = try await harness.store.agentCommandResult(commandID, principal: device.principal)
        #expect(expired.dispatch == .notApplied)
    }

    @Test
    func testHookSessionsAcceptNoSessionCommands() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness, grants: DeviceGrant.agentPhone.union([.agentMessagesSend]))
        let agent = try await startAgent(harness)
        await assertControlError(.unsupportedOperation) {
            _ = try await harness.store.createAgentChallenge(principal: device.principal, request: try AgentReviewChallengeRequest(sessionAction: .message(
                agentSessionID: agent.sessionID, runID: agent.runID, expectedSessionVersion: 1, mode: .newTurn, expectedTurnID: nil, text: "hi"
            )))
        }
    }
}

extension AgentBrokerTests {
    @Test
    func testPendingOnlySnapshotAndKeysetPagingSkipNothing() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        let agent = try await startAgent(harness)
        var records: [InputRecord] = []
        for _ in 0..<5 { records.append(try await publishInput(harness, try inputSpec(harness, agent: agent))) }
        // Page 1 holds the session and the first input.
        let first = try await harness.store.agentSnapshot(principal: device.principal, pageToken: nil, limit: 2)
        #expect(first.inputs.count == 1)
        // The first input resolves between pages; with offset paging the
        // next unchanged input would be skipped.
        _ = try await harness.store.withdrawInput(principal: harness.originPrincipal, requestID: records[0].spec.requestID,
                                                  mutationID: .random(), runID: agent.runID, requestHash: records[0].requestHash)
        var seen = Set(first.inputs.compactMap(\.requestID))
        var token = first.nextPageToken
        while let next = token {
            let page = try await harness.store.agentSnapshot(principal: device.principal, pageToken: next, limit: 2)
            seen.formUnion(page.inputs.compactMap(\.requestID))
            token = page.nextPageToken
        }
        #expect(seen == Set(records.map(\.spec.requestID)))
        // Pending only: the withdrawn input is left out.
        let pending = try await harness.store.agentSnapshot(principal: device.principal, pageToken: nil, limit: 50, pendingOnly: true)
        #expect(Set(pending.inputs.compactMap(\.requestID)) == Set(records.dropFirst().map(\.spec.requestID)))
        // Resolved history older than a day is not in any snapshot.
        harness.clock.advance(BrokerStore.agentSnapshotRecentWindow + 400)
        let later = try await harness.store.agentSnapshot(principal: device.principal, pageToken: nil, limit: 50)
        #expect(later.inputs.isEmpty, "all expired more than a day ago")
    }

    @Test
    func testSessionCommandRecordsNeedTheSessionGrant() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let sender = try await phone(harness, grants: DeviceGrant.agentPhone.union([.agentMessagesSend]))
        let reader = try await phone(harness, grants: [.agentInputsRead])
        let (agent, projection) = try await managedSession(harness)
        let cursor = try await harness.store.agentSnapshot(principal: reader.principal, pageToken: nil, limit: 50).cursor
        let action = AgentSessionAction.message(agentSessionID: agent.sessionID, runID: agent.runID, expectedSessionVersion: projection.sessionVersion,
                                                mode: .newTurn, expectedTurnID: nil, text: "secret instruction")
        let challenge = try await harness.store.createAgentChallenge(principal: sender.principal, request: try AgentReviewChallengeRequest(sessionAction: action))
        let commandID = ControlID.random()
        _ = try await harness.store.submitAgentCommand(principal: sender.principal,
                                                       signedCommand: try sign(harness, action, device: sender, challengeID: challenge.challengeID, commandID: commandID),
                                                       idempotencyKey: commandID)
        let changes = try await harness.store.agentChanges(principal: reader.principal, cursor: cursor, limit: 50)
        #expect(!(changes.events.contains { $0.resourceID == commandID }), "instruction text stays with session readers")
    }

    @Test
    func testKilledSessionsAgeOutEvenIfNeverEnded() async throws {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let device = try await phone(harness)
        _ = try await startAgent(harness)
        harness.clock.advance(ApprovalPolicy.commandRetention + 3600)
        await harness.store.purgeRetained()
        let snapshot = try await harness.store.agentSnapshot(principal: device.principal, pageToken: nil, limit: 50)
        #expect(snapshot.sessions.isEmpty)
    }
}

private extension InputRecord {
    func withResponse(_ response: InputResponse?) -> InputRecord { self }
}
