import Foundation
import Testing
@testable import ShellControlProtocol
@testable import ShellControlSecurity

/// `shell-agent/1` protocol rules (docs/specs/agent-relay.md sections 5–8, 14).
@Suite
final class AgentProtocolTests {
    private let hex = String(repeating: "a", count: 64)
    private let now = ControlTimestamp(Date(timeIntervalSince1970: 1_790_000_000))

    private func shellOperation(command: String = "git status --short", kind: AgentToolKind = .shell, scope: String = AgentPermissionScope.singleNativeGate,
                                options: [String: AgentOptionValue] = ["timeout": .integer(120000)]) throws -> AgentToolOperation {
        try AgentToolOperation(
            provider: "claude_code", providerBuild: "2.1.281", adapterBuild: "1.0.0",
            agentSessionID: .random(), nativeWaitID: .random(), providerSessionID: "native-session",
            kind: kind, toolName: "Bash", cwd: "/Users/example/src",
            permissionScope: scope, reason: "Check the tree",
            shellRequest: try AgentShellRequest(representation: .commandString, command: command, options: options),
            unavailable: ["shell_identity"], nativeRequestSHA256: hex, contextSHA256: hex
        )
    }

    private func approvalSpec(_ operation: AgentToolOperation, review: MinimumReview = .full) throws -> ApprovalSpec {
        try ApprovalSpec(
            requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
            createdAt: now, expiresAt: now.adding(300), summary: "Bash: git status",
            operation: .agentTool(operation), minimumReview: review, requiredFeatures: operation.requiredFeatures
        )
    }

    @Test
    func testAgentOperationRoundTripsAndKeepsTheRequestHash() throws {
        let spec = try approvalSpec(try shellOperation())
        let decoded = try ApprovalSpec(json: try JSONValue.parse(try JSONCanonicalization.canonicalize(spec.json)))
        #expect(decoded == spec)
        #expect((try decoded.requestHash()) == (try spec.requestHash()))
        #expect(spec.requiredFeatures == ["agent.tool.v1", "agent.shell.v1", "consume.v1"])
        #expect(spec.operation.json["shell_request"]?["shell_identity"] == .null)
    }

    @Test
    func testFullReviewAgentShellIsApprovableOnIPhoneOnly() throws {
        var record = try ApprovalRecord(spec: try approvalSpec(try shellOperation()), projection: ApprovalProjection())
        record.projection.presence = SourcePresence(lastSeenAt: now, isWaiting: true)
        #expect(record.approvability(at: now, review: .full) == .approvable)
        #expect(record.approvability(at: now, review: .watch) == .reviewElsewhere(reason: .policyRequiresFullReview))
    }

    @Test
    func testWatchShellPolicyIsNarrow() throws {
        var short = try ApprovalRecord(spec: try approvalSpec(try shellOperation(options: [:]), review: .watch), projection: ApprovalProjection())
        short.projection.presence = SourcePresence(lastSeenAt: now, isWaiting: true)
        #expect(short.approvability(at: now, review: .watch) == .approvable)

        var multiline = try ApprovalRecord(spec: try approvalSpec(try shellOperation(command: "echo a\nrm -rf x", options: [:]), review: .watch), projection: ApprovalProjection())
        multiline.projection.presence = SourcePresence(lastSeenAt: now, isWaiting: true)
        #expect(multiline.approvability(at: now, review: .watch) == .reviewElsewhere(reason: .policyRequiresFullReview))
    }

    @Test
    func testUnknownKindAndBroadScopeAreNeverApprovable() throws {
        // A4 / A7: an unknown variant or a scope wider than one gate.
        for operation in [
            try AgentToolOperation(
                provider: "codex", providerBuild: "x", adapterBuild: "y", agentSessionID: .random(), nativeWaitID: .random(),
                kind: .unknown("network_grant"), toolName: "net", cwd: nil, nativeRequestSHA256: hex, contextSHA256: hex
            ),
            try shellOperation(scope: "session")
        ] {
            var record = try ApprovalRecord(spec: try approvalSpec(operation), projection: ApprovalProjection())
            record.projection.presence = SourcePresence(lastSeenAt: now, isWaiting: true)
            #expect(!(record.spec.operation.isRecognized))
            #expect(record.approvability(at: now, review: .full) != .approvable)
        }
    }

