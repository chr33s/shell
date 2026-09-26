import Foundation
import Testing

@testable import Shell

/// Pins the zone-change checkpoint rule (SYNC-01..03).
///
/// The token returned by a zone-changes fetch used to be persisted before the
/// fetched records were applied, so a crash or a local write failure between
/// the two skipped those changes permanently: the next fetch started after
/// them. The token is now committed by `applyFetchedChanges` only once every
/// record and tombstone of an enabled class persisted and every record in the
/// fetched pages actually downloaded. Otherwise the old token stays and the
/// range is re-delivered; local apply is last-write-wins, so replay is safe.
///
/// The fetch/apply sequence itself awaits `CKDatabase`, which a unit test
/// cannot reach, so the decision was extracted and is pinned here.
@Suite
struct CloudKitCheckpointTests {

    @Test func advancesOnlyWhenEverythingApplied() {
        #expect(CloudKitSyncManager.shouldAdvanceCheckpoint(
            recordsApplied: true, deletionsApplied: true, hadRecordFailures: false))
    }

    @Test func localRecordFailureHoldsCheckpoint() {
        #expect(!CloudKitSyncManager.shouldAdvanceCheckpoint(
            recordsApplied: false, deletionsApplied: true, hadRecordFailures: false))
    }

    @Test func localTombstoneFailureHoldsCheckpoint() {
        #expect(!CloudKitSyncManager.shouldAdvanceCheckpoint(
            recordsApplied: true, deletionsApplied: false, hadRecordFailures: false))
    }

    @Test func undownloadedRecordHoldsCheckpoint() {
        #expect(!CloudKitSyncManager.shouldAdvanceCheckpoint(
            recordsApplied: true, deletionsApplied: true, hadRecordFailures: true))
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
    }
}
