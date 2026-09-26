import Foundation
import Testing
@testable import ShellControlProtocol
@testable import ShellControlClient

@Suite
final class StateAndClientTests {
    @Test
    func testResolutionIsImmutableOnceTerminal() throws {
        #expect(Resolution.pending.canTransition(to: .approved))
        #expect(!(Resolution.approved.canTransition(to: .rejected)))
        #expect(!(Resolution.rejected.canTransition(to: .pending)))
    }

    @Test
    func testDispatchTransitions() throws {
        #expect(Dispatch.none.canTransition(to: .awaitingOrigin))
        #expect(Dispatch.awaitingOrigin.canTransition(to: .claimed))
        #expect(Dispatch.awaitingOrigin.canTransition(to: .applied))
        #expect(Dispatch.claimed.canTransition(to: .unknown))
        // Unknown reconciles only with positive evidence, and never to pending.
        #expect(Dispatch.unknown.canTransition(to: .applied))
        #expect(!(Dispatch.applied.canTransition(to: .claimed)))
        #expect(!(Dispatch.unknown.canTransition(to: .awaitingOrigin)))
    }

    @Test
    func testPresenceGoesStaleAfterFortyFiveSeconds() throws {
        let seen = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:00:00Z"))
        let presence = SourcePresence(lastSeenAt: seen, isWaiting: true)
        #expect(presence.isFresh(at: seen.adding(44)))
        #expect(!(presence.isFresh(at: seen.adding(46))))
        #expect(!(SourcePresence(lastSeenAt: seen, isWaiting: false).isFresh(at: seen)))
    }

    @Test
    func testErrorCodeMapping() throws {
        #expect(ControlErrorCode.alreadyClaimed.httpStatus == 409)
        #expect(ControlErrorCode.originUnavailable.httpStatus == 423)
        #expect(ControlErrorCode.hashMismatch.clientAction == .requireFreshReview)
        #expect(ControlErrorCode.unsupportedOperation.clientAction == .handoff)
        #expect(!(ControlErrorCode.alreadyResolved.isRetryable))
        #expect(ControlErrorCode.temporarilyUnavailable.isRetryable)
    }

    @Test
    func testSanitizerEscapesBidiAndControlCharacters() throws {
        let result = DisplaySanitizer.sanitize("rm\u{202E}txt.exe\u{07}")
        #expect(result.didEscape)
        #expect(result.text.contains("<U+202E>"))
        #expect(!(result.isTruncated))
        let long = DisplaySanitizer.sanitize(String(repeating: "a", count: 600), maxScalars: 100)
        #expect(long.isTruncated)
    }

    /// A character that renders as nothing hides the difference between what
    /// is shown and what would run just as effectively as a bidi override.
    @Test
    func testSanitizerEscapesInvisibleAndLineBreakingScalars() throws {
        for scalar in ["\u{200B}", "\u{200D}", "\u{FEFF}", "\u{00AD}", "\u{2028}", "\u{2029}", "\u{E000}"] {
            let result = DisplaySanitizer.sanitize("rm\(scalar)-rf")
            #expect(result.didEscape, "did not escape \(scalar.unicodeScalars.first!.value)")
            #expect(!(result.text.unicodeScalars.contains(scalar.unicodeScalars.first!)))
        }
        // Ordinary text is left exactly as it is.
        let plain = DisplaySanitizer.sanitize("rm -rf /tmp/naïve — done")
        #expect(!(plain.didEscape))
        #expect(plain.text == "rm -rf /tmp/naïve — done")
    }

    /// A `sendMessageData` whose reply handler never fires — a `WCSession`
    /// torn down mid-flight — used to park the review forever: there is no
    /// second transport, and the continuation cannot be cancelled out of.
    @Test
    func testAGatewayRoundTripThatNeverAnswersTimesOut() async throws {
        let client = WatchGatewayClient(
            link: HangingGatewayLink(),
            watchDeviceID: .random(),
            timeout: .milliseconds(50)
        )
        do {
            _ = try await client.enrollmentStatus()
            Issue.record("a link that never answers must not return a result")
        } catch let error as WatchGatewayError {
            #expect(error == .iPhoneUnreachable)
        }
    }

    @Test
    func testIPCFramingRoundTrip() throws {
        var buffer = try IPCFraming.frame(JSONValue.object(["a": 1]))
        buffer.append(try IPCFraming.frame(JSONValue.object(["b": 2])))
        #expect((try IPCFraming.decodeFrame(from: &buffer)) == .object(["a": 1]))
        #expect((try IPCFraming.decodeFrame(from: &buffer)) == .object(["b": 2]))
        #expect((try IPCFraming.decodeFrame(from: &buffer)) == nil)
    }

    @Test
    func testPartialFrameYieldsNilRatherThanGarbage() throws {
        var buffer = try IPCFraming.frame(JSONValue.object(["a": 1]))
        buffer.removeLast()
        #expect((try IPCFraming.decodeFrame(from: &buffer)) == nil)
    }

