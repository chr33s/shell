import XCTest
import Synchronization
@testable import ShellControlProtocol
@testable import ShellControlSecurity
@testable import ShellControlClient

/// Client-side review → challenge → sign → submit for typed answers, the
/// journal, and the Watch agent gateway (spec.agent-relay.md 8, 13, 15.5).
final class AgentClientTests: XCTestCase {
    private let hex = String(repeating: "d", count: 64)
    private let now = ControlTimestamp(Date(timeIntervalSince1970: 1_790_000_000))

    final class StubService: AgentInputService, @unchecked Sendable {
        let lock = NSLock()
        var record: InputRecord
        var submitted: [String] = []
        var submitError: (any Error)?
        var dispatch: AgentDispatch = .awaitingOrigin
        let deviceID: ControlID

        init(record: InputRecord, deviceID: ControlID) {
            self.record = record
            self.deviceID = deviceID
        }

        func input(_ requestID: ControlID) async throws -> InputRecord { lock.withLock { record } }

        func agentReviewChallenge(_ request: AgentReviewChallengeRequest) async throws -> AgentReviewChallenge {
            AgentReviewChallenge(challengeID: "c", deviceID: deviceID, action: .inputRespond, expiresAt: record.spec.expiresAt)
        }

        func submitAgent(signedCommand: String, commandID: ControlID) async throws -> AgentCommandResult {
            try lock.withLock {
                submitted.append(signedCommand)
                if let submitError { throw submitError }
                return AgentCommandResult(recorded: true, commandID: commandID, requestID: record.spec.requestID,
                                          resolution: .answered, dispatch: dispatch, serverTime: record.spec.createdAt)
            }
        }

        func agentCommandResult(_ commandID: ControlID) async throws -> AgentCommandResult {
            AgentCommandResult(recorded: true, commandID: commandID, dispatch: lock.withLock { dispatch }, serverTime: record.spec.createdAt)
        }
    }

    private func record(review: MinimumReview = .watch, present: Bool = true) throws -> InputRecord {
        let spec = try InputSpec(
            requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
            createdAt: now, expiresAt: now.adding(300), summary: "Pick",
            source: try InputSource(provider: "claude_code", providerBuild: "b", adapterBuild: "a",
                                    nativeRequestSHA256: hex, contextSHA256: hex, answerMappingSHA256: hex,
                                    agentSessionID: .random(), nativeWaitID: .random()),
            questions: [try InputQuestion(id: "q", prompt: "Which?", kind: .singleChoice(choices: [
                try InputChoice(id: "a", label: "A"), try InputChoice(id: "b", label: "B")
            ]), required: true)],
            allowedResponses: [.answer, .decline],
            minimumReview: review
        )
        return try InputRecord(spec: spec, projection: InputProjection(
            presence: present ? SourcePresence(lastSeenAt: now, isWaiting: true) : .absent
        ))
    }

    private func coordinator(_ service: StubService, journal: CommandJournal, grants: Set<DeviceGrant> = DeviceGrant.agentPhone, review: MinimumReview = .full) -> AgentInputCoordinator {
        AgentInputCoordinator(
            service: service, journal: journal, key: InMemoryDeviceKey(),
            signer: SignerIdentity(deviceID: service.deviceID, audience: "shell-control:x", grants: grants),
            review: review, now: { [now] in now.date }
        )
    }

    func testRespondSignsTheExactAnswerAndJournalsItFirst() async throws {
        let service = StubService(record: try record(), deviceID: .random())
        let journal = CommandJournal(now: { [now] in now.date })
        let state = try await coordinator(service, journal: journal).respond(
            .answer([.singleChoice(questionID: "q", choiceID: "b")]), reviewed: service.record
        )
        guard case .responseRecorded(let result) = state else { return XCTFail("\(state)") }
        let payload = try SignedPayloadReader.payload(ofCompactJWS: try XCTUnwrap(service.submitted.first))
        let command = try InputRespondCommand(json: payload)
        XCTAssertEqual(command.response, .answer([.singleChoice(questionID: "q", choiceID: "b")]))
        XCTAssertEqual(command.envelope.commandID, result.commandID)
        let pending = await journal.command(result.commandID)
        XCTAssertEqual(pending?.agentType, .inputRespond)
        XCTAssertNil(pending?.type)
    }

