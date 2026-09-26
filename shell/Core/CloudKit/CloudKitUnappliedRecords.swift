//
//  CloudKitUnappliedRecords.swift
//  shell
//
//  Durable journal of fetched zone changes that could not be applied locally
//  (SYNC-03). Recording them lets the zone checkpoint advance past a record
//  that fails every time — holding the checkpoint instead re-fetched the whole
//  range on every sync, forever, while the sync still reported success. Each
//  sync re-reads the journaled records by ID and applies the server's current
//  version (or its deletion), so nothing is lost and the checkpoint never
//  stalls.
//

import Foundation

struct CloudKitUnappliedRecord: Codable, Hashable, Sendable {
    let recordName: String
    /// Nil when the record failed to download, so its type was never seen.
    let recordType: String?
}

struct CloudKitUnappliedRecords {
    static let defaultsKey = "cloudKitUnappliedZoneRecords"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var records: Set<CloudKitUnappliedRecord> {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([CloudKitUnappliedRecord].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    /// Replace the journal. Must be called before the checkpoint that skips
    /// these records is persisted.
    func replace(with records: Set<CloudKitUnappliedRecord>) {
        guard !records.isEmpty else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let sorted = records.sorted { ($0.recordName, $0.recordType ?? "") < ($1.recordName, $1.recordType ?? "") }
        if let data = try? JSONEncoder().encode(sorted) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func add(_ newRecords: Set<CloudKitUnappliedRecord>) {
        guard !newRecords.isEmpty else { return }
        replace(with: records.union(newRecords))
    }

    /// Drop everything — the checkpoint was reset for a new context (account
    /// switch, sync disabled), so a full refetch supersedes the journal.
    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
