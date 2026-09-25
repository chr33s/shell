//
//  ControlAgentSessionTests.swift
//  ShellTests
//
//  Managed-session commands on the phone: the message is built from the
//  session exactly as reviewed (new turn when idle, steering the exact turn
//  when running), invalid text is refused before signing, missing grants
//  hide the controls, session-command delivery events are carried by the
//  agent feed without breaking it, and a moved session is reported for a
//  fresh review without resending (docs/specs/agent-relay.md section 15).
//

import XCTest
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@testable import Shell

@MainActor
final class ControlAgentSessionTests: XCTestCase {
    private let now = ControlTimestamp(Date(timeIntervalSince1970: 1_790_000_000))
    private let allGrants = DeviceGrant.agentPhone.union([.agentMessagesSend, .agentTurnsCancel])

    // MARK: Compose

    func testIdleSessionBuildsANewTurnFromTheReviewedProjection() throws {
        let session = try makeSession(turnState: .idle, version: 7)
        var draft = AgentMessageDraft()
        draft.text = "Run the focused tests"
        let proposal = try draft.proposal(for: session)
        XCTAssertEqual(proposal.target, .newTurn)
        XCTAssertEqual(proposal.action, .message(
            agentSessionID: session.registration.agentSessionID, runID: session.registration.runID,
            expectedSessionVersion: 7, mode: .newTurn, expectedTurnID: nil, text: "Run the focused tests"
        ))
        XCTAssertEqual(ControlAgentText.target(proposal.target), "Starts a new turn")
    }

    func testRunningSessionSteersTheExactActiveTurn() throws {
        let session = try makeSession(turnState: .active, turnID: "turn-42", version: 9)
        var draft = AgentMessageDraft()
        draft.text = "Also check the docs\n\tplease"
        let proposal = try draft.proposal(for: session)
        XCTAssertEqual(proposal.target, .steer(turnID: "turn-42"))
        XCTAssertEqual(proposal.action.expectedSessionVersion, 9)
        guard case .message(_, _, _, .steer, "turn-42", let text) = proposal.action else {
            return XCTFail("expected steering of turn-42")
        }
        XCTAssertEqual(text, "Also check the docs\n\tplease", "sent exactly as typed")
        // Line breaks stay real; the tab is shown escaped.
        XCTAssertEqual(proposal.displayLines.map(\.text), ["Also check the docs", "<U+0009>please"])
        XCTAssertTrue(proposal.didEscape)
        XCTAssertEqual(ControlAgentText.target(proposal.target), "Steers turn turn-42")

        // A later projection does not change what was reviewed.
        let moved = try makeSession(turnState: .active, turnID: "turn-43", version: 10)
        XCTAssertEqual(proposal.reviewed.activeTurnID, "turn-42")
        XCTAssertNotEqual(try draft.proposal(for: moved).action, proposal.action)
    }

    func testOverLimitAndControlCharacterTextIsRefused() throws {
        let session = try makeSession(turnState: .idle)
        var draft = AgentMessageDraft()
        XCTAssertEqual(draft.problem, .empty)
        XCTAssertThrowsError(try draft.proposal(for: session))

        draft.text = String(repeating: "é", count: AgentMessageDraft.maximumBytes / 2)
        XCTAssertEqual(draft.byteCount, AgentMessageDraft.maximumBytes, "limits are UTF-8 bytes")
        XCTAssertNil(draft.problem)
        draft.text += "x"
        XCTAssertTrue(draft.isOverLimit)
        XCTAssertEqual(draft.problem, .tooLong(bytes: AgentMessageDraft.maximumBytes + 1))
        XCTAssertThrowsError(try draft.proposal(for: session)) { error in
            XCTAssertEqual(error as? AgentMessageDraft.DraftError, .tooLong(bytes: AgentMessageDraft.maximumBytes + 1))
        }

        for bad in ["clear\u{1B}[2J", "bell\u{07}", "del\u{7F}", "c1\u{85}"] {
            draft.text = bad
            XCTAssertEqual(draft.problem, .controlCharacters, bad.debugDescription)
            XCTAssertThrowsError(try draft.proposal(for: session))
        }
    }