    func testChangedRequestIsNeverSigned() async throws {
        let reviewed = try record()
        let service = StubService(record: reviewed, deviceID: .random())
        service.record.projection.stateVersion = 2
        do {
            _ = try await coordinator(service, journal: CommandJournal()).respond(.answer([.singleChoice(questionID: "q", choiceID: "a")]), reviewed: reviewed)
            XCTFail("expected a changed-request refusal")
        } catch AgentInputCoordinator.CoordinatorError.requestChangedDuringReview {}
        XCTAssertTrue(service.submitted.isEmpty)
    }

    func testWatchCannotAnswerFullReviewButMayDeclineWithoutPresence() async throws {
        let full = StubService(record: try record(review: .full), deviceID: .random())
        do {
            _ = try await coordinator(full, journal: CommandJournal(), grants: DeviceGrant.agentWatchReviewer, review: .watch)
                .respond(.answer([.singleChoice(questionID: "q", choiceID: "a")]), reviewed: full.record)
            XCTFail("expected full review")
        } catch AgentInputCoordinator.CoordinatorError.notAnswerableHere(let reason) {
            XCTAssertEqual(reason, .policyRequiresFullReview)
        }
        let absent = StubService(record: try record(present: false), deviceID: .random())
        let coordinator = coordinator(absent, journal: CommandJournal())
        do {
            _ = try await coordinator.respond(.answer([.singleChoice(questionID: "q", choiceID: "a")]), reviewed: absent.record)
            XCTFail("expected source not present")
        } catch AgentInputCoordinator.CoordinatorError.notAnswerableHere(let reason) {
            XCTAssertEqual(reason, .sourceNotPresent)
        }
        _ = try await coordinator.respond(.decline, reviewed: absent.record)
        XCTAssertEqual(absent.submitted.count, 1)
    }

    func testAmbiguousSubmissionIsReconciledByTheSameCommand() async throws {
        // A25: a timeout leaves the journal entry; reconciliation queries the
        // same command ID and never signs again.
        let service = StubService(record: try record(), deviceID: .random())
        service.submitError = URLError(.timedOut)
        let journal = CommandJournal(now: { [now] in now.date })
        let coordinator = coordinator(service, journal: journal)
        let state = try await coordinator.respond(.answer([.singleChoice(questionID: "q", choiceID: "a")]), reviewed: service.record)
        guard case .outcomeUnknown(let commandID, _) = state else { return XCTFail("\(state)") }
        service.dispatch = .nativeResponseWritten
        let pending = try await XCTUnwrapAsync(await journal.command(commandID))
        let reconciled = try await coordinator.reconcile(pending)
        guard case .deliveredToAgent = reconciled else { return XCTFail("\(reconciled)") }
        XCTAssertEqual(service.submitted.count, 1)
        // The decision coordinator leaves agent commands alone.
        let decision = DecisionCoordinator(service: StubDecisions(), journal: journal, key: InMemoryDeviceKey(),
                                           signer: SignerIdentity(deviceID: .random(), audience: "shell-control:x", grants: []))
        let skipped = try await decision.reconcile(pending)
        guard case .outcomeUnknown = skipped else { return XCTFail("\(skipped)") }
    }

    func testMissingGrantRefusesBeforeAnyCall() async throws {
        let service = StubService(record: try record(), deviceID: .random())
        do {
            _ = try await coordinator(service, journal: CommandJournal(), grants: DeviceGrant.watchDefault)
                .respond(.answer([.singleChoice(questionID: "q", choiceID: "a")]), reviewed: service.record)
            XCTFail("expected missing grant")
        } catch AgentInputCoordinator.CoordinatorError.missingGrant(let grant) {
            XCTAssertEqual(grant, .agentInputsRespond)
        }
    }

