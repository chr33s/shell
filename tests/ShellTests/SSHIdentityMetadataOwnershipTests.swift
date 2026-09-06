import XCTest

@testable import Shell

/// Pins the ownership gate in `SSHIdentityMetadataStore.reconcile`.
///
/// The bug this file exists for: `reconcile` used to tombstone every record
/// whose identity was absent from *this* device's key list. Because
/// `applyRemoteChanges` writes other devices' records into the same store —
/// and a Secure Enclave key on another device can never be present here — that
/// swept records belonging to other devices and pushed the deletions to
/// CloudKit, destroying the identity metadata account-wide. The fix scopes the
/// sweep to records stamped with this device's own `ownerDeviceID`.
///
/// Ownership is driven through the injected `owningDeviceID` seam rather than
/// through `UserDefaults`, so these tests never depend on the host device's
/// real identity, on `ProtectedDataGuard.isAvailable`, or on each other. Each
/// test gets its own on-disk store directory and deletes it afterwards.
@MainActor
final class SSHIdentityMetadataOwnershipTests: XCTestCase {
    private var storeName = ""

    override func setUp() {
        super.setUp()
        storeName = "test_ssh_identity_metadata_\(UUID().uuidString)"
        removeStoreDirectory()
    }

    override func tearDown() {
        removeStoreDirectory()
        super.tearDown()
    }

    // MARK: - Scenario (a): a device sweeping only its own leftovers

    /// A fresh install that publishes its keys and then reconciles against the
    /// same list must tombstone nothing. Breaks if the sweep stops filtering on
    /// `liveIDs` and starts tombstoning indiscriminately.
    func testReconcileWithEveryLocalKeyStillPresentTombstonesNothing() {
        let store = makeStore(ownedBy: "device-A")
        let first = makeKey(named: "first")
        let second = makeKey(named: "second")

        store.record(first)
        store.record(second)
        store.reconcile(with: [first, second])

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertTrue(
            store.allRecordsForSync.allSatisfy { !$0.isDeleted },
            "Reconciling against the identities that are actually present must tombstone nothing"
        )
    }

    /// The sweep must still do its job for records this device published: a key
    /// deleted locally leaves a stale record, and that record is this device's
    /// to tombstone.
    ///
    /// This is the counterweight to the ownership gate. Without it the gate
    /// could be "fixed" by never sweeping at all — every other test in this
    /// file would still pass while stale records accumulated forever.
    func testReconcileTombstonesThisDevicesOwnRecordWhoseKeyIsGone() {
        let store = makeStore(ownedBy: "device-A")
        let surviving = makeKey(named: "surviving")
        let removed = makeKey(named: "removed")

        store.record(surviving)
        store.record(removed)
        XCTAssertEqual(store.entries.count, 2)

        store.reconcile(with: [surviving])

        XCTAssertEqual(store.entries.map(\.id), [surviving.id])
        XCTAssertEqual(record(removed.id, in: store)?.isDeleted, true)
        XCTAssertEqual(
            record(removed.id, in: store)?.ownerDeviceID,
            "device-A",
            "A record this device published must carry this device's owner ID"
        )
    }

    // MARK: - Scenario (b): the data-loss regression

    /// THE REGRESSION. Device B reconciles its own key list while holding a
    /// record published by device A and a legacy record with no owner at all.
    /// Neither may be tombstoned — they describe identities that live
    /// elsewhere, and tombstoning them pushes the deletion account-wide.
    ///
    /// Fails the moment the `stale.ownerDeviceID == owner` clause is dropped
    /// from the sweep in `reconcile`, or the `ownerDeviceID` field stops being
    /// stamped by `record`.
    func testReconcileNeverTombstonesRecordsPublishedByAnotherDeviceOrByNobody() {
        let store = makeStore(ownedBy: "device-B")
        let localKey = makeKey(named: "local to B")
        let staleLocalKey = makeKey(named: "deleted on B")
        store.record(localKey)
        store.record(staleLocalKey)

        let deviceARecord = makeMetadata(named: "secure enclave key on A", ownerDeviceID: "device-A")
        let legacyRecord = makeMetadata(named: "written before ownership existed", ownerDeviceID: nil)
        XCTAssertEqual(store.applyRemoteChanges([deviceARecord, legacyRecord]), 2)

        // The user renames a key on device B, so B republishes its own list.
        store.reconcile(with: [localKey])

        XCTAssertEqual(
            record(deviceARecord.id, in: store)?.isDeleted,
            false,
            "Device A's record must survive device B's reconcile — this is the account-wide data loss"
        )
        XCTAssertEqual(
            record(legacyRecord.id, in: store)?.ownerDeviceID,
            nil,
            "An unowned record is nobody's to sweep and must keep its nil owner"
        )
        XCTAssertEqual(
            record(legacyRecord.id, in: store)?.isDeleted,
            false,
            "A record written before `ownerDeviceID` existed must survive"
        )
        XCTAssertEqual(
            record(staleLocalKey.id, in: store)?.isDeleted,
            true,
            "B's own stale record is still B's to tombstone"
        )
        XCTAssertEqual(store.entries.map(\.id).sorted(by: idOrder), [deviceARecord.id, legacyRecord.id, localKey.id].sorted(by: idOrder))
    }

