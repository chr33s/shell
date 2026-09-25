import XCTest
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@testable import ShellWatch

/// Agent questions on the Watch: narrow eligibility, drafts that need an
/// explicit final confirmation, live-only submission, and answers signed by
/// the Watch's own key (docs/specs/agent-relay.md sections 7.1, 12.2, and 14.5).
@MainActor
final class AgentInputTests: XCTestCase {
    private let now = ControlTimestamp(Date(timeIntervalSince1970: 1_790_000_000))

    private struct Rig {
        let session: ControlSession
        let gateway: StubGateway
        let keys: InMemoryCredentialStore
        let reviewers: InMemoryWatchReviewerStore
        let journal: InMemoryCommandJournal
    }

    private func rig(grants: Set<DeviceGrant> = DeviceGrant.watchReviewerDefault.union(DeviceGrant.agentWatchReviewer)) async throws -> Rig {
        let gateway = StubGateway(now: now)
        let keys = InMemoryCredentialStore()
        let key = InMemoryDeviceKey()
        try keys.storeSigningKey(key)
        let reviewer = WatchTestFixtures.activeReviewer(accountID: gateway.accountID, key: key, grants: grants)
        let reviewers = InMemoryWatchReviewerStore(reviewer)
        await gateway.setReviewer(reviewer)
        let journal = InMemoryCommandJournal()
        let session = try ControlSession(
            link: gateway, keys: keys, reviewerStore: reviewers, cache: InMemoryInboxCache(),
            journalStore: journal, now: { [now] in now.date }
        )
        return Rig(session: session, gateway: gateway, keys: keys, reviewers: reviewers, journal: journal)
    }

    private func choice(_ id: String) throws -> InputChoice { try InputChoice(id: id, label: id.uppercased()) }

    // MARK: Eligibility

    func testOnlyNarrowLiveQuestionsAreAnswerableOnTheWatch() throws {
        let narrow = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        XCTAssertEqual(WatchInputEligibility.evaluate(narrow, now: now, gatewayReachable: true, fetchedLive: true), .answerable)

        // Three questions: over the Watch's two-question policy.
        let many = try WatchTestFixtures.makeInput(createdAt: now, questions: try ["a", "b", "c"].map {
            try InputQuestion(id: $0, prompt: "Pick", kind: .singleChoice(choices: [try choice("x"), try choice("y")]), required: true)
        }, presentAt: now)
        XCTAssertEqual(WatchInputEligibility.evaluate(many, now: now, gatewayReachable: true, fetchedLive: true),
                       .reviewOnIPhone(.policyRequiresFullReview))

        // Five choices: over the four-choice policy.
        let wide = try WatchTestFixtures.makeInput(createdAt: now, questions: [
            try InputQuestion(id: "q", prompt: "Pick", kind: .singleChoice(choices: try ["a", "b", "c", "d", "e"].map(choice)), required: true)
        ], presentAt: now)
        XCTAssertEqual(WatchInputEligibility.evaluate(wide, now: now, gatewayReachable: true, fetchedLive: true),
                       .reviewOnIPhone(.policyRequiresFullReview))

        // Long text is not short text.
        let long = try WatchTestFixtures.makeInput(createdAt: now, questions: [
            try InputQuestion(id: "q", prompt: "Why?", kind: .text(maximumBytes: 2048, hint: nil), required: true)
        ], presentAt: now)
        XCTAssertEqual(WatchInputEligibility.evaluate(long, now: now, gatewayReachable: true, fetchedLive: true),
                       .reviewOnIPhone(.policyRequiresFullReview))

        let full = try WatchTestFixtures.makeInput(createdAt: now, minimumReview: .full, presentAt: now)
        XCTAssertEqual(WatchInputEligibility.evaluate(full, now: now, gatewayReachable: true, fetchedLive: true),
                       .reviewOnIPhone(.policyRequiresFullReview))

        let absent = try WatchTestFixtures.makeInput(createdAt: now)
        XCTAssertEqual(WatchInputEligibility.evaluate(absent, now: now, gatewayReachable: true, fetchedLive: true),
                       .reviewOnIPhone(.sourceNotPresent))
        XCTAssertTrue(WatchInputEligibility.permitsDecline(absent, now: now, gatewayReachable: true, fetchedLive: true),
                      "a decline, like a reject, does not need the agent's presence")
    }