    @Test
    func testMalformedAgentOperationDecodesAsUnknownWithTheSameHash() throws {
        var raw = try #require(try shellOperation().json.objectValue)
        raw["future_field"] = "x"
        let operation = try ControlOperation.decode(.object(raw))
        guard case .unknown(let schema, let kept) = operation else { Issue.record("expected unknown")
return }
        #expect(schema == AgentToolOperation.schema)
        #expect(kept == .object(raw))
    }

    @Test
    func testFileChangeNeedsBaseHashAndIsNeverWatchEligible() throws {
        #expect(throws: (any Error).self) { try AgentFileChange(path: "/tmp/a", change: .modify, diff: "-a\n+b", baseSHA256: nil) }
        let operation = try AgentToolOperation(
            provider: "claude_code", providerBuild: "b", adapterBuild: "a", agentSessionID: .random(), nativeWaitID: .random(),
            kind: .fileChange, toolName: "Edit", cwd: "/tmp",
            fileChanges: [try AgentFileChange(path: "/tmp/a", change: .modify, diff: "-a\n+b", baseSHA256: hex)],
            nativeRequestSHA256: hex, contextSHA256: hex
        )
        #expect(operation.isRenderable)
        #expect(!(operation.isWatchEligible))
    }

    @Test
    func testShellOptionsNeedTheIPhone() throws {
        // Options change what runs; a Watch-sized review shows only the command.
        #expect(!(try shellOperation().isWatchEligible))
        let bare = try AgentToolOperation(
            provider: "codex", providerBuild: "b", adapterBuild: "a", agentSessionID: .random(), nativeWaitID: .random(),
            kind: .shell, toolName: "Bash", cwd: "/tmp",
            shellRequest: try AgentShellRequest(representation: .commandString, command: "git status"),
            nativeRequestSHA256: hex, contextSHA256: hex
        )
        #expect(bare.isWatchEligible)
    }

