//
//  CloudKitSyncable.swift
//  shell
//
//  Fork-specific CloudKit record schema (spec section 6). Four record types
//  live in the private database: SSH profiles, public SSH identity metadata,
//  known hosts, and app settings.
//
//  Nothing secret is ever written here. Passwords and synchronizable private
//  keys live in the iCloud Keychain; Secure Enclave private keys never leave
//  the device that generated them.
//

import Foundation
import CloudKit
import Crypto
import os.log

/// Deterministic CloudKit record name helper
enum CloudKitRecordName {
    static func make(recordType: String, identity: String) -> String {
        let data = Data(identity.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(recordType)_\(hex)"
    }

    static func recordType(from recordName: String) -> String? {
        recordName.split(separator: "_", maxSplits: 1).first.map(String.init)
    }
}

/// Protocol for types that can be converted to/from CKRecord
protocol CloudKitSyncable: SyncableRecord {
    /// CloudKit record type name
    static var recordType: String { get }

    /// Current schema version for this record type
    static var schemaVersion: Int { get }

    /// Convert this record to a CKRecord
    func toCKRecord() -> CKRecord

    /// Deterministic record name for this record
    static func recordName(for record: Self) -> String

    /// Apply the record fields to an existing CKRecord (used for conflict resolution)
    func apply(to record: CKRecord)

    /// Create an instance from a CKRecord
    static func from(_ record: CKRecord) -> Self?
}

extension CloudKitSyncable {
    func toCKRecord() -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: Self.recordName(for: self),
            zoneID: CloudKitSyncSettings.zoneID
        )
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        apply(to: record)
        return record
    }
}

// MARK: - SSHProfile + CloudKitSyncable

extension SSHProfile: CloudKitSyncable {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "CloudKitProfile")

    static var recordType: String { "ShellSSHProfile" }
    static var schemaVersion: Int { 1 }

    static func recordName(for record: SSHProfile) -> String {
        CloudKitRecordName.make(recordType: recordType, identity: record.id.uuidString)
    }

    func apply(to record: CKRecord) {
        record["profileID"] = id.uuidString
        record["name"] = name
        record["host"] = sshConfig.host
        record["port"] = Int64(sshConfig.port)
        record["username"] = sshConfig.username
        record["authType"] = Self.authTypeString(sshConfig.authMethod)
        record["identityID"] = sshConfig.authMethod.keyID?.uuidString
        record["jumpHost"] = Self.encodeJumpHost(sshConfig.jumpHost)
        record["terminalType"] = sshConfig.terminalType
        record["tmuxMode"] = sshConfig.tmuxMode.rawValue
        record["tmuxSessionName"] = sshConfig.tmuxSessionName
        record["modifiedAt"] = modifiedAt
        record["deleted"] = isDeleted ? 1 : 0
        record["createdAt"] = createdAt
        record["schemaVersion"] = Int64(Self.schemaVersion)
        record["deviceID"] = CloudKitSyncSettings.deviceID
    }

    static func from(_ record: CKRecord) -> SSHProfile? {
        guard let profileIDString = record["profileID"] as? String,
              let profileID = UUID(uuidString: profileIDString),
              let name = record["name"] as? String,
              let host = record["host"] as? String,
              let username = record["username"] as? String else {
            logger.warning("Skipping malformed profile record \(record.recordID.recordName, privacy: .public)")
            return nil
        }

        let port = Int(record["port"] as? Int64 ?? 22)
        var config = SSHConfig(host: host, port: port, username: username)
        config.authMethod = authMethod(
            from: record["authType"] as? String,
            identityID: record["identityID"] as? String
        )
        config.jumpHost = decodeJumpHost(record["jumpHost"] as? Data)
        config.terminalType = record["terminalType"] as? String
        let mode = TmuxMode(rawValue: record["tmuxMode"] as? String ?? "") ?? .off
        config.tmuxMode = mode
        config.tmuxSessionName = record["tmuxSessionName"] as? String

        let createdAt = record["createdAt"] as? Date ?? Date()
        let fieldModifiedAt = record["modifiedAt"] as? Date ?? createdAt
        let modifiedAt = record.modificationDate ?? fieldModifiedAt
        let isDeleted = (record["deleted"] as? Int64 ?? 0) == 1

        return SSHProfile(
            id: profileID,
            name: name,
            sshConfig: config,
            modifiedAt: modifiedAt,
            isDeleted: isDeleted,
            createdAt: createdAt
        )
    }

    // MARK: Auth encoding
    //
    // Only the SHAPE of the auth method travels: which kind it is, and the
    // identity UUID for key auth. Passwords stay in the Keychain.

    private static func authTypeString(_ method: SSHConfig.AuthMethod) -> String {
        switch method {
        case .password, .savedPassword: return "password"
        case .key: return "key"
        case .keyboardInteractive: return "keyboardInteractive"
        case .unknown(let rawType): return rawType
        }
    }

    private static func authMethod(from type: String?, identityID: String?) -> SSHConfig.AuthMethod {
        switch type {
        case "password":
            // A synced profile never carries the secret; resolve it locally.
            return .savedPassword
        case "key":
            guard let identityID, let uuid = UUID(uuidString: identityID) else {
                return .savedPassword
            }
            return .key(uuid)
        case "keyboardInteractive":
            return .keyboardInteractive
        case let other?:
            return .unknown(rawType: other)
        case nil:
            return .savedPassword
        }
    }

    private static func encodeJumpHost(_ jumpHost: SSHConfig.JumpHostConfig?) -> Data? {
        guard let jumpHost else { return nil }
        // Encoding drops any inline password: `AuthMethod.encode` never emits one.
        return try? JSONEncoder().encode(jumpHost)
    }

    private static func decodeJumpHost(_ data: Data?) -> SSHConfig.JumpHostConfig? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(SSHConfig.JumpHostConfig.self, from: data)
    }
}