    /// An unavailable iPhone disables submission immediately; cached details
    /// stay readable but stale, and cannot answer or decline.
    func testUnreachableOrStaleDisablesSubmission() throws {
        let record = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        let unreachable = WatchInputEligibility.evaluate(record, now: now, gatewayReachable: false, fetchedLive: true)
        XCTAssertEqual(unreachable, .iPhoneUnavailable)
        XCTAssertFalse(unreachable.permitsSubmission)
        XCTAssertFalse(WatchInputEligibility.permitsDecline(record, now: now, gatewayReachable: false, fetchedLive: true))

        let stale = WatchInputEligibility.evaluate(record, now: now, gatewayReachable: true, fetchedLive: false)
        XCTAssertEqual(stale, .stale)
        XCTAssertFalse(stale.permitsSubmission)
        XCTAssertFalse(WatchInputEligibility.permitsDecline(record, now: now, gatewayReachable: true, fetchedLive: false))
    }

    func testAnUnreachableIPhoneQueuesNoAnswer() async throws {
        let rig = try await rig()
        let record = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        await rig.gateway.setAgentInputs([record])
        await rig.session.start()
        XCTAssertEqual(rig.session.pendingAgentInputs.map(\.spec.requestID), [record.spec.requestID])

        var draft = WatchAnswerDraft()
        let question = try XCTUnwrap(record.spec.questions.first)
        draft.select("focused", in: question)
        let proposed = try XCTUnwrap(draft.proposedResponse(for: record.spec))
        XCTAssertTrue(draft.confirm(proposed, for: record.spec))

        await rig.gateway.setReachable(false)
        rig.session.gatewayReachabilityChanged(false)
        await rig.session.respond(with: draft, to: record)
        let submitted = await rig.gateway.agentSubmitted
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertTrue(try rig.journal.load().isEmpty, "no answer is held for later delivery")
        XCTAssertNil(rig.session.agentSubmissions[record.spec.requestID])
        XCTAssertNotNil(rig.session.agentProblems[record.spec.requestID])
        XCTAssertEqual(rig.session.pendingAgentInputs.count, 1, "cached details remain readable")
    }

    /// Shell options change what runs: the review lists every one, escaped,
    /// and one too long to show in full keeps approval off the Watch.
    func testShellOptionsAreShownInFull() throws {
        func operation(_ options: [String: AgentOptionValue]) throws -> AgentToolOperation {
            try AgentToolOperation(
                provider: "claude_code", providerBuild: "tested", adapterBuild: "adapter",
                agentSessionID: .random(), nativeWaitID: .random(), kind: .shell, toolName: "Bash",
                cwd: "/srv/work", reason: nil,
                shellRequest: try AgentShellRequest(representation: .commandString, command: "git status", options: options),
                unavailable: [],
                nativeRequestSHA256: String(repeating: "a", count: 64), contextSHA256: String(repeating: "b", count: 64)
            )
        }
        let shown = try operation(["timeout": .integer(600), "run_in_background": .bool(true), "note": .string("a\u{202E}b")])
        XCTAssertFalse(shown.isWatchEligible, "the Watch cannot approve options")
        let rows = AgentOperationRows.options(shown)
        XCTAssertEqual(rows.map(\.name.text), ["note", "run_in_background", "timeout"])
        XCTAssertEqual(rows.map(\.value.text), ["a<U+202E>b", "true", "600"])
        XCTAssertTrue(rows[0].value.didEscape)
        XCTAssertFalse(AgentOperationRows.hidesContent(.agentTool(shown)))

        let long = try operation(["note": .string(String(repeating: "x", count: 1000))])
        XCTAssertTrue(AgentOperationRows.hidesContent(.agentTool(long)), "a truncated option value keeps approval disabled")
    }

    // MARK: Snapshot

