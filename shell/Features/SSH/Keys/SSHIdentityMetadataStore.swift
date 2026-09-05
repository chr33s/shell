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

    private init() {
        self.store = SyncableFileStore<SSHIdentityMetadata>(storeName: "ssh_identity_metadata")
        updateEntriesFromStore()
    }

    // MARK: - Local mutations

    /// Publish (or refresh) the public metadata for a local identity.
    func record(_ identity: SSHKey) {
        let metadata = SSHIdentityMetadata(identity: identity)
        guard store.record(for: metadata.id) != metadata else { return }
        do {
            try store.save(metadata)
            updateEntriesFromStore()
        } catch {
            Self.logger.error("Failed to persist identity metadata: \(error.localizedDescription)")
        }
    }

    /// Replace the published set with exactly the identities that exist locally,
    /// tombstoning any metadata whose identity is gone.
    func reconcile(with identities: [SSHKey]) {
        let liveIDs = Set(identities.map(\.id))
        for identity in identities {
            record(identity)
        }
        for stale in store.allRecords where !stale.isDeleted && !liveIDs.contains(stale.id) {
            try? store.softDelete(id: stale.id)
        }
        updateEntriesFromStore()
    }

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

    private func updateEntriesFromStore() {
        entries = store.activeRecords.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
