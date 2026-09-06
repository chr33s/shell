import Foundation
import Combine
import LocalAuthentication
import Security
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Crypto      // Must import for Insecure namespace
import Citadel     // Import AFTER Crypto so extensions take precedence
import os.log
import SwiftUI

/// Union type holding either a standard NIOSSHPrivateKey, a Citadel RSA key,
/// or a Secure Enclave-backed P-256 key.
///
/// `@unchecked Sendable` because the constituent crypto types
/// (`NIOSSHPrivateKey` and Citadel's `Insecure.RSA.PrivateKey`) don't carry
/// explicit `Sendable` conformances but are immutable opaque values once
/// constructed. The async `loadPrivateKey(id:)` overload builds the variant
/// inside a `Task.detached` parse and hands it back to the MainActor caller —
/// that crossing only type-checks under strict concurrency with this explicit
/// contract.
enum SSHPrivateKeyVariant: @unchecked Sendable {
    case nioSSH(NIOSSHPrivateKey)
    case rsa(Insecure.RSA.PrivateKey)
    /// Secure Enclave P-256 key, reconstructed from its device-bound
    /// `dataRepresentation` and wrapped in NIOSSH's native
    /// `secureEnclaveP256Key` backing. Signing routes through CryptoKit's
    /// `SecureEnclave.P256.Signing.PrivateKey`, so the key never leaves the
    /// enclave. All-platform (the Secure Enclave exists on visionOS too).
    case secureEnclaveP256(NIOSSHPrivateKey)
}

/// Manages SSH keys for authentication
@MainActor
class SSHKeyManager: ObservableObject {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHKeyManager")

    static let shared = SSHKeyManager()

    private static let defaultKeyIDsKey = "defaultSSHKeyIDs"

    /// All saved SSH keys (metadata only, actual keys in Keychain)
    @Published private(set) var savedKeys: [SSHKey] = []

    /// Ordered list of default key IDs to try during authentication
    /// Keys are tried in order until one succeeds (SSH servers typically allow 6 attempts)
    @Published private(set) var defaultKeyIDs: [UUID] = []

    /// Primary default key (first in the ordered list).
    var primaryDefaultKeyID: UUID? { defaultKeyIDs.first }

    /// Find a saved key by its user-assigned name (case-insensitive).
    func findKey(byName name: String) -> SSHKey? {
        savedKeys.first { $0.name.lowercased() == name.lowercased() }
    }

    /// Publisher for key changes
    let keysDidChange = PassthroughSubject<Void, Never>()

    /// Legacy-encrypted keys with no usable local passphrase; unusable on
    /// this device until unlocked once via `unlockLegacyKey`.
    @Published private(set) var keysNeedingUnlock: Set<UUID> = []

    /// Single-flight guard for the background legacy-key migration scan.
    private var legacyKeyMigrationTask: Task<Void, Never>?

    /// Authenticated LAContexts from in-flight loads, reused by the
    /// opportunistic legacy-key migration write.
    private var authenticatedLoadContexts: [UUID: LAContext] = [:]

    /// Keys with an opportunistic migration in flight (single-flight per key).
    private var opportunisticMigrationsInFlight: Set<UUID> = []

    private let keychainManager: KeychainManager

    private init() {
        self.keychainManager = KeychainManager.shared
        loadKeys()                   // 1. Load from keychain
        loadDefaultKeyIDs()          // 2. Load ordered default keys
        discoverSyncedKeys()         // 3. Find keys synced from other devices
        // Backfill cached public key blobs for existing keys that don't have them
        backfillPublicKeyBlobs()
        // Normalize legacy passphrase-encrypted keys in place (#285)
        scheduleLegacyKeyMigrationIfNeeded()
        // The launch-time metadata backfill deliberately does NOT run here —
        // see `publishInitialIdentityMetadata()`.
    }

    // MARK: - Identity metadata

    /// Runs the launch-time identity-metadata backfill, so an install that
    /// predates the metadata store publishes the public half of every key it
    /// already holds without waiting for the user to edit one.
    ///
    /// `CloudKitSyncManager` calls this the moment it has wired
    /// `SSHIdentityMetadataStore.onLocalChange`, and nothing else does. It
    /// cannot run from `init()`: the store skips a `record` whose content is
    /// unchanged, so the *first* publish is the only one that can ever fire the
    /// sync callback. Publishing from `init()` meant that whenever
    /// `SSHKeyManager.shared` was touched before `CloudKitSyncManager.shared`
    /// the backfill was written to disk with no callback attached and nothing
    /// was pushed — and `pushAllLocalRecords()` only runs from
    /// `performInitialSync()`, so those records could sit out of iCloud until
    /// the key was next mutated.
    ///
    /// Safe to call more than once: `record` is idempotent on unchanged
    /// content, so a repeat pass is a no-op rather than a second push.
    func publishInitialIdentityMetadata() {
        publishIdentityMetadata()
    }

    /// Publishes the *public* half of every local identity so other devices can
    /// see which identities exist. No private key material enters this store:
    /// software keys travel through the iCloud Keychain and Secure Enclave keys
    /// never leave the device that created them (spec §7).
    ///
    /// `reconcile` tombstones only the records this device itself published, so
    /// another device's identities — which are absent from `savedKeys` by
    /// design — survive the pass untouched.
    private func publishIdentityMetadata() {
        let store = SSHIdentityMetadataStore.shared
        guard ProtectedDataGuard.isAvailable else {
            // Locked device: `loadKeys()` cannot see `.deviceOnly` keys (their
            // Keychain items are `WhenUnlockedThisDeviceOnly`), so publish what
            // we can and skip the reconcile — tombstoning against a partial
            // list would delete those identities' metadata on every device.
            for key in savedKeys {
                store.record(key)
            }
            return
        }
        store.reconcile(with: savedKeys)
    }

    /// Single exit point for every key mutation: refresh the synced public
    /// metadata, then notify observers.
    private func notifyKeysChanged() {
        publishIdentityMetadata()
        keysDidChange.send()
    }

    // MARK: - Public Methods

    /// Imports a new SSH key
    /// - Parameters:
    ///   - name: User-friendly name for the key
    ///   - keyString: The key content (PEM or OpenSSH format)
    ///   - passphrase: Optional passphrase for encrypted keys
    ///   - storageLevel: Controls where/how the key is stored (default: .backupOnly)
    ///   - authRequirement: Controls when authentication is required (default: .none)
    /// - Returns: The imported SSHKey
    /// - Throws: Error if import fails
    func importKey(
        name: String,
        keyString: String,
        passphrase: String? = nil,
        storageLevel: KeyStorageLevel = .backupOnly,
        authRequirement: KeyAuthRequirement = .none
    ) throws -> SSHKey {
        // Validate name
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ImportError.invalidName
        }

        Self.logger.info("Importing key '\(name)'")

        // Store encrypted OpenSSH keys decrypted: passphrases are device-local
        // and never sync, so an encrypted blob is unusable after iCloud sync.
        let storedKeyString: String
        do {
            switch try OpenSSHKeyNormalizer.normalize(keyString: keyString, passphrase: passphrase) {
            case .normalized(let normalizedText):
                storedKeyString = normalizedText
                Self.logger.info("Normalized encrypted key to unencrypted OpenSSH container")
            case .alreadyPlaintext, .notOpenSSHContainer:
                storedKeyString = keyString
            }
        } catch OpenSSHKeyNormalizer.NormalizerError.passphraseRequired {
            throw SSHKeyParser.ParserError.encryptedKeyNeedsPassphrase
        } catch OpenSSHKeyNormalizer.NormalizerError.incorrectPassphrase {
            throw SSHKeyParser.ParserError.incorrectPassphrase
        } catch {
            // Fall back to legacy storage; the parse below decides usability.
            Self.logger.warning("Key normalization failed, storing original: \(error.localizedDescription)")
            storedKeyString = keyString
        }

        // Parse the key
        let parsedKey = try SSHKeyParser.parse(keyString: storedKeyString, passphrase: passphrase)
        Self.logger.info("Parsed as key type: \(parsedKey.keyType.rawValue)")
        Self.logger.info("Fingerprint: \(parsedKey.fingerprint)")
        Self.logger.info("Has NIO SSH key: \(parsedKey.nioSSHKey != nil)")
        Self.logger.info("Has RSA key: \(parsedKey.rsaKey != nil)")

        // Check for duplicate fingerprint
        if savedKeys.contains(where: { $0.fingerprint == parsedKey.fingerprint }) {
            throw ImportError.duplicateKey
        }

        // Create SSHKey metadata with security settings
        var sshKey = SSHKey(
            name: name.trimmingCharacters(in: .whitespaces),
            keyType: parsedKey.keyType,
            fingerprint: parsedKey.fingerprint,
            hasPassphrase: parsedKey.isEncrypted,
            storageLevel: storageLevel,
            authRequirement: authRequirement
        )

        // Cache public key blob for agent forwarding (avoids loading key from Keychain just for matching)
        let keyVariant: SSHPrivateKeyVariant
        if let nioSSHKey = parsedKey.nioSSHKey {
            keyVariant = .nioSSH(nioSSHKey)
        } else if let rsaKey = parsedKey.rsaKey {
            keyVariant = .rsa(rsaKey.citadelKey)
        } else {
            throw ImportError.dataConversionFailed
        }

        sshKey.publicKeyBlob = SSHPublicKeyBlob.makeData(from: keyVariant, keyType: parsedKey.keyType)

        Self.logger.info("Created metadata with keyType: \(sshKey.keyType.rawValue)")
        Self.logger.info("Security: storageLevel=\(storageLevel.rawValue), authRequirement=\(authRequirement.rawValue)")
        Self.logger.info("Cached public key blob: \(sshKey.publicKeyBlob?.count ?? 0) bytes")

        // Store key data in Keychain with security configuration
        guard let keyData = storedKeyString.data(using: .utf8) else {
            throw ImportError.dataConversionFailed
        }

        do {
            try keychainManager.savePrivateKey(
                keyData,
                identifier: sshKey.id.uuidString,
                storageLevel: storageLevel,
                authRequirement: authRequirement
            )

            // Retain the passphrase only when the stored blob still needs it.
            if let passphrase = passphrase, parsedKey.isEncrypted {
                try keychainManager.savePassphrase(passphrase, forKey: sshKey.id.uuidString)
            }
        } catch {
            throw ImportError.keychainError(error)
        }

