import Foundation

// MARK: - Key Security Options

/// Controls where and how the key is stored in the keychain.
///
/// Spec vocabulary: `SSHKeyStorage`.
nonisolated enum KeyStorageLevel: String, Codable, CaseIterable, Sendable {
    /// Key stays on this device only - not included in backups or sync
    case deviceOnly
    /// Key is included in encrypted device backups but not synced to iCloud
    case backupOnly
    /// Key syncs across devices via iCloud Keychain
    case iCloudSync

    var displayName: String {
        switch self {
        case .deviceOnly: return String(localized: "This Device Only", comment: "Key storage: device only")
        case .backupOnly: return String(localized: "Include in Backups", comment: "Key storage: include in backups")
        case .iCloudSync: return String(localized: "Sync with iCloud", comment: "Key storage: iCloud sync")
        }
    }

    var description: String {
        switch self {
        case .deviceOnly:
            return String(localized: "Key stays on this device only. Not included in backups or sync. Lost if device is reset.", comment: "Key storage description: device only")
        case .backupOnly:
            return String(localized: "Key is included in encrypted device backups but not synced to iCloud.", comment: "Key storage description: include in backups")
        case .iCloudSync:
            return String(localized: "Key syncs across your devices via iCloud Keychain.", comment: "Key storage description: iCloud sync")
        }
    }

    var iconName: String {
        switch self {
        case .deviceOnly: return "iphone"
        case .backupOnly: return "externaldrive"
        case .iCloudSync: return "icloud"
        }
    }
}

/// Spec name for ``KeyStorageLevel``.
typealias SSHKeyStorage = KeyStorageLevel

/// Controls when biometric/passcode authentication is required to use the key
nonisolated enum KeyAuthRequirement: String, Codable, CaseIterable, Sendable {
    static let iCloudAuthenticationAdvisory = String(
        localized: "For iCloud-synced keys, Shell enforces this prompt before use; the synchronized Keychain item itself cannot use a device-bound access control.",
        comment: "Advisory explaining the app-level authentication gate for synchronized SSH keys"
    )

    /// No additional authentication required beyond device unlock
    case none
    /// Authenticate once per session (time-based expiry)
    case perSession
    /// Authenticate every time the key is used for signing
    case perUse

    var displayName: String {
        switch self {
        case .none: return String(localized: "None", comment: "Key auth requirement: none")
        case .perSession: return String(localized: "Once Per Session", comment: "Key auth requirement: per session")
        case .perUse: return String(localized: "Every Time", comment: "Key auth requirement: every use")
        }
    }

    var description: String {
        switch self {
        case .none:
            return String(localized: "No additional authentication required.", comment: "Key auth requirement description: none")
        case .perSession:
            return String(localized: "Authenticate once when you first use this key after opening the app.", comment: "Key auth requirement description: per session")
        case .perUse:
            return String(localized: "Authenticate every time this key is used for a connection.", comment: "Key auth requirement description: every use")
        }
    }

    var iconName: String {
        switch self {
        case .none: return "lock.open"
        case .perSession: return "timer"
        case .perUse: return "faceid"
        }
    }
}

// MARK: - Secure Enclave

/// Metadata for an SSH key whose P-256 private key is generated inside the
/// Secure Enclave and can never be read by software (not even this app).
/// Only the public point is retained here so the SSH wire blob and
/// fingerprint can be rebuilt without touching the Keychain. The opaque
/// `dataRepresentation` reference (device-bound, useless elsewhere) lives in
/// the Keychain under the private-key service, like any other key id.
///
/// Spec vocabulary: `SecureEnclaveIdentityInfo`.
nonisolated struct SecureEnclaveKeyInfo: Codable, Hashable, Sendable {
    /// Uncompressed EC public point (65 bytes: 0x04 || x || y).
    let publicKeyX963: Data
    /// When the enclave key was generated.
    let createdDate: Date
}

/// Spec name for ``SecureEnclaveKeyInfo``.
typealias SecureEnclaveIdentityInfo = SecureEnclaveKeyInfo

// MARK: - OpenSSH user certificates

