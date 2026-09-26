import Foundation
import Testing

@testable import Shell

/// Pins the zone-change checkpoint rules (SYNC-01..03).
///
/// The token returned by a zone-changes fetch used to be persisted before the
/// fetched records were applied, so a crash or a local write failure between
/// the two skipped those changes permanently. The token is now committed by
/// `applyFetchedChanges` after local application, and anything that failed to
/// download or persist is first written to the durable unapplied-records
/// journal, which every sync retries by record ID. Holding the checkpoint
/// instead would stall forever on a record that always fails.
///
/// The fetch/apply sequence awaits `CKDatabase`, which a unit test cannot
/// reach, so the journal is tested directly and the ordering by source text.
@MainActor
@Suite
final class CloudKitCheckpointTests {
    private let suiteName = "dev.chr33s.shell.tests.unapplied.\(UUID().uuidString)"
    nonisolated(unsafe) private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func record(_ name: String, _ type: String? = "Profile") -> CloudKitUnappliedRecord {
        CloudKitUnappliedRecord(recordName: name, recordType: type)
    }

    @Test func journalStartsEmpty() {
        #expect(CloudKitUnappliedRecords(defaults: defaults).records.isEmpty)
    }

    @Test func journalSurvivesReload() {
        CloudKitUnappliedRecords(defaults: defaults).add([record("a"), record("b", nil)])
        // A fresh instance reads what the previous one persisted.
        let reloaded = CloudKitUnappliedRecords(defaults: defaults).records
        #expect(reloaded == [record("a"), record("b", nil)])
    }

    @Test func addMergesWithoutDroppingPendingWork() {
        let journal = CloudKitUnappliedRecords(defaults: defaults)
        journal.add([record("a")])
        journal.add([record("b")])
        #expect(journal.records == [record("a"), record("b")])
    }

    @Test func retryReplacesWithStillFailing() {
        let journal = CloudKitUnappliedRecords(defaults: defaults)
        journal.add([record("a"), record("b")])
        journal.replace(with: [record("b")])
        #expect(journal.records == [record("b")])
        journal.replace(with: [])
        #expect(journal.records.isEmpty)
        #expect(defaults.data(forKey: CloudKitUnappliedRecords.defaultsKey) == nil)
    }

    @Test func clearDropsEverything() {
        let journal = CloudKitUnappliedRecords(defaults: defaults)
        journal.add([record("a")])
        journal.clear()
        #expect(journal.records.isEmpty)
    }

    /// Source tripwire: `fetchZoneChanges` must not persist the token it
    /// fetched. Resetting to nil is allowed (it only widens the next fetch);
    /// adopting `newChangeToken` belongs to `applyFetchedChanges` alone.
    @Test func fetchDoesNotCommitFetchedToken() throws {
        guard SourceTree.isAvailable else { return }
        let url = SourceTree.appSources
            .appendingPathComponent("Core/CloudKit/CloudKitSyncManager.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let adoptions = source.components(separatedBy: "zoneChangeToken = changes.newChangeToken").count - 1
        #expect(adoptions == 1, "Only applyFetchedChanges may adopt a fetched token")
        let applyRange = try #require(source.range(of: "private func applyFetchedChanges"))
        let adoptRange = try #require(source.range(of: "zoneChangeToken = changes.newChangeToken"))
        #expect(adoptRange.lowerBound > applyRange.lowerBound)
        // Failures are journaled before the token that skips them is saved.
        let journalRange = try #require(source.range(of: "unappliedRecords.add(failed)"))
        #expect(journalRange.lowerBound > applyRange.lowerBound)
        #expect(journalRange.lowerBound < adoptRange.lowerBound)
    }
}
