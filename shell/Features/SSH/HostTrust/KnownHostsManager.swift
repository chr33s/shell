import Foundation
import Combine
import os.log

/// Manages known SSH hosts with sync-ready file-based persistence
@MainActor
final class KnownHostsManager: ObservableObject {
    /// Shared singleton instance
    static let shared = KnownHostsManager()

    /// File store for sync-ready per-record storage
    private var store: SyncableFileStore<KnownHost>

    /// Lookup table from legacy ID (hostname:port) to UUID
    private var legacyIdToUUID: [String: UUID] = [:]

    /// Logger for debugging
    private let logger = Logger(subsystem: "dev.chr33s.shell", category: "KnownHosts")

    /// Callback for CloudKit sync integration
    var onLocalChange: ((KnownHost, SyncOperation) -> Void)? {
        didSet {
            store.onLocalChange = onLocalChange
        }
    }

    /// Initialize the manager and load existing known hosts
    init() {
        // Run migration before initializing store
        SyncMigrationManager.migrateIfNeeded()

        self.store = SyncableFileStore<KnownHost>(storeName: "known_hosts")

        // Build legacy ID lookup table
        rebuildLegacyIdLookup()

        logger.info("Loaded \(self.store.activeCount) known hosts")
    }

    /// Rebuild the legacy ID to UUID lookup table
    private func rebuildLegacyIdLookup() {
        legacyIdToUUID = [:]
        for host in store.activeRecords {
            legacyIdToUUID[host.legacyId] = host.id
        }
    }

    /// Get the known host entry for a specific hostname and port
    func getHost(hostname: String, port: Int) -> KnownHost? {
        let legacyId = "\(hostname):\(port)"
        guard let uuid = legacyIdToUUID[legacyId] else {
            return nil
        }
        let host = store.record(for: uuid)
        // Return nil if soft-deleted
        return host?.isDeleted == false ? host : nil
    }

    /// Get a host by UUID
    func getHost(id: UUID) -> KnownHost? {
        let host = store.record(for: id)
        return host?.isDeleted == false ? host : nil
    }

    /// Add or update a known host
    func addHost(_ host: KnownHost) {
        // Check if host already exists by legacy ID
        if let existingUUID = legacyIdToUUID[host.legacyId],
           var existing = store.record(for: existingUUID) {
            // Update existing host - preserve the UUID
            existing = KnownHost(
                id: existingUUID,
                hostname: host.hostname,
                port: host.port,
                publicKeyData: host.publicKeyData,
                keyType: host.keyType,
                fingerprint: host.fingerprint,
                firstSeen: existing.firstSeen,  // Preserve original firstSeen
                lastSeen: host.lastSeen,
                modifiedAt: Date(),
                isDeleted: false
            )
            try? store.save(existing)
            logger.info("Updated known host: \(host.hostname):\(host.port)")
        } else {
            // Add new host
            try? store.save(host)
            legacyIdToUUID[host.legacyId] = host.id
            logger.info("Added known host: \(host.hostname):\(host.port)")
        }
    }

    /// Update the last seen timestamp for a host
    func updateLastSeen(hostname: String, port: Int) {
        let legacyId = "\(hostname):\(port)"
        guard let uuid = legacyIdToUUID[legacyId],
              var host = store.record(for: uuid) else { return }

        host.updateLastSeen()
        try? store.save(host)
    }

    /// Remove a known host by hostname and port
    func removeHost(hostname: String, port: Int) {
        let legacyId = "\(hostname):\(port)"
        guard let uuid = legacyIdToUUID[legacyId] else { return }

        try? store.softDelete(id: uuid)
        legacyIdToUUID.removeValue(forKey: legacyId)
        logger.info("Removed known host: \(hostname):\(port)")
    }

    /// Remove a known host by UUID
    func removeHost(id: UUID) {
        guard let host = store.record(for: id) else { return }

        try? store.softDelete(id: id)
        legacyIdToUUID.removeValue(forKey: host.legacyId)
        logger.info("Removed known host: \(host.hostname):\(host.port)")
    }

    /// Remove all known hosts
    func removeAll() {
        for host in store.activeRecords {
            try? store.softDelete(id: host.id)
        }
        legacyIdToUUID.removeAll()
        logger.info("Removed all known hosts")
    }