    /// The Watch asks only for what can still be answered, and a cut longer
    /// than it reads is never adopted: its cursor would skip the rest.
    func testAgentSnapshotIsPendingOnlyAndACappedCutIsNotAdopted() async throws {
        let rig = try await rig()
        let pending = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        await rig.gateway.setAgentInputs([pending])
        await rig.session.start()
        XCTAssertEqual(rig.session.pendingAgentInputs.map(\.spec.requestID), [pending.spec.requestID])
        let flags = await rig.gateway.agentSnapshotPendingOnly
        XCTAssertEqual(flags, [true])

        let capped = try await self.rig()
        let many = try (0...ControlSession.agentMaxSnapshotPages).map { _ in
            try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        }
        await capped.gateway.setAgentInputs(many)
        await capped.gateway.setAgentSnapshotPageSize(1)
        await capped.session.start()
        XCTAssertTrue(capped.session.pendingAgentInputs.isEmpty, "a partial cut is not adopted")
        XCTAssertNotEqual(capped.session.agentAvailability, .available)
        XCTAssertNotNil(capped.session.lastError)
        var cappedFlags = await capped.gateway.agentSnapshotPendingOnly
        XCTAssertEqual(cappedFlags.count, ControlSession.agentMaxSnapshotPages)
        XCTAssertTrue(cappedFlags.allSatisfy { $0 })

        // No cursor was adopted: the next refresh snapshots again rather
        // than reading changes after the last page it saw.
        await capped.session.refreshAgent(force: true)
        let types = await capped.gateway.agentRequestTypes()
        XCTAssertFalse(types.contains(.changesFetch))
        cappedFlags = await capped.gateway.agentSnapshotPendingOnly
        XCTAssertEqual(cappedFlags.count, 2 * ControlSession.agentMaxSnapshotPages)

        // Once the pending work fits, the cut is adopted in full.
        await capped.gateway.setAgentSnapshotPageSize(nil)
        await capped.session.refreshAgent(force: true)
        XCTAssertEqual(capped.session.pendingAgentInputs.count, many.count)
        XCTAssertEqual(capped.session.agentAvailability, .available)
    }

    // MARK: Drafts

    /// Dictation produces a draft only: nothing is signable until the exact
    /// text is confirmed, and a later edit withdraws the confirmation.
    func testDictatedTextNeedsAFinalConfirmation() throws {
        let record = try WatchTestFixtures.makeInput(createdAt: now, questions: [
            try InputQuestion(id: "note", prompt: "Anything else?", kind: .text(maximumBytes: 120, hint: nil), required: true)
        ], presentAt: now)
        let question = try XCTUnwrap(record.spec.questions.first)
        var draft = WatchAnswerDraft()
        draft.setDraftText("run the focused suite", for: question)
        XCTAssertEqual(draft.answers.byteCount(for: question), 21)
        XCTAssertNil(draft.confirmedResponse(for: record.spec), "a dictation result is a draft")

        let proposed = try XCTUnwrap(draft.proposedResponse(for: record.spec))
        XCTAssertEqual(proposed, .answer([.text(questionID: "note", text: "run the focused suite")]))
        XCTAssertFalse(draft.confirm(.answer([.text(questionID: "note", text: "something else")]), for: record.spec),
                       "only the exact text on screen can be confirmed")
        XCTAssertTrue(draft.confirm(proposed, for: record.spec))
        XCTAssertEqual(draft.confirmedResponse(for: record.spec), proposed)

        draft.setDraftText("run everything", for: question)
        XCTAssertNil(draft.confirmedResponse(for: record.spec), "an edit after confirmation withdraws it")
    }

    func testAnUnconfirmedDraftIsNeverSent() async throws {
        let rig = try await rig()
        let record = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        await rig.gateway.setAgentInputs([record])
        await rig.session.start()
        var draft = WatchAnswerDraft()
        draft.select("all", in: try XCTUnwrap(record.spec.questions.first))
        await rig.session.respond(with: draft, to: record)
        let submitted = await rig.gateway.agentSubmitted
        XCTAssertTrue(submitted.isEmpty)
        let types = await rig.gateway.agentRequestTypes()
        XCTAssertFalse(types.contains(.reviewChallenge), "nothing is even challenged before confirmation")
    }

