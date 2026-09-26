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

import Foundation
import Testing
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@testable import Shell

@MainActor
@Suite
final class ControlAgentSessionTests {
    private let now = ControlTimestamp(Date(timeIntervalSince1970: 1_790_000_000))
    private let allGrants = DeviceGrant.agentPhone.union([.agentMessagesSend, .agentTurnsCancel])

    // MARK: Compose

    @Test
    func testIdleSessionBuildsANewTurnFromTheReviewedProjection() throws {
        let session = try makeSession(turnState: .idle, version: 7)
        var draft = AgentMessageDraft()
        draft.text = "Run the focused tests"
        let proposal = try draft.proposal(for: session)
        #expect(proposal.target == .newTurn)
        #expect(proposal.action == .message(
            agentSessionID: session.registration.agentSessionID, runID: session.registration.runID,
            expectedSessionVersion: 7, mode: .newTurn, expectedTurnID: nil, text: "Run the focused tests"
        ))
        #expect(ControlAgentText.target(proposal.target) == "Starts a new turn")
    }

    @Test
    func testRunningSessionSteersTheExactActiveTurn() throws {
        let session = try makeSession(turnState: .active, turnID: "turn-42", version: 9)
        var draft = AgentMessageDraft()
        draft.text = "Also check the docs\n\tplease"
        let proposal = try draft.proposal(for: session)
        #expect(proposal.target == .steer(turnID: "turn-42"))
        #expect(proposal.action.expectedSessionVersion == 9)
        guard case .message(_, _, _, .steer, "turn-42", let text) = proposal.action else {
            Issue.record("expected steering of turn-42")
return
        }
        #expect(text == "Also check the docs\n\tplease", "sent exactly as typed")
        // Line breaks stay real; the tab is shown escaped.
        #expect(proposal.displayLines.map(\.text) == ["Also check the docs", "<U+0009>please"])
        #expect(proposal.didEscape)
        #expect(ControlAgentText.target(proposal.target) == "Steers turn turn-42")

        // A later projection does not change what was reviewed.
        let moved = try makeSession(turnState: .active, turnID: "turn-43", version: 10)
        #expect(proposal.reviewed.activeTurnID == "turn-42")
        #expect((try draft.proposal(for: moved).action) != proposal.action)
    }

    @Test
    func testOverLimitAndControlCharacterTextIsRefused() throws {
        let session = try makeSession(turnState: .idle)
        var draft = AgentMessageDraft()
        #expect(draft.problem == .empty)
        #expect(throws: (any Error).self){ try draft.proposal(for: session) }

        draft.text = String(repeating: "é", count: AgentMessageDraft.maximumBytes / 2)
        #expect(draft.byteCount == AgentMessageDraft.maximumBytes, "limits are UTF-8 bytes")
        #expect((draft.problem) == nil)
        draft.text += "x"
        #expect(draft.isOverLimit)
        #expect(draft.problem == .tooLong(bytes: AgentMessageDraft.maximumBytes + 1))
        do { _ = try draft.proposal(for: session)
Issue.record("expected an error")
} catch let error {
            #expect(error as? AgentMessageDraft.DraftError == .tooLong(bytes: AgentMessageDraft.maximumBytes + 1))
        }

        for bad in ["clear\u{1B}[2J", "bell\u{07}", "del\u{7F}", "c1\u{85}"] {
            draft.text = bad
            #expect(draft.problem == .controlCharacters, "\(bad.debugDescription)")
            #expect(throws: (any Error).self){ try draft.proposal(for: session) }
        }
    }

    /// A managed session that never reported its turn state has nothing to
    /// bind a message to.
    @Test
    func testNoTurnStateOffersNoCompose() throws {
        let session = try makeSession(turnState: nil)
        #expect(!(AgentSessionControls(session: session, grants: allGrants).canCompose))
        var draft = AgentMessageDraft()
        draft.text = "hello"
        do { _ = try draft.proposal(for: session)
Issue.record("expected an error")
} catch let error {
            #expect(error as? AgentMessageDraft.DraftError == .notOffered)
        }
    }

    // MARK: Grants

    @Test
    func testMissingGrantsHideTheControls() throws {
        let running = try makeSession(turnState: .active, turnID: "t1")

        let full = AgentSessionControls(session: running, grants: allGrants)
        #expect(full.canRead)
        #expect(full.canCompose)
        #expect(full.canInterrupt)

        let readOnly = AgentSessionControls(session: running, grants: DeviceGrant.agentPhone)
        #expect(readOnly.canRead)
        #expect(!(readOnly.canCompose))
        #expect(!(readOnly.canInterrupt))
        #expect(readOnly.messagesNeedGrant)
        #expect(readOnly.cancelNeedsGrant)

        let messagesOnly = AgentSessionControls(session: running, grants: DeviceGrant.agentPhone.union([.agentMessagesSend]))
        #expect(messagesOnly.canCompose)
        #expect(!(messagesOnly.canInterrupt), "cancellation is a separate opt-in")

        // No session read grant: nothing is shown at all.
        let noRead = allGrants.subtracting([.agentSessionsRead])
        #expect(!(AgentSessionControls(session: running, grants: noRead).canCompose))
        #expect(AgentSessionControls.visibleSessions([running], grants: noRead).isEmpty)

        // Interrupt needs a running turn.
        let idle = try makeSession(turnState: .idle)
        #expect(!(AgentSessionControls(session: idle, grants: allGrants).canInterrupt))
        #expect(AgentSessionControls(session: idle, grants: allGrants).canCompose)

        // A session that did not negotiate the features offers neither.
        let plain = try makeSession(turnState: .active, turnID: "t1", operations: [])
        let controls = AgentSessionControls(session: plain, grants: allGrants)
        #expect(!(controls.canCompose))
        #expect(!(controls.canInterrupt))
        #expect(!(controls.messagesNeedGrant))

        // An ended session offers nothing.
        var ended = running
        ended.state = .ended
        #expect(!(AgentSessionControls(session: ended, grants: allGrants).canCompose))
    }

    @Test
    func testOnlyManagedSessionsAreListed() throws {
        let managed = try makeSession(turnState: .idle)
        let hook = try makeSession(turnState: nil, profile: .hook, operations: [])
        #expect(AgentSessionControls.visibleSessions([hook, managed], grants: allGrants).map(\.registration.agentSessionID) == [managed.registration.agentSessionID])
    }

    @Test
    func testInterruptBindsTheExactTurn() throws {
        let session = try makeSession(turnState: .active, turnID: "turn-7", version: 4)
        let proposal = try AgentSessionProposal.interrupt(session)
        #expect(proposal.target == .cancel(turnID: "turn-7"))
        #expect(proposal.action == .cancel(agentSessionID: session.registration.agentSessionID,
                                                runID: session.registration.runID, expectedSessionVersion: 4, turnID: "turn-7"))
        #expect(throws: (any Error).self){ try AgentSessionProposal.interrupt(try makeSession(turnState: .idle)) }
    }

    // MARK: Feed

    /// A session-command record on `agent.delivery.updated` is tracked as a
    /// command outcome; input and approval events in the same page still
    /// parse, and unreadable projections are skipped.
    @Test
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

        #expect(inbox.sessionCommands[record.commandID]?.dispatch == .dispatchStarted)
        #expect(inbox.pendingInputs.map(\.spec.requestID) == [input.spec.requestID])
        #expect((inbox.approvals[reference.requestID]) != nil)
        #expect(inbox.unsupportedInputs.isEmpty, "a delivery event is never an unsupported question")
        #expect(inbox.cursor == ChangeCursor("ac1.9.t"))

        let outcomes = AgentSessionCommandOutcome.merge(sessionID: sessionID, local: [:], records: inbox.sessionCommands)
        #expect(outcomes.map(\.outcome) == [.waitingForAgent])
        #expect(!(outcomes[0].isSettled))
        #expect(outcomes[0].outcome.text == "Waiting for agent")
    }

    /// Turn events move the mirrored turn state and session version the
    /// same way the broker does.
    @Test
    func testTurnEventsMoveTheMirroredTurnState() throws {
        let session = try makeSession(turnState: .idle, version: 3)
        let sessionID = session.registration.agentSessionID
        var inbox = ControlAgentInbox()
        inbox.adopt(session)
        let started = try AgentEvent(type: .turnStarted, originID: .random(), agentSessionID: sessionID,
                                     providerTurnID: "turn-9", occurredAt: now, observedAt: now)
        inbox.apply(AgentChangePage(events: [event(.turnStarted, resource: sessionID, version: 4, started.json)],
                                    cursor: ChangeCursor("ac1.10.t"), serverTime: now))
        #expect(inbox.session(sessionID)?.turnState == .active)
        #expect(inbox.session(sessionID)?.activeTurnID == "turn-9")
        #expect(inbox.session(sessionID)?.sessionVersion == 4)

        let completed = try AgentEvent(type: .turnCompleted, originID: .random(), agentSessionID: sessionID,
                                       providerTurnID: "turn-9", occurredAt: now, observedAt: now)
        inbox.apply(AgentChangePage(events: [event(.turnCompleted, resource: sessionID, version: 5, completed.json)],
                                    cursor: ChangeCursor("ac1.11.t"), serverTime: now))
        #expect(inbox.session(sessionID)?.turnState == .idle)
        #expect((inbox.session(sessionID)?.activeTurnID) == nil)
        #expect(inbox.turnEvents.count == 1)

        // An older projection never replaces a newer one.
        inbox.adopt(session)
        #expect(inbox.session(sessionID)?.sessionVersion == 5)
    }

    @Test
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
        #expect(merged.map(\.outcome) == [.agentAccepted])
        #expect(merged[0].isSettled)

        let unknown = AgentSessionCommandOutcome.merge(
            sessionID: sessionID,
            local: [commandID: AgentLocalSessionCommand(sessionID: sessionID, action: nil,
                                                        state: .outcomeUnknown(commandID: commandID, reason: "timeout"), at: now)],
            records: [:]
        )
        #expect(unknown.map(\.outcome) == [.outcomeUnknown])
        #expect(!(unknown[0].isSettled), "an ambiguous submission is still followed")

        let words = [AgentSessionOutcome.sending, .recorded, .waitingForAgent, .agentAccepted, .notApplied, .outcomeUnknown].map(\.text)
        #expect(Set(words).count == 6)
    }

    // MARK: Sending

    /// The broker refuses a stale session version: the user is told the
    /// session changed, nothing is resent, and the journal keeps nothing to
    /// retry.
    @Test
    func testStaleVersionSurfacesSessionChangedWithoutResending() async throws {
        let session = try makeSession(turnState: .active, turnID: "turn-1", version: 5)
        let service = StubSessionService(session: session, now: now)
        service.submitError = ControlError(code: .staleVersion, message: "the active turn changed")
        let journal = try CommandJournal(store: InMemoryCommandJournal())
        let coordinator = makeCoordinator(service: service, journal: journal)

        let proposal = try AgentMessageDraft(text: "steer").proposal(for: session)
        let result = try await AgentSessionSender.send(proposal, with: coordinator)
        #expect(result == .refused(.sessionChanged))
        #expect(AgentSessionSendFailure.sessionChanged.text == "The session changed — review again")
        #expect(service.submitted == 1, "submitted once, never resent")
        let pending = await journal.pending
        #expect(pending.isEmpty, "a proven refusal leaves nothing to retry")
    }

    /// A session that moved after review is refused before anything is
    /// signed or submitted; the proposal is not rebuilt against the new turn.
    @Test
    func testMovedSessionIsRefusedBeforeSigning() async throws {
        let reviewed = try makeSession(turnState: .active, turnID: "turn-1", version: 5)
        let service = StubSessionService(session: try makeSession(turnState: .active, turnID: "turn-2", version: 6,
                                                                   like: reviewed), now: now)
        let journal = try CommandJournal(store: InMemoryCommandJournal())
        let coordinator = makeCoordinator(service: service, journal: journal)

        let result = try await AgentSessionSender.send(try AgentMessageDraft(text: "steer").proposal(for: reviewed), with: coordinator)
        #expect(result == .refused(.sessionChanged))
        #expect(service.submitted == 0)
        #expect(service.challenges == 0)
    }

    @Test
    func testMissingGrantIsRefusedBeforeSigning() async throws {
        let session = try makeSession(turnState: .active, turnID: "turn-1")
        let service = StubSessionService(session: session, now: now)
        let coordinator = makeCoordinator(service: service, journal: try CommandJournal(store: InMemoryCommandJournal()),
                                          grants: DeviceGrant.agentPhone.union([.agentMessagesSend]))
        let result = try await AgentSessionSender.send(try AgentSessionProposal.interrupt(session), with: coordinator)
        #expect(result == .refused(.missingGrant(.agentTurnsCancel)))
        #expect(service.submitted == 0)
    }

    @Test
    func testAcceptedSubmissionNamesItsCommand() async throws {
        let session = try makeSession(turnState: .idle, version: 2)
        let service = StubSessionService(session: session, now: now)
        let coordinator = makeCoordinator(service: service, journal: try CommandJournal(store: InMemoryCommandJournal()))
        let result = try await AgentSessionSender.send(try AgentMessageDraft(text: "start").proposal(for: session), with: coordinator)
        guard case .submitted(let state) = result else { Issue.record("expected a submission")
return }
        #expect(AgentSessionOutcome(state) == .recorded)
        #expect((AgentSessionSender.commandID(of: state)) != nil)
        #expect(service.submitted == 1)
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
