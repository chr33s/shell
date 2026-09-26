import Foundation
import Testing
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@testable import ShellWatch

/// Agent questions on the Watch: narrow eligibility, drafts that need an
/// explicit final confirmation, live-only submission, and answers signed by
/// the Watch's own key (docs/specs/agent-relay.md sections 7.1, 12.2, and 14.5).
@MainActor
@Suite
final class AgentInputTests {
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

    @Test
    func testOnlyNarrowLiveQuestionsAreAnswerableOnTheWatch() throws {
        let narrow = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        #expect(WatchInputEligibility.evaluate(narrow, now: now, gatewayReachable: true, fetchedLive: true) == .answerable)

        // Three questions: over the Watch's two-question policy.
        let many = try WatchTestFixtures.makeInput(createdAt: now, questions: try ["a", "b", "c"].map {
            try InputQuestion(id: $0, prompt: "Pick", kind: .singleChoice(choices: [try choice("x"), try choice("y")]), required: true)
        }, presentAt: now)
        #expect(WatchInputEligibility.evaluate(many, now: now, gatewayReachable: true, fetchedLive: true) == .reviewOnIPhone(.policyRequiresFullReview))

        // Five choices: over the four-choice policy.
        let wide = try WatchTestFixtures.makeInput(createdAt: now, questions: [
            try InputQuestion(id: "q", prompt: "Pick", kind: .singleChoice(choices: try ["a", "b", "c", "d", "e"].map(choice)), required: true)
        ], presentAt: now)
        #expect(WatchInputEligibility.evaluate(wide, now: now, gatewayReachable: true, fetchedLive: true) == .reviewOnIPhone(.policyRequiresFullReview))

        // Long text is not short text.
        let long = try WatchTestFixtures.makeInput(createdAt: now, questions: [
            try InputQuestion(id: "q", prompt: "Why?", kind: .text(maximumBytes: 2048, hint: nil), required: true)
        ], presentAt: now)
        #expect(WatchInputEligibility.evaluate(long, now: now, gatewayReachable: true, fetchedLive: true) == .reviewOnIPhone(.policyRequiresFullReview))

        let full = try WatchTestFixtures.makeInput(createdAt: now, minimumReview: .full, presentAt: now)
        #expect(WatchInputEligibility.evaluate(full, now: now, gatewayReachable: true, fetchedLive: true) == .reviewOnIPhone(.policyRequiresFullReview))

        let absent = try WatchTestFixtures.makeInput(createdAt: now)
        #expect(WatchInputEligibility.evaluate(absent, now: now, gatewayReachable: true, fetchedLive: true) == .reviewOnIPhone(.sourceNotPresent))
        #expect(WatchInputEligibility.permitsDecline(absent, now: now, gatewayReachable: true, fetchedLive: true), "a decline, like a reject, does not need the agent's presence")
    }

    /// An unavailable iPhone disables submission immediately; cached details
    /// stay readable but stale, and cannot answer or decline.
    @Test
    func testUnreachableOrStaleDisablesSubmission() throws {
        let record = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        let unreachable = WatchInputEligibility.evaluate(record, now: now, gatewayReachable: false, fetchedLive: true)
        #expect(unreachable == .iPhoneUnavailable)
        #expect(!(unreachable.permitsSubmission))
        #expect(!(WatchInputEligibility.permitsDecline(record, now: now, gatewayReachable: false, fetchedLive: true)))

        let stale = WatchInputEligibility.evaluate(record, now: now, gatewayReachable: true, fetchedLive: false)
        #expect(stale == .stale)
        #expect(!(stale.permitsSubmission))
        #expect(!(WatchInputEligibility.permitsDecline(record, now: now, gatewayReachable: true, fetchedLive: false)))
    }

    @Test
    func testAnUnreachableIPhoneQueuesNoAnswer() async throws {
        let rig = try await rig()
        let record = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        await rig.gateway.setAgentInputs([record])
        await rig.session.start()
        #expect(rig.session.pendingAgentInputs.map(\.spec.requestID) == [record.spec.requestID])

        var draft = WatchAnswerDraft()
        let question = try #require(record.spec.questions.first)
        draft.select("focused", in: question)
        let proposed = try #require(draft.proposedResponse(for: record.spec))
        #expect(draft.confirm(proposed, for: record.spec))

        await rig.gateway.setReachable(false)
        rig.session.gatewayReachabilityChanged(false)
        await rig.session.respond(with: draft, to: record)
        let submitted = await rig.gateway.agentSubmitted
        #expect(submitted.isEmpty)
        #expect(try rig.journal.load().isEmpty, "no answer is held for later delivery")
        #expect((rig.session.agentSubmissions[record.spec.requestID]) == nil)
        #expect((rig.session.agentProblems[record.spec.requestID]) != nil)
        #expect(rig.session.pendingAgentInputs.count == 1, "cached details remain readable")
    }

