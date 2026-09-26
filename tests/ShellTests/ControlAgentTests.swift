//
//  ControlAgentTests.swift
//  ShellTests
//
//  The phone's agent view model: discovery that hides the section on a Mac
//  without the extension, opt-in grants, snapshot-then-changes, the
//  approval-then-input lookup for notification hints, and the exact typed
//  answer (docs/specs/agent-relay.md sections 6.3, 11, 12.1, and 14).
//

import Foundation
import Testing
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@testable import Shell

@MainActor
@Suite
final class ControlAgentTests {
    private let now = ControlTimestamp(Date(timeIntervalSince1970: 1_790_000_000))

    // MARK: Discovery and grants

    /// A Mac without `shell-agent/1` answers `not_found`: the section is
    /// hidden and the probe is not repeated on every refresh.
    @Test
    func testNotFoundCapabilitiesHidesTheSectionWithoutAnErrorLoop() async throws {
        let service = StubAgentService(now: now)
        service.capabilitiesError = ControlError(code: .notFound, message: "no such endpoint")
        let clock = TestClock(now.date)
        let center = ControlAgentCenter(now: { clock.date })

        await center.refresh(using: service, grants: DeviceGrant.agentPhone)
        #expect(center.availability == .unsupported)
        #expect((center.problem) == nil, "an older Mac is not an error")
        #expect(!(center.isAvailable))

        clock.advance(60)
        await center.refresh(using: service, grants: DeviceGrant.agentPhone)
        #expect(service.calls == ["capabilities"], "not asked again before the reprobe interval")
    }

    /// Discovery needs no grant; without the agent read grant nothing else is
    /// fetched and the section says so.
    @Test
    func testWithoutTheGrantAgentQuestionsAreNotEnabled() async throws {
        let service = StubAgentService(now: now)
        let center = ControlAgentCenter(now: { [now] in now.date })
        await center.refresh(using: service, grants: DeviceGrant.watchDefault)
        #expect(center.availability == .notEnabled)
        #expect(service.calls == ["capabilities"])
        #expect(!(center.canRespond))
    }

    /// One snapshot, then only changes after its cursor, and never faster
    /// than the poll floor.
    @Test
    func testSnapshotThenChangesNoFasterThanThePollFloor() async throws {
        let record = try makeInput()
        let service = StubAgentService(now: now)
        service.inputs = [record]
        let clock = TestClock(now.date)
        let center = ControlAgentCenter(now: { clock.date })

        await center.refresh(using: service, grants: DeviceGrant.agentPhone)
        #expect(center.isAvailable)
        #expect(center.inbox.pendingInputs.map(\.spec.requestID) == [record.spec.requestID])

        clock.advance(1)
        await center.refresh(using: service, grants: DeviceGrant.agentPhone)
        #expect(service.calls == ["capabilities", "snapshot"], "throttled to the poll floor")

        var answered = record
        answered.projection.resolution = .answered
        answered.projection.dispatch = .nativeResponseWritten
        answered.projection.stateVersion = 3
        service.events = [AgentChangeEvent(
            eventID: .random(), sequence: LogSequence(2), type: .deliveryUpdated, resourceID: record.spec.requestID,
            resourceVersion: 3, serverTime: now, projection: answered.json
        )]
        clock.advance(ControlAgentCenter.minimumInterval)
        await center.refresh(using: service, grants: DeviceGrant.agentPhone)
        #expect(service.calls == ["capabilities", "snapshot", "changes"])
        #expect(center.inbox.pendingInputs.isEmpty)
        let resolved = try #require(center.inbox.resolvedInputs.first)
        #expect(ControlAgentText.resolution(resolved.projection) == "Delivered to agent")
    }

