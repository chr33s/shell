import Foundation

/// Represents a known SSH host and its trusted public key
struct KnownHost: Codable, Identifiable, Equatable, Hashable, SyncableRecord {
    /// Stable unique identifier for sync
    let id: UUID

    /// hostname:port identity used for host lookup and as the CloudKit record name.
    var legacyId: String { "\(hostname):\(port)" }

    /// Hostname or IP address
    let hostname: String

    /// SSH port (typically 22)
    let port: Int

    /// Base64-encoded public key data
    let publicKeyData: String

    /// Key type (e.g., "ed25519", "ecdsa-sha2-nistp256", "ssh-rsa")
    let keyType: String

    /// SHA256 fingerprint in colon-separated hex format (e.g., "aa:bb:cc:...")
    let fingerprint: String

    /// Timestamp when this host was first added
    let firstSeen: Date

    /// Timestamp when this host key was last verified
    var lastSeen: Date

    /// Timestamp when this record was last modified (for sync)
    var modifiedAt: Date

    /// Soft delete flag for sync tombstones
    var isDeleted: Bool

    /// Display-friendly host identifier
    var displayName: String {
        port == 22 ? hostname : "\(hostname):\(port)"
    }

    /// Truncated fingerprint for list display (first 24 characters)
    var shortFingerprint: String {
        guard fingerprint.count > 24 else { return fingerprint }
        return String(fingerprint.prefix(24)) + "..."
    }

    /// Full fingerprint with SHA256 prefix for display
    var fullFingerprint: String {
        fingerprint.hasPrefix("SHA256:") ? fingerprint : "SHA256:\(fingerprint)"
    }

    /// Create a new known host entry
    init(hostname: String, port: Int, publicKeyData: String, keyType: String, fingerprint: String,
         firstSeen: Date = Date(), lastSeen: Date = Date()) {
        self.id = UUID()
        self.hostname = hostname
        self.port = port
        self.publicKeyData = publicKeyData
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.modifiedAt = Date()
        self.isDeleted = false
    }

    /// Create with an explicit ID (identity-preserving update and sync).
    init(id: UUID, hostname: String, port: Int, publicKeyData: String, keyType: String, fingerprint: String,
         firstSeen: Date = Date(), lastSeen: Date = Date(), modifiedAt: Date? = nil, isDeleted: Bool = false) {
        self.id = id
        self.hostname = hostname
        self.port = port
        self.publicKeyData = publicKeyData
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.modifiedAt = modifiedAt ?? Date()
        self.isDeleted = isDeleted
    }

    /// Update the last seen timestamp
    mutating func updateLastSeen() {
        lastSeen = Date()
        modifiedAt = Date()
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: KnownHost, rhs: KnownHost) -> Bool {
        lhs.id == rhs.id &&
        lhs.hostname == rhs.hostname &&
        lhs.port == rhs.port &&
        lhs.publicKeyData == rhs.publicKeyData &&
        lhs.keyType == rhs.keyType &&
        lhs.fingerprint == rhs.fingerprint &&
        lhs.firstSeen == rhs.firstSeen &&
        lhs.lastSeen == rhs.lastSeen &&
        lhs.modifiedAt == rhs.modifiedAt &&
        lhs.isDeleted == rhs.isDeleted
    }
}

/// Uniquely identifies a host by hostname and port
struct HostIdentifier: Hashable, Codable {
    let hostname: String
    let port: Int

    init(hostname: String, port: Int) {
        self.hostname = hostname
        self.port = port
    }
}