    /// A managed session that never reported its turn state has nothing to
    /// bind a message to.
    func testNoTurnStateOffersNoCompose() throws {
        let session = try makeSession(turnState: nil)
        XCTAssertFalse(AgentSessionControls(session: session, grants: allGrants).canCompose)
        var draft = AgentMessageDraft()
        draft.text = "hello"
        XCTAssertThrowsError(try draft.proposal(for: session)) { error in
            XCTAssertEqual(error as? AgentMessageDraft.DraftError, .notOffered)
        }
    }

    // MARK: Grants

    func testMissingGrantsHideTheControls() throws {
        let running = try makeSession(turnState: .active, turnID: "t1")

        let full = AgentSessionControls(session: running, grants: allGrants)
        XCTAssertTrue(full.canRead)
        XCTAssertTrue(full.canCompose)
        XCTAssertTrue(full.canInterrupt)

        let readOnly = AgentSessionControls(session: running, grants: DeviceGrant.agentPhone)
        XCTAssertTrue(readOnly.canRead)
        XCTAssertFalse(readOnly.canCompose)
        XCTAssertFalse(readOnly.canInterrupt)
        XCTAssertTrue(readOnly.messagesNeedGrant)
        XCTAssertTrue(readOnly.cancelNeedsGrant)

        let messagesOnly = AgentSessionControls(session: running, grants: DeviceGrant.agentPhone.union([.agentMessagesSend]))
        XCTAssertTrue(messagesOnly.canCompose)
        XCTAssertFalse(messagesOnly.canInterrupt, "cancellation is a separate opt-in")

        // No session read grant: nothing is shown at all.
        let noRead = allGrants.subtracting([.agentSessionsRead])
        XCTAssertFalse(AgentSessionControls(session: running, grants: noRead).canCompose)
        XCTAssertTrue(AgentSessionControls.visibleSessions([running], grants: noRead).isEmpty)

        // Interrupt needs a running turn.
        let idle = try makeSession(turnState: .idle)
        XCTAssertFalse(AgentSessionControls(session: idle, grants: allGrants).canInterrupt)
        XCTAssertTrue(AgentSessionControls(session: idle, grants: allGrants).canCompose)

        // A session that did not negotiate the features offers neither.
        let plain = try makeSession(turnState: .active, turnID: "t1", operations: [])
        let controls = AgentSessionControls(session: plain, grants: allGrants)
        XCTAssertFalse(controls.canCompose)
        XCTAssertFalse(controls.canInterrupt)
        XCTAssertFalse(controls.messagesNeedGrant)

        // An ended session offers nothing.
        var ended = running
        ended.state = .ended
        XCTAssertFalse(AgentSessionControls(session: ended, grants: allGrants).canCompose)
    }

    func testOnlyManagedSessionsAreListed() throws {
        let managed = try makeSession(turnState: .idle)
        let hook = try makeSession(turnState: nil, profile: .hook, operations: [])
        XCTAssertEqual(AgentSessionControls.visibleSessions([hook, managed], grants: allGrants).map(\.registration.agentSessionID),
                       [managed.registration.agentSessionID])
    }

    func testInterruptBindsTheExactTurn() throws {
        let session = try makeSession(turnState: .active, turnID: "turn-7", version: 4)
        let proposal = try AgentSessionProposal.interrupt(session)
        XCTAssertEqual(proposal.target, .cancel(turnID: "turn-7"))
        XCTAssertEqual(proposal.action, .cancel(agentSessionID: session.registration.agentSessionID,
                                                runID: session.registration.runID, expectedSessionVersion: 4, turnID: "turn-7"))
        XCTAssertThrowsError(try AgentSessionProposal.interrupt(try makeSession(turnState: .idle)))
    }

    // MARK: Feed

