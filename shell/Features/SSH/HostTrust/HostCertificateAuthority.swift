import Foundation

/// A trusted OpenSSH host certificate authority.
///
/// When a server presents a host certificate (`*-cert-v01@openssh.com`) signed
/// by one of these CAs, and the connection hostname matches the CA's
/// `hostPatterns`, the host key is validated automatically without prompting —
/// mirroring an OpenSSH `@cert-authority` line in `known_hosts`.
struct HostCertificateAuthority: Codable, Identifiable, Equatable, Hashable, SyncableRecord {
    /// Stable unique identifier for sync.
    let id: UUID

    /// User-friendly label (e.g. "Acme Corp Host CA").
    var name: String

    /// The CA public key in OpenSSH wire form: "<keytype> <base64>".
    /// (Any trailing comment from the pasted line is stripped on import.)
    let publicKeyOpenSSH: String

    /// Algorithm identifier of the CA key (e.g. "ssh-ed25519"). Display only.
    let keyType: String

    /// SHA256 fingerprint of the CA key, colon-separated hex prefixed "SHA256:".
    let fingerprint: String

    /// Hostname patterns this CA is trusted for (OpenSSH glob: `*`, `?`,
    /// comma-separated). `["*"]` trusts the CA for every host.
    var hostPatterns: [String]

    /// Timestamp when this CA was added.
    let addedDate: Date

    /// Timestamp when this record was last modified (for sync).
    var modifiedAt: Date

    /// Soft delete flag for sync tombstones.
    var isDeleted: Bool

    /// Display-friendly summary of the host patterns.
    var patternsDisplay: String {
        hostPatterns.isEmpty ? "—" : hostPatterns.joined(separator: ", ")
    }

    /// Full fingerprint with SHA256 prefix for display.
    var fullFingerprint: String {
        fingerprint.hasPrefix("SHA256:") ? fingerprint : "SHA256:\(fingerprint)"
    }

    /// Create a new host CA entry.
    init(name: String,
         publicKeyOpenSSH: String,
         keyType: String,
         fingerprint: String,
         hostPatterns: [String],
         addedDate: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.hostPatterns = hostPatterns
        self.addedDate = addedDate
        self.modifiedAt = Date()
        self.isDeleted = false
    }

    /// Create with explicit ID (for sync / updates).
    init(id: UUID,
         name: String,
         publicKeyOpenSSH: String,
         keyType: String,
         fingerprint: String,
         hostPatterns: [String],
         addedDate: Date,
         modifiedAt: Date? = nil,
         isDeleted: Bool = false) {
        self.id = id
        self.name = name
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.hostPatterns = hostPatterns
        self.addedDate = addedDate
        self.modifiedAt = modifiedAt ?? Date()
        self.isDeleted = isDeleted
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HostCertificateAuthority, rhs: HostCertificateAuthority) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.publicKeyOpenSSH == rhs.publicKeyOpenSSH &&
        lhs.keyType == rhs.keyType &&
        lhs.fingerprint == rhs.fingerprint &&
        lhs.hostPatterns == rhs.hostPatterns &&
        lhs.addedDate == rhs.addedDate &&
        lhs.modifiedAt == rhs.modifiedAt &&
        lhs.isDeleted == rhs.isDeleted
    }
}