    func testJournalRoundTripsAgentCommands() throws {
        let command = PendingCommand(commandID: .random(), signedCommand: "a.b.c", agentType: .inputRespond,
                                     targetID: .random(), notAfter: now)
        XCTAssertEqual(try PendingCommand(json: command.json), command)
    }

    // MARK: Gateway

    func testAgentGatewayRequestIsStrictAndSeparate() throws {
        let request = WatchAgentGatewayRequest(type: .inputFetch, watchDeviceID: .random(), body: .object(["request_id": JSONValue(ControlID.random())]))
        let data = try request.encoded()
        XCTAssertTrue(WatchAgentGatewayRequest.claims(data))
        XCTAssertEqual(try WatchAgentGatewayRequest(data: data), request)
        XCTAssertThrowsError(try WatchGatewayRequest(data: data))
        var raw = try XCTUnwrap(request.json.objectValue)
        raw["url"] = "https://example.com"
        XCTAssertThrowsError(try WatchAgentGatewayRequest(data: try JSONCanonicalization.canonicalize(.object(raw))))
        raw.removeValue(forKey: "url")
        raw["type"] = "http.fetch"
        XCTAssertThrowsError(try WatchAgentGatewayRequest(data: try JSONCanonicalization.canonicalize(.object(raw))))
    }

    func testRouterRefusesAnUnboundWatchForAgentCalls() async throws {
        let router = WatchGatewayRouter(
            client: { ControlAPIClient(baseURL: URL(string: "http://127.0.0.1:9")!) },
            binding: InMemoryWatchBindingStore(nil)
        )
        let request = WatchAgentGatewayRequest(type: .capabilitiesFetch, watchDeviceID: .random())
        let reply = try WatchGatewayResponse(data: await router.handle(try request.encoded()))
        XCTAssertEqual(reply.messageID, request.messageID)
        guard case .failure(let error) = reply.result else { return XCTFail("\(reply.result)") }
        XCTAssertEqual(error.code, .reviewerNotBound)
    }

    func testWatchClientFailsClosedWhenTheIPhoneIsUnreachable() async throws {
        struct Unreachable: WatchGatewayLink {
            func isReachable() async -> Bool { false }
            func send(_ data: Data) async throws -> Data { XCTFail("must not send"); return Data() }
        }
        let client = WatchAgentGatewayClient(link: Unreachable(), watchDeviceID: .random())
        do {
            _ = try await client.input(.random())
            XCTFail("expected unreachable")
        } catch WatchGatewayError.iPhoneUnreachable {}
    }

    func testOldIPhoneReplyMeansUnsupported() async throws {
        struct OldPhone: WatchGatewayLink {
            func isReachable() async -> Bool { true }
            // An older router answers an unknown protocol with its fallback.
            func send(_ data: Data) async throws -> Data {
                try JSONCanonicalization.canonicalize(.object(["v": 1, "ok": false, "error": ControlError(code: .invalidPayload, message: "x").json]))
            }
        }
        let client = WatchAgentGatewayClient(link: OldPhone(), watchDeviceID: .random())
        do {
            _ = try await client.capabilities()
            XCTFail("expected unsupported")
        } catch WatchGatewayError.unsupportedVersion {}
    }
}

private struct StubDecisions: ControlDecisionService {
    func approval(_ requestID: ControlID) async throws -> ApprovalRecord { throw ControlError(code: .notFound, message: "") }
    func reviewChallenge(_ request: ReviewChallengeRequest) async throws -> ReviewChallenge { throw ControlError(code: .notFound, message: "") }
    func submit(signedCommand: String, commandID: ControlID) async throws -> CommandResult { throw ControlError(code: .notFound, message: "") }
    func commandResult(_ commandID: ControlID) async throws -> CommandResult { throw ControlError(code: .notFound, message: "") }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
