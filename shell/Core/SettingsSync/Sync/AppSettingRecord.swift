//
//  AppSettingRecord.swift
//  shell
//
//  One CloudKit record per settings key. The payload is a self-describing
//  CodableValue JSON string, so adding a setting never changes the schema.
//

import Foundation
import CloudKit
import Crypto
import os

struct AppSettingRecord: CloudKitSyncable {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "AppSettingRecord")
    /// Deterministic per key so `SyncableRecord` identity is stable across devices.
    let id: UUID
    let key: String
    /// Nil when `isDeleted` (tombstone = reset to default).
    var payload: CodableValue?
    var modifiedAt: Date
    var isDeleted: Bool
    var deviceID: String

    static var recordType: String { "AppSetting" }
    static var schemaVersion: Int { 1 }

    /// CKRecord field limit is 1 MB; refuse anything close to it.
    static let maxPayloadBytes = 900_000
    /// Remote timestamps ahead of the server clock by more than this are clamped.
    static let futureSkewTolerance: TimeInterval = 300

    init(key: String, payload: CodableValue?, modifiedAt: Date, isDeleted: Bool, deviceID: String) {
        self.id = Self.deterministicID(for: key)
        self.key = key
        self.payload = payload
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
        self.deviceID = deviceID
    }

    static func recordName(for record: AppSettingRecord) -> String {
        CloudKitRecordName.make(recordType: recordType, identity: record.key)
    }

    /// First 16 bytes of SHA256(key) with RFC 4122 version 5 and variant bits set.
    static func deterministicID(for key: String) -> UUID {
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Payload encoding

    nonisolated static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    nonisolated static func encodePayload(_ value: CodableValue) -> String? {
        guard let data = try? payloadEncoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decodePayload(_ string: String) -> CodableValue? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CodableValue.self, from: data)
    }

    /// Stable content hash used to suppress re-pushing unchanged values.
    nonisolated static func contentHash(of value: CodableValue?) -> String {
        guard let value, let json = encodePayload(value) else { return "tombstone" }
        let digest = SHA256.hash(data: Data(json.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var contentHash: String { Self.contentHash(of: isDeleted ? nil : payload) }

    var payloadSizeOK: Bool {
        guard let payload, let json = Self.encodePayload(payload) else { return true }
        return json.utf8.count <= Self.maxPayloadBytes
    }

    // MARK: - CloudKitSyncable

    func apply(to record: CKRecord) {
        record["key"] = key as CKRecordValue
        if !isDeleted, let payload, let json = Self.encodePayload(payload) {
            record["payload"] = json as CKRecordValue
        } else {
            record["payload"] = nil
        }
        record["modifiedAt"] = modifiedAt as CKRecordValue
        record["isDeleted"] = (isDeleted ? 1 : 0) as CKRecordValue
        record["schemaVersion"] = Int64(Self.schemaVersion) as CKRecordValue
        record["deviceID"] = deviceID as CKRecordValue
    }

    static func from(_ record: CKRecord) -> AppSettingRecord? {
        guard record.recordType == recordType, let key = record["key"] as? String else { return nil }
        let isDeleted = (record["isDeleted"] as? Int64 ?? 0) != 0
        // A live record with no readable payload is corrupt, not a reset.
        var payload: CodableValue?
        if !isDeleted {
            guard let json = record["payload"] as? String, let decoded = decodePayload(json) else {
                logger.error("Ignoring \(key, privacy: .public): live record has no decodable payload")
                return nil
            }
            payload = decoded
        }
        // The field is the edit time on the writing device; server time would
        // let "last to reach the server" win, which is wrong for offline edits.
        let serverDate = record.modificationDate ?? Date()
        let field = record["modifiedAt"] as? Date ?? serverDate
        let modifiedAt = min(field, serverDate.addingTimeInterval(futureSkewTolerance))
        return AppSettingRecord(
            key: key,
            payload: payload,
            modifiedAt: modifiedAt,
            isDeleted: isDeleted,
            deviceID: record["deviceID"] as? String ?? ""
        )
    }
}