    /// More history than one refresh can page through still loads what can
    /// be answered, with a note, instead of failing every refresh.
    @Test
    func testSnapshotOverThePageCapFallsBackToPendingOnly() async throws {
        let pending = try makeInput()
        var resolved = try makeInput()
        resolved.projection.resolution = .answered
        let service = StubAgentService(now: now)
        service.inputs = [pending, resolved]
        service.unboundedHistory = true
        let center = ControlAgentCenter(now: { [now] in now.date })

        await center.refresh(using: service, grants: DeviceGrant.agentPhone)
        #expect((center.problem) == nil, "a capped snapshot is not a refresh failure")
        #expect(center.inbox.omitsOlderOutcomes)
        #expect(center.inbox.pendingInputs.map(\.spec.requestID) == [pending.spec.requestID])
        #expect(center.inbox.resolvedInputs.isEmpty, "the partial full cut is never adopted")
        #expect(center.inbox.cursor == ChangeCursor("ac1.1.t"))
        #expect(service.calls.filter { $0 == "snapshot" }.count == ControlAgentCenter.maxSnapshotPages)
        #expect(service.calls.last == "snapshot-pending")

        await center.refresh(using: service, grants: DeviceGrant.agentPhone, force: true)
        #expect(service.calls.last == "changes", "the pending-only cursor is followed like any other")
        #expect(center.inbox.omitsOlderOutcomes, "older outcomes stay omitted until a full snapshot")
    }

    // MARK: Notification lookup

    /// Inputs reuse the approval hint: an approval `not_found` falls back to
    /// the input endpoint.
    @Test
    func testApprovalNotFoundFallsBackToInputLookup() async throws {
        let record = try makeInput()
        let found = try await ControlRequestLookup.resolve(
            approval: { throw ControlError(code: .notFound, message: "no such request") },
            input: { record }
        )
        #expect(found == .input(record))
    }

    @Test
    func testLookupReportsTheApprovalErrorWhenNeitherExists() async throws {
        do {
            _ = try await ControlRequestLookup.resolve(
                approval: { throw ControlError(code: .notFound, message: "no such request") },
                input: { throw ControlError(code: .notAuthorized, message: "missing grant agent.inputs.read") }
            )
            Issue.record("expected not found")
        } catch let error as ControlError {
            #expect(error.code == .notFound)
        }
        // Without the read grant, the input endpoint is not even tried.
        do {
            _ = try await ControlRequestLookup.resolve(
                approval: { throw ControlError(code: .notFound, message: "no such request") },
                input: nil
            )
            Issue.record("expected not found")
        } catch let error as ControlError {
            #expect(error.code == .notFound)
        }
    }

    // MARK: Answers and rendering