    func testMultiChoiceKeepsCommittedOrderAndItsMaximum() throws {
        let record = try WatchTestFixtures.makeInput(createdAt: now, questions: [
            try InputQuestion(id: "q", prompt: "Which?", kind: .multiChoice(choices: try ["a", "b", "c", "d"].map(choice), minimum: 1, maximum: 2), required: true)
        ], presentAt: now)
        let question = try XCTUnwrap(record.spec.questions.first)
        var draft = WatchAnswerDraft()
        draft.select("c", in: question)
        draft.select("a", in: question)
        draft.select("d", in: question)
        XCTAssertEqual(draft.answers.selectionCount(for: question), 2, "the maximum is not exceeded")
        XCTAssertEqual(draft.proposedResponse(for: record.spec), .answer([.multiChoice(questionID: "q", choiceIDs: ["a", "c"])]))
    }

    // MARK: Signing and transport

    /// The answer is signed by the Watch's key under its own device ID and
    /// carried unchanged; the iPhone cannot substitute its own.
    func testAnswerIsSignedByTheWatchKey() async throws {
        let rig = try await rig()
        let record = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        await rig.gateway.setAgentInputs([record])
        await rig.session.start()
        XCTAssertEqual(rig.session.agentAvailability, .available)

        var draft = WatchAnswerDraft()
        draft.select("focused", in: try XCTUnwrap(record.spec.questions.first))
        let proposed = try XCTUnwrap(draft.proposedResponse(for: record.spec))
        XCTAssertTrue(draft.confirm(proposed, for: record.spec))
        await rig.session.respond(with: draft, to: record)

        let submitted = await rig.gateway.agentSubmitted
        let jws = try XCTUnwrap(submitted.first)
        let reviewer = try XCTUnwrap(rig.reviewers.load())
        let key = try XCTUnwrap(try rig.keys.loadSigningKey())
        let verified = try ControlJWS.verifyAgent(compactSerialization: jws) { id in
            id == reviewer.watchDeviceID ? key.publicJWK : nil
        }
        XCTAssertEqual(verified.deviceID, reviewer.watchDeviceID)
        guard case .inputRespond(let command) = verified.command else { return XCTFail("\(verified.command)") }
        XCTAssertEqual(command.envelope.audience, reviewer.audience)
        XCTAssertEqual(command.requestID, record.spec.requestID)
        XCTAssertEqual(command.response, .answer([.singleChoice(questionID: "test_scope", choiceID: "focused")]))
        guard case .responseRecorded = try XCTUnwrap(rig.session.agentSubmissions[record.spec.requestID]) else {
            return XCTFail("recorded is shown as recorded, not accepted")
        }
        let types = await rig.gateway.agentRequestTypes()
        // Refetched before signing, then a fresh challenge, then the command.
        let order = types.filter { [.inputFetch, .reviewChallenge, .commandSubmit].contains($0) }
        XCTAssertEqual(order, [.inputFetch, .reviewChallenge, .commandSubmit])
    }

    /// An iPhone without the extension makes agent questions unsupported;
    /// it is not an error the Watch keeps reporting.
    func testAnOldIPhoneMakesAgentQuestionsUnsupported() async throws {
        let rig = try await rig()
        await rig.gateway.setAgentSupported(false)
        await rig.session.start()
        XCTAssertEqual(rig.session.phase, .ready)
        XCTAssertEqual(rig.session.agentAvailability, .unsupported)
        XCTAssertNil(rig.session.gatewayProblem)
        XCTAssertTrue(rig.session.pendingAgentInputs.isEmpty)
    }

    func testWithoutTheGrantAgentQuestionsAreNotEnabled() async throws {
        let rig = try await rig(grants: DeviceGrant.watchReviewerDefault)
        await rig.gateway.setAgentNotAuthorized(true)
        await rig.session.start()
        XCTAssertEqual(rig.session.agentAvailability, .notEnabled)
        XCTAssertNil(rig.session.gatewayProblem)
        XCTAssertNil(rig.session.lastError)
    }
}
