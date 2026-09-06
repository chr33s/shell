//
//  SyncableRecord.swift
//  shell
//
//  Protocol for records that can be synced via CloudKit
//

import Foundation

/// Protocol for types that can be synced via CloudKit
///
/// Conforming types must have:
/// - A stable UUID identifier that persists across updates (via Identifiable)
/// - A modifiedAt timestamp for last-write-wins conflict resolution
/// - An isDeleted flag for soft deletes (sync tombstones)
protocol SyncableRecord: Codable, Identifiable, Hashable where ID == UUID {
    /// Timestamp of the last modification (for conflict resolution)
    var modifiedAt: Date { get set }

    /// Soft delete flag - deleted records are kept for sync tombstones
    var isDeleted: Bool { get set }
}

/// Operation types for sync queue
enum SyncOperation: String, Codable, Sendable {
    case create
    case update
    case delete
}

/// A pending change waiting to be synced
struct PendingChange: Codable, Identifiable, Sendable {
    let id: UUID
    let recordType: String
    let recordID: String
    let operation: SyncOperation
    let payload: Data
    let createdAt: Date
    var retryCount: Int

    init(recordType: String, recordID: String, operation: SyncOperation, payload: Data) {
        self.id = UUID()
        self.recordType = recordType
        self.recordID = recordID
        self.operation = operation
        self.payload = payload
        self.createdAt = Date()
        self.retryCount = 0
    }
}