/// An OpenSSH user certificate attached to a key (the contents of a `-cert.pub`
/// file, issued by a CA signing this key's public key). Public, non-secret data;
/// it lives in the key's metadata JSON so it follows the key's storageLevel sync
/// and is deleted with the key. One active certificate per key — replacing it is
/// how rotation works, matching OpenSSH's one `-cert.pub` per identity file.
///
/// Spec vocabulary: `SSHUserCertificate`.
nonisolated struct SSHUserCertificateInfo: Codable, Hashable, Sendable {
    /// Raw certificate wire blob (the base64-decoded portion of the cert line).
    /// Source of truth: used verbatim for auth offers and export.
    let certificateBlob: Data

    /// Certificate algorithm string, e.g. "ssh-ed25519-cert-v01@openssh.com".
    let certType: String

    /// CA-assigned key identity (free-form text, ssh-keygen -I).
    let keyID: String

    /// CA-assigned serial number (0 if the CA doesn't number certificates).
    let serial: UInt64

    /// Usernames this certificate is valid for. Empty = valid for any user.
    let validPrincipals: [String]

    /// Validity window start, seconds since epoch. 0 = no start bound.
    let validAfter: UInt64

    /// Validity window end, seconds since epoch. UInt64.max = never expires.
    let validBefore: UInt64

    /// CA public key type, e.g. "ssh-ed25519".
    let caKeyType: String

    /// CA public key fingerprint in `SSHHostKeyFormatter` display format
    /// ("SHA256:" + colon-separated hex).
    let caFingerprint: String

    /// Trailing comment from the imported cert line, if any.
    let comment: String?

    /// When the certificate was attached in this app.
    let addedDate: Date

    var isExpired: Bool {
        validBefore != .max && Date().timeIntervalSince1970 >= Double(validBefore)
    }

    var isNotYetValid: Bool {
        validAfter != 0 && Date().timeIntervalSince1970 < Double(validAfter)
    }

    /// Valid now but expiring within 30 days.
    var isExpiringSoon: Bool {
        guard validBefore != .max, !isExpired, !isNotYetValid else { return false }
        let thirtyDays: TimeInterval = 30 * 24 * 3600
        return Double(validBefore) - Date().timeIntervalSince1970 < thirtyDays
    }

    /// The authorized_keys-style one-line export: "<certType> <base64> <comment>".
    func exportLine(fallbackComment: String) -> String {
        let trailer = comment?.isEmpty == false ? comment! : fallbackComment
        return "\(certType) \(certificateBlob.base64EncodedString()) \(trailer)"
    }
}

/// Spec name for ``SSHUserCertificateInfo``.
typealias SSHUserCertificate = SSHUserCertificateInfo

// MARK: - SSH Identity Model