    /// A session-command record on `agent.delivery.updated` is tracked as a
    /// command outcome; input and approval events in the same page still
    /// parse, and unreadable projections are skipped.
    func testSessionCommandDeliveryEventsParseWithoutBreakingTheInbox() throws {
        let session = try makeSession(turnState: .idle, version: 3)
        let sessionID = session.registration.agentSessionID
        var inbox = ControlAgentInbox()
        inbox.adopt(session)

        let action = try AgentMessageDraft(text: "go").proposal(for: session).action
        var record = AgentSessionCommandRecord(commandID: .random(), action: action, deviceID: .random(),
                                               recordedAt: now, notAfter: now.adding(60))
        let input = try makeInput()
        let reference = AgentApprovalReference(requestID: .random(), agentSessionID: sessionID)
        record.dispatch = .dispatchStarted
        record.version = 2
        var stale = record
        stale.dispatch = .awaitingOrigin
        stale.version = 1
        inbox.apply(AgentChangePage(events: [
            event(.deliveryUpdated, resource: record.commandID, version: 2, record.json),
            event(.inputCreated, resource: input.spec.requestID, version: 1, input.json),
            event(.deliveryUpdated, resource: .random(), version: 1, .object(["unexpected": "shape"])),
            event(.deliveryUpdated, resource: reference.requestID, version: 1, reference.json),
            // An older copy of the same record never moves it backwards.
            event(.deliveryUpdated, resource: record.commandID, version: 1, stale.json)
        ], cursor: ChangeCursor("ac1.9.t"), serverTime: now))

        XCTAssertEqual(inbox.sessionCommands[record.commandID]?.dispatch, .dispatchStarted)
        XCTAssertEqual(inbox.pendingInputs.map(\.spec.requestID), [input.spec.requestID])
        XCTAssertNotNil(inbox.approvals[reference.requestID])
        XCTAssertTrue(inbox.unsupportedInputs.isEmpty, "a delivery event is never an unsupported question")
        XCTAssertEqual(inbox.cursor, ChangeCursor("ac1.9.t"))

        let outcomes = AgentSessionCommandOutcome.merge(sessionID: sessionID, local: [:], records: inbox.sessionCommands)
        XCTAssertEqual(outcomes.map(\.outcome), [.waitingForAgent])
        XCTAssertFalse(outcomes[0].isSettled)
        XCTAssertEqual(outcomes[0].outcome.text, "Waiting for agent")
    }

    /// Turn events move the mirrored turn state and session version the
    /// same way the broker does.
    func testTurnEventsMoveTheMirroredTurnState() throws {
        let session = try makeSession(turnState: .idle, version: 3)
        let sessionID = session.registration.agentSessionID
        var inbox = ControlAgentInbox()
        inbox.adopt(session)
        let started = try AgentEvent(type: .turnStarted, originID: .random(), agentSessionID: sessionID,
                                     providerTurnID: "turn-9", occurredAt: now, observedAt: now)
        inbox.apply(AgentChangePage(events: [event(.turnStarted, resource: sessionID, version: 4, started.json)],
                                    cursor: ChangeCursor("ac1.10.t"), serverTime: now))
        XCTAssertEqual(inbox.session(sessionID)?.turnState, .active)
        XCTAssertEqual(inbox.session(sessionID)?.activeTurnID, "turn-9")
        XCTAssertEqual(inbox.session(sessionID)?.sessionVersion, 4)

        let completed = try AgentEvent(type: .turnCompleted, originID: .random(), agentSessionID: sessionID,
                                       providerTurnID: "turn-9", occurredAt: now, observedAt: now)
        inbox.apply(AgentChangePage(events: [event(.turnCompleted, resource: sessionID, version: 5, completed.json)],
                                    cursor: ChangeCursor("ac1.11.t"), serverTime: now))
        XCTAssertEqual(inbox.session(sessionID)?.turnState, .idle)
        XCTAssertNil(inbox.session(sessionID)?.activeTurnID)
        XCTAssertEqual(inbox.turnEvents.count, 1)

        // An older projection never replaces a newer one.
        inbox.adopt(session)
        XCTAssertEqual(inbox.session(sessionID)?.sessionVersion, 5)
    }