    /// Get all known hosts as an array (for UI display)
    var allHosts: [KnownHost] {
        store.activeRecords.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Get total count of known hosts
    var count: Int {
        store.activeCount
    }

    /// All records including tombstones (for CloudKit sync)
    var allRecordsForSync: [KnownHost] {
        store.allRecords
    }

    /// Whether the last disk load failed to list the store directory
    var lastDiskLoadFailed: Bool {
        store.lastLoadFailed
    }

    // MARK: - Compatibility with old API

    /// Dictionary access for legacy code (read-only snapshot)
    var hosts: [HostIdentifier: KnownHost] {
        Dictionary(uniqueKeysWithValues: store.activeRecords.map { host in
            (HostIdentifier(hostname: host.hostname, port: host.port), host)
        })
    }

    // MARK: - Sync Support

    /// Apply changes from remote sync
    /// Uses logical identity (hostname:port) to prevent duplicates
    @discardableResult
    func applyRemoteChanges(_ remoteHosts: [KnownHost]) -> Int {
        applyRemoteChangesWithFailures(remoteHosts).applied
    }

    /// Apply changes from remote sync, returning both successful applies and any persistence failures.
    /// Used by the backup restore path so the UI can surface real errors instead of silent loss.
    func applyRemoteChangesWithFailures(
        _ remoteHosts: [KnownHost]
    ) -> (applied: Int, failures: [(id: UUID, error: Error)]) {
        var applied = 0
        var failures: [(id: UUID, error: Error)] = []

        for remote in remoteHosts {
            // Check by logical identity (hostname:port), not just UUID
            if let existingUUID = legacyIdToUUID[remote.legacyId],
               let existing = store.record(for: existingUUID) {
                // Same logical host exists - use last-write-wins
                guard remote.modifiedAt > existing.modifiedAt else {
                    continue  // Local is newer, keep local
                }
                // Remote is newer - update existing record (keep local UUID)
                let updated = KnownHost(
                    id: existingUUID,  // Keep local UUID for consistency
                    hostname: remote.hostname,
                    port: remote.port,
                    publicKeyData: remote.publicKeyData,
                    keyType: remote.keyType,
                    fingerprint: remote.fingerprint,
                    firstSeen: min(existing.firstSeen, remote.firstSeen),
                    lastSeen: max(existing.lastSeen, remote.lastSeen),
                    modifiedAt: remote.modifiedAt,
                    isDeleted: remote.isDeleted
                )
                do {
                    try store.save(updated, updateTimestamp: false, notifySync: false)
                    applied += 1
                } catch {
                    failures.append((id: existingUUID, error: error))
                    let idString = existingUUID.uuidString
                    let hostname = updated.hostname
                    let desc = error.localizedDescription
                    logger.error("Failed to persist remote known host \(idString) (\(hostname)): \(desc)")
                }
            } else if store.record(for: remote.id) != nil {
                // Same UUID exists but different logical identity (shouldn't happen)
                // Skip to avoid confusion
                logger.warning("UUID collision for different hosts: \(remote.id)")
            } else {
                // Truly new host - add it
                do {
                    try store.save(remote, updateTimestamp: false, notifySync: false)
                    legacyIdToUUID[remote.legacyId] = remote.id
                    applied += 1
                } catch {
                    failures.append((id: remote.id, error: error))
                    let idString = remote.id.uuidString
                    let hostname = remote.hostname
                    let desc = error.localizedDescription
                    logger.error("Failed to persist remote known host \(idString) (\(hostname)): \(desc)")
                }
            }
        }

        let failureCount = failures.count
        logger.info("Applied \(applied) remote changes to known_hosts (\(failureCount) failures)")
        return (applied, failures)
    }

    /// Apply remote deletions from CloudKit change sets
    func applyRemoteDeletions(recordNames: Set<String>) {
        guard !recordNames.isEmpty else { return }

        var deletedCount = 0

        for host in store.activeRecords {
            let recordName = CloudKitRecordName.make(
                recordType: KnownHost.recordType,
                identity: host.legacyId
            )
            if recordNames.contains(recordName) {
                var deleted = host
                deleted.isDeleted = true
                deleted.modifiedAt = Date()
                try? store.save(deleted, updateTimestamp: false, notifySync: false)
                legacyIdToUUID.removeValue(forKey: host.legacyId)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            logger.info("Applied \(deletedCount) remote deletions to known_hosts")
        }
    }

    /// Get hosts modified after a given date (for sync)
    func hostsModifiedAfter(_ date: Date) -> [KnownHost] {
        store.recordsModifiedAfter(date)
    }

    /// Reload hosts from disk
    func reload() {
        store.reload()
        rebuildLegacyIdLookup()
    }
}