    /// Shell options change what runs: the review lists every one, escaped,
    /// and one too long to show in full keeps approval off the Watch.
    @Test
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
        #expect(!(shown.isWatchEligible), "the Watch cannot approve options")
        let rows = AgentOperationRows.options(shown)
        #expect(rows.map(\.name.text) == ["note", "run_in_background", "timeout"])
        #expect(rows.map(\.value.text) == ["a<U+202E>b", "true", "600"])
        #expect(rows[0].value.didEscape)
        #expect(!(AgentOperationRows.hidesContent(.agentTool(shown))))

        let long = try operation(["note": .string(String(repeating: "x", count: 1000))])
        #expect(AgentOperationRows.hidesContent(.agentTool(long)), "a truncated option value keeps approval disabled")
    }

    // MARK: Snapshot

    /// The Watch asks only for what can still be answered, and a cut longer
    /// than it reads is never adopted: its cursor would skip the rest.
    @Test
    func testAgentSnapshotIsPendingOnlyAndACappedCutIsNotAdopted() async throws {
        let rig = try await rig()
        let pending = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        await rig.gateway.setAgentInputs([pending])
        await rig.session.start()
        #expect(rig.session.pendingAgentInputs.map(\.spec.requestID) == [pending.spec.requestID])
        let flags = await rig.gateway.agentSnapshotPendingOnly
        #expect(flags == [true])

        let capped = try await self.rig()
        let many = try (0...ControlSession.agentMaxSnapshotPages).map { _ in
            try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        }
        await capped.gateway.setAgentInputs(many)
        await capped.gateway.setAgentSnapshotPageSize(1)
        await capped.session.start()
        #expect(capped.session.pendingAgentInputs.isEmpty, "a partial cut is not adopted")
        #expect(capped.session.agentAvailability != .available)
        #expect((capped.session.lastError) != nil)
        var cappedFlags = await capped.gateway.agentSnapshotPendingOnly
        #expect(cappedFlags.count == ControlSession.agentMaxSnapshotPages)
        #expect(cappedFlags.allSatisfy { $0 })

        // No cursor was adopted: the next refresh snapshots again rather
        // than reading changes after the last page it saw.
        await capped.session.refreshAgent(force: true)
        let types = await capped.gateway.agentRequestTypes()
        #expect(!(types.contains(.changesFetch)))
        cappedFlags = await capped.gateway.agentSnapshotPendingOnly
        #expect(cappedFlags.count == 2 * ControlSession.agentMaxSnapshotPages)

        // Once the pending work fits, the cut is adopted in full.
        await capped.gateway.setAgentSnapshotPageSize(nil)
        await capped.session.refreshAgent(force: true)
        #expect(capped.session.pendingAgentInputs.count == many.count)
        #expect(capped.session.agentAvailability == .available)
    }

    // MARK: Drafts

    /// Dictation produces a draft only: nothing is signable until the exact
    /// text is confirmed, and a later edit withdraws the confirmation.
    @Test
    func testDictatedTextNeedsAFinalConfirmation() throws {
        let record = try WatchTestFixtures.makeInput(createdAt: now, questions: [
            try InputQuestion(id: "note", prompt: "Anything else?", kind: .text(maximumBytes: 120, hint: nil), required: true)
        ], presentAt: now)
        let question = try #require(record.spec.questions.first)
        var draft = WatchAnswerDraft()
        draft.setDraftText("run the focused suite", for: question)
        #expect(draft.answers.byteCount(for: question) == 21)
        #expect((draft.confirmedResponse(for: record.spec)) == nil, "a dictation result is a draft")

        let proposed = try #require(draft.proposedResponse(for: record.spec))
        #expect(proposed == .answer([.text(questionID: "note", text: "run the focused suite")]))
        #expect(!(draft.confirm(.answer([.text(questionID: "note", text: "something else")]), for: record.spec)), "only the exact text on screen can be confirmed")
        #expect(draft.confirm(proposed, for: record.spec))
        #expect(draft.confirmedResponse(for: record.spec) == proposed)

        draft.setDraftText("run everything", for: question)
        #expect((draft.confirmedResponse(for: record.spec)) == nil, "an edit after confirmation withdraws it")
    }

    @Test
    func testAnUnconfirmedDraftIsNeverSent() async throws {
        let rig = try await rig()
        let record = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        await rig.gateway.setAgentInputs([record])
        await rig.session.start()
        var draft = WatchAnswerDraft()
        draft.select("all", in: try #require(record.spec.questions.first))
        await rig.session.respond(with: draft, to: record)
        let submitted = await rig.gateway.agentSubmitted
        #expect(submitted.isEmpty)
        let types = await rig.gateway.agentRequestTypes()
        #expect(!(types.contains(.reviewChallenge)), "nothing is even challenged before confirmation")
    }

    @Test
    func testMultiChoiceKeepsCommittedOrderAndItsMaximum() throws {
        let record = try WatchTestFixtures.makeInput(createdAt: now, questions: [
            try InputQuestion(id: "q", prompt: "Which?", kind: .multiChoice(choices: try ["a", "b", "c", "d"].map(choice), minimum: 1, maximum: 2), required: true)
        ], presentAt: now)
        let question = try #require(record.spec.questions.first)
        var draft = WatchAnswerDraft()
        draft.select("c", in: question)
        draft.select("a", in: question)
        draft.select("d", in: question)
        #expect(draft.answers.selectionCount(for: question) == 2, "the maximum is not exceeded")
        #expect(draft.proposedResponse(for: record.spec) == .answer([.multiChoice(questionID: "q", choiceIDs: ["a", "c"])]))
    }

    // MARK: Signing and transport

    /// The answer is signed by the Watch's key under its own device ID and
    /// carried unchanged; the iPhone cannot substitute its own.
    @Test
    func testAnswerIsSignedByTheWatchKey() async throws {
        let rig = try await rig()
        let record = try WatchTestFixtures.makeInput(createdAt: now, presentAt: now)
        await rig.gateway.setAgentInputs([record])
        await rig.session.start()
        #expect(rig.session.agentAvailability == .available)

        var draft = WatchAnswerDraft()
        draft.select("focused", in: try #require(record.spec.questions.first))
        let proposed = try #require(draft.proposedResponse(for: record.spec))
        #expect(draft.confirm(proposed, for: record.spec))
        await rig.session.respond(with: draft, to: record)

        let submitted = await rig.gateway.agentSubmitted
        let jws = try #require(submitted.first)
        let reviewer = try #require(rig.reviewers.load())
        let key = try #require(try rig.keys.loadSigningKey())
        let verified = try ControlJWS.verifyAgent(compactSerialization: jws) { id in
            id == reviewer.watchDeviceID ? key.publicJWK : nil
        }
        #expect(verified.deviceID == reviewer.watchDeviceID)
        guard case .inputRespond(let command) = verified.command else { Issue.record("\(verified.command)")
return }
        #expect(command.envelope.audience == reviewer.audience)
        #expect(command.requestID == record.spec.requestID)
        #expect(command.response == .answer([.singleChoice(questionID: "test_scope", choiceID: "focused")]))
        guard case .responseRecorded = try #require(rig.session.agentSubmissions[record.spec.requestID]) else {
            Issue.record("recorded is shown as recorded, not accepted")
return
        }
        let types = await rig.gateway.agentRequestTypes()
        // Refetched before signing, then a fresh challenge, then the command.
        let order = types.filter { [.inputFetch, .reviewChallenge, .commandSubmit].contains($0) }
        #expect(order == [.inputFetch, .reviewChallenge, .commandSubmit])
    }

    /// An iPhone without the extension makes agent questions unsupported;
    /// it is not an error the Watch keeps reporting.
    @Test
    func testAnOldIPhoneMakesAgentQuestionsUnsupported() async throws {
        let rig = try await rig()
        await rig.gateway.setAgentSupported(false)
        await rig.session.start()
        #expect(rig.session.phase == .ready)
        #expect(rig.session.agentAvailability == .unsupported)
        #expect((rig.session.gatewayProblem) == nil)
        #expect(rig.session.pendingAgentInputs.isEmpty)
    }

    @Test
    func testWithoutTheGrantAgentQuestionsAreNotEnabled() async throws {
        let rig = try await rig(grants: DeviceGrant.watchReviewerDefault)
        await rig.gateway.setAgentNotAuthorized(true)
        await rig.session.start()
        #expect(rig.session.agentAvailability == .notEnabled)
        #expect((rig.session.gatewayProblem) == nil)
        #expect((rig.session.lastError) == nil)
    }
}
