import Foundation
import Testing
import ShellControlProtocol
import ShellControlClient

@testable import ShellWatch

/// The Watch's small protected cache (docs/specs/control-protocol.md section 11.5).
@Suite
final class ProtectedCacheTests {
    private let now = ControlTimestamp(Date(timeIntervalSince1970: 1_788_000_000))

    private func makeCache() throws -> (ProtectedInboxCache, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-watch-cache-\(UUID().uuidString)")
        return (try ProtectedInboxCache(directory: directory), directory)
    }

    @Test
    func testCacheRoundTripsTheProjectionAndItsFreshness() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        var state = InboxState()
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        state.approvals[record.spec.requestID] = record
        state.notifications = [:]
        state.cursor = ChangeCursor("c1.7.tag")
        state.lastRefreshedAt = now
        state.seenEventIDs = [.random()]
        try cache.commit(state)

        let loaded = try #require(try cache.load())
        #expect(loaded.approvals[record.spec.requestID]?.requestHash == record.requestHash)
        #expect(loaded.cursor?.rawValue == "c1.7.tag")
        #expect(loaded.lastRefreshedAt == now)
        #expect(loaded.seenEventIDs == state.seenEventIDs)
    }

    /// A cached record whose digest no longer verifies is dropped rather than
    /// shown: stale display is fine, unverifiable display is not.
    @Test
    func testATamperedCachedRecordIsDropped() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        var state = InboxState()
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        state.approvals[record.spec.requestID] = record
        try cache.commit(state)

        let url = directory.appendingPathComponent("control-inbox.json")
        let encoded = try JSONValue.parse(try Data(contentsOf: url), limits: JSONLimits(maxDocumentBytes: 1 << 20))
        var members = try #require(encoded.objectValue)
        var approvals = try #require(members["approvals"]?.arrayValue)
        var entry = try #require(approvals[0].objectValue)
        var spec = try #require(entry["spec"]?.objectValue)
        var operation = try #require(spec["operation"]?.objectValue)
        // Swap the argument vector while leaving the advertised digest alone.
        operation["argv"] = JSONValue(strings: ["/usr/bin/git", "push", "--force"])
        spec["operation"] = .object(operation)
        entry["spec"] = .object(spec)
        approvals[0] = .object(entry)
        members["approvals"] = .array(approvals)
        try JSONCanonicalization.canonicalize(.object(members)).write(to: url)

        let loaded = try #require(try cache.load())
        #expect(loaded.approvals.isEmpty)
    }

    @Test
    func testClearRemovesTheCacheFile() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try cache.commit(InboxState())
        #expect((try cache.load()) != nil)
        try cache.clear()
        #expect((try cache.load()) == nil)
    }

    /// THE REGRESSION: the cache parsed with a 4096-element limit while the
    /// reconciler only trims seen event IDs past 5000, so a valid cache with
    /// 4097–5000 IDs failed to load and the Watch started empty offline.
    @Test
    func testACacheWithUpToFiveThousandSeenEventIDsStillLoads() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        var state = InboxState()
        state.approvals[record.spec.requestID] = record
        state.cursor = ChangeCursor("c1.9.tag")
        state.seenEventIDs = Set((0..<5000).map { _ in ControlID.random() })
        // Written the way an older build did: unbounded.
        let url = directory.appendingPathComponent("control-inbox.json")
        try JSONCanonicalization.canonicalize(ProtectedInboxCache.encode(state)).write(to: url)

        let loaded = try #require(try cache.load())
        #expect((loaded.approvals[record.spec.requestID]) != nil)
        #expect(loaded.cursor?.rawValue == "c1.9.tag")
        #expect(loaded.seenEventIDs.count == InboxBounds.maxSeenEventIDs, "trimmed to the cap on load")
    }

    @Test
    func testACommitIsBoundedAndReloads() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = InboxState()
        state.seenEventIDs = Set((0..<(InboxBounds.maxSeenEventIDs + 500)).map { _ in ControlID.random() })
        var pendingIDs: Set<ControlID> = []
        for index in 0..<(InboxBounds.maxApprovals + 50) {
            let resolution: Resolution = index < 10 ? .pending : .approved
            let record = try WatchTestFixtures.makeRecord(createdAt: now, resolution: resolution, presentAt: now)
            state.approvals[record.spec.requestID] = record
            if resolution == .pending { pendingIDs.insert(record.spec.requestID) }
        }
        try cache.commit(state)

        let loaded = try #require(try cache.load())
        #expect(loaded.seenEventIDs.count == InboxBounds.maxSeenEventIDs)
        #expect(loaded.approvals.count == InboxBounds.maxApprovals)
        #expect(pendingIDs.isSubset(of: Set(loaded.approvals.keys)), "every pending request survives trimming")
    }

    /// Unreadable dedup bookkeeping costs the cursor (forcing a fresh
    /// snapshot), not the cached records.
    @Test
    func testUnreadableSeenIDsKeepTheRecords() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        var state = InboxState()
        state.approvals[record.spec.requestID] = record
        state.cursor = ChangeCursor("c1.3.tag")
        guard case .object(var members) = ProtectedInboxCache.encode(state) else { Issue.record("expected object")
return }
        members["seen_event_ids"] = .string("not an array")
        let url = directory.appendingPathComponent("control-inbox.json")
        try JSONCanonicalization.canonicalize(.object(members)).write(to: url)

        let loaded = try #require(try cache.load())
        #expect((loaded.approvals[record.spec.requestID]) != nil)
        #expect((loaded.cursor) == nil)
    }

    /// Unresolved command ids are persisted apart from the projection, so a
    /// snapshot refresh cannot erase an ambiguous submitted decision.
    @Test
    func testCommandJournalPersistsSeparately() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-watch-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileCommandJournalStore(directory: directory)
        let command = PendingCommand(
            commandID: .random(),
            signedCommand: "header.payload.signature",
            type: .approvalDecide,
            targetID: .random(),
            notAfter: now.adding(60),
            status: .outcomeUnknown
        )
        try store.save([command])

        let reloaded = try FileCommandJournalStore(directory: directory).load()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.commandID == command.commandID)
        #expect(reloaded.first?.status == .outcomeUnknown)
        #expect(reloaded.first?.signedCommand == "header.payload.signature")
    }
}
