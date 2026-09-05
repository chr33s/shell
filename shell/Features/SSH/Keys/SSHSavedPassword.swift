import Foundation

/// Represents metadata for a saved SSH password stored in the Keychain
/// The actual password is stored separately in Keychain, this just tracks metadata
nonisolated struct SSHSavedPassword: Codable, Identifiable, Hashable, Sendable {
    /// Unique identifier for the saved password entry
    let id: UUID

    /// The connection key this password is for (format: "host:port:username" lowercased)
    let connectionKey: String

    /// The hostname or IP address
    let host: String

    /// The port (default: 22)
    let port: Int

    /// The username
    let username: String

    /// Controls where/how the password is stored (device-only, backup, or iCloud sync)
    var storageLevel: KeyStorageLevel

    /// Controls when biometric/passcode authentication is required
    var authRequirement: KeyAuthRequirement

    /// Date when the password was first saved
    let createdDate: Date

    /// Date when the password was last updated
    var lastModifiedDate: Date

    /// Date when the password was last used successfully.
    ///
    /// Device-local and UI-only: deliberately NOT part of the Codable
    /// representation (see `CodingKeys`), so bumping it never re-writes the
    /// synchronizable Keychain metadata item. Re-touching that synced item
    /// would resurrect a password deleted on another device (iCloud Keychain
    /// resolves conflicts last-writer-wins). The value is sourced from a
    /// device-local store in `SSHPasswordManager` after each load.
    var lastUsedDate: Date?

    init(
        id: UUID = UUID(),
        host: String,
        port: Int = 22,
        username: String,
        storageLevel: KeyStorageLevel = .backupOnly,
        authRequirement: KeyAuthRequirement = .none
    ) {
        self.id = id
        self.connectionKey = Self.makeConnectionKey(host: host, port: port, username: username)
        self.host = host
        self.port = port
        self.username = username
        self.storageLevel = storageLevel
        self.authRequirement = authRequirement
        self.createdDate = Date()
        self.lastModifiedDate = Date()
        self.lastUsedDate = nil
    }

    /// Creates a connection key from host, port, and username
    /// Format: "host:port:username" (all lowercased for case-insensitive matching)
    static func makeConnectionKey(host: String, port: Int, username: String) -> String {
        "\(host.lowercased()):\(port):\(username.lowercased())"
    }

    /// Display name for UI (e.g., "user@host" or "user@host:2222")
    var displayName: String {
        if port == 22 {
            return "\(username)@\(host)"
        }
        return "\(username)@\(host):\(port)"
    }

    /// Short display name showing just the host
    var shortDisplayName: String {
        host
    }

    // MARK: - Codable (backward compatible)

    enum CodingKeys: String, CodingKey {
        case id, connectionKey, host, port, username
        case storageLevel, authRequirement
        case createdDate, lastModifiedDate
        // `lastUsedDate` is intentionally omitted — it is device-local and
        // must never be serialized into the synchronizable Keychain metadata.
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields
        id = try container.decode(UUID.self, forKey: .id)
        connectionKey = try container.decode(String.self, forKey: .connectionKey)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decode(String.self, forKey: .username)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        lastModifiedDate = try container.decode(Date.self, forKey: .lastModifiedDate)

        // Optional fields with defaults
        storageLevel = try container.decodeIfPresent(KeyStorageLevel.self, forKey: .storageLevel) ?? .backupOnly
        authRequirement = try container.decodeIfPresent(KeyAuthRequirement.self, forKey: .authRequirement) ?? .none

        // Device-local, populated by `SSHPasswordManager` after load — never
        // decoded from the (synchronizable) Keychain metadata blob. Old blobs
        // that still contain a `lastUsedDate` key decode fine; it is ignored.
        lastUsedDate = nil
    }
}