    /// With no readable device ID — a locked device, where
    /// `CloudKitSyncSettings.deviceID` would hand back a throwaway
    /// `transient-<pid>` value — the sweep is skipped entirely rather than run
    /// under an identity that never comes back.
    ///
    /// Fails if `reconcile` starts sweeping unconditionally, or if the `nil`
    /// branch is changed to fall back to some other identity.
    func testReconcileSkipsTheSweepEntirelyWhenNoStableDeviceIDIsAvailable() {
        let store = makeStore(ownedBy: nil)
        let present = makeKey(named: "present")
        let absent = makeKey(named: "absent")
        store.record(present)
        store.record(absent)

        store.reconcile(with: [present])

        XCTAssertEqual(
            record(absent.id, in: store)?.isDeleted,
            false,
            "A device that cannot name itself must not tombstone anything"
        )
    }

    // MARK: - Scenario (c): no ownership ping-pong

    /// The same iCloud Keychain key exists on two devices. Republishing it on
    /// device B while device A owns the record must not rewrite the record —
    /// every rewrite is a CloudKit push, and two devices trading ownership back
    /// and forth would push forever.
    ///
    /// `onLocalChange` is the sync push hook, so counting its calls is
    /// literally counting pushes. Fails if `sameContent` stops normalising
    /// `ownerDeviceID` (or `modifiedAt`), or if the early return in `record` is
    /// removed.
    func testRepublishingAKeyOwnedByAnotherDeviceNeitherRewritesNorReclaimsIt() {
        let store = makeStore(ownedBy: "device-B")
        let sharedKey = makeKey(named: "iCloud Keychain key")

        var remote = SSHIdentityMetadata(identity: sharedKey)
        remote.ownerDeviceID = "device-A"
        XCTAssertEqual(store.applyRemoteChanges([remote]), 1)

        let pushes = PushCounter()
        store.onLocalChange = { _, _ in pushes.count += 1 }

        store.record(sharedKey)
        store.record(sharedKey)
        store.record(sharedKey)

        XCTAssertEqual(pushes.count, 0, "Republishing unchanged content must not fire a sync push")
        XCTAssertEqual(
            record(sharedKey.id, in: store)?.ownerDeviceID,
            "device-A",
            "Ownership must not ping-pong to whichever device published last"
        )
    }

    /// A legacy record with no owner is adopted by the device that holds the
    /// key — otherwise it could never be swept — but exactly once. The second
    /// publish sees a non-nil owner and stops.
    ///
    /// Fails if the `claimsUnownedRecord` branch is deleted (the record is
    /// never claimed, so the first assertion goes nil) or if it stops being
    /// gated on `existing.ownerDeviceID == nil` (the claim fires on every call
    /// and the push count climbs).
    func testAnUnownedRecordIsClaimedOnceByTheDeviceThatHoldsTheKey() {
        let store = makeStore(ownedBy: "device-A")
        let key = makeKey(named: "adopted")

        var unowned = SSHIdentityMetadata(identity: key)
        unowned.ownerDeviceID = nil
        XCTAssertEqual(store.applyRemoteChanges([unowned]), 1)

        let pushes = PushCounter()
        store.onLocalChange = { _, _ in pushes.count += 1 }

        store.record(key)
        XCTAssertEqual(record(key.id, in: store)?.ownerDeviceID, "device-A")
        XCTAssertEqual(pushes.count, 1, "Claiming an unowned record is one write")

        store.record(key)
        store.record(key)
        XCTAssertEqual(pushes.count, 1, "The claim must write once and then stop")
    }

    // MARK: - Helpers

    private final class PushCounter {
        var count = 0
    }

    private func makeStore(ownedBy deviceID: String?) -> SSHIdentityMetadataStore {
        SSHIdentityMetadataStore(storeName: storeName, owningDeviceID: { deviceID })
    }

    private func makeKey(named name: String) -> SSHKey {
        SSHKey(
            name: name,
            keyType: .ed25519,
            fingerprint: "SHA256:\(name.replacingOccurrences(of: " ", with: "-"))",
            storageLevel: .iCloudSync
        )
    }

    private func makeMetadata(named name: String, ownerDeviceID: String?) -> SSHIdentityMetadata {
        SSHIdentityMetadata(
            id: UUID(),
            name: name,
            keyType: SSHKey.KeyType.secureEnclaveP256.rawValue,
            fingerprint: "SHA256:\(name.replacingOccurrences(of: " ", with: "-"))",
            storageType: KeyStorageLevel.deviceOnly.rawValue,
            publicKey: nil,
            certificate: nil,
            secureEnclaveDeviceBound: true,
            ownerDeviceID: ownerDeviceID
        )
    }

    private func record(_ id: UUID, in store: SSHIdentityMetadataStore) -> SSHIdentityMetadata? {
        store.allRecordsForSync.first { $0.id == id }
    }

    private func idOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }

    private func removeStoreDirectory() {
        guard !storeName.isEmpty else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(storeName, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }
}