// MARK: - SSHIdentityMetadata

/// The public half of an SSH identity, safe to put in CloudKit: key type,
/// fingerprint, public key blob, and the attached OpenSSH user certificate.
///
/// `secureEnclaveDeviceBound` marks identities whose private key is held in
/// this device's Secure Enclave. Those keys can never move; on another device
/// the identity shows as unavailable rather than silently failing to sign.
struct SSHIdentityMetadata: Codable, Identifiable, Hashable, SyncableRecord, Sendable {
    let id: UUID
    var name: String
    var keyType: String
    var fingerprint: String
    var storageType: String
    /// SSH wire-format public key blob (public data).
    var publicKey: Data?
    /// OpenSSH user certificate blob, if one is attached (public data).
    var certificate: Data?
    var secureEnclaveDeviceBound: Bool

    var modifiedAt: Date
    var isDeleted: Bool

    init(
        id: UUID,
        name: String,
        keyType: String,
        fingerprint: String,
        storageType: String,
        publicKey: Data?,
        certificate: Data?,
        secureEnclaveDeviceBound: Bool,
        modifiedAt: Date = Date(),
        isDeleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.storageType = storageType
        self.publicKey = publicKey
        self.certificate = certificate
        self.secureEnclaveDeviceBound = secureEnclaveDeviceBound
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
    }

    /// Project the public metadata out of a local identity.
    init(identity: SSHKey) {
        self.init(
            id: identity.id,
            name: identity.name,
            keyType: identity.keyType.rawValue,
            fingerprint: identity.fingerprint,
            storageType: identity.storageLevel.rawValue,
            publicKey: identity.publicKeyBlob,
            certificate: identity.userCertificate?.certificateBlob,
            secureEnclaveDeviceBound: identity.secureEnclaveInfo != nil,
            modifiedAt: identity.securityModifiedDate ?? identity.createdDate,
            isDeleted: false
        )
    }
}

extension SSHIdentityMetadata: CloudKitSyncable {
    static var recordType: String { "ShellSSHIdentityMetadata" }
    static var schemaVersion: Int { 1 }