    @Test
    func testTheAnswerIsExactAndCanonical() throws {
        let spec = try makeInput(questions: [
            try InputQuestion(id: "zeta", prompt: "Note", kind: .text(maximumBytes: 8, hint: nil), required: false),
            try InputQuestion(id: "alpha", prompt: "Which?", kind: .multiChoice(choices: [
                try InputChoice(id: "a", label: "A"), try InputChoice(id: "b", label: "B"), try InputChoice(id: "c", label: "C")
            ], minimum: 1, maximum: 2), required: true)
        ]).spec
        let text = try #require(spec.question("zeta"))
        let multi = try #require(spec.question("alpha"))
        var draft = InputAnswerDraft()
        #expect(throws: (any Error).self, "a required answer is missing") { try draft.response(for: spec) }
        draft.select("c", in: multi)
        draft.select("a", in: multi)
        draft.select("b", in: multi)
        #expect(draft.selectionCount(for: multi) == 2, "the committed maximum holds")
        draft.setText("né", for: text)
        #expect(draft.byteCount(for: text) == 3, "limits are UTF-8 bytes")
        #expect(try draft.response(for: spec) == .answer([
            .multiChoice(questionID: "alpha", choiceIDs: ["a", "c"]),
            .text(questionID: "zeta", text: "né")
        ]))
        draft.setText("123456789", for: text)
        #expect(throws: (any Error).self, "over-limit text is refused before signing") { try draft.response(for: spec) }
    }

    /// The exact command is shown with control and bidi characters escaped
    /// visibly, split only at real line breaks.
    @Test
    func testShellOperationRendersExactlyAndVisibly() throws {
        let operation = try AgentToolOperation(
            provider: "claude_code", providerBuild: "tested", adapterBuild: "adapter",
            agentSessionID: .random(), nativeWaitID: .random(), kind: .shell, toolName: "Bash",
            cwd: "/Users/example/src", reason: "check status",
            shellRequest: try AgentShellRequest(representation: .commandString, command: "git status\necho \u{202E}txt.exe"),
            unavailable: ["shell_identity"],
            nativeRequestSHA256: String(repeating: "a", count: 64), contextSHA256: String(repeating: "b", count: 64)
        )
        let display = AgentOperationDisplay(operation)
        #expect(display.commandLines.count == 2)
        #expect(display.commandText == "git status\necho <U+202E>txt.exe")
        #expect(display.didEscape)
        #expect(!(display.isTruncated))
        #expect(display.unavailable == ["shell_identity"])
    }

    // MARK: Fixtures

    private func makeInput(questions: [InputQuestion]? = nil) throws -> InputRecord {
        let hex = String(repeating: "d", count: 64)
        let spec = try InputSpec(
            requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
            createdAt: now, expiresAt: now.adding(300), summary: "Choose the test scope",
            source: try InputSource(
                provider: "codex", providerBuild: "tested", adapterBuild: "adapter",
                nativeRequestSHA256: hex, contextSHA256: hex, answerMappingSHA256: hex,
                agentSessionID: .random(), nativeWaitID: .random()
            ),
            questions: try questions ?? [InputQuestion(
                id: "test_scope", prompt: "Which tests should run next?",
                kind: .singleChoice(choices: [try InputChoice(id: "focused", label: "Changed modules only")]),
                required: true
            )],
            allowedResponses: [.answer, .decline],
            minimumReview: .watch
        )
        return try InputRecord(spec: spec, projection: InputProjection(presence: SourcePresence(lastSeenAt: now, isWaiting: true)))
    }
}

/// A Mac's agent endpoints, scripted.
private nonisolated final class StubAgentService: ControlAgentService, @unchecked Sendable {
    private let lock = NSLock()
    private let now: ControlTimestamp
    private var log: [String] = []
    var capabilitiesError: (any Error)?
    var inputs: [InputRecord] = []
    var events: [AgentChangeEvent] = []
    /// When set, a full snapshot never ends within the page cap; a
    /// pending-only one lists the pending inputs in one page.
    var unboundedHistory = false

    init(now: ControlTimestamp) { self.now = now }

    var calls: [String] { lock.withLock { log } }

    func agentCapabilities() async throws -> AgentCapabilities {
        try lock.withLock {
            log.append("capabilities")
            if let capabilitiesError { throw capabilitiesError }
            return AgentCapabilities(serverTime: now)
        }
    }

    func agentSnapshot(pageToken: String?, limit: Int, pendingOnly: Bool) async throws -> AgentSnapshotPage {
        lock.withLock {
            log.append(pendingOnly ? "snapshot-pending" : "snapshot")
            let listed = pendingOnly ? inputs.filter { $0.projection.resolution == .pending } : inputs
            let page = (pageToken.flatMap { Int($0.dropFirst()) } ?? 0) + 1
            return AgentSnapshotPage(
                sessions: [], inputs: listed.map { .supported($0) }, approvals: [], snapshotToken: "a1.1.t",
                nextPageToken: unboundedHistory && !pendingOnly ? "p\(page)" : nil, cursor: ChangeCursor("ac1.1.t"), serverTime: now
            )
        }
    }

    func agentChanges(after cursor: ChangeCursor, limit: Int) async throws -> AgentChangePage {
        lock.withLock {
            log.append("changes")
            defer { events = [] }
            return AgentChangePage(events: events, cursor: ChangeCursor("ac1.2.t"), serverTime: now)
        }
    }
}

private nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var date: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