        // Roll back the key material if metadata persistence fails.
        do {
            let metadataData = try JSONEncoder().encode(sshKey)
            try keychainManager.saveSSHKeyMetadata(
                metadataData,
                identifier: sshKey.id.uuidString,
                storageLevel: storageLevel
            )
        } catch {
            try? keychainManager.deletePrivateKey(identifier: sshKey.id.uuidString)
            keychainManager.deletePassphrase(forKey: sshKey.id.uuidString)
            throw ImportError.keychainError(error)
        }

        // Add to saved keys
        savedKeys.append(sshKey)
        notifyKeysChanged()

        // Add as default if it's the first key
        if savedKeys.count == 1 {
            addToDefaults(id: sshKey.id)
        }

        return sshKey
    }

    /// Whether this device has a usable Secure Enclave (false on Intel Macs
    /// without a T2 and on most Simulators). Drives whether the
    /// hardware-protected key option is offered.
    nonisolated static var isSecureEnclaveAvailable: Bool {
        SecureEnclave.isAvailable
    }

    // MARK: - Secure Enclave Key Generation

    /// Generates a P-256 signing key inside the Secure Enclave. The private
    /// key is created in, and never leaves, the enclave: no software (this
    /// app included) can read it. Only the device-bound, opaque
    /// `dataRepresentation` reference is stored in the Keychain, so these
    /// keys are inherently device-only (never backed up or synced) and the
    /// public key / authorized_keys line is the sole exportable artifact.
    ///
    /// - Parameters:
    ///   - name: User-facing key name.
    ///   - authRequirement: `.none` signs silently while the device is
    ///     unlocked; `.perSession` / `.perUse` require Face ID / Touch ID
    ///     (or passcode) per the enclave key's own access control.
    /// - Returns: The created `SSHKey` (metadata only; the secret is in the
    ///   enclave).
    func createSecureEnclaveKey(
        name: String,
        authRequirement: KeyAuthRequirement = .perSession
    ) throws -> SSHKey {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveError.unavailable
        }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            throw ImportError.invalidName
        }

        Self.logger.info("Generating Secure Enclave P-256 key '\(trimmedName)' (auth=\(authRequirement.rawValue))")

        // Build the enclave key's access control. The biometric/passcode
        // gate (when requested) is enforced here, at the key, rather than on
        // the Keychain item that stores its reference.
        let access = try Self.secureEnclaveAccessControl(for: authRequirement)

        let seKey: SecureEnclave.P256.Signing.PrivateKey
        do {
            seKey = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        } catch {
            Self.logger.error("Secure Enclave key creation failed: \(error.localizedDescription)")
            throw SecureEnclaveError.creationFailed(error)
        }

        // Fingerprint over the raw x963 public point, matching the ECDSA
        // P-256 convention in SSHKeyParser / SSHKeyGenerator so dedup is
        // consistent with imported / generated software P-256 keys.
        let x963 = Data(seKey.publicKey.x963Representation)
        let fingerprint = Self.sha256Hex(x963)
        if savedKeys.contains(where: { $0.fingerprint == fingerprint }) {
            throw ImportError.duplicateKey
        }

        let dataRep = seKey.dataRepresentation
        let nioKey = NIOSSHPrivateKey(secureEnclaveP256Key: seKey)

        var sshKey = SSHKey(
            name: trimmedName,
            keyType: .secureEnclaveP256,
            fingerprint: fingerprint,
            hasPassphrase: false,
            storageLevel: .deviceOnly,
            authRequirement: authRequirement
        )
        sshKey.secureEnclaveInfo = SecureEnclaveKeyInfo(publicKeyX963: x963, createdDate: sshKey.createdDate)

        // Cache the SSH wire-format public blob so agent forwarding /
        // authorized_keys export never need the Keychain. GPG keygrips stay
        // nil on purpose: the enclave can't expose the scalar GPG's PKSIGN
        // needs, so SE keys must never be advertised as GPG identities.
        let blobBuffer = SSHPublicKeyBlob.make(from: .secureEnclaveP256(nioKey), keyType: .secureEnclaveP256)
        sshKey.publicKeyBlob = blobBuffer.getData(at: blobBuffer.readerIndex, length: blobBuffer.readableBytes)

        // Store the opaque dataRepresentation (device-bound, useless
        // elsewhere) as device-only with NO access control — the biometric
        // gate lives in the enclave key itself, so adding one here would
        // double-prompt.
        do {
            try keychainManager.savePrivateKey(
                dataRep,
                identifier: sshKey.id.uuidString,
                storageLevel: .deviceOnly,
                authRequirement: .none
            )
        } catch {
            throw ImportError.keychainError(error)
        }

        // Persist metadata explicitly and surface any failure. saveKeys()
        // only logs write errors, which would let us report a "created" key
        // that vanishes on relaunch while orphaning the enclave reference
        // saved above: write the metadata, and on failure roll back the
        // just-saved reference.
        do {
            let metadataData = try JSONEncoder().encode(sshKey)
            try keychainManager.saveSSHKeyMetadata(
                metadataData,
                identifier: sshKey.id.uuidString,
                storageLevel: sshKey.storageLevel
            )
        } catch {
            try? keychainManager.deletePrivateKey(identifier: sshKey.id.uuidString)
            throw ImportError.keychainError(error)
        }

        savedKeys.append(sshKey)
        notifyKeysChanged()

        if savedKeys.count == 1 {
            addToDefaults(id: sshKey.id)
        }

        Self.logger.info("Secure Enclave key created: \(trimmedName) [\(fingerprint.prefix(16))]")
        return sshKey
    }

    /// Builds the `SecAccessControl` for a Secure Enclave signing key.
    /// `.privateKeyUsage` is mandatory for enclave signing keys; when auth
    /// is required we add a biometric-with-passcode-fallback constraint
    /// (mirroring ``KeychainManager``'s software-key access control).
    nonisolated private static func secureEnclaveAccessControl(
        for authRequirement: KeyAuthRequirement
    ) throws -> SecAccessControl {
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]

        if authRequirement != .none {
            let context = LAContext()
            let biometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            if biometricsAvailable {
                flags.formUnion([.biometryCurrentSet, .or, .devicePasscode])
            } else {
                flags.insert(.devicePasscode)
            }
        }

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &error
        ) else {
            throw SecureEnclaveError.accessControlFailed(error?.takeRetainedValue())
        }
        return access
    }

    /// Lowercase hex SHA-256 of `data` (fingerprint encoding shared with
    /// SSHKeyParser / SSHKeyGenerator).
    nonisolated private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Deletes an SSH key
    /// - Parameter id: The key ID to delete
    /// - Throws: Error if deletion fails
    func deleteKey(id: UUID) throws {
        guard let index = savedKeys.firstIndex(where: { $0.id == id }) else {
            throw DeleteError.keyNotFound
        }

        // Remove from Keychain (private key + metadata + passphrase). For a
        // Secure Enclave key the "private key" item is the opaque
        // dataRepresentation; removing it makes the enclave key permanently
        // unusable (it can't be reconstructed without that reference).
        do {
            try keychainManager.deletePrivateKey(identifier: id.uuidString)
            try keychainManager.deleteSSHKeyMetadata(identifier: id.uuidString)
            keychainManager.deletePassphrase(forKey: id.uuidString)
        } catch {
            throw DeleteError.keychainError(error)
        }

        // Drop any cached Secure Enclave auth context for this key.
        SSHKeyAuthManager.shared.clearSecureEnclaveContext(for: id)

        // Drop OpenPubkey secrets (refresh token + PK token) if this was an
        // opkssh identity key.
        keychainManager.deleteOpenPubkeySecrets(forKey: id.uuidString)

        // Remove from saved keys
        savedKeys.remove(at: index)

        // Tombstone the published metadata explicitly. `reconcile` only sweeps
        // records this device published, so a key that was first published by
        // another device (a software key that reached us through the iCloud
        // Keychain) would otherwise leave its metadata behind. This deletion is
        // user-initiated and removes the shared Keychain item, so the identity
        // really is gone everywhere.
        SSHIdentityMetadataStore.shared.remove(id: id)

        // Remove from defaults list (no auto-replacement)
        if defaultKeyIDs.contains(id) {
            defaultKeyIDs.removeAll { $0 == id }
            saveDefaultKeyIDs()
        }

        notifyKeysChanged()
    }

    /// Adds a key to the ordered defaults list
    /// - Parameters:
    ///   - id: The key ID to add
    ///   - index: Optional position to insert at (appends if nil or out of range)
    func addToDefaults(id: UUID, at index: Int? = nil) {
        guard savedKeys.contains(where: { $0.id == id }) else { return }
        guard !defaultKeyIDs.contains(id) else { return }

        if let index = index, index >= 0 && index <= defaultKeyIDs.count {
            defaultKeyIDs.insert(id, at: index)
        } else {
            defaultKeyIDs.append(id)
        }
        saveDefaultKeyIDs()
    }

    /// Removes a key from the defaults list
    /// - Parameter id: The key ID to remove
    func removeFromDefaults(id: UUID) {
        guard defaultKeyIDs.contains(id) else { return }
        defaultKeyIDs.removeAll { $0 == id }
        saveDefaultKeyIDs()
    }

    /// Checks if a key is in the defaults list
    /// - Parameter id: The key ID to check
    /// - Returns: True if the key is a default
    func isDefault(id: UUID) -> Bool {
        defaultKeyIDs.contains(id)
    }

    /// Gets the priority index of a default key (0 = highest priority)
    /// - Parameter id: The key ID to check
    /// - Returns: The index in the defaults list, or nil if not a default
    func defaultPriority(for id: UUID) -> Int? {
        defaultKeyIDs.firstIndex(of: id)
    }

    /// Loads a private key for authentication.
    ///
    /// This is the legacy synchronous entrypoint. The parse step runs
    /// on the caller's thread, which on `@MainActor` callers means the
    /// expensive OpenSSH bcrypt KDF + AES-CTR decryption blocks the UI
    /// for every encrypted key load. Prefer ``loadPrivateKey(id:)`` —
    /// the `async` overload — for new code so the parse can hop off
    /// the main thread via `Task.detached`. The sync version is kept
    /// for sync-only call sites that can't yet be converted.
    ///
    /// - Parameter id: The key ID to load
    /// - Returns: The private key as a variant type
    /// - Throws: Error if loading fails
    func loadPrivateKey(id: UUID) throws -> SSHPrivateKeyVariant {
        guard let savedKey = savedKeys.first(where: { $0.id == id }) else {
            throw LoadError.keyNotFound
        }

        // Secure Enclave identities expose a device-bound reference, not
        // software private-key material. Authentication is enforced by the
        // enclave itself.
        if savedKey.secureEnclaveInfo != nil {
            return try resolvedHardwareVariant(id: id)
        }

        // A synchronous call cannot safely perform shell's explicit
        // authentication gate for synchronizable keys. Reject every protected
        // software key here so callers must use the async authenticated
        // overload. Local Keychain ACLs remain defense in depth, not the
        // entrypoint contract.
        guard savedKey.authRequirement == .none else {
            throw LoadError.authenticationRequiresAsyncLoad
        }

        guard let prep = try preparePrivateKeyLoad(id: id) else {
            // All reference-backed variants returned above; a nil result here
            // means the metadata changed into an unsupported reference form.
            throw LoadError.invalidKeyData
        }
        let parsedKey: SSHKeyParser.ParsedKey
        do {
            parsedKey = try SSHKeyParser.parse(keyString: prep.keyString, passphrase: prep.passphrase)
        } catch SSHKeyParser.ParserError.encryptedKeyNeedsPassphrase,
                SSHKeyParser.ParserError.incorrectPassphrase {
            applyLegacyMigrationOutcome(.needsUnlock, keyID: id)
            throw LoadError.legacyKeyNeedsUnlock(keyID: id, keyName: savedKey.name)
        }
        return try Self.materializeParsedKey(parsedKey)
    }

    /// Async variant of ``loadPrivateKey(id:)`` that enforces the key's
    /// authentication requirement, then runs the CPU-bound parsing
    /// (OpenSSH bcrypt KDF + AES-CTR for encrypted keys, ASN.1 walks for
    /// PKCS#8) off the MainActor via `Task.detached`. The Keychain +
    /// metadata steps still run on the manager's MainActor; only the
    /// parse hops off.
    ///
    /// Prefer this overload over the sync one in any `async` context —
    /// especially `SSHConnectionHelper.buildAuthMethod`, which is the
    /// hot path for every new SSH connection.
    func loadPrivateKey(id: UUID) async throws -> SSHPrivateKeyVariant {
        guard let savedKey = savedKeys.first(where: { $0.id == id }) else {
            throw LoadError.keyNotFound
        }

        // All async consumers are use sites (SSH connections, signing, agents),
        // so protected keys must flow through the authentication-aware loader.
        // This also covers iCloud-synced keys, whose Keychain items cannot carry
        // the device-bound access control used by local keys.
        if savedKey.authRequirement != .none {
            return try await loadPrivateKeyWithAuth(id: id)
        }

        // Secure Enclave keys authenticate at load (off the SSH event loop)
        // so the handshake signature is silent and the session is recorded
        // only on a real success.
        if savedKey.secureEnclaveInfo != nil {
            return try await secureEnclaveVariantAuthenticated(for: savedKey)
        }
        guard let prep = try preparePrivateKeyLoad(id: id) else {
            return try resolvedHardwareVariant(id: id)
        }
        let keyString = prep.keyString
        let passphrase = prep.passphrase
        let parsedKey: SSHKeyParser.ParsedKey
        do {
            parsedKey = try await Task.detached(priority: .userInitiated) {
                try SSHKeyParser.parse(keyString: keyString, passphrase: passphrase)
            }.value
        } catch SSHKeyParser.ParserError.encryptedKeyNeedsPassphrase,
                SSHKeyParser.ParserError.incorrectPassphrase {
            applyLegacyMigrationOutcome(.needsUnlock, keyID: id)
            throw LoadError.legacyKeyNeedsUnlock(keyID: id, keyName: savedKey.name)
        }
        return try Self.materializeParsedKey(parsedKey)
    }

    /// Shared prep: metadata lookup + Keychain reads. Returns
    /// `nil` when the key is a hardware reference (no parse needed).
    private func preparePrivateKeyLoad(id: UUID) throws -> (keyString: String, passphrase: String?)? {
        Self.logger.info("Loading private key with ID: \(id.uuidString)")

        guard let savedKey = savedKeys.first(where: { $0.id == id }) else {
            Self.logger.info("WARNING: No metadata found for key ID \(id.uuidString)")
            throw LoadError.keyNotFound
        }

        // Secure Enclave keys store an opaque (binary) dataRepresentation,
        // not a PEM — short-circuit so the utf8 decode below is skipped and
        // the variant is rebuilt in ``resolvedHardwareVariant``.
        if savedKey.secureEnclaveInfo != nil {
            return nil
        }

        let keyData = try keychainManager.loadPrivateKey(identifier: id.uuidString)
        Self.logger.info("Loaded \(keyData.count) bytes from keychain")
        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw LoadError.dataConversionFailed
        }
        let passphrase = keychainManager.loadPassphrase(forKey: id.uuidString)
        return (keyString, passphrase)
    }

    /// Build the Secure Enclave variant directly from saved metadata.
    /// Separate from ``preparePrivateKeyLoad`` so callers can keep
    /// the `nil`-means-"device-bound key" contract clean.
    private func resolvedHardwareVariant(id: UUID) throws -> SSHPrivateKeyVariant {
        guard let savedKey = savedKeys.first(where: { $0.id == id }) else {
            throw LoadError.keyNotFound
        }
        guard savedKey.secureEnclaveInfo != nil else {
            throw LoadError.invalidKeyData
        }
        Self.logger.info("Loading Secure Enclave reference (no PEM, opaque dataRepresentation)")
        return try secureEnclaveVariant(for: savedKey)
    }

    /// Synchronous Secure Enclave reconstruction, used by the legacy sync
    /// load path and identity/public-key lookups. Reuses an already-
    /// authenticated session context when one exists (so signing is silent),
    /// otherwise reconstructs with a fresh context that prompts at sign time.
    /// It deliberately never records a session: only a confirmed-successful
    /// authentication (the async ``secureEnclaveVariantAuthenticated(for:)``
    /// path) does that, matching software-key behavior.
    private func secureEnclaveVariant(for savedKey: SSHKey) throws -> SSHPrivateKeyVariant {
        let dataRep = try keychainManager.loadPrivateKey(identifier: savedKey.id.uuidString)
        let authManager = SSHKeyAuthManager.shared
        let reason = "Authenticate to use '\(savedKey.name)'"
        let context = authManager.cachedSecureEnclaveContext(for: savedKey.id)
            ?? authManager.makeSecureEnclaveContext(for: savedKey, reason: reason)
        do {
            let seKey = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: dataRep,
                authenticationContext: context
            )
            return .secureEnclaveP256(NIOSSHPrivateKey(secureEnclaveP256Key: seKey))
        } catch {
            Self.logger.error("Failed to reconstruct Secure Enclave key: \(error.localizedDescription)")
            throw LoadError.invalidKeyData
        }
    }

    /// Authenticate a Secure Enclave key at LOAD time (off the SSH event
    /// loop) and reconstruct it with the resulting context so the handshake
    /// signature is silent. A `.perSession` session is recorded only AFTER
    /// the biometric/passcode actually succeeds — a cancel or failure throws
    /// and leaves no recorded session and no cached context, exactly like the
    /// software-key path. Within a valid session the cached, authenticated
    /// context is reused without a new prompt.
    private func secureEnclaveVariantAuthenticated(for savedKey: SSHKey) async throws -> SSHPrivateKeyVariant {
        let dataRep = try keychainManager.loadPrivateKey(identifier: savedKey.id.uuidString)
        let authManager = SSHKeyAuthManager.shared
        let reason = "Authenticate to use '\(savedKey.name)'"

        var context: LAContext? = nil
        if savedKey.authRequirement != .none {
            if savedKey.authRequirement == .perSession,
               !authManager.needsAuthentication(for: savedKey),
               let cached = authManager.cachedSecureEnclaveContext(for: savedKey.id) {
                // Session still valid — reuse the already-authenticated context.
                context = cached
            } else {
                guard let fresh = authManager.makeSecureEnclaveContext(for: savedKey, reason: reason) else {
                    throw LoadError.invalidKeyData
                }
                let access = try Self.secureEnclaveAccessControl(for: savedKey.authRequirement)
                try await Self.evaluateAccessControl(access, on: fresh, reason: reason)
                // Record the session only now that auth has succeeded.
                if savedKey.authRequirement == .perSession {
                    authManager.recordAuthentication(for: savedKey.id)
                    authManager.cacheSecureEnclaveContext(fresh, for: savedKey.id)
                }
                context = fresh
            }
        }

        do {
            let seKey = try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: dataRep,
                authenticationContext: context
            )
            return .secureEnclaveP256(NIOSSHPrivateKey(secureEnclaveP256Key: seKey))
        } catch {
            Self.logger.error("Failed to reconstruct Secure Enclave key: \(error.localizedDescription)")
            throw LoadError.invalidKeyData
        }
    }

    /// Bridge `LAContext.evaluateAccessControl`'s completion API to async,
    /// mapping user/app/system cancel to `LoadError.authenticationCancelled`,
    /// a missing device passcode to `LoadError.authenticationUnavailable`, and
    /// other failures to `LoadError.authenticationFailed`.
    nonisolated private static func evaluateAccessControl(
        _ access: SecAccessControl,
        on context: LAContext,
        reason: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.evaluateAccessControl(access, operation: .useKeySign, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                } else if let laError = error as? LAError,
                          laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel {
                    continuation.resume(throwing: LoadError.authenticationCancelled)
                } else if let laError = error as? LAError, laError.code == .passcodeNotSet {
                    continuation.resume(throwing: LoadError.authenticationUnavailable)
                } else {
                    continuation.resume(throwing: LoadError.authenticationFailed)
                }
            }
        }
    }

    /// Authenticate an iCloud-synced software key on the device where it is
    /// being used. Device-owner authentication prefers available biometry and
    /// retains the existing passcode/password fallback behavior.
    nonisolated private static func evaluateDeviceOwnerAuthentication(
        on context: LAContext,
        reason: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume()
                } else if let laError = error as? LAError,
                          laError.code == .userCancel || laError.code == .appCancel || laError.code == .systemCancel {
                    continuation.resume(throwing: LoadError.authenticationCancelled)
                } else if let laError = error as? LAError, laError.code == .passcodeNotSet {
                    continuation.resume(throwing: LoadError.authenticationUnavailable)
                } else {
                    continuation.resume(throwing: LoadError.authenticationFailed)
                }
            }
        }
    }

    /// Map a `ParsedKey` into the public ``SSHPrivateKeyVariant``.
    /// `nonisolated static` so it can be invoked from the cooperative
    /// pool inside the detached parse task without an actor hop.
    nonisolated private static func materializeParsedKey(_ parsedKey: SSHKeyParser.ParsedKey) throws -> SSHPrivateKeyVariant {
        if let nioSSHKey = parsedKey.nioSSHKey {
            return .nioSSH(nioSSHKey)
        } else if let rsaKey = parsedKey.rsaKey {
            return .rsa(rsaKey.citadelKey)
        } else {
            throw LoadError.invalidKeyData
        }
    }

    /// Finds a key by ID
    /// - Parameter id: The key ID to find
    /// - Returns: The SSHKey if found
    func findKey(id: UUID) -> SSHKey? {
        savedKeys.first(where: { $0.id == id })
    }

    /// Finds a key by its SHA256 fingerprint
    /// Used for cross-device key resolution when UUID doesn't match
    /// - Parameter fingerprint: The SHA256 fingerprint (hex string without colons)
    /// - Returns: The SSHKey if found
    func findKey(byFingerprint fingerprint: String) -> SSHKey? {
        savedKeys.first { $0.fingerprint == fingerprint }
    }

    /// Resolves a key by UUID with fallback to fingerprint matching
    /// Used for cross-device YubiKey support where UUID may differ across devices
    /// - Parameters:
    ///   - id: The primary key UUID to look up
    ///   - fingerprint: Optional fingerprint for fallback resolution
    /// - Returns: The SSHKey if found by either method
    func resolveKey(id: UUID, fingerprint: String? = nil) -> SSHKey? {
        // Try primary UUID lookup first
        if let key = findKey(id: id) {
            return key
        }

        // Fallback to fingerprint matching for cross-device resolution
        if let fingerprint, let key = findKey(byFingerprint: fingerprint) {
            Self.logger.info("Resolved key by fingerprint fallback: \(key.name)")
            return key
        }

        return nil
    }

    /// Resolves a key using a resolution hint for multi-strategy cross-device matching
    /// Tries strategies in order: UUID → fingerprint → YubiKey serial+slot → FIDO2 credential → hardware ID
    /// - Parameters:
    ///   - id: The primary key UUID to look up
    ///   - hint: Resolution hint with alternative identifiers
    /// - Returns: The SSHKey if found by any strategy
    func resolveKey(id: UUID, hint: KeyResolutionHint?) -> SSHKey? {
        // 1. UUID match (fast path)
        if let key = findKey(id: id) {
            return key
        }

        guard let hint else { return nil }

        // 2. Fingerprint match
        if let fingerprint = hint.fingerprint, let key = findKey(byFingerprint: fingerprint) {
            Self.logger.info("Resolved key by fingerprint: \(key.name)")
            return key
        }

        return nil
    }

    /// Refreshes the key list from Keychain to detect iCloud sync changes.
    /// Fire-and-forget: runs `SecItemCopyMatching` off the main actor and applies
    /// the diff back on main when complete. Safe to call during foreground
    /// resume — a slow securityd will not block the FrontBoard scene-update
    /// transaction.
    func refreshKeys() {
        Task {
            await refreshKeysAsync()
        }
    }

    /// Awaitable variant of `refreshKeys()` for callers that want to know when
    /// the refresh has applied (e.g. SwiftUI `.refreshable`).
    ///
    /// `shouldApply` is an optional pre-apply guard called after the
    /// detached Keychain read returns, just before the `@Published savedKeys`
    /// mutation. Lifecycle callers pass a `LifecycleEpoch` check so a
    /// backgrounding that lands during the Keychain read aborts the apply
    /// instead of publishing onto a backgrounded scene. Returning `false`
    /// leaves the existing `savedKeys` unchanged; the next refresh after the
    /// real foreground resume will pick up the latest Keychain state.
    func refreshKeysAsync(shouldApply: (@MainActor () -> Bool)? = nil) async {
        let oldKeys = savedKeys
        let oldKeysByID = Dictionary(uniqueKeysWithValues: oldKeys.map { ($0.id, $0) })

        let (loaded, discovered) = await Task.detached(priority: .utility) {
            () -> (loaded: [SSHKey], discovered: [SSHKey]) in
            let loaded = Self.loadKeysFromKeychain()
            let existingIDs = Set(loaded.map { $0.id.uuidString })
            let discovered = Self.discoverSyncedKeysFromKeychain(existingIDs: existingIDs)
            return (loaded, discovered)
        }.value

        // Stale-result guard: if the user (or another refresh) mutated
        // `savedKeys` while our Keychain read was in flight, the snapshot
        // we computed against `oldKeys` is no longer authoritative. Bailing
        // is correct — the mutation already updated `savedKeys` directly,
        // and any subsequent refresh will pick up the latest Keychain state.
        guard savedKeys == oldKeys else {
            Self.logger.info("Skipping refreshKeys apply: savedKeys mutated during background read")
            return
        }

        // Caller-provided lifecycle guard — checked AFTER the await but
        // BEFORE the @Published mutation, closing the residual race that the
        // pre-await wrapper at the call site cannot cover.
        if let shouldApply, !shouldApply() {
            return
        }

        applyRefresh(loaded: loaded, discovered: discovered, oldKeys: oldKeys, oldKeysByID: oldKeysByID)
    }

    private func applyRefresh(
        loaded: [SSHKey],
        discovered: [SSHKey],
        oldKeys: [SSHKey],
        oldKeysByID: [UUID: SSHKey]
    ) {
        savedKeys = loaded
        if !discovered.isEmpty {
            savedKeys.append(contentsOf: discovered)
            Self.logger.info("Added \(discovered.count) keys synced from iCloud")
        }

        // savedKeys was replaced wholesale: drop parsed-certificate cache entries so a
        // certificate rotated through sync is re-parsed (the cache is also blob-checked
        // on read, this just frees entries for removed/changed keys).
        certifiedKeyCache.removeAll()

        // Compare for any changes: additions, deletions, or modifications
        var hasChanges = false

        // Check for new or modified keys
        for newKey in savedKeys {
            if let oldKey = oldKeysByID[newKey.id] {
                // Key exists - check if metadata changed
                if oldKey.name != newKey.name ||
                   oldKey.storageLevel != newKey.storageLevel ||
                   oldKey.authRequirement != newKey.authRequirement ||
                   oldKey.securityModifiedDate != newKey.securityModifiedDate ||
                   oldKey.userCertificate != newKey.userCertificate {
                    hasChanges = true
                    let keyName = newKey.name
                    Self.logger.info("Key metadata changed: \(keyName)")
                    break
                }
            } else {
                // New key added
                hasChanges = true
                let keyName = newKey.name
                Self.logger.info("New key discovered: \(keyName)")
                break
            }
        }

        // Check for deleted keys
        if !hasChanges {
            let newIDs = Set(savedKeys.map { $0.id })
            for oldKey in oldKeys {
                if !newIDs.contains(oldKey.id) {
                    hasChanges = true
                    let keyName = oldKey.name
                    Self.logger.info("Key removed: \(keyName)")
                    break
                }
            }
        }

        let defaultsPruned = reconcileDefaultKeyIDs()

        // Backfill blob cache asynchronously: the legacy synchronous path
        // (still used by `init()` on cold-start) does `SecItemCopyMatching`
        // on main per non-blob key, which can stall the FrontBoard scene-
        // update transaction on a contended securityd. The async variant
        // hops Keychain reads to a utility queue and only mutates blobs
        // back on main.
        if hasChanges {
            Task { @MainActor [weak self] in
                await self?.backfillPublicKeyBlobsAsync()
            }
        }

        if hasChanges || defaultsPruned {
            notifyKeysChanged()
        }

        if hasChanges {
            // VPN snapshots embed whether a key is safe for interaction-free
            // background use. A metadata change arriving through iCloud can
            // change that answer without any local migration, so rebuild the
            // snapshots whenever the effective key set changes.

            // Newly synced blobs may carry (or resolve) legacy encryption.
            scheduleLegacyKeyMigrationIfNeeded()

            let keyCount = savedKeys.count
            Self.logger.info("SSH keys refreshed: \(keyCount) keys")
        } else if defaultsPruned {
            let keyCount = savedKeys.count
            Self.logger.info("SSH defaults reconciled: \(keyCount) keys")
        }
    }

    /// Updates a key's name
    /// - Parameters:
    ///   - id: The key ID
    ///   - newName: The new name
    func updateKeyName(id: UUID, newName: String) {
        guard let index = savedKeys.firstIndex(where: { $0.id == id }),
              !newName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        savedKeys[index].name = newName.trimmingCharacters(in: .whitespaces)
        saveKeys()
        notifyKeysChanged()
    }

    // MARK: - User Certificates

    /// Cache of parsed certificates keyed by key ID, invalidated on attach/remove
    /// and cleared on metadata refresh. Each entry carries the source blob and is
    /// only served while it still matches the key's CURRENT stored certificate, so
    /// a rotation that arrives through any path (sync refresh included) can never
    /// be answered with a stale parse. Parsing is cheap; this avoids a re-parse
    /// per connection attempt.
    private var certifiedKeyCache: [UUID: (blob: Data, cert: NIOSSHCertifiedPublicKey)] = [:]

    /// Finds the saved key whose public key matches a certificate's embedded key blob.
    /// Comparison is on normalized wire blobs (see SSHUserCertificateParser).
    func findKey(forCertificateEmbeddedBlob blob: Data) -> SSHKey? {
        savedKeys.first { key in
            guard let cached = key.publicKeyBlob else { return false }
            return SSHUserCertificateParser.normalizedCachedBlob(cached) == blob
        }
    }

    /// Attaches (or replaces) a user certificate on a key after verifying the
    /// certificate's embedded public key matches the key.
    func attachUserCertificate(keyID: UUID, parsed: ParsedUserCertificate) throws {
        guard let index = savedKeys.firstIndex(where: { $0.id == keyID }) else {
            throw ImportError.invalidName
        }
        let key = savedKeys[index]

        guard let cachedBlob = key.publicKeyBlob,
              SSHUserCertificateParser.normalizedCachedBlob(cachedBlob) == parsed.embeddedPublicKeyBlob else {
            throw SSHUserCertificateImportError.keyMismatch(expectedKeyName: key.name)
        }

        let keyName = key.name
        savedKeys[index].userCertificate = parsed.info
        certifiedKeyCache[keyID] = (blob: parsed.info.certificateBlob, cert: parsed.certifiedKey)
        saveKeys()
        notifyKeysChanged()

        let certKeyID = parsed.info.keyID
        Self.logger.info("Attached user certificate '\(certKeyID)' to key '\(keyName)'")
    }

    /// Removes the user certificate from a key.
    func removeUserCertificate(keyID: UUID) {
        guard let index = savedKeys.firstIndex(where: { $0.id == keyID }),
              savedKeys[index].userCertificate != nil else {
            return
        }
        savedKeys[index].userCertificate = nil
        certifiedKeyCache[keyID] = nil
        saveKeys()
        notifyKeysChanged()
    }

    /// Parses the stored certificate blob for a key (cached). Returns nil if the key
    /// has no certificate or the stored blob no longer parses (e.g. synced from a
    /// newer app version with an unknown key type).
    func certifiedPublicKey(forKeyID id: UUID) -> NIOSSHCertifiedPublicKey? {
        guard let key = savedKeys.first(where: { $0.id == id }),
              let certInfo = key.userCertificate else {
            certifiedKeyCache[id] = nil
            return nil
        }
        // Serve the cache only while it matches the current stored blob (a rotation
        // through sync/refresh must re-parse, never return the old certificate).
        if let cached = certifiedKeyCache[id], cached.blob == certInfo.certificateBlob {
            return cached.cert
        }
        let keyName = key.name
        do {
            let cert = try SSHUserCertificateParser.certifiedKey(fromStoredBlob: certInfo.certificateBlob)
            certifiedKeyCache[id] = (blob: certInfo.certificateBlob, cert: cert)
            return cert
        } catch {
            certifiedKeyCache[id] = nil
            Self.logger.error("Stored certificate for key '\(keyName)' failed to parse: \(error.localizedDescription)")
            return nil
        }
    }

    /// The certificate to offer for a connection, or nil to use the plain key only.
    ///
    /// Expired or not-yet-valid certificates are skipped (a guaranteed server-side
    /// reject would burn one of the server's MaxAuthTries attempts); the decision is
    /// recorded in the SSH debug log. A principal/username mismatch still offers the
    /// certificate (servers can map principals via AuthorizedPrincipalsFile), with a
    /// logged warning.
    func usableCertifiedKey(forKeyID id: UUID, username: String) -> NIOSSHCertifiedPublicKey? {
        guard let key = savedKeys.first(where: { $0.id == id }),
              let certInfo = key.userCertificate else {
            return nil
        }

        if certInfo.isExpired {
            return nil
        }
        if certInfo.isNotYetValid {
            return nil
        }
        guard let cert = certifiedPublicKey(forKeyID: id) else { return nil }
        return cert
    }

    // MARK: - Authentication-Aware Key Loading

    /// Loads a private key with authentication if required
    ///
    /// This method provides auth deduplication - if multiple concurrent requests
    /// come in for the same key, only the first one triggers a biometric prompt
    /// and others wait to share the result.
    ///
    /// - Parameter id: The key ID to load
    /// - Returns: The private key as a variant type
    /// - Throws: Error if loading fails or authentication is cancelled
    func loadPrivateKeyWithAuth(id: UUID) async throws -> SSHPrivateKeyVariant {
        Self.logger.info("Loading private key with auth for ID: \(id.uuidString)")

        guard let savedKey = savedKeys.first(where: { $0.id == id }) else {
            throw LoadError.keyNotFound
        }

        // Secure Enclave keys: the biometric/passcode gate lives in the
        // enclave key's own access control and fires at sign time, so we
        // just reconstruct the key (carrying the right LAContext) here.
        if savedKey.secureEnclaveInfo != nil {
            Self.logger.info("Loading Secure Enclave reference (authenticating at load)")
            return try await secureEnclaveVariantAuthenticated(for: savedKey)
        }

        let authManager = SSHKeyAuthManager.shared

        // Check if authentication is needed
        let needsAuth = authManager.needsAuthentication(for: savedKey)
        Self.logger.info("Needs authentication: \(needsAuth) (requirement: \(savedKey.authRequirement.rawValue))")

        // If auth is needed, use deduplication to avoid multiple prompts for concurrent requests
        let keyData: Data
        if needsAuth {
            keyData = try await authManager.loadWithDeduplication(keyID: id) { [keychainManager, authManager] in
                // Create authentication context (must hop to MainActor since authManager is MainActor-isolated)
                let reason = "Authenticate to use '\(savedKey.name)'"
                let context = await MainActor.run {
                    authManager.createContext(for: savedKey, reason: reason)
                }

                // Synchronizable Keychain items intentionally omit
                // SecAccessControl because the device-bound biometric flags
                // are incompatible with iCloud sync. Enforce the metadata's
                // auth requirement locally on every device before reading the
                // synced secret. The same context is passed into the following
                // query for a consistent authenticated-load interface.
                if savedKey.storageLevel == .iCloudSync {
                    try await Self.evaluateDeviceOwnerAuthentication(
                        on: context,
                        reason: reason
                    )
                }

                // Load key data from Keychain with authentication
                do {
                    let data = try keychainManager.loadPrivateKey(
                        identifier: id.uuidString,
                        authRequirement: savedKey.authRequirement,
                        context: context
                    )
                    // Keep the authenticated context so the opportunistic
                    // legacy-key migration can rewrite the item promptless.
                    await MainActor.run {
                        SSHKeyManager.shared.authenticatedLoadContexts[id] = context
                    }
                    return data
                } catch let error as KeychainManager.KeychainError {
                    switch error {
                    case .authenticationCancelled:
                        throw LoadError.authenticationCancelled
                    case .authenticationFailed:
                        throw LoadError.authenticationFailed
                    default:
                        throw error
                    }
                }
            }

            // Record successful authentication for perSession
            if savedKey.authRequirement == .perSession {
                authManager.recordAuthentication(for: id)
            }
        } else {
            // No auth needed, load directly
            do {
                keyData = try keychainManager.loadPrivateKey(
                    identifier: id.uuidString,
                    authRequirement: savedKey.authRequirement,
                    context: nil
                )
            } catch let error as KeychainManager.KeychainError {
                switch error {
                case .authenticationCancelled:
                    throw LoadError.authenticationCancelled
                case .authenticationFailed:
                    throw LoadError.authenticationFailed
                default:
                    throw error
                }
            }
        }

        Self.logger.info("Loaded \(keyData.count) bytes from keychain")

        // Clear the stored context on every exit unless a scheduled
        // migration takes ownership of it.
        var contextOwnedByMigration = false
        defer {
            if !contextOwnedByMigration {
                authenticatedLoadContexts.removeValue(forKey: id)
            }
        }

        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw LoadError.dataConversionFailed
        }

        // Load passphrase if available
        let passphrase = keychainManager.loadPassphrase(forKey: id.uuidString)

        // Parse off-main: bcrypt KDF + AES-CTR for encrypted keys is
        // expensive enough to introduce visible UI hangs every time a
        // biometric-gated key is used. The `keyString`/`passphrase`
        // are plain `String`s (Sendable), so the detached hop is free.
        let parsedKey: SSHKeyParser.ParsedKey
        do {
            parsedKey = try await Task.detached(priority: .userInitiated) {
                try SSHKeyParser.parse(keyString: keyString, passphrase: passphrase)
            }.value
        } catch SSHKeyParser.ParserError.encryptedKeyNeedsPassphrase,
                SSHKeyParser.ParserError.incorrectPassphrase {
            // Legacy-encrypted blob without a usable local passphrase (the
            // passphrase never syncs) — needs a one-time manual unlock.
            applyLegacyMigrationOutcome(.needsUnlock, keyID: id)
            throw LoadError.legacyKeyNeedsUnlock(keyID: id, keyName: savedKey.name)
        }

        // The key just decrypted: normalize the stored blob in place (#285).
        // The stored context stays in place for the migration to consume —
        // dedup waiters all pass through here, and only the first schedules.
        if parsedKey.isEncrypted, let passphrase {
            contextOwnedByMigration = true
            scheduleOpportunisticLegacyMigration(
                id: id,
                keyString: keyString,
                passphrase: passphrase,
                expectedFingerprint: savedKey.fingerprint
            )
        }

        // Return the appropriate key type
        let keyVariant: SSHPrivateKeyVariant
        if let nioSSHKey = parsedKey.nioSSHKey {
            Self.logger.info("Returning standard NIO SSH key (Ed25519/ECDSA)")
            keyVariant = .nioSSH(nioSSHKey)
        } else if let rsaKey = parsedKey.rsaKey {
            Self.logger.info("Returning RSA key from Citadel")
            keyVariant = .rsa(rsaKey.citadelKey)
        } else {
            throw LoadError.invalidKeyData
        }

        // Cache the public key blob if not already cached (for future agent forwarding matching)
        if let keyIndex = savedKeys.firstIndex(where: { $0.id == id }),
           savedKeys[keyIndex].publicKeyBlob == nil {
            let blobBuffer = SSHPublicKeyBlob.make(from: keyVariant, keyType: savedKey.keyType)
            savedKeys[keyIndex].publicKeyBlob = blobBuffer.getData(at: blobBuffer.readerIndex, length: blobBuffer.readableBytes)
            let blobSize = savedKeys[keyIndex].publicKeyBlob?.count ?? 0
            Self.logger.info("Cached public key blob for \(savedKey.name) (\(blobSize) bytes)")
            saveKeys()
        }

        return keyVariant
    }

    // MARK: - Security Migration

    /// Migrates a key to new security settings
    /// - Parameters:
    ///   - id: The key ID to migrate
    ///   - newStorageLevel: The new storage level
    ///   - newAuthRequirement: The new authentication requirement
    /// - Throws: Error if migration fails
    func migrateKeySecurity(
        id: UUID,
        newStorageLevel: KeyStorageLevel,
        newAuthRequirement: KeyAuthRequirement
    ) async throws {
        Self.logger.info("Migrating security for key ID: \(id.uuidString)")

        guard var keyIndex = savedKeys.firstIndex(where: { $0.id == id }) else {
            throw MigrationError.keyNotFound
        }

        let key = savedKeys[keyIndex]
        Self.logger.info("Current: storage=\(key.storageLevel.rawValue), auth=\(key.authRequirement.rawValue)")
        Self.logger.info("New: storage=\(newStorageLevel.rawValue), auth=\(newAuthRequirement.rawValue)")

        // Secure Enclave keys only have metadata stored — the device-bound
        // private key can never be migrated or synchronized.
        if key.isHardwareKey {
            Self.logger.info("Hardware key detected, migrating metadata only")

            var migratedKey = key
            migratedKey.storageLevel = newStorageLevel
            migratedKey.authRequirement = newAuthRequirement
            migratedKey.securityModifiedDate = Date()

            // Migrate metadata keychain item (delete and re-save with new sync flag)
            var metadataWasDeleted = false
            do {
                try keychainManager.deleteSSHKeyMetadata(identifier: id.uuidString)
                metadataWasDeleted = true
                let metadataData = try JSONEncoder().encode(migratedKey)
                try keychainManager.saveSSHKeyMetadata(
                    metadataData,
                    identifier: id.uuidString,
                    storageLevel: newStorageLevel
                )
            } catch {
                let originalError = error
                let rollbackFailures = restoreMetadataAfterFailedMigration(
                    originalKey: key,
                    originalWasDeleted: metadataWasDeleted
                )
                Self.logger.error("Failed to migrate hardware key metadata: \(error.localizedDescription)")
                throw migrationError(original: originalError, rollbackFailures: rollbackFailures)
            }

            savedKeys[keyIndex] = migratedKey
            notifyKeysChanged()
            Self.logger.info("Hardware key migration completed successfully")
            return
        }

        // Step 1: Load existing key data (may require authentication with current settings)
        let keyData: Data
        do {
            // Use existing auth requirement to load
            let context: LAContext?
            if key.authRequirement != .none {
                let authManager = SSHKeyAuthManager.shared
                context = authManager.createContext(for: key, reason: "Authenticate to update '\(key.name)' security settings")
            } else {
                context = nil
            }

            // Synced items have no SecAccessControl for Keychain to evaluate.
            // Authenticate explicitly before allowing a protected key's
            // security metadata or storage placement to be changed.
            if key.storageLevel == .iCloudSync, let context {
                try await Self.evaluateDeviceOwnerAuthentication(
                    on: context,
                    reason: "Authenticate to update '\(key.name)' security settings"
                )
            }

            // The authentication await above is actor-reentrant. A Keychain
            // refresh can replace or reorder savedKeys while the prompt is
            // visible, so never retain the pre-await array index. Re-resolve
            // by identity and require the complete metadata snapshot to still
            // match before the first destructive Keychain operation below.
            guard let currentKeyIndex = savedKeys.firstIndex(where: { $0.id == id }),
                  savedKeys[currentKeyIndex] == key else {
                Self.logger.warning("Aborting security migration because key metadata changed during authentication")
                throw MigrationError.keyChangedDuringAuthentication
            }
            keyIndex = currentKeyIndex

            keyData = try keychainManager.loadPrivateKey(
                identifier: id.uuidString,
                authRequirement: key.authRequirement,
                context: context
            )
        } catch let error as KeychainManager.KeychainError {
            switch error {
            case .authenticationCancelled:
                throw MigrationError.authenticationCancelled
            case .authenticationFailed:
                throw MigrationError.authenticationFailed
            default:
                throw MigrationError.keychainError(error)
            }
        } catch LoadError.authenticationCancelled {
            throw MigrationError.authenticationCancelled
        } catch LoadError.authenticationUnavailable {
            throw MigrationError.authenticationUnavailable
        } catch LoadError.authenticationFailed {
            throw MigrationError.authenticationFailed
        } catch let error as MigrationError {
            throw error
        } catch {
            throw MigrationError.keychainError(error)
        }

        // Step 2: Delete old keychain entry
        do {
            try keychainManager.deletePrivateKey(identifier: id.uuidString)
        } catch {
            throw MigrationError.keychainError(error)
        }

        // Step 3: Save private key with new security settings
        do {
            try keychainManager.savePrivateKey(
                keyData,
                identifier: id.uuidString,
                storageLevel: newStorageLevel,
                authRequirement: newAuthRequirement
            )
        } catch {
            let originalError = error
            Self.logger.error("Private-key migration failed, attempting rollback")
            let rollbackFailures = restorePrivateKeyAfterFailedMigration(keyData, originalKey: key)
            throw migrationError(original: originalError, rollbackFailures: rollbackFailures)
        }

        // Keep the old in-memory metadata authoritative until its durable
        // Keychain replacement succeeds. This is especially important for
        // synchronizable keys, where metadata is the authentication gate.
        var migratedKey = key
        migratedKey.storageLevel = newStorageLevel
        migratedKey.authRequirement = newAuthRequirement
        migratedKey.securityModifiedDate = Date()

        // Step 4: Migrate metadata keychain item (delete and re-save with new sync flag)
        var metadataWasDeleted = false
        do {
            try keychainManager.deleteSSHKeyMetadata(identifier: id.uuidString)
            metadataWasDeleted = true
            let metadataData = try JSONEncoder().encode(migratedKey)
            try keychainManager.saveSSHKeyMetadata(
                metadataData,
                identifier: id.uuidString,
                storageLevel: newStorageLevel
            )
        } catch {
            let originalError = error
            Self.logger.error("Metadata migration failed, restoring original key and metadata")
            var rollbackFailures = restorePrivateKeyAfterFailedMigration(keyData, originalKey: key)
            rollbackFailures.append(contentsOf: restoreMetadataAfterFailedMigration(
                originalKey: key,
                originalWasDeleted: metadataWasDeleted
            ))
            throw migrationError(original: originalError, rollbackFailures: rollbackFailures)
        }

        // Step 5: Publish the new metadata only after both durable items exist.
        savedKeys[keyIndex] = migratedKey
        notifyKeysChanged()

        // Step 6: Clear auth session for this key
        SSHKeyAuthManager.shared.clearAuthentication(for: id)

        Self.logger.info("Migration completed successfully")
    }

    /// Best-effort restoration of the original private-key item. Every step is
    /// attempted so callers can report all rollback failures rather than
    /// abandoning the rollback after the first error.
    private func restorePrivateKeyAfterFailedMigration(
        _ keyData: Data,
        originalKey: SSHKey
    ) -> [String] {
        var failures: [String] = []

        do {
            try keychainManager.deletePrivateKey(identifier: originalKey.id.uuidString)
        } catch {
            failures.append("remove replacement private key: \(error.localizedDescription)")
        }

        do {
            try keychainManager.savePrivateKey(
                keyData,
                identifier: originalKey.id.uuidString,
                storageLevel: originalKey.storageLevel,
                authRequirement: originalKey.authRequirement
            )
        } catch {
            failures.append("restore original private key: \(error.localizedDescription)")
        }

        return failures
    }

    /// Best-effort restoration of the original metadata item and sync class.
    /// If the initial delete failed, the original item is still authoritative
    /// and must not be touched by rollback.
    private func restoreMetadataAfterFailedMigration(
        originalKey: SSHKey,
        originalWasDeleted: Bool
    ) -> [String] {
        guard originalWasDeleted else { return [] }

        do {
            let metadataData = try JSONEncoder().encode(originalKey)
            try keychainManager.saveSSHKeyMetadata(
                metadataData,
                identifier: originalKey.id.uuidString,
                storageLevel: originalKey.storageLevel
            )
        } catch KeychainManager.KeychainError.duplicateItem {
            // An item is already present (for example, restored by Keychain
            // sync while migration was failing). Do not delete it again.
            return []
        } catch {
            return ["restore original metadata: \(error.localizedDescription)"]
        }

        return []
    }

    private func migrationError(original: Error, rollbackFailures: [String]) -> MigrationError {
        guard !rollbackFailures.isEmpty else {
            Self.logger.info("Security migration rollback completed successfully")
            return .keychainError(original)
        }

        let details = rollbackFailures.joined(separator: "; ")
        Self.logger.fault("Security migration rollback incomplete: \(details)")
        return .rollbackFailed(original: original, details: details)
    }

    // MARK: - Private Methods

    /// Discovers keys synced from other devices via iCloud Keychain
    private func discoverSyncedKeys() {
        let existingIDs = Set(savedKeys.map { $0.id.uuidString })
        let newKeys = Self.discoverSyncedKeysFromKeychain(existingIDs: existingIDs)
        if !newKeys.isEmpty {
            savedKeys.append(contentsOf: newKeys)
            Self.logger.info("Added \(newKeys.count) keys synced from iCloud")
        }
    }

    /// Pure Keychain read for synced-key discovery. Safe to invoke from any
    /// thread; caller is responsible for applying results on the main actor.
    private nonisolated static func discoverSyncedKeysFromKeychain(existingIDs: Set<String>) -> [SSHKey] {
        let km = KeychainManager.shared
        let discovered = km.discoverAllSSHKeyMetadata()

        var newKeys: [SSHKey] = []
        for (identifier, data, isSynced) in discovered {
            guard !existingIDs.contains(identifier) else { continue }
            guard isSynced else { continue }

            do {
                let key = try JSONDecoder().decode(SSHKey.self, from: data)
                guard try km.sshPrivateKeyExists(identifier: identifier, synchronizable: true) else {
                    throw KeychainManager.KeychainError.itemNotFound
                }
                newKeys.append(key)
                logger.info("Discovered synced key: \(key.name)")
            } catch {
                logger.warning("Could not load synced key \(identifier): \(error.localizedDescription)")
            }
        }
        return newKeys
    }

    private func loadKeys() {
        savedKeys = Self.loadKeysFromKeychain()
    }

    /// Pure Keychain read for primary key metadata. Safe to invoke from any
    /// thread; caller is responsible for applying results on the main actor.
    private nonisolated static func loadKeysFromKeychain() -> [SSHKey] {
        let km = KeychainManager.shared
        let identifiers = km.listSSHKeyMetadataIdentifiers()
        var keys: [SSHKey] = []

        for identifier in identifiers {
            do {
                let data = try km.loadSSHKeyMetadata(identifier: identifier)
                let key = try JSONDecoder().decode(SSHKey.self, from: data)
                keys.append(key)
            } catch {
                logger.warning("Failed to load key metadata \(identifier): \(error.localizedDescription)")
            }
        }

        logger.info("Loaded \(keys.count) SSH keys from Keychain")
        return keys
    }

    private func saveKeys() {
        // Save each key's metadata to keychain
        for key in savedKeys {
            do {
                let data = try JSONEncoder().encode(key)
                // Try update first, fall back to save if not found
                do {
                    try keychainManager.updateSSHKeyMetadata(data, identifier: key.id.uuidString)
                } catch KeychainManager.KeychainError.itemNotFound {
                    try keychainManager.saveSSHKeyMetadata(
                        data,
                        identifier: key.id.uuidString,
                        storageLevel: key.storageLevel
                    )
                }
            } catch {
                Self.logger.error("Failed to save key metadata \(key.name): \(error.localizedDescription)")
            }
        }
    }

    private func loadDefaultKeyIDs() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultKeyIDsKey),
              let uuidStrings = try? JSONDecoder().decode([String].self, from: data) else {
            defaultKeyIDs = []
            return
        }

        // Convert strings to UUIDs, filtering out invalid ones and keys that no longer exist
        let existingKeyIDs = Set(savedKeys.map { $0.id })
        defaultKeyIDs = uuidStrings.compactMap { UUID(uuidString: $0) }
            .filter { existingKeyIDs.contains($0) }
    }

    private func saveDefaultKeyIDs() {
        let uuidStrings = defaultKeyIDs.map { $0.uuidString }
        if let data = try? JSONEncoder().encode(uuidStrings) {
            UserDefaults.standard.set(data, forKey: Self.defaultKeyIDsKey)
        }
    }

    /// Removes stale or duplicate default key references while preserving order.
    /// - Returns: True if defaults were modified.
    private func reconcileDefaultKeyIDs() -> Bool {
        let existingIDs = Set(savedKeys.map { $0.id })
        let currentDefaults = defaultKeyIDs
        var seen: Set<UUID> = []
        var pruned: [UUID] = []
        pruned.reserveCapacity(currentDefaults.count)

        for id in currentDefaults {
            guard existingIDs.contains(id) else { continue }
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            pruned.append(id)
        }

        guard pruned != currentDefaults else { return false }

        defaultKeyIDs = pruned
        saveDefaultKeyIDs()

        let removedCount = currentDefaults.count - pruned.count
        let remainingCount = pruned.count
        Self.logger.info("Pruned \(removedCount) stale default key reference(s). Remaining defaults: \(remainingCount)")
        return true
    }

    /// Backfill cached public key blobs for identities that don't have them.
    ///
    /// Called on init so every identity has a cached blob for certificate and
    /// public-key matching. Auth-protected identities are skipped: producing
    /// the blob needs a Keychain read, and that would prompt for biometrics at
    /// launch. Their blobs fill in the next time the key is used successfully.
    private func backfillPublicKeyBlobs() {
        var needsSave = false

        for (index, key) in savedKeys.enumerated() {
            guard key.publicKeyBlob == nil else { continue }

            guard key.authRequirement == .none else {
                Self.logger.info("Skipping blob backfill for auth-protected key: \(key.name)")
                continue
            }

            do {
                let keyVariant = try loadPrivateKey(id: key.id)
                savedKeys[index].publicKeyBlob = SSHPublicKeyBlob.makeData(from: keyVariant, keyType: key.keyType)
                let blobSize = savedKeys[index].publicKeyBlob?.count ?? 0
                Self.logger.info("Backfilled public key blob for: \(key.name) (\(blobSize) bytes)")
                needsSave = true
            } catch {
                Self.logger.warning("Failed to backfill blob for \(key.name): \(error.localizedDescription)")
            }
        }

        if needsSave {
            saveKeys()
        }
    }

    /// Async variant of `backfillPublicKeyBlobs` that performs the Keychain
    /// reads off the main actor. Called after a foreground refresh discovers
    /// or modifies keys; the synchronous variant remains for cold-start use
    /// from `init()`.
    private func backfillPublicKeyBlobsAsync() async {
        struct Candidate: Sendable {
            let id: UUID
            let keyType: SSHKey.KeyType
            let name: String
        }

        // Snapshot candidates on main.
        let candidates: [Candidate] = savedKeys.compactMap { key in
            guard key.publicKeyBlob == nil else { return nil }
            guard key.authRequirement == .none else { return nil }
            // Secure Enclave identities get their blob at generation time.
            guard key.secureEnclaveInfo == nil else { return nil }
            return Candidate(id: key.id, keyType: key.keyType, name: key.name)
        }

        guard !candidates.isEmpty else { return }

        var needsSave = false

        for candidate in candidates {
            // Hop off main for the SecItemCopyMatching calls.
            let identifier = candidate.id.uuidString
            let keychainResult: (keyData: Data?, passphrase: String?) = await Task.detached(priority: .utility) {
                let km = KeychainManager.shared
                let keyData = try? km.loadPrivateKey(identifier: identifier)
                let passphrase = km.loadPassphrase(forKey: identifier)
                return (keyData, passphrase)
            }.value

            guard let keyData = keychainResult.keyData,
                  let keyString = String(data: keyData, encoding: .utf8) else {
                continue
            }

            // Re-locate on main: the user may have deleted the key during
            // the off-main read, or another path may have set the blob.
            guard let currentIndex = savedKeys.firstIndex(where: { $0.id == candidate.id }),
                  savedKeys[currentIndex].publicKeyBlob == nil else {
                continue
            }

            do {
                let parsedKey = try SSHKeyParser.parse(keyString: keyString, passphrase: keychainResult.passphrase)
                let keyVariant: SSHPrivateKeyVariant
                if let nio = parsedKey.nioSSHKey {
                    keyVariant = .nioSSH(nio)
                } else if let rsa = parsedKey.rsaKey {
                    keyVariant = .rsa(rsa.citadelKey)
                } else {
                    continue
                }
                let blob = SSHPublicKeyBlob.makeData(from: keyVariant, keyType: candidate.keyType)
                savedKeys[currentIndex].publicKeyBlob = blob
                Self.logger.info("Backfilled public key blob for: \(candidate.name) (\(blob?.count ?? 0) bytes)")
                needsSave = true
            } catch {
                Self.logger.warning("Failed to backfill blob for \(candidate.name): \(error.localizedDescription)")
            }
        }

        if needsSave {
            saveKeys()
        }
    }

    // MARK: - Legacy Encrypted-Key Migration (#285)

    private enum LegacyMigrationOutcome: Sendable {
        case migrated
        case alreadyNormalized
        case clean                // no legacy state; only clear stale markers
        case needsUnlock          // encrypted, no usable local passphrase
        case skipped              // transient; retry on a later scan
    }

    /// Normalize one stored legacy blob in place. The blob header, not the
    /// metadata flag, is authoritative (sync can deliver either first).
    /// Never shows UI; callers must only pass interaction-free items.
    private nonisolated static func runInteractionFreeLegacyMigration(
        identifier: String,
        expectedFingerprint: String,
        hasPassphraseHint: Bool
    ) -> LegacyMigrationOutcome {
        let km = KeychainManager.shared
        let storedPassphrase = km.loadPassphrase(forKey: identifier)

        // Always inspect the blob: normalized metadata can sync before the
        // still-encrypted blob, so the flag alone proves nothing.
        guard let blob = try? km.loadPrivateKey(identifier: identifier),
              let keyString = String(data: blob, encoding: .utf8) else {
            return .skipped
        }

        do {
            switch try OpenSSHKeyNormalizer.normalize(keyString: keyString, passphrase: storedPassphrase) {
            case .alreadyPlaintext, .notOpenSSHContainer:
                return (hasPassphraseHint || storedPassphrase != nil) ? .alreadyNormalized : .clean
            case .normalized(let normalizedText):
                guard let normalizedData = normalizedText.data(using: .utf8),
                      let parsed = try? SSHKeyParser.parse(keyString: normalizedText, passphrase: nil),
                      parsed.fingerprint == expectedFingerprint else {
                    return .skipped
                }
                // Re-read so a newer synced blob is never clobbered.
                guard let current = try? km.loadPrivateKey(identifier: identifier),
                      current == blob else {
                    return .skipped
                }
                do {
                    try km.updatePrivateKey(normalizedData, identifier: identifier)
                } catch {
                    logger.warning("Legacy key migration write failed for \(identifier): \(error.localizedDescription)")
                    return .skipped
                }
                return .migrated
            }
        } catch OpenSSHKeyNormalizer.NormalizerError.passphraseRequired,
                OpenSSHKeyNormalizer.NormalizerError.incorrectPassphrase {
            return .needsUnlock
        } catch {
            logger.warning("Legacy key migration failed for \(identifier): \(error.localizedDescription)")
            return .skipped
        }
    }

    /// Metadata first, passphrase deletion last — re-runnable after a crash
    /// at any boundary.
    private func applyLegacyMigrationOutcome(_ outcome: LegacyMigrationOutcome, keyID: UUID) {
        switch outcome {
        case .migrated, .alreadyNormalized:
            var changed = false
            if let index = savedKeys.firstIndex(where: { $0.id == keyID }),
               savedKeys[index].hasPassphrase {
                savedKeys[index].hasPassphrase = false
                saveKeys()
                changed = true
            }
            keychainManager.deletePassphrase(forKey: keyID.uuidString)
            if keysNeedingUnlock.remove(keyID) != nil { changed = true }
            if case .migrated = outcome {
                Self.logger.info("Normalized legacy encrypted key \(keyID.uuidString) in place")
            }
            if changed { notifyKeysChanged() }
        case .clean:
            if keysNeedingUnlock.remove(keyID) != nil {
                notifyKeysChanged()
            }
        case .needsUnlock:
            if !keysNeedingUnlock.contains(keyID) {
                keysNeedingUnlock.insert(keyID)
                Self.logger.warning("Legacy encrypted key \(keyID.uuidString) has no usable local passphrase; manual unlock required")
                notifyKeysChanged()
            }
        case .skipped:
            break
        }
    }

    /// Background-migrates keys whose items are readable without interaction:
    /// `authRequirement == .none` plus `.iCloudSync` (synced items carry no
    /// SecAccessControl; the app-level gate covers key *use* only).
    /// ACL-protected keys migrate during their next authenticated load.
    func scheduleLegacyKeyMigrationIfNeeded() {
        guard legacyKeyMigrationTask == nil else { return }

        struct Candidate: Sendable {
            let id: UUID
            let fingerprint: String
            let hasPassphrase: Bool
        }
        let candidates: [Candidate] = savedKeys.compactMap { key in
            guard key.secureEnclaveInfo == nil,
                  key.authRequirement == .none || key.storageLevel == .iCloudSync else {
                return nil
            }
            return Candidate(id: key.id, fingerprint: key.fingerprint, hasPassphrase: key.hasPassphrase)
        }
        guard !candidates.isEmpty else { return }

        legacyKeyMigrationTask = Task { @MainActor [weak self] in
            for candidate in candidates {
                let outcome = await Task.detached(priority: .utility) {
                    Self.runInteractionFreeLegacyMigration(
                        identifier: candidate.id.uuidString,
                        expectedFingerprint: candidate.fingerprint,
                        hasPassphraseHint: candidate.hasPassphrase
                    )
                }.value
                guard let self else { return }
                self.applyLegacyMigrationOutcome(outcome, keyID: candidate.id)
            }
            self?.legacyKeyMigrationTask = nil
        }
    }

    /// Normalizes an already-decrypted legacy key after an authenticated
    /// load, reusing that load's stored LAContext so the ACL-protected
    /// re-read and write need no second prompt. Single-flight per key;
    /// Keychain calls stay on the main actor to keep the context in one
    /// isolation region.
    private func scheduleOpportunisticLegacyMigration(
        id: UUID,
        keyString: String,
        passphrase: String,
        expectedFingerprint: String
    ) {
        guard opportunisticMigrationsInFlight.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            let normalizedData: Data? = await Task.detached(priority: .utility) {
                guard case .normalized(let text) = try? OpenSSHKeyNormalizer.normalize(
                    keyString: keyString,
                    passphrase: passphrase
                ),
                      let parsed = try? SSHKeyParser.parse(keyString: text, passphrase: nil),
                      parsed.fingerprint == expectedFingerprint else {
                    return nil
                }
                return text.data(using: .utf8)
            }.value

            guard let self else { return }
            defer {
                self.opportunisticMigrationsInFlight.remove(id)
                self.authenticatedLoadContexts.removeValue(forKey: id)
            }
            guard let normalizedData else { return }

            let identifier = id.uuidString
            let context = self.authenticatedLoadContexts[id]
            // Authenticated re-read (ACL items would otherwise re-prompt):
            // bail if the blob changed since this load decrypted it.
            guard let currentKey = self.savedKeys.first(where: { $0.id == id }),
                  let current = try? self.keychainManager.loadPrivateKey(
                    identifier: identifier,
                    authRequirement: currentKey.authRequirement,
                    context: context
                  ),
                  String(data: current, encoding: .utf8) == keyString else {
                return
            }
            do {
                try self.keychainManager.updatePrivateKey(normalizedData, identifier: identifier, context: context)
            } catch {
                Self.logger.warning("Opportunistic legacy key migration failed for \(identifier): \(error.localizedDescription)")
                return
            }
            self.applyLegacyMigrationOutcome(.migrated, keyID: id)
        }
    }

    /// One-time manual repair for a legacy-encrypted key with no local
    /// passphrase (typically synced from another device). Authenticates per
    /// the key's policy, normalizes, and rewrites the blob in place.
    func unlockLegacyKey(id: UUID, passphrase: String) async throws {
        guard let savedKey = savedKeys.first(where: { $0.id == id }) else {
            throw LoadError.keyNotFound
        }
        let identifier = id.uuidString

        var context: LAContext?
        if savedKey.authRequirement != .none {
            let reason = "Authenticate to unlock '\(savedKey.name)'"
            let ctx = SSHKeyAuthManager.shared.createContext(for: savedKey, reason: reason)
            if savedKey.storageLevel == .iCloudSync {
                try await Self.evaluateDeviceOwnerAuthentication(on: ctx, reason: reason)
            }
            context = ctx
        }

        let keyData: Data
        do {
            keyData = try keychainManager.loadPrivateKey(
                identifier: identifier,
                authRequirement: savedKey.authRequirement,
                context: context
            )
        } catch let error as KeychainManager.KeychainError {
            switch error {
            case .authenticationCancelled: throw LoadError.authenticationCancelled
            case .authenticationFailed: throw LoadError.authenticationFailed
            default: throw error
            }
        }
        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw LoadError.dataConversionFailed
        }

        let expectedFingerprint = savedKey.fingerprint
        let normalizedData: Data? = try await Task.detached(priority: .userInitiated) {
            switch try OpenSSHKeyNormalizer.normalize(keyString: keyString, passphrase: passphrase) {
            case .normalized(let text):
                guard let parsed = try? SSHKeyParser.parse(keyString: text, passphrase: nil),
                      parsed.fingerprint == expectedFingerprint,
                      let data = text.data(using: .utf8) else {
                    throw OpenSSHKeyNormalizer.NormalizerError.verificationFailed("Fingerprint mismatch")
                }
                return data
            case .alreadyPlaintext, .notOpenSSHContainer:
                return nil
            }
        }.value

        if let normalizedData {
            // Authenticated re-read: don't clobber a blob that changed since
            // we loaded it, and don't re-prompt for ACL-protected items.
            let current: Data
            do {
                current = try keychainManager.loadPrivateKey(
                    identifier: identifier,
                    authRequirement: savedKey.authRequirement,
                    context: context
                )
            } catch {
                throw MigrationError.keychainError(error)
            }
            guard current == keyData else {
                throw MigrationError.keyChangedDuringAuthentication
            }
            try keychainManager.updatePrivateKey(normalizedData, identifier: identifier, context: context)
            applyLegacyMigrationOutcome(.migrated, keyID: id)
        } else {
            applyLegacyMigrationOutcome(.alreadyNormalized, keyID: id)
        }
        scheduleLegacyKeyMigrationIfNeeded()
    }

    // MARK: - Error Types

    enum ImportError: LocalizedError {
        case invalidName
        case duplicateKey
        case dataConversionFailed
        case keychainError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidName:
                return "Please provide a valid name for the key."
            case .duplicateKey:
                return "This key is already imported (duplicate fingerprint)."
            case .dataConversionFailed:
                return "Failed to convert key data."
            case .keychainError(let error):
                return error.localizedDescription
            }
        }
    }

    enum DeleteError: LocalizedError {
        case keyNotFound
        case keychainError(Error)

        var errorDescription: String? {
            switch self {
            case .keyNotFound:
                return "Key not found."
            case .keychainError(let error):
                return error.localizedDescription
            }
        }
    }

    enum LoadError: LocalizedError {
        case keyNotFound
        case dataConversionFailed
        case invalidKeyData
        case authenticationRequiresAsyncLoad
        case authenticationCancelled
        case authenticationUnavailable
        case authenticationFailed
        case legacyKeyNeedsUnlock(keyID: UUID, keyName: String)

        var errorDescription: String? {
            switch self {
            case .keyNotFound:
                return "Key not found in keychain."
            case .dataConversionFailed:
                return "Failed to convert key data."
            case .invalidKeyData:
                return "Invalid key data - unable to parse key."
            case .authenticationRequiresAsyncLoad:
                return "This key requires authentication and must be loaded asynchronously."
            case .authenticationCancelled:
                return "Authentication was cancelled."
            case .authenticationUnavailable:
                return "Device authentication is unavailable. Set a device passcode and try again."
            case .authenticationFailed:
                return "Authentication failed. Please try again."
            case .legacyKeyNeedsUnlock(_, let keyName):
                return "'\(keyName)' was imported with a passphrase on another device, and passphrases don't sync. Open Settings → SSH Keys → \(keyName) and unlock it once with its passphrase."
            }
        }
    }

    enum MigrationError: LocalizedError {
        case keyNotFound
        case keychainError(Error)
        case rollbackFailed(original: Error, details: String)
        case keyChangedDuringAuthentication
        case authenticationCancelled
        case authenticationUnavailable
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .keyNotFound:
                return "Key not found."
            case .keychainError(let error):
                return "Keychain error: \(error.localizedDescription)"
            case .rollbackFailed(let original, let details):
                return "Keychain migration failed (\(original.localizedDescription)), and rollback was incomplete: \(details)"
            case .keyChangedDuringAuthentication:
                return "This key changed while authentication was in progress. Review its current security settings and try again."
            case .authenticationCancelled:
                return "Authentication was cancelled."
            case .authenticationUnavailable:
                return "Device authentication is unavailable. Set a device passcode and try again."
            case .authenticationFailed:
                return "Authentication failed. Please try again."
            }
        }
    }

    enum SecureEnclaveError: LocalizedError {
        case unavailable
        case accessControlFailed(CFError?)
        case creationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The Secure Enclave is not available on this device."
            case .accessControlFailed:
                return "Could not configure Secure Enclave protection. A device passcode is required for biometric or passcode-protected keys."
            case .creationFailed(let error):
                return "Failed to create the Secure Enclave key: \(error.localizedDescription)"
            }
        }
    }
}
