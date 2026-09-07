import XCTest
import ShellControlProtocol
import ShellControlClient

@testable import ShellWatch

/// The Watch's small protected cache (spec.watch.md section 7).
final class ProtectedCacheTests: XCTestCase {
    private let now = ControlTimestamp(Date(timeIntervalSince1970: 1_788_000_000))

    private func makeCache() throws -> (ProtectedInboxCache, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-watch-cache-\(UUID().uuidString)")
        return (try ProtectedInboxCache(directory: directory), directory)
    }

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

        let loaded = try XCTUnwrap(try cache.load())
        XCTAssertEqual(loaded.approvals[record.spec.requestID]?.requestHash, record.requestHash)
        XCTAssertEqual(loaded.cursor?.rawValue, "c1.7.tag")
        XCTAssertEqual(loaded.lastRefreshedAt, now)
        XCTAssertEqual(loaded.seenEventIDs, state.seenEventIDs)
    }

    /// A cached record whose digest no longer verifies is dropped rather than
    /// shown: stale display is fine, unverifiable display is not.
    func testATamperedCachedRecordIsDropped() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }

        var state = InboxState()
        let record = try WatchTestFixtures.makeRecord(createdAt: now, presentAt: now)
        state.approvals[record.spec.requestID] = record
        try cache.commit(state)

        let url = directory.appendingPathComponent("control-inbox.json")
        let encoded = try JSONValue.parse(try Data(contentsOf: url), limits: JSONLimits(maxDocumentBytes: 1 << 20))
        var members = try XCTUnwrap(encoded.objectValue)
        var approvals = try XCTUnwrap(members["approvals"]?.arrayValue)
        var entry = try XCTUnwrap(approvals[0].objectValue)
        var spec = try XCTUnwrap(entry["spec"]?.objectValue)
        var operation = try XCTUnwrap(spec["operation"]?.objectValue)
        // Swap the argument vector while leaving the advertised digest alone.
        operation["argv"] = JSONValue(strings: ["/usr/bin/git", "push", "--force"])
        spec["operation"] = .object(operation)
        entry["spec"] = .object(spec)
        approvals[0] = .object(entry)
        members["approvals"] = .array(approvals)
        try JSONCanonicalization.canonicalize(.object(members)).write(to: url)

        let loaded = try XCTUnwrap(try cache.load())
        XCTAssertTrue(loaded.approvals.isEmpty)
    }

    func testClearRemovesTheCacheFile() throws {
        let (cache, directory) = try makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        try cache.commit(InboxState())
        XCTAssertNotNil(try cache.load())
        try cache.clear()
        XCTAssertNil(try cache.load())
    }

    /// Unresolved command ids are persisted apart from the projection, so a
    /// snapshot refresh cannot erase an ambiguous submitted decision.
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
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.commandID, command.commandID)
        XCTAssertEqual(reloaded.first?.status, .outcomeUnknown)
        XCTAssertEqual(reloaded.first?.signedCommand, "header.payload.signature")
    }
}