    static func recordName(for record: SSHIdentityMetadata) -> String {
        CloudKitRecordName.make(recordType: recordType, identity: record.id.uuidString)
    }

    func apply(to record: CKRecord) {
        record["identityID"] = id.uuidString
        record["name"] = name
        record["keyType"] = keyType
        record["fingerprint"] = fingerprint
        record["storageType"] = storageType
        record["publicKey"] = publicKey
        record["certificate"] = certificate
        record["secureEnclaveDeviceBound"] = secureEnclaveDeviceBound ? 1 : 0
        record["modifiedAt"] = modifiedAt
        record["deleted"] = isDeleted ? 1 : 0
        record["schemaVersion"] = Int64(Self.schemaVersion)
        record["deviceID"] = CloudKitSyncSettings.deviceID
    }

    static func from(_ record: CKRecord) -> SSHIdentityMetadata? {
        guard let identityIDString = record["identityID"] as? String,
              let identityID = UUID(uuidString: identityIDString),
              let name = record["name"] as? String,
              let keyType = record["keyType"] as? String,
              let fingerprint = record["fingerprint"] as? String else {
            return nil
        }

        let fieldModifiedAt = record["modifiedAt"] as? Date ?? Date()
        return SSHIdentityMetadata(
            id: identityID,
            name: name,
            keyType: keyType,
            fingerprint: fingerprint,
            storageType: record["storageType"] as? String ?? KeyStorageLevel.deviceOnly.rawValue,
            publicKey: record["publicKey"] as? Data,
            certificate: record["certificate"] as? Data,
            secureEnclaveDeviceBound: (record["secureEnclaveDeviceBound"] as? Int64 ?? 0) == 1,
            modifiedAt: record.modificationDate ?? fieldModifiedAt,
            isDeleted: (record["deleted"] as? Int64 ?? 0) == 1
        )
    }
}

// MARK: - KnownHost + CloudKitSyncable

extension KnownHost: CloudKitSyncable {
    static var recordType: String { "ShellKnownHost" }
    static var schemaVersion: Int { 1 }

    static func recordName(for record: KnownHost) -> String {
        CloudKitRecordName.make(recordType: recordType, identity: record.legacyId)
    }

    func apply(to record: CKRecord) {
        record["hostID"] = id.uuidString
        record["legacyId"] = legacyId
        record["hostname"] = hostname
        record["port"] = Int64(port)
        record["publicKey"] = publicKeyData
        record["keyType"] = keyType
        record["fingerprint"] = fingerprint
        record["firstSeen"] = firstSeen
        record["lastSeen"] = lastSeen
        record["modifiedAt"] = modifiedAt
        record["deleted"] = isDeleted ? 1 : 0
        record["schemaVersion"] = Int64(Self.schemaVersion)
        record["deviceID"] = CloudKitSyncSettings.deviceID
    }

    static func from(_ record: CKRecord) -> KnownHost? {
        guard let hostIDString = record["hostID"] as? String,
              let hostID = UUID(uuidString: hostIDString),
              let hostname = record["hostname"] as? String,
              let publicKeyData = record["publicKey"] as? String,
              let keyType = record["keyType"] as? String,
              let fingerprint = record["fingerprint"] as? String else {
            return nil
        }

        let port = Int(record["port"] as? Int64 ?? 22)
        let firstSeen = record["firstSeen"] as? Date ?? Date()
        let lastSeen = record["lastSeen"] as? Date ?? firstSeen
        let fieldModifiedAt = record["modifiedAt"] as? Date ?? lastSeen
        let modifiedAt = record.modificationDate ?? fieldModifiedAt
        let isDeleted = (record["deleted"] as? Int64 ?? 0) == 1

        return KnownHost(
            id: hostID,
            hostname: hostname,
            port: port,
            publicKeyData: publicKeyData,
            keyType: keyType,
            fingerprint: fingerprint,
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            modifiedAt: modifiedAt,
            isDeleted: isDeleted
        )
    }
}