    func testOutcomesAreDistinctAndNeverMoveBackwards() throws {
        let session = try makeSession(turnState: .idle)
        let sessionID = session.registration.agentSessionID
        let action = try AgentMessageDraft(text: "go").proposal(for: session).action
        let commandID = ControlID.random()
        let result = AgentCommandResult(recorded: true, commandID: commandID, dispatch: .awaitingOrigin, serverTime: now)
        var record = AgentSessionCommandRecord(commandID: commandID, action: action, deviceID: .random(),
                                               recordedAt: now, notAfter: now.adding(60))
        record.dispatch = .accepted
        let local = [commandID: AgentLocalSessionCommand(sessionID: sessionID, action: action,
                                                         state: .responseRecorded(result), at: now)]
        let merged = AgentSessionCommandOutcome.merge(sessionID: sessionID, local: local, records: [commandID: record])
        XCTAssertEqual(merged.map(\.outcome), [.agentAccepted])
        XCTAssertTrue(merged[0].isSettled)

        let unknown = AgentSessionCommandOutcome.merge(
            sessionID: sessionID,
            local: [commandID: AgentLocalSessionCommand(sessionID: sessionID, action: nil,
                                                        state: .outcomeUnknown(commandID: commandID, reason: "timeout"), at: now)],
            records: [:]
        )
        XCTAssertEqual(unknown.map(\.outcome), [.outcomeUnknown])
        XCTAssertFalse(unknown[0].isSettled, "an ambiguous submission is still followed")

        let words = [AgentSessionOutcome.sending, .recorded, .waitingForAgent, .agentAccepted, .notApplied, .outcomeUnknown].map(\.text)
        XCTAssertEqual(Set(words).count, 6)
    }

    // MARK: Sending

    /// The broker refuses a stale session version: the user is told the
    /// session changed, nothing is resent, and the journal keeps nothing to
    /// retry.
    func testStaleVersionSurfacesSessionChangedWithoutResending() async throws {
        let session = try makeSession(turnState: .active, turnID: "turn-1", version: 5)
        let service = StubSessionService(session: session, now: now)
        service.submitError = ControlError(code: .staleVersion, message: "the active turn changed")
        let journal = try CommandJournal(store: InMemoryCommandJournal())
        let coordinator = makeCoordinator(service: service, journal: journal)

        let proposal = try AgentMessageDraft(text: "steer").proposal(for: session)
        let result = try await AgentSessionSender.send(proposal, with: coordinator)
        XCTAssertEqual(result, .refused(.sessionChanged))
        XCTAssertEqual(AgentSessionSendFailure.sessionChanged.text, "The session changed — review again")
        XCTAssertEqual(service.submitted, 1, "submitted once, never resent")
        let pending = await journal.pending
        XCTAssertTrue(pending.isEmpty, "a proven refusal leaves nothing to retry")
    }

    /// A session that moved after review is refused before anything is
    /// signed or submitted; the proposal is not rebuilt against the new turn.
    func testMovedSessionIsRefusedBeforeSigning() async throws {
        let reviewed = try makeSession(turnState: .active, turnID: "turn-1", version: 5)
        let service = StubSessionService(session: try makeSession(turnState: .active, turnID: "turn-2", version: 6,
                                                                   like: reviewed), now: now)
        let journal = try CommandJournal(store: InMemoryCommandJournal())
        let coordinator = makeCoordinator(service: service, journal: journal)

        let result = try await AgentSessionSender.send(try AgentMessageDraft(text: "steer").proposal(for: reviewed), with: coordinator)
        XCTAssertEqual(result, .refused(.sessionChanged))
        XCTAssertEqual(service.submitted, 0)
        XCTAssertEqual(service.challenges, 0)
    }

    func testMissingGrantIsRefusedBeforeSigning() async throws {
        let session = try makeSession(turnState: .active, turnID: "turn-1")
        let service = StubSessionService(session: session, now: now)
        let coordinator = makeCoordinator(service: service, journal: try CommandJournal(store: InMemoryCommandJournal()),
                                          grants: DeviceGrant.agentPhone.union([.agentMessagesSend]))
        let result = try await AgentSessionSender.send(try AgentSessionProposal.interrupt(session), with: coordinator)
        XCTAssertEqual(result, .refused(.missingGrant(.agentTurnsCancel)))
        XCTAssertEqual(service.submitted, 0)
    }

    func testAcceptedSubmissionNamesItsCommand() async throws {
        let session = try makeSession(turnState: .idle, version: 2)
        let service = StubSessionService(session: session, now: now)
        let coordinator = makeCoordinator(service: service, journal: try CommandJournal(store: InMemoryCommandJournal()))
        let result = try await AgentSessionSender.send(try AgentMessageDraft(text: "start").proposal(for: session), with: coordinator)
        guard case .submitted(let state) = result else { return XCTFail("expected a submission") }
        XCTAssertEqual(AgentSessionOutcome(state), .recorded)
        XCTAssertNotNil(AgentSessionSender.commandID(of: state))
        XCTAssertEqual(service.submitted, 1)
    }