/// An SSH identity: a key pair this app can authenticate with, optionally
/// carrying an OpenSSH user certificate. The private half lives in the
/// Keychain (software keys) or the Secure Enclave (device-bound P-256 keys);
/// only the metadata below is persisted alongside it.
///
/// Spec vocabulary: `SSHIdentity`.
nonisolated struct SSHKey: Codable, Identifiable, Hashable, Sendable {
    /// Unique identifier for the key (used as Keychain account identifier)
    let id: UUID

    /// User-provided name for the key (e.g., "Work Server", "GitHub")
    var name: String

    /// Type of SSH key algorithm
    var keyType: KeyType

    /// SHA256 fingerprint of the public key for identification
    let fingerprint: String

    /// Date when the key was imported
    let createdDate: Date

    /// Whether this key has an associated passphrase stored in keychain
    var hasPassphrase: Bool

    /// Controls where/how the key is stored (device-only, backup, or iCloud sync)
    var storageLevel: KeyStorageLevel

    /// Controls when biometric/passcode authentication is required
    var authRequirement: KeyAuthRequirement

    /// Date when security settings were last modified (nil if never changed)
    var securityModifiedDate: Date?

    /// Cached public key blob in SSH wire format, so public-key comparisons
    /// never have to load the private key (and so never trigger biometrics).
    var publicKeyBlob: Data?

    /// Secure Enclave metadata (for keys whose P-256 private key is
    /// generated in and never leaves the Secure Enclave). All-platform —
    /// the Secure Enclave exists on iOS, iPadOS, macOS (Apple silicon / T2),
    /// and visionOS. Presence marks the key as hardware-protected with no
    /// software-accessible secret material.
    var secureEnclaveInfo: SecureEnclaveKeyInfo?

    /// OpenSSH user certificate attached to this key (nil if none).
    var userCertificate: SSHUserCertificateInfo?

    /// Returns true if this key requires hardware-held material for signing.
    /// In this fork that means the Secure Enclave.
    var isHardwareKey: Bool {
        return secureEnclaveInfo != nil || keyType.isHardwareKey
    }

    /// A Secure Enclave private key is bound to the device that generated it.
    /// Metadata may sync; the key itself never does.
    var isDeviceBound: Bool { secureEnclaveInfo != nil }

    /// The SSH key type string to offer during authentication.
    var effectiveSSHKeyTypeString: String {
        keyType.sshKeyTypeString
    }

    init(
        id: UUID = UUID(),
        name: String,
        keyType: KeyType,
        fingerprint: String,
        hasPassphrase: Bool = false,
        storageLevel: KeyStorageLevel = .backupOnly,
        authRequirement: KeyAuthRequirement = .none
    ) {
        self.id = id
        self.name = name
        self.keyType = keyType
        self.fingerprint = fingerprint
        self.createdDate = Date()
        self.hasPassphrase = hasPassphrase
        self.storageLevel = storageLevel
        self.authRequirement = authRequirement
        self.securityModifiedDate = nil
        self.publicKeyBlob = nil
        self.secureEnclaveInfo = nil
        self.userCertificate = nil
    }

    // MARK: - Codable (tolerant of records written by earlier schemas)

    enum CodingKeys: String, CodingKey {
        case id, name, keyType, fingerprint, createdDate, hasPassphrase
        case storageLevel, authRequirement, securityModifiedDate, publicKeyBlob
        case secureEnclaveInfo
        case userCertificate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        keyType = try container.decode(KeyType.self, forKey: .keyType)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        hasPassphrase = try container.decode(Bool.self, forKey: .hasPassphrase)

        // Optional fields with backward-compatible defaults
        storageLevel = try container.decodeIfPresent(KeyStorageLevel.self, forKey: .storageLevel) ?? .backupOnly
        authRequirement = try container.decodeIfPresent(KeyAuthRequirement.self, forKey: .authRequirement) ?? .none
        securityModifiedDate = try container.decodeIfPresent(Date.self, forKey: .securityModifiedDate)
        publicKeyBlob = try container.decodeIfPresent(Data.self, forKey: .publicKeyBlob)
        secureEnclaveInfo = try container.decodeIfPresent(SecureEnclaveKeyInfo.self, forKey: .secureEnclaveInfo)
        userCertificate = try container.decodeIfPresent(SSHUserCertificateInfo.self, forKey: .userCertificate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(keyType, forKey: .keyType)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(createdDate, forKey: .createdDate)
        try container.encode(hasPassphrase, forKey: .hasPassphrase)
        try container.encode(storageLevel, forKey: .storageLevel)
        try container.encode(authRequirement, forKey: .authRequirement)
        try container.encodeIfPresent(securityModifiedDate, forKey: .securityModifiedDate)
        try container.encodeIfPresent(publicKeyBlob, forKey: .publicKeyBlob)
        try container.encodeIfPresent(secureEnclaveInfo, forKey: .secureEnclaveInfo)
        try container.encodeIfPresent(userCertificate, forKey: .userCertificate)
    }

    /// Supported SSH key types.
    ///
    /// Raw values are persisted in key metadata — never change them.
    nonisolated enum KeyType: String, Codable, CaseIterable, Sendable {
        case rsa = "RSA"
        case ed25519 = "Ed25519"
        case ecdsaP256 = "ECDSA P-256"
        case ecdsaP384 = "ECDSA P-384"
        case ecdsaP521 = "ECDSA P-521"

        /// Secure Enclave (P-256, hardware-protected; private key never leaves the device)
        case secureEnclaveP256 = "Secure Enclave P-256"

        /// Display name for UI
        var displayName: String {
            rawValue
        }

        /// Short identifier for compact display
        var shortName: String {
            switch self {
            case .rsa: return "RSA"
            case .ed25519: return "ED25519"
            case .ecdsaP256: return "P256"
            case .ecdsaP384: return "P384"
            case .ecdsaP521: return "P521"
            case .secureEnclaveP256: return "SE P256"
            }
        }

        /// Color for key type badges in UI
        var badgeColor: String {
            switch self {
            case .rsa: return "red"
            case .ed25519: return "blue"
            case .ecdsaP256: return "green"
            case .ecdsaP384: return "orange"
            case .ecdsaP521: return "purple"
            case .secureEnclaveP256: return "indigo"
            }
        }

        /// SSH key type string used in public key format (e.g., "ssh-ed25519")
        var sshKeyTypeString: String {
            switch self {
            case .rsa: return "ssh-rsa"
            case .ed25519: return "ssh-ed25519"
            case .ecdsaP256: return "ecdsa-sha2-nistp256"
            case .ecdsaP384: return "ecdsa-sha2-nistp384"
            case .ecdsaP521: return "ecdsa-sha2-nistp521"
            // Standard ECDSA P-256 on the wire; the key lives in the Secure Enclave.
            case .secureEnclaveP256: return "ecdsa-sha2-nistp256"
            }
        }

        /// Whether this is a hardware-protected key type
        var isHardwareKey: Bool {
            self == .secureEnclaveP256
        }

        /// Whether the private key material is accessible to software. Drives
        /// the "software vs hardware-protected" distinction in the key UI.
        /// Software keys (RSA/Ed25519/ECDSA) load their secret into app
        /// memory to sign; Secure Enclave keys never expose the secret.
        var hasSoftwareAccess: Bool {
            self != .secureEnclaveP256
        }
    }

    /// Formatted fingerprint for display (e.g., "SHA256:abc123...")
    var formattedFingerprint: String {
        "SHA256:\(fingerprint.prefix(16))..."
    }

    /// Full fingerprint with colons every 2 characters (e.g., "ab:cd:ef:12...")
    var colonFormattedFingerprint: String {
        let hex = fingerprint
        var result = ""
        for (index, char) in hex.enumerated() {
            if index > 0 && index % 2 == 0 {
                result += ":"
            }
            result.append(char)
        }
        return result.uppercased()
    }
}

/// Spec name for ``SSHKey``.
typealias SSHIdentity = SSHKey