    @Test
    func testExitCodeConvention() throws {
        #expect(ApprovalWaitOutcome.rejected(decisionID: .random()).exitCode.rawValue == 10)
        #expect(ApprovalWaitOutcome.expired.exitCode.rawValue == 11)
        #expect(ApprovalWaitOutcome.cancelled.exitCode.rawValue == 12)
        #expect(ApprovalWaitOutcome.unavailable(reason: "x").exitCode.rawValue == 13)
    }

    @Test
    func testPushPayloadStaysUnderTheAPNsLimit() throws {
        let payload = ApprovalPushPayload(eventID: .random(), requestID: .random())
        let encoded = try payload.encoded()
        #expect(encoded.count < 4096)
        // The payload carries identifiers only: no credential, key, or command.
        let value = try JSONValue.parse(encoded)
        #expect((value["token"]) == nil)
        #expect((value["command"]) == nil)
        #expect(value["aps"]?["category"]?.stringValue == "SHELL_APPROVAL_V1")
        #expect(payload.collapseID == "approval.\(payload.requestID.rawValue)")
    }

    @Test
    func testAPNsExpirationNeverOutlivesTheDeadline() throws {
        let deadline = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:05:00Z"))
        let headers = APNsRequestHeaders(topic: "dev.chr33s.shell.watchkitapp", expiresAt: deadline, collapseID: "approval.x")
        #expect(headers.headerFields["apns-expiration"] == String(Int64(deadline.date.timeIntervalSince1970)))
        #expect(headers.headerFields["apns-push-type"] == "alert")
        #expect(headers.headerFields["apns-priority"] == "10")
    }

    // MARK: Reconciliation

    private func makeRecord(requestID: ControlID, stateVersion: Int64, resolution: Resolution = .pending) throws -> ApprovalRecord {
        let created = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:00:00Z"))
        let spec = try ApprovalSpec(
            requestID: requestID,
            originID: .random(),
            jobID: .random(),
            runID: .random(),
            createdAt: created,
            expiresAt: created.adding(300),
            summary: "Push feature branch",
            operation: .exec(try ExecOperation(argv: ["/usr/bin/git", "push"], cwd: "/srv", contextSHA256: String(repeating: "a", count: 64))),
            minimumReview: .watch,
            requiredFeatures: [ExecOperation.schema]
        )
        return try ApprovalRecord(spec: spec, projection: ApprovalProjection(stateVersion: stateVersion, resolution: resolution))
    }

    @Test
    func testSnapshotAppliesAtomicallyAndDeltasDeduplicate() throws {
        let requestID = ControlID.random()
        let record = try makeRecord(requestID: requestID, stateVersion: 1)
        let serverTime = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:00:10Z"))
        var accumulator = InboxReconciler.SnapshotAccumulator(firstPage: SnapshotPage(
            approvals: [record],
            notifications: [],
            snapshotToken: "s1",
            nextPageToken: nil,
            cursor: ChangeCursor("c1.5.tag"),
            serverTime: serverTime
        ))
        var reconciler = InboxReconciler()
        try reconciler.applyCompletedSnapshot(accumulator, at: serverTime)
        #expect(reconciler.state.pendingApprovals.count == 1)
        #expect(reconciler.state.lastRefreshedAt == serverTime)

        let resolved = try makeRecord(requestID: requestID, stateVersion: 2, resolution: .approved)
        let event = ChangeEvent(
            eventID: .random(),
            sequence: LogSequence(6),
            type: .approvalResolved,
            resourceID: requestID,
            resourceVersion: 2,
            serverTime: serverTime,
            projection: resolved.json
        )
        let page = ChangePage(events: [event, event], cursor: ChangeCursor("c1.6.tag"), serverTime: serverTime)
        // At-least-once delivery: the duplicate applies once.
        #expect(reconciler.apply(page) == 1)
        #expect(reconciler.state.approvals[requestID]?.projection.resolution == .approved)
        #expect(reconciler.state.cursor?.rawValue == "c1.6.tag")

        // A stale redelivery cannot roll the record backwards.
        let stale = ChangeEvent(
            eventID: .random(),
            sequence: LogSequence(7),
            type: .approvalResolved,
            resourceID: requestID,
            resourceVersion: 1,
            serverTime: serverTime,
            projection: record.json
        )
        _ = reconciler.apply(ChangePage(events: [stale], cursor: ChangeCursor("c1.7.tag"), serverTime: serverTime))
        #expect(reconciler.state.approvals[requestID]?.projection.resolution == .approved)
        _ = accumulator
    }

    @Test
    func testIncompleteSnapshotIsNotApplied() throws {
        let serverTime = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:00:10Z"))
        let accumulator = InboxReconciler.SnapshotAccumulator(firstPage: SnapshotPage(
            approvals: [],
            notifications: [],
            snapshotToken: "s1",
            nextPageToken: "1@s1",
            cursor: ChangeCursor("c1.5.tag"),
            serverTime: serverTime
        ))
        var reconciler = InboxReconciler()
        #expect(throws: (any Error).self) { try reconciler.applyCompletedSnapshot(accumulator, at: serverTime) }
    }