    @Test
    func testSharedDraftBuildsOneCanonicalResponse() throws {
        let spec = try inputSpec()
        var draft = InputAnswerDraft()
        guard case .multiChoice(let choices, _, _) = spec.questions[1].kind else { Issue.record("multi")
return }
        draft.select(choices[2].id, in: spec.questions[1])
        draft.select(choices[0].id, in: spec.questions[1])
        draft.select(choices[1].id, in: spec.questions[1]) // past the maximum of 2: refused
        #expect(draft.selectionCount(for: spec.questions[1]) == 2)
        #expect(throws: (any Error).self) { try draft.response(for: spec) } // required single choice missing
        draft.select("all", in: spec.questions[0])
        #expect(try draft.response(for: spec) == .answer([
            .singleChoice(questionID: "scope", choiceID: "all"),
            .multiChoice(questionID: "targets", choiceIDs: ["ios", "watch"])
        ]), "sorted by question, choices in committed order, not tap order")
    }

    @Test
    func testOversizeOperationIsRefused() throws {
        let big = String(repeating: "x", count: AgentPolicy.maximumOperationBytes)
        #expect(throws: (any Error).self) { try shellOperation(command: big) }
    }

    // MARK: Inputs

    func inputSpec(allowDecline: Bool = false, review: MinimumReview = .watch) throws -> InputSpec {
        try InputSpec(
            requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
            createdAt: now, expiresAt: now.adding(300), summary: "Choose the test scope",
            source: try InputSource(
                provider: "claude_code", providerBuild: "b", adapterBuild: "a",
                nativeRequestSHA256: hex, contextSHA256: hex, answerMappingSHA256: hex,
                agentSessionID: .random(), nativeWaitID: .random(), providerRequestID: .integer(23)
            ),
            questions: [
                try InputQuestion(id: "scope", prompt: "Which tests should run next?", kind: .singleChoice(choices: [
                    try InputChoice(id: "focused", label: "Changed modules only"),
                    try InputChoice(id: "all", label: "Entire test suite")
                ]), required: true),
                try InputQuestion(id: "targets", prompt: "Targets?", kind: .multiChoice(choices: [
                    try InputChoice(id: "ios", label: "iOS"), try InputChoice(id: "mac", label: "Mac"), try InputChoice(id: "watch", label: "Watch")
                ], minimum: 1, maximum: 2), required: false)
            ],
            allowedResponses: allowDecline ? [.answer, .decline] : [.answer],
            minimumReview: review
        )
    }

    @Test
    func testInputSpecRoundTripPreservesNativeIDType() throws {
        let spec = try inputSpec()
        let decoded = try InputSpec(json: try JSONValue.parse(try JSONCanonicalization.canonicalize(spec.json)))
        #expect(decoded == spec)
        #expect(decoded.source.providerRequestID == .integer(23))
        #expect(decoded.permitsWatchReview)
        #expect((try decoded.requestHash()) == (try spec.requestHash()))
    }

    @Test
    func testInputSpecLimits() throws {
        #expect(throws: (any Error).self) { try InputQuestion(id: "has space", prompt: "p", kind: .text(maximumBytes: 10, hint: nil), required: true) }
        #expect(throws: (any Error).self) { try InputQuestion(id: "q", prompt: "p", kind: .singleChoice(choices: [
            try InputChoice(id: "a", label: "A"), try InputChoice(id: "a", label: "B")
        ]), required: true) }
        #expect(throws: (any Error).self) { try InputQuestion(id: "q", prompt: String(repeating: "é", count: 1100), kind: .text(maximumBytes: 10, hint: nil), required: true) }
        #expect(throws: (any Error).self) { try InputQuestion(id: "q", prompt: "p", kind: .multiChoice(choices: [try InputChoice(id: "a", label: "A")], minimum: 2, maximum: 1), required: true) }
    }

    @Test
    func testResponseValidationRejectsEveryMalformedShape() throws {
        // A21.
        let spec = try inputSpec()
        let valid = InputResponse.answer([
            .singleChoice(questionID: "scope", choiceID: "focused"),
            .multiChoice(questionID: "targets", choiceIDs: ["ios", "watch"])
        ])
        do { _ = try valid.validate(against: spec) } catch { Issue.record("unexpected error: \(error)") }
        let invalid: [InputResponse] = [
            .answer([]),                                                               // missing required
            .answer([.singleChoice(questionID: "scope", choiceID: "nope")]),           // unknown choice
            .answer([.singleChoice(questionID: "scope", choiceID: "all"), .singleChoice(questionID: "scope", choiceID: "all")]),
            .answer([.singleChoice(questionID: "extra", choiceID: "a"), .singleChoice(questionID: "scope", choiceID: "all")]),
            .answer([.singleChoice(questionID: "targets", choiceID: "ios"), .singleChoice(questionID: "scope", choiceID: "all")]), // unsorted
            .answer([.singleChoice(questionID: "scope", choiceID: "all"), .multiChoice(questionID: "targets", choiceIDs: ["ios", "mac", "watch"])]),
            .answer([.singleChoice(questionID: "scope", choiceID: "all"), .multiChoice(questionID: "targets", choiceIDs: ["watch", "ios"])]),
            .answer([.text(questionID: "scope", text: "all")]),                        // wrong kind
            .decline                                                                   // not offered
        ]
        for response in invalid {
            #expect(throws: (any Error).self, "\(response)") { try response.validate(against: spec) }
        }
        do { _ = try InputResponse.decline.validate(against: try inputSpec(allowDecline: true)) } catch { Issue.record("unexpected error: \(error)") }
    }

    @Test
    func testTextLimitIsBytesNotCharacters() throws {
        let spec = try InputSpec(
            requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
            createdAt: now, expiresAt: now.adding(60), summary: "Name",
            source: try InputSource(provider: "claude_code", providerBuild: "b", adapterBuild: "a",
                                    nativeRequestSHA256: hex, contextSHA256: hex, answerMappingSHA256: hex,
                                    agentSessionID: .random(), nativeWaitID: .random()),
            questions: [try InputQuestion(id: "name", prompt: "Name?", kind: .text(maximumBytes: 4, hint: nil), required: true)],
            minimumReview: .watch
        )
        do { _ = try InputResponse.answer([.text(questionID: "name", text: "abcd")]).validate(against: spec) } catch { Issue.record("unexpected error: \(error)") }
        #expect(throws: (any Error).self) { try InputResponse.answer([.text(questionID: "name", text: "ééé")]).validate(against: spec) }
    }

    @Test
    func testInputRespondSignsAndVerifiesOnlyThroughTheAgentDecoder() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random()
        let command = try InputRespondCommand(
            envelope: try AgentCommandEnvelope(
                type: .inputRespond, commandID: .random(), deviceID: deviceID,
                audience: "shell-control:\(ControlID.random().rawValue)", issuedAt: now, notAfter: now.adding(60)
            ),
            requestID: .random(), requestHash: "sha256:" + hex, expectedStateVersion: 1, policyVersion: 1,
            challengeID: "challenge", response: .answer([.singleChoice(questionID: "scope", choiceID: "all")])
        )
        let jws = try ControlJWS.sign(payload: command.json, deviceID: deviceID, key: key)
        let verified = try ControlJWS.verifyAgent(compactSerialization: jws) { $0 == deviceID ? key.publicJWK : nil }
        #expect(verified.command == .inputRespond(command))
        // The legacy decoder does not silently accept the new type.
        #expect(throws: (any Error).self) { try ControlJWS.verify(compactSerialization: jws) { $0 == deviceID ? key.publicJWK : nil } }
        #expect(command.json["action"] == "answer")
        #expect(command.json["answers"]?.arrayValue?.count == 1)
    }

    @Test
    func testSessionCommandsBindTheExactActionDigest() throws {
        let session = ControlID.random(), run = ControlID.random()
        let action = AgentSessionAction.message(agentSessionID: session, runID: run, expectedSessionVersion: 3, mode: .steer, expectedTurnID: "turn_1", text: "Only unit tests")
        let challenge = try AgentReviewChallengeRequest(sessionAction: action)
        #expect((try AgentReviewChallengeRequest(json: challenge.json)) == challenge)
        guard case .session(_, 3, let digest) = challenge.target else { Issue.record("target")
return }
        #expect(digest == action.digest)
        let key = InMemoryDeviceKey(), deviceID = ControlID.random()
        let command = try AgentSessionCommand(
            envelope: try AgentCommandEnvelope(type: .agentMessage, commandID: .random(), deviceID: deviceID,
                                               audience: "shell-control:x", issuedAt: now, notAfter: now.adding(60)),
            action: action, challengeID: "c"
        )
        let jws = try ControlJWS.sign(payload: command.json, deviceID: deviceID, key: key)
        let verified = try ControlJWS.verifyAgent(compactSerialization: jws) { $0 == deviceID ? key.publicJWK : nil }
        #expect(verified.command == .session(command))
        // A payload whose text differs from its digest is refused.
        var tampered = try #require(command.json.objectValue)
        tampered["text"] = "rm -rf everything"
        #expect(throws: (any Error).self) { try AgentSessionCommand(json: .object(tampered)) }
        // Plain text only, and the mode decides whether a turn is named.
        #expect(throws: (any Error).self) { try AgentSessionAction.message(agentSessionID: session, runID: run, expectedSessionVersion: 1, mode: .newTurn, expectedTurnID: "t", text: "x").validate() }
        #expect(throws: (any Error).self) { try AgentSessionAction.message(agentSessionID: session, runID: run, expectedSessionVersion: 1, mode: .steer, expectedTurnID: nil, text: "x").validate() }
        #expect(throws: (any Error).self) { try AgentSessionAction.message(agentSessionID: session, runID: run, expectedSessionVersion: 1, mode: .newTurn, expectedTurnID: nil, text: "a\u{1b}[2J").validate() }
        // An input challenge cannot carry a session action, and vice versa.
        #expect(throws: (any Error).self) { try AgentReviewChallengeRequest(action: .agentMessage, requestID: .random(), requestHash: "sha256:" + hex, expectedStateVersion: 1, policyVersion: 1) }
    }

    @Test
    func testMessagesAndCancellationNeedAManagedSession() throws {
        #expect(throws: (any Error).self) { try AgentSessionRegistration(
            agentSessionID: .random(), runID: .random(), provider: "claude_code", providerBuild: "b", adapterBuild: "a",
            profile: .hook, evidence: .contractTested, operations: [AgentFeature.messages], startedAt: now
        ) }
        do { _ = try AgentSessionRegistration(
            agentSessionID: .random(), runID: .random(), provider: "codex", providerBuild: "b", adapterBuild: "a",
            profile: .managed, evidence: .userAttested, operations: [AgentFeature.messages, AgentFeature.turnCancel], startedAt: now
        ) } catch { Issue.record("unexpected error: \(error)") }
    }

    @Test
    func testPermitValidationComparesEveryBinding() throws {
        let key = InMemoryDeviceKey()
        let deviceID = ControlID.random(), origin = ControlID.random(), run = ControlID.random(), wait = ControlID.random()
        let requestID = ControlID.random()
        let response = InputResponse.answer([.singleChoice(questionID: "scope", choiceID: "all")])
        let command = try InputRespondCommand(
            envelope: try AgentCommandEnvelope(type: .inputRespond, commandID: .random(), deviceID: deviceID,
                                               audience: "shell-control:x", issuedAt: now, notAfter: now.adding(60)),
            requestID: requestID, requestHash: "sha256:" + hex, expectedStateVersion: 1, policyVersion: 1,
            challengeID: "c", response: response
        )
        let jws = try ControlJWS.sign(payload: command.json, deviceID: deviceID, key: key)
        let request = InputConsumeRequest(mutationID: .random(), runID: run, nativeWaitID: wait, requestHash: "sha256:" + hex,
                                          commandID: command.envelope.commandID, responseHash: response.responseHash)
        func permit(wait: ControlID = wait, response permitted: InputResponse = response) -> InputConsumePermit {
            InputConsumePermit(permitID: .random(), mutationID: request.mutationID, originID: origin, runID: run,
                               nativeWaitID: wait, requestID: requestID, requestHash: "sha256:" + hex,
                               commandID: command.envelope.commandID, responseHash: response.responseHash,
                               response: permitted, commandJWS: jws, issuedAt: now, applyBefore: now.adding(10))
        }
        do { _ = try permit().validate(request: request, originID: origin, requestID: requestID) } catch { Issue.record("unexpected error: \(error)") }
        #expect(throws: (any Error).self) { try permit(wait: .random()).validate(request: request, originID: origin, requestID: requestID) }
        #expect(throws: (any Error).self) { try permit(response: .decline).validate(request: request, originID: origin, requestID: requestID) }
        #expect(throws: (any Error).self) { try permit().validate(request: request, originID: .random(), requestID: requestID) }
        let decoded = try InputConsumePermit(json: permit().json)
        #expect(decoded.response == response)
    }

    @Test
    func testDispatchStatesAreForwardOnlyAndLegacyMappingIsConservative() throws {
        #expect(AgentDispatch.claimed.canTransition(to: .dispatchStarted))
        #expect(!(AgentDispatch.dispatchStarted.canTransition(to: .claimed)))
        #expect(!(AgentDispatch.accepted.canTransition(to: .notApplied)))
        #expect(AgentDispatch.nativeResponseWritten.legacyReceiptResult == .unknown)
        #expect(AgentDispatch.accepted.legacyReceiptResult == .applied)
        #expect((AgentDispatch.dispatchStarted.legacyReceiptResult) == nil)
    }

    @Test
    func testUnsupportedInputInAPageDoesNotBreakThePage() throws {
        let record = try InputRecord(spec: try inputSpec(), projection: InputProjection())
        var raw = try #require(record.json.objectValue)
        var spec = try #require(raw["spec"]?.objectValue)
        spec["effect"] = "grant_permission"
        spec["new_constraint"] = true
        raw["spec"] = .object(spec)
        let page = try AgentSnapshotPage(json: .object([
            "sessions": [], "approvals": [],
            "inputs": .array([record.json, .object(raw)]),
            "snapshot_token": "s", "cursor": "a1.0.x", "server_time": JSONValue(now)
        ]))
        #expect(page.inputs.count == 2)
        guard case .supported = page.inputs[0], case .unsupported(let id, _) = page.inputs[1] else { Issue.record("item kinds")
return }
        #expect(id == record.spec.requestID)
    }

    @Test
    func testUnknownEffectIsNotAnswerable() throws {
        let base = try inputSpec()
        let spec = try InputSpec(
            requestID: base.requestID, originID: base.originID, jobID: base.jobID, runID: base.runID,
            createdAt: base.createdAt, expiresAt: base.expiresAt, summary: base.summary, effect: "grant_permission",
            source: base.source, questions: base.questions, minimumReview: .full
        )
        var record = try InputRecord(spec: spec, projection: InputProjection())
        record.projection.presence = SourcePresence(lastSeenAt: now, isWaiting: true)
        #expect(record.answerability(at: now, review: .full) == .reviewElsewhere(reason: .unknownOperationSchema))
    }

    @Test
    func testAnswerMappingDigestIsStable() throws {
        let mapping = InputAnswerMapping(questions: ["scope": .init(nativeKey: "Which tests?", choices: ["all": "Entire test suite"])])
        #expect(mapping.sha256Hex == InputAnswerMapping(questions: mapping.questions).sha256Hex)
        #expect(ASCIIHex.isSHA256(mapping.sha256Hex))
    }

    @Test
    func testTerminalLocationRejectsNonTmuxIdentifiers() throws {
        do { _ = try TerminalLocation(serverInstance: hex, sessionID: "$1", windowID: "@2", paneID: "%3", observedAt: now) } catch { Issue.record("unexpected error: \(error)") }
        #expect(throws: (any Error).self) { try TerminalLocation(serverInstance: hex, sessionID: "main", windowID: "@2", paneID: "%3", observedAt: now) }
        #expect(throws: (any Error).self) { try TerminalLocation(serverInstance: "/tmp/tmux-501/default", sessionID: "$1", windowID: "@2", paneID: "%3", observedAt: now) }
    }

    @Test
    func testInformationalSessionsPublishNoOperations() throws {
        #expect(throws: (any Error).self) { try AgentSessionRegistration(
            agentSessionID: .random(), runID: .random(), provider: "codex", providerBuild: "b", adapterBuild: "a",
            profile: .informational, evidence: .contractTested, operations: [AgentFeature.shell], startedAt: now
        ) }
        #expect(throws: (any Error).self) { try AgentSessionRegistration(
            agentSessionID: .random(), runID: .random(), provider: "codex", providerBuild: "b", adapterBuild: "a",
            profile: .hook, evidence: .documented, operations: [AgentFeature.shell], startedAt: now
        ) }
    }
}
