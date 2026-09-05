//
//  DeviceKeyOverride.swift
//  shell
//
//  Per-device key overrides for synced profiles/history entries.
//  Stored locally (never synced) — allows different devices to use different
//  physical keys for the same connection profile.
//

import Foundation

/// Target for a device key override — either a saved profile or a connection identity string
enum OverrideTarget: Codable, Hashable, Sendable {
    /// A saved connection profile (by UUID)
    case profile(UUID)
    /// A connection identity string ("ssh:user@host:port" from history)
    case connectionIdentity(String)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, profileID, identity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "profile":
            let id = try container.decode(UUID.self, forKey: .profileID)
            self = .profile(id)
        case "connectionIdentity":
            let identity = try container.decode(String.self, forKey: .identity)
            self = .connectionIdentity(identity)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown override target type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .profile(let id):
            try container.encode("profile", forKey: .type)
            try container.encode(id, forKey: .profileID)
        case .connectionIdentity(let identity):
            try container.encode("connectionIdentity", forKey: .type)
            try container.encode(identity, forKey: .identity)
        }
    }
}

/// A per-device override specifying which local key to use for a connection.
/// Key selection only — auth method type stays as the profile/history defines.
struct DeviceKeyOverride: Codable, Sendable, Identifiable {
    var id: UUID = UUID()

    /// What this override applies to
    let target: OverrideTarget

    /// Override for primary auth key (nil = no override, use profile's key)
    var targetKeyID: UUID?

    /// Override for fallback key chain
    var targetFallbackKeyIDs: [UUID]?

    /// Override for jump host key
    var jumpHostKeyID: UUID?

    /// Override for jump host fallback chain
    var jumpHostFallbackKeyIDs: [UUID]?

    /// When this override was created
    var createdAt: Date

    /// Profile's modifiedAt when override was created (for staleness detection)
    var sourceModifiedAt: Date?

    /// User note (e.g., "Using work YubiKey")
    var note: String?
}