    @Test
    func testJournalKeepsAmbiguousCommandsAcrossSnapshots() async throws {
        let notAfter = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:01:00Z"))
        let journal = CommandJournal(now: { notAfter.date })
        let commandID = ControlID.random()
        try await journal.record(PendingCommand(
            commandID: commandID,
            signedCommand: "a.b.c",
            type: .approvalDecide,
            targetID: .random(),
            notAfter: notAfter
        ))
        try await journal.update(commandID, status: .outcomeUnknown)
        let pending = await journal.pending
        #expect(pending.first?.status == .outcomeUnknown)
        // The identical command may be retried only while its lifetime holds.
        #expect(pending[0].isRetryable(at: notAfter.adding(-5)))
        #expect(!(pending[0].isRetryable(at: notAfter.adding(5))))
    }

    /// Commands whose outcome is never learned — the device stayed offline,
    /// the app was killed — used to accumulate forever, until the persisted
    /// journal no longer parsed and every ambiguous decision was lost at once.
    @Test
    func testJournalDropsCommandsPastTheRetentionWindow() async throws {
        let notAfter = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:01:00Z"))
        let store = InMemoryCommandJournal()
        let live = CommandJournal(store: store, now: { notAfter.date })
        try await live.record(PendingCommand(
            commandID: .random(), signedCommand: "a.b.c", type: .approvalDecide,
            targetID: .random(), notAfter: notAfter
        ))
        var count = await live.pending.count
        #expect(count == 1)

        // Still held just inside the window, gone once it closes.
        let inside = CommandJournal(store: store, now: { notAfter.date.addingTimeInterval(CommandJournal.retention - 60) })
        count = await inside.pending.count
        #expect(count == 1)
        let outside = CommandJournal(store: store, now: { notAfter.date.addingTimeInterval(CommandJournal.retention + 60) })
        count = await outside.pending.count
        #expect(count == 0)
        #expect((try store.load().count) == 0, "the prune is persisted, not just in memory")
    }

    @Test
    func testJournalIsCappedAtItsMaximumEntries() async throws {
        let base = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:01:00Z"))
        let journal = CommandJournal(now: { base.date })
        for offset in 0..<(CommandJournal.maximumEntries + 25) {
            try await journal.record(PendingCommand(
                commandID: .random(), signedCommand: "a.b.c", type: .approvalDecide,
                targetID: .random(), notAfter: base.adding(TimeInterval(offset))
            ))
        }
        let pending = await journal.pending
        #expect(pending.count == CommandJournal.maximumEntries)
        // The newest deadlines survive; the oldest are the ones dropped.
        #expect(pending.last?.notAfter == base.adding(TimeInterval(CommandJournal.maximumEntries + 24)))
    }

    /// A store that cannot be read yet — a protected file before first
    /// unlock — must not be treated as empty: a save would overwrite it.
    @Test
    func testUnreadableJournalRefusesWritesUntilItCanBeRead() async throws {
        final class LockedStore: CommandJournalStore, @unchecked Sendable {
            let lock = NSLock()
            var locked = true
            var saved: [PendingCommand]
            var saves = 0
            init(_ saved: [PendingCommand]) { self.saved = saved }
            func load() throws -> [PendingCommand] {
                try lock.withLock {
                    if locked { throw CocoaError(.fileReadNoPermission) }
                    return saved
                }
            }
            func save(_ commands: [PendingCommand]) throws {
                lock.withLock { saved = commands; saves += 1 }
            }
        }
        let notAfter = try #require(ControlTimestamp(rfc3339: "2026-09-07T09:01:00Z"))
        let earlier = PendingCommand(
            commandID: .random(), signedCommand: "a.b.c", type: .approvalDecide,
            targetID: .random(), notAfter: notAfter, status: .outcomeUnknown
        )
        let store = LockedStore([earlier])
        let journal = CommandJournal(store: store, now: { notAfter.date })

        var available = await journal.isAvailable
        #expect(!(available))
        let unreadable = await journal.pending
        #expect(unreadable == [])
        do {
            try await journal.record(PendingCommand(
                commandID: .random(), signedCommand: "d.e.f", type: .approvalDecide,
                targetID: .random(), notAfter: notAfter
            ))
            Issue.record("recorded into an unread journal")
        } catch is CommandJournalUnavailable {}
        #expect(store.saves == 0, "nothing overwrote the unread entries")

        store.lock.withLock { store.locked = false }
        available = await journal.isAvailable
        #expect(available)
        let pending = await journal.pending
        #expect(pending == [earlier])
    }

    @Test
    func testFileJournalSetsAsideBytesThatDoNotParse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileCommandJournalStore(directory: directory, protection: [])
        let url = directory.appendingPathComponent("control-commands.json")
        try Data("[{\"command_id\":".utf8).write(to: url)

        #expect((try store.load()) == [])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!(names.contains("control-commands.json")))
        #expect(names.contains { $0.hasPrefix("control-commands.json.corrupt-") }, "the bytes are kept")
    }
}

/// Reachable, but its reply never arrives.
private struct HangingGatewayLink: WatchGatewayLink {
    func isReachable() async -> Bool { true }
    func send(_ data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (_: CheckedContinuation<Data, any Error>) in }
    }
}
