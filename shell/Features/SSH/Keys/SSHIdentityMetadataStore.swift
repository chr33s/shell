//
//  SSHIdentityMetadataStore.swift
//  shell
//
//  Persistent store for the *public* half of every SSH identity, so other
//  devices can see which keys exist, their fingerprints and any attached
//  OpenSSH user certificate. Private key material never reaches this store —
//  software keys sync through the iCloud Keychain, and Secure Enclave keys
//  never leave the device that created them (spec §7).
//

import Foundation
import Observation
import os.log

@MainActor
@Observable
final class SSHIdentityMetadataStore {
    static let shared = SSHIdentityMetadataStore()
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHIdentityMetadata")

    private var store: SyncableFileStore<SSHIdentityMetadata>

    /// Active (non-tombstoned) metadata, sorted by name.
    private(set) var entries: [SSHIdentityMetadata] = []

    /// All records including tombstones (for CloudKit sync)
    var allRecordsForSync: [SSHIdentityMetadata] {
        store.allRecords
    }

    /// Whether the last disk load failed to list the store directory
    var lastDiskLoadFailed: Bool {
        store.lastLoadFailed
    }

    /// Callback for CloudKit sync integration
    var onLocalChange: ((SSHIdentityMetadata, SyncOperation) -> Void)? {
        didSet { store.onLocalChange = onLocalChange }
    }

    /// How this store learns the device ID to stamp on the records it
    /// publishes. Injected only so tests can drive ownership deterministically
    /// and without touching the live device identity; production always uses
    /// `liveOwningDeviceID`, which is what `shared` gets.
    private let owningDeviceID: @MainActor () -> String?

    init(
        storeName: String = "ssh_identity_metadata",
        owningDeviceID: (@MainActor () -> String?)? = nil
    ) {
        self.owningDeviceID = owningDeviceID ?? { SSHIdentityMetadataStore.liveOwningDeviceID }
        self.store = SyncableFileStore<SSHIdentityMetadata>(storeName: storeName)
        updateEntriesFromStore()
    }

    // MARK: - Local mutations

    /// Publish (or refresh) the public metadata for a local identity.
    func record(_ identity: SSHKey) {
        var metadata = SSHIdentityMetadata(identity: identity)
        let existing = store.record(for: metadata.id)
        // This method is only ever called with an identity that exists on this
        // device, so this device is the rightful owner of the record. With no
        // readable device ID (locked device) keep whatever owner is already
        // stored rather than clearing it — see `owningDeviceID`.
        metadata.ownerDeviceID = owningDeviceID() ?? existing?.ownerDeviceID
        if let existing {
            // Adopt a record that nobody owns (written before the field
            // existed, or by an older build) even when nothing else changed:
            // an unowned record is one `reconcile` can never tombstone. The
            // claim writes once and then stops, because the next pass sees a
            // non-nil owner.
            let claimsUnownedRecord = existing.ownerDeviceID == nil && metadata.ownerDeviceID != nil
            // Otherwise compare content only: the projection carries the key's
            // own security-modified date while the stored copy was stamped by
            // `save(_:)`, so a whole-value `!=` never matches and every call
            // would rewrite the file and fire a CloudKit push.
            if !claimsUnownedRecord, Self.sameContent(existing, metadata) { return }
        }
        do {
            try store.save(metadata)
            updateEntriesFromStore()
        } catch {
            Self.logger.error("Failed to persist identity metadata: \(error.localizedDescription)")
        }
    }

    /// Refresh the published metadata for every local identity, then tombstone
    /// the records **this device published** whose identity is gone.
    ///
    /// The sweep is deliberately scoped by owner. `applyRemoteChanges` writes
    /// other devices' records into this same store, and an identity that lives
    /// on another device — a Secure Enclave key above all, which by definition
    /// can never be here (spec §7) — is *expected* to be absent from this
    /// device's key list. Sweeping on absence alone would tombstone it and push
    /// that deletion to every device, destroying the metadata account-wide.
    /// A record this device did not publish is therefore never soft-deleted
    /// here; only `remove(id:)` (an explicit, user-initiated key deletion) and
    /// `applyRemoteDeletions` can tombstone one.
    func reconcile(with identities: [SSHKey]) {
        let liveIDs = Set(identities.map(\.id))
        for identity in identities {
            record(identity)
        }
        if let owner = owningDeviceID() {
            // `stale.ownerDeviceID == owner` compares `String?` against
            // `String`: an unowned (nil) record never matches, so it survives.
            var swept = 0
            for stale in store.allRecords
            where !stale.isDeleted && !liveIDs.contains(stale.id) && stale.ownerDeviceID == owner {
                try? store.softDelete(id: stale.id)
                swept += 1
            }
            if swept > 0 {
                Self.logger.info("Tombstoned \(swept) identity metadata record(s) published by this device")
            }
        } else {
            Self.logger.info("Skipped identity metadata sweep: no stable device ID available")
        }
        updateEntriesFromStore()
    }

    /// Tombstone one identity's metadata outright — for a deliberate, local
    /// key deletion, which removes the identity everywhere (the Keychain item
    /// it deletes is the shared one). Unlike `reconcile` this ignores ownership,
    /// so it must only be called when the user actually deleted the key.
    func remove(id: UUID) {
        try? store.softDelete(id: id)
        updateEntriesFromStore()
    }

    // MARK: - Sync Support

    @discardableResult
    func applyRemoteChanges(_ remote: [SSHIdentityMetadata]) -> Int {
        let applied = (try? store.applyRemoteChanges(remote)) ?? 0
        updateEntriesFromStore()
        return applied
    }

    func applyRemoteDeletions(recordNames: Set<String>) {
        guard !recordNames.isEmpty else { return }
        var deleted = 0
        for entry in entries {
            let recordName = CloudKitRecordName.make(
                recordType: SSHIdentityMetadata.recordType,
                identity: entry.id.uuidString
            )
            if recordNames.contains(recordName) {
                try? store.softDelete(id: entry.id)
                deleted += 1
            }
        }
        if deleted > 0 {
            Self.logger.info("Applied \(deleted) remote deletions to identity metadata")
            updateEntriesFromStore()
        }
    }

    func reload() {
        store.reload()
        updateEntriesFromStore()
    }

    // MARK: - Private

    /// The stable device ID to stamp on records this device publishes, or
    /// `nil` when it cannot be established. While protected data is unavailable
    /// `CloudKitSyncSettings.deviceID` hands back a throwaway `transient-<pid>`
    /// value; stamping that would claim ownership under an ID that never comes
    /// back, and a record owned by nobody real can never be swept again.
    private static var liveOwningDeviceID: String? {
        guard ProtectedDataGuard.isAvailable else { return nil }
        return CloudKitSyncSettings.deviceID
    }

    /// Equality that ignores `modifiedAt`, which is stamped by the store on
    /// save and therefore always differs from a freshly projected record, and
    /// `ownerDeviceID`, which is claimed only on a real content change: two
    /// devices holding the same iCloud Keychain key would otherwise trade
    /// ownership back and forth, each rewrite firing a CloudKit push.
    private static func sameContent(_ lhs: SSHIdentityMetadata, _ rhs: SSHIdentityMetadata) -> Bool {
        var normalized = lhs
        normalized.modifiedAt = rhs.modifiedAt
        normalized.ownerDeviceID = rhs.ownerDeviceID
        return normalized == rhs
    }

    private func updateEntriesFromStore() {
        entries = store.activeRecords.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
