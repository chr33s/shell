//
//  SyncableFileStore.swift
//  shell
//
//  Generic file-based store for syncable records
//

import Foundation
import os.log

/// Generic file-based store for syncable records
///
/// Stores each record as a separate JSON file in a dedicated directory,
/// enabling efficient per-record sync operations.
///
/// Directory structure:
/// ```
/// Documents/.ghostty/sync/{storeName}/
///   {uuid1}.json
///   {uuid2}.json
///   ...
/// ```
@MainActor
struct SyncableFileStore<T: SyncableRecord> {
    private nonisolated static var logger: Logger {
        Logger(subsystem: "dev.chr33s.shell", category: "SyncableFileStore")
    }

    /// All records indexed by ID (includes soft-deleted records)
    private(set) var records: [UUID: T] = [:]

    /// Whether the last load failed to list the store directory (as opposed
    /// to the directory simply being empty). Lets callers distinguish "no
    /// data" from "data unreadable" when records is empty.
    private(set) var lastLoadFailed = false

    /// Directory where record files are stored
    let directoryURL: URL

    /// Name of this store (used for logging)
    let storeName: String

    /// Callback when a record is modified locally (for sync integration)
    var onLocalChange: ((T, SyncOperation) -> Void)?

    /// JSON encoder with consistent formatting
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// JSON decoder
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// How long a soft-deleted record's file is kept before it is removed.
    ///
    /// The tombstone is the only thing on this device that says the record is
    /// gone. Drop it while another device is still offline holding a live copy
    /// and the next fetch re-adopts that copy as a brand-new record — for
    /// `known_hosts` that means silently re-trusting a host key the user
    /// deliberately removed, so the window has to be generous. Ninety days is
    /// past any plausible period a second device sits unopened (a phone left in
    /// a drawer for a season) and past CloudKit's own change-token horizon,
    /// after which a returning device re-fetches the zone from scratch and
    /// re-learns the deletion from the server copy of the tombstone.
    nonisolated static var tombstoneRetention: TimeInterval { 90 * 24 * 60 * 60 }

    /// Initialize a new file store
    /// - Parameter storeName: Name of the store (used for directory name)
    init(storeName: String) {
        self.storeName = storeName

        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directoryURL = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent(storeName, isDirectory: true)

        createDirectoryIfNeeded()
        loadAllRecords()
        purgeExpiredTombstones()
    }

    // MARK: - Public API

    /// All non-deleted records as an array
    var activeRecords: [T] {
        records.values.filter { !$0.isDeleted }
    }

    /// All records including tombstones (for sync)
    var allRecords: [T] {
        Array(records.values)
    }

    /// Get a record by ID
    func record(for id: UUID) -> T? {
        records[id]
    }

    /// Save a record (creates or updates)
    /// - Parameter record: The record to save
    /// - Parameter updateTimestamp: Whether to update modifiedAt (default: true)
    /// - Parameter notifySync: Whether to notify sync callback (false for remote changes to avoid loop)
    mutating func save(_ record: T, updateTimestamp: Bool = true, notifySync: Bool = true) throws {
        let storeName = self.storeName
        var mutableRecord = record

        if updateTimestamp {
            mutableRecord.modifiedAt = Date()
        }

        let fileURL = fileURL(for: mutableRecord.id)
        let recordIDString = mutableRecord.id.uuidString

        let data: Data
        do {
            data = try encoder.encode(mutableRecord)
        } catch {
            let desc = error.localizedDescription
            Self.logger.error("Encode failed for \(storeName)/\(recordIDString): \(desc)")
            throw error
        }

        do {
            try writeAtomically(data: data, to: fileURL)
        } catch {
            let destination = fileURL.path
            let desc = error.localizedDescription
            Self.logger.error("Write failed for \(storeName)/\(recordIDString) at \(destination): \(desc)")
            throw error
        }

        let isNew = records[mutableRecord.id] == nil
        records[mutableRecord.id] = mutableRecord

        Self.logger.debug("Saved record \(recordIDString) to \(storeName)")

        // Only notify sync for local changes, not when applying remote changes
        if notifySync {
            onLocalChange?(mutableRecord, isNew ? .create : .update)
        }
    }

    /// Soft delete a record (marks as deleted for sync tombstone)
    mutating func softDelete(id: UUID) throws {
        let storeName = self.storeName
        guard var record = records[id] else {
            Self.logger.warning("Attempted to delete non-existent record \(id.uuidString)")
            return
        }

        record.isDeleted = true
        record.modifiedAt = Date()
        // notifySync: false — the explicit .delete notification below is the single
        // notification for this deletion. Leaving save's default (true) fired an
        // extra .update for the same tombstone, so one delete issued two concurrent
        // CloudKit saves of the same record.
        try save(record, updateTimestamp: false, notifySync: false)

        Self.logger.info("Soft deleted record \(id.uuidString) from \(storeName)")
        onLocalChange?(record, .delete)
    }

    /// Permanently remove a record (use sparingly - breaks sync)
    mutating func hardDelete(id: UUID) throws {
        let storeName = self.storeName
        let fileURL = fileURL(for: id)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }

        records.removeValue(forKey: id)
        Self.logger.info("Hard deleted record \(id.uuidString) from \(storeName)")
    }

    /// Get records modified after a given date
    func recordsModifiedAfter(_ date: Date) -> [T] {
        records.values.filter { $0.modifiedAt > date }
    }

    /// Apply changes from remote sync
    /// - Parameter remoteRecords: Records received from CloudKit
    /// - Returns: Number of records that were updated locally
    @discardableResult
    mutating func applyRemoteChanges(_ remoteRecords: [T]) throws -> Int {
        let storeName = self.storeName
        var updatedCount = 0

        for remote in remoteRecords {
            // notifySync: false — these records came FROM the remote. Notifying
            // would push each fetched record straight back to CloudKit, bumping
            // server change tags and invalidating every other device's zone
            // change token.
            if let local = records[remote.id] {
                // Last-write-wins
                if remote.modifiedAt > local.modifiedAt {
                    try save(remote, updateTimestamp: false, notifySync: false)
                    updatedCount += 1
                }
            } else {
                // New record from remote
                try save(remote, updateTimestamp: false, notifySync: false)
                updatedCount += 1
            }
        }

        Self.logger.info("Applied \(updatedCount) remote changes to \(storeName)")
        return updatedCount
    }

    /// Purge soft-deleted records older than a given date
    /// - Parameter olderThan: Date threshold
    /// - Returns: Number of records purged
    @discardableResult
    mutating func purgeTombstones(olderThan date: Date) throws -> Int {
        let storeName = self.storeName
        let toPurge = records.values.filter { $0.isDeleted && $0.modifiedAt < date }
        guard !toPurge.isEmpty else { return 0 }
        var purgedCount = 0

        for record in toPurge {
            do {
                try hardDelete(id: record.id)
                purgedCount += 1
            } catch {
                // One file the OS will not unlink (a TCC denial on the
                // non-sandboxed macOS build, say) must not strand every
                // later tombstone behind it; the next launch retries.
                let recordIDString = record.id.uuidString
                let desc = error.localizedDescription
                Self.logger.error("Failed to purge tombstone \(storeName)/\(recordIDString): \(desc)")
            }
        }

        Self.logger.info("Purged \(purgedCount) tombstones from \(storeName)")
        return purgedCount
    }

    /// Drop tombstone files that have outlived `tombstoneRetention`.
    ///
    /// Runs once per store at launch, which is where each of the three
    /// managers builds its store. Without it every profile, known host and
    /// identity the user has ever deleted stays on disk — and in `allRecords`,
    /// the set pushed to CloudKit — for the life of the install.
    ///
    /// Deliberately local only: the CloudKit copy of the tombstone is left
    /// alone. It is a few hundred bytes, it is the durable record of the
    /// deletion, and it is what re-deletes the record on a device that
    /// reappears after any offline period. Removing it server-side is the one
    /// change that could resurrect a deleted profile or host key, so a purged
    /// record that comes back on a full re-fetch comes back as a tombstone and
    /// is dropped again on the next launch.
    private mutating func purgeExpiredTombstones() {
        // A failed listing left `records` empty; there is nothing to purge and
        // nothing to conclude from the emptiness.
        guard !lastLoadFailed else { return }
        _ = try? purgeTombstones(olderThan: Date().addingTimeInterval(-Self.tombstoneRetention))
    }

    /// Reload all records from disk
    mutating func reload() {
        records.removeAll()
        loadAllRecords()
    }

    // MARK: - Private Helpers

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func createDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            Self.logger.error("Failed to create directory for \(self.storeName): \(error.localizedDescription)")
        }
    }

    private mutating func loadAllRecords() {
        let storeName = self.storeName
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            lastLoadFailed = false
        } catch {
            // On the non-sandboxed macOS build this directory lives in the
            // real ~/Documents, which is TCC-protected — a denied or racing
            // grant surfaces here as NSCocoaErrorDomain 257 / EPERM, not as
            // a missing directory.
            lastLoadFailed = true
            let nsError = error as NSError
            let path = directoryURL.path
            let dirExists = FileManager.default.fileExists(atPath: path)
            let domain = nsError.domain
            let code = nsError.code
            let desc = nsError.localizedDescription
            Self.logger.error("Failed to list \(storeName) at \(path) (directory exists: \(dirExists)): \(domain) \(code) — \(desc)")
            return
        }

        var loadedCount = 0
        var errorCount = 0

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let record = try decoder.decode(T.self, from: data)
                records[record.id] = record
                loadedCount += 1
            } catch {
                let fileName = fileURL.lastPathComponent
                let desc = error.localizedDescription
                Self.logger.error("Failed to load record \(storeName)/\(fileName): \(desc)")
                errorCount += 1
            }
        }

        Self.logger.info("Loaded \(loadedCount) records from \(storeName) (\(errorCount) errors)")
    }

    private func writeAtomically(data: Data, to url: URL) throws {
        // `.atomic` writes a sibling temp file and renames it over the
        // destination in one step. The previous implementation wrote its own
        // hidden `.<uuid>.tmp`, then removed the destination and moved the temp
        // into place: a crash (or a throwing move) between the unlink and the
        // rename left the record on disk only under a hidden name that
        // loadAllRecords skips, permanently losing a host-key trust entry,
        // identity metadata or a connection profile. Do not reintroduce the
        // remove/move dance.
        try data.write(to: url, options: [.atomic])
    }
}

// MARK: - Convenience Extensions

extension SyncableFileStore {
    /// Count of active (non-deleted) records
    var activeCount: Int {
        records.values.filter { !$0.isDeleted }.count
    }
}