    // MARK: Fixtures

    private func makeCoordinator(service: StubSessionService, journal: CommandJournal,
                                 grants: Set<DeviceGrant>? = nil) -> AgentSessionCoordinator {
        AgentSessionCoordinator(
            service: service, journal: journal, key: InMemoryDeviceKey(),
            signer: SignerIdentity(deviceID: .random(), audience: "shell-control:account-1", grants: grants ?? allGrants),
            now: { [now] in now.date }
        )
    }

    private func makeSession(
        turnState: AgentTurnState?, turnID: String? = nil, version: Int64 = 1,
        profile: AgentIntegrationProfile = .managed,
        operations: [String] = [AgentFeature.messages, AgentFeature.turnCancel],
        like other: AgentSessionProjection? = nil
    ) throws -> AgentSessionProjection {
        let registration = try other?.registration ?? AgentSessionRegistration(
            agentSessionID: .random(), runID: .random(), provider: "codex", providerBuild: "0.50.0",
            adapterBuild: "adapter", profile: profile, evidence: .contractTested, operations: operations, startedAt: now
        )
        return AgentSessionProjection(registration: registration, sessionVersion: version, turnState: turnState,
                                      activeTurnID: turnState == .active ? (turnID ?? "turn") : nil)
    }

    private func event(_ type: AgentEventType, resource: ControlID, version: Int64, _ projection: JSONValue) -> AgentChangeEvent {
        AgentChangeEvent(eventID: .random(), sequence: LogSequence(UInt64(version)), type: type, resourceID: resource,
                         resourceVersion: version, serverTime: now, projection: projection)
    }

    private func makeInput() throws -> InputRecord {
        let hex = String(repeating: "d", count: 64)
        let spec = try InputSpec(
            requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
            createdAt: now, expiresAt: now.adding(300), summary: "Choose",
            source: try InputSource(
                provider: "codex", providerBuild: "tested", adapterBuild: "adapter",
                nativeRequestSHA256: hex, contextSHA256: hex, answerMappingSHA256: hex,
                agentSessionID: .random(), nativeWaitID: .random()
            ),
            questions: [try InputQuestion(
                id: "q", prompt: "Which?",
                kind: .singleChoice(choices: [try InputChoice(id: "a", label: "A")]), required: true
            )],
            allowedResponses: [.answer],
            minimumReview: .watch
        )
        return try InputRecord(spec: spec, projection: InputProjection(presence: SourcePresence(lastSeenAt: now, isWaiting: true)))
    }
}

/// A Mac's session endpoints, scripted.
private nonisolated final class StubSessionService: AgentSessionService, @unchecked Sendable {
    private let lock = NSLock()
    private let session: AgentSessionProjection
    private let now: ControlTimestamp
    private var submitCount = 0
    private var challengeCount = 0
    var submitError: (any Error)?

    init(session: AgentSessionProjection, now: ControlTimestamp) {
        self.session = session
        self.now = now
    }

    var submitted: Int { lock.withLock { submitCount } }
    var challenges: Int { lock.withLock { challengeCount } }

    func agentSession(_ id: ControlID) async throws -> AgentSessionProjection { session }

    func agentReviewChallenge(_ request: AgentReviewChallengeRequest) async throws -> AgentReviewChallenge {
        lock.withLock { challengeCount += 1 }
        return AgentReviewChallenge(challengeID: "challenge-1", deviceID: .random(), action: request.action, expiresAt: now.adding(60))
    }

    func submitAgent(signedCommand: String, commandID: ControlID) async throws -> AgentCommandResult {
        try lock.withLock {
            submitCount += 1
            if let submitError { throw submitError }
            return AgentCommandResult(recorded: true, commandID: commandID, dispatch: .awaitingOrigin, serverTime: now)
        }
    }

    func agentCommandResult(_ commandID: ControlID) async throws -> AgentCommandResult {
        AgentCommandResult(recorded: true, commandID: commandID, dispatch: .awaitingOrigin, serverTime: now)
    }
}
