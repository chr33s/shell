//
//  ConnectionProfile.swift
//  shell
//
//  The saved SSH profile model (spec section 3). `ConnectionProfile` is kept
//  as an alias so existing call sites read naturally; `SSHProfile` is the
//  spec name and the one to prefer in new code.
//

import Foundation

/// A user-saved SSH connection profile.
///
/// Everything about the endpoint and how to reach it lives in `sshConfig`;
/// this type adds identity, naming, sync metadata, and usage stats. The
/// profile references an identity by UUID (through `SSHConfig.authMethod`)
/// and never duplicates certificate or private-key material.
struct SSHProfile: Codable, Identifiable, Hashable, SyncableRecord {
    let id: UUID

    /// User-assigned display name
    var name: String

    /// SSH connection configuration: host, port, username, auth, jump host,
    /// `TERM`, and the tmux selection.
    var sshConfig: SSHConfig

    // MARK: - SyncableRecord Conformance

    /// Timestamp of the last modification (for conflict resolution)
    var modifiedAt: Date

    /// Soft delete flag - deleted records are kept for sync tombstones
    var isDeleted: Bool

    // MARK: - Additional Metadata

    /// When this profile was created
    var createdAt: Date

    /// When this profile was last used for a connection
    var lastUsedAt: Date?

    /// Number of times this profile has been used
    var useCount: Int

    // MARK: - Initialization

    init(name: String, sshConfig: SSHConfig) {
        self.init(id: UUID(), name: name, sshConfig: sshConfig)
    }

    /// Create a profile with an explicit ID (for migration and sync)
    init(
        id: UUID,
        name: String,
        sshConfig: SSHConfig,
        modifiedAt: Date? = nil,
        isDeleted: Bool = false,
        createdAt: Date? = nil,
        lastUsedAt: Date? = nil,
        useCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.sshConfig = sshConfig
        self.modifiedAt = modifiedAt ?? Date()
        self.isDeleted = isDeleted
        self.createdAt = createdAt ?? Date()
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, sshConfig
        case modifiedAt, isDeleted, createdAt, lastUsedAt, useCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        sshConfig = try container.decode(SSHConfig.self, forKey: .sshConfig)

        let now = Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? now
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        useCount = try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(sshConfig, forKey: .sshConfig)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try container.encode(useCount, forKey: .useCount)
    }

    // MARK: - Display

    /// "user@host" or "user@host:port" when the port is non-default.
    var displayString: String {
        sshConfig.port == 22
            ? "\(sshConfig.username)@\(sshConfig.host)"
            : "\(sshConfig.username)@\(sshConfig.host):\(sshConfig.port)"
    }

    // MARK: - Matching

    /// Matches this profile against a search string
    func matches(_ searchText: String) -> Bool {
        let needle = searchText.lowercased()
        if needle.isEmpty { return true }
        if name.lowercased().contains(needle) { return true }
        if sshConfig.host.lowercased().contains(needle) { return true }
        if sshConfig.username.lowercased().contains(needle) { return true }
        return false
    }
}

/// The name most existing call sites use for ``SSHProfile``.
typealias ConnectionProfile = SSHProfile
