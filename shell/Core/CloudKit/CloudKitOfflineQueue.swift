//
//  CloudKitOfflineQueue.swift
//  shell
//
//  Manages offline queue for pending CloudKit changes
//

import Foundation
import Observation
import os.log

/// Manages a queue of pending changes for when the device is offline
@MainActor
@Observable
final class CloudKitOfflineQueue {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "CloudKitOfflineQueue")

    /// Pending changes waiting to be synced
    private(set) var pendingChanges: [PendingChange] = []

    /// File URL for persisting the queue
    private let queueURL: URL

    /// JSON encoder
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// JSON decoder
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.queueURL = documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("pending_changes.json")

        load()
    }

    /// Number of pending changes
    var count: Int {
        pendingChanges.count
    }

    /// Whether there are pending changes
    var hasPendingChanges: Bool {
        !pendingChanges.isEmpty
    }

    /// Add a change to the queue
    func enqueue(_ change: PendingChange) {
        // Check for existing change for the same record
        if let existingIndex = pendingChanges.firstIndex(where: {
            $0.recordType == change.recordType && $0.recordID == change.recordID
        }) {
            // Replace with newer change (last-write-wins)
            pendingChanges[existingIndex] = change
        } else {
            pendingChanges.append(change)
        }

        persist()
        Self.logger.debug("Enqueued change: \(change.recordType)/\(change.recordID) (\(change.operation.rawValue))")
    }

    /// Enqueue a syncable record change
    func enqueue<T: CloudKitSyncable>(_ record: T, operation: SyncOperation) {
        guard let payload = try? encoder.encode(record) else {
            Self.logger.error("Failed to encode record for offline queue")
            return
        }

        let change = PendingChange(
            recordType: T.recordType,
            recordID: T.recordName(for: record),
            operation: operation,
            payload: payload
        )
        enqueue(change)
    }

    /// Remove a change from the queue (after successful sync)
    func dequeue(_ id: UUID) {
        pendingChanges.removeAll { $0.id == id }
        persist()
        Self.logger.debug("Dequeued change: \(id.uuidString)")
    }

    /// Remove all changes for a specific record
    func dequeueRecord(_ recordID: String) {
        pendingChanges.removeAll { $0.recordID == recordID }
        persist()
    }

    /// Get the next batch of changes to sync (oldest first)
    func nextBatch(limit: Int = 100) -> [PendingChange] {
        Array(pendingChanges.sorted { $0.createdAt < $1.createdAt }.prefix(limit))
    }

    /// Increment retry count for a change
    func incrementRetry(_ id: UUID) {
        if let index = pendingChanges.firstIndex(where: { $0.id == id }) {
            pendingChanges[index].retryCount += 1
            persist()
        }
    }

    /// Drop every queued change of one record type
    func removeAll(recordType: String) {
        pendingChanges.removeAll { $0.recordType == recordType }
        persist()
    }

    /// Clear all pending changes
    func clearAll() {
        pendingChanges.removeAll()
        persist()
        Self.logger.info("Cleared all pending changes")
    }

    /// Remove changes that have exceeded max retries
    func pruneFailedChanges(maxRetries: Int = 10) {
        let beforeCount = pendingChanges.count
        pendingChanges.removeAll { $0.retryCount > maxRetries }

        if pendingChanges.count < beforeCount {
            persist()
            Self.logger.warning("Pruned \(beforeCount - self.pendingChanges.count) failed changes")
        }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: queueURL.path) else {
            pendingChanges = []
            return
        }

        do {
            let data = try Data(contentsOf: queueURL)
            pendingChanges = try decoder.decode([PendingChange].self, from: data)
            Self.logger.info("Loaded \(self.pendingChanges.count) pending changes")
        } catch {
            Self.logger.error("Failed to load offline queue: \(error.localizedDescription)")
            pendingChanges = []
        }
    }

    private func persist() {
        do {
            // Ensure directory exists
            let directory = queueURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let data = try encoder.encode(pendingChanges)
            try data.write(to: queueURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to persist offline queue: \(error.localizedDescription)")
        }
    }
}
