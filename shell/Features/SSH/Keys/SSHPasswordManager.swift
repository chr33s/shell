import Foundation
import LocalAuthentication
import os.log

/// Manages SSH passwords stored in the Keychain
@MainActor
@Observable
class SSHPasswordManager {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHPasswordManager")

    static let shared = SSHPasswordManager()

    // MARK: - UserDefaults Keys

    /// Device-local map of `connectionKey -> lastUsedDate`. Kept out of the
    /// synchronizable Keychain metadata so a connect can update "last used"
    /// without re-writing (and thus resurrecting) a synced password item.
    private static let lastUsedDatesKey = "sshPasswordLastUsedDates"

    // MARK: - Published Properties

    /// All saved password metadata (actual passwords stored in Keychain)
    private(set) var savedPasswords: [SSHSavedPassword] = []

    /// Default storage level for new passwords
    var defaultStorageLevel: KeyStorageLevel {
        didSet {
            guard !isReloading else { return }
            SettingsStore.shared.set(Settings.Connections.passwordDefaultStorageLevel, defaultStorageLevel)
        }
    }

    /// Default auth requirement for new passwords
    var defaultAuthRequirement: KeyAuthRequirement {
        didSet {
            guard !isReloading else { return }
            SettingsStore.shared.set(Settings.Connections.passwordDefaultAuthRequirement, defaultAuthRequirement)
        }
    }

    @ObservationIgnored private var isReloading = false

    // MARK: - Session-based Auth Cache

    /// Tracks passwords that have been authenticated this session (for .perSession requirement)
    private var sessionAuthenticatedPasswords: Set<String> = []

    private let keychainManager: KeychainManager

    private init() {
        self.keychainManager = KeychainManager.shared
        self.defaultStorageLevel = SettingsStore.shared.get(Settings.Connections.passwordDefaultStorageLevel)
        self.defaultAuthRequirement = SettingsStore.shared.get(Settings.Connections.passwordDefaultAuthRequirement)

        // Load saved passwords from Keychain
        loadPasswords()

        SettingsRefreshHub.shared.register(keys: [
            Settings.Connections.passwordDefaultStorageLevel.name,
            Settings.Connections.passwordDefaultAuthRequirement.name,
        ]) { [weak self] keys in self?.reload(keys: keys) }
    }

    private func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if keys.contains(Settings.Connections.passwordDefaultStorageLevel.name) {
            defaultStorageLevel = SettingsStore.shared.get(Settings.Connections.passwordDefaultStorageLevel)
        }
        if keys.contains(Settings.Connections.passwordDefaultAuthRequirement.name) {
            defaultAuthRequirement = SettingsStore.shared.get(Settings.Connections.passwordDefaultAuthRequirement)
        }
    }

    // MARK: - Public Methods

    /// Saves a new SSH password
    /// - Parameters:
    ///   - password: The password string
    ///   - host: The hostname or IP
    ///   - port: The port (default: 22)
    ///   - username: The username
    ///   - storageLevel: Storage level (defaults to app-wide setting)
    ///   - authRequirement: Auth requirement (defaults to app-wide setting)
    /// - Returns: The saved password metadata
    /// - Throws: Error if save fails
    @discardableResult
    func savePassword(
        _ password: String,
        host: String,
        port: Int = 22,
        username: String,
        storageLevel: KeyStorageLevel? = nil,
        authRequirement: KeyAuthRequirement? = nil
    ) throws -> SSHSavedPassword {
        let effectiveStorageLevel = storageLevel ?? defaultStorageLevel
        let effectiveAuthRequirement = authRequirement ?? defaultAuthRequirement
        let connectionKey = SSHSavedPassword.makeConnectionKey(host: host, port: port, username: username)

        Self.logger.info("Saving password for \(connectionKey)")

        // Check if we already have a password for this connection
        if let existingIndex = savedPasswords.firstIndex(where: { $0.connectionKey == connectionKey }) {
            // No-op when the stored password is unchanged. A routine reconnect
            // re-asserts the same password; re-writing the synchronizable
            // Keychain item would overwrite a deletion that propagated from
            // another device (iCloud Keychain is last-writer-wins). We only
            // skip when we can verify equality WITHOUT prompting — for an
            // auth-gated entry we can't read non-interactively, so we fall
            // through and honor the write (a genuine change must not be lost).
            if let stored = currentStoredPasswordWithoutPrompt(
                connectionKey: connectionKey,
                authRequirement: savedPasswords[existingIndex].authRequirement
            ), stored == password {
                Self.logger.info("Password for \(connectionKey) unchanged — skipping Keychain write")
                return savedPasswords[existingIndex]
            }

            // Update existing
            Self.logger.info("Updating existing password for \(connectionKey)")
            try keychainManager.updateSSHPassword(password, connectionKey: connectionKey)

            // Update metadata
            savedPasswords[existingIndex].lastModifiedDate = Date()
            try savePasswordMetadata(savedPasswords[existingIndex])

            return savedPasswords[existingIndex]
        }

        // Create new password entry
        let savedPassword = SSHSavedPassword(
            host: host,
            port: port,
            username: username,
            storageLevel: effectiveStorageLevel,
            authRequirement: effectiveAuthRequirement
        )

        // Save password to Keychain
        try keychainManager.saveSSHPassword(
            password,
            connectionKey: connectionKey,
            storageLevel: effectiveStorageLevel,
            authRequirement: effectiveAuthRequirement
        )

        // Save metadata
        try savePasswordMetadata(savedPassword)

        // Add to in-memory list
        savedPasswords.append(savedPassword)

        Self.logger.info("Saved password for \(connectionKey)")

        return savedPassword
    }

    /// Loads a password from the Keychain
    /// - Parameters:
    ///   - host: The hostname or IP
    ///   - port: The port (default: 22)
    ///   - username: The username
    /// - Returns: The password string
    /// - Throws: Error if load fails or authentication is cancelled
    func loadPassword(host: String, port: Int = 22, username: String) async throws -> String {
        let connectionKey = SSHSavedPassword.makeConnectionKey(host: host, port: port, username: username)
        return try await loadPassword(connectionKey: connectionKey)
    }

    /// Loads a password from the Keychain using connection key
    /// - Parameter connectionKey: The connection key
    /// - Returns: The password string
    /// - Throws: Error if load fails or authentication is cancelled
    func loadPassword(connectionKey: String) async throws -> String {
        Self.logger.info("Loading password for \(connectionKey)")

        guard let savedPassword = savedPasswords.first(where: { $0.connectionKey == connectionKey }) else {
            throw PasswordError.notFound
        }

        // Check if authentication is needed
        let needsAuth = needsAuthentication(for: savedPassword)
        Self.logger.info("Needs authentication: \(needsAuth) (requirement: \(savedPassword.authRequirement.rawValue))")

        let context: LAContext?
        if needsAuth {
            context = createContext(for: savedPassword)
        } else {
            context = nil
        }

        do {
            let password = try keychainManager.loadSSHPassword(
                connectionKey: connectionKey,
                authRequirement: savedPassword.authRequirement,
                context: context
            )

            // Record successful authentication for perSession
            if savedPassword.authRequirement == .perSession {
                sessionAuthenticatedPasswords.insert(connectionKey)
            }

            // Update last used date — DEVICE-LOCAL ONLY. We deliberately do
            // not call `savePasswordMetadata` here: re-writing the
            // synchronizable Keychain metadata on every connect would
            // resurrect a password the user deleted on another device (iCloud
            // Keychain is last-writer-wins, so a write after a delete wins).
            if let index = savedPasswords.firstIndex(where: { $0.connectionKey == connectionKey }) {
                let now = Date()
                savedPasswords[index].lastUsedDate = now
                setLastUsedDate(now, for: connectionKey)
            }

            return password
        } catch let error as KeychainManager.KeychainError {
            switch error {
            case .authenticationCancelled:
                throw PasswordError.authenticationCancelled
            case .authenticationFailed:
                throw PasswordError.authenticationFailed
            case .itemNotFound:
                throw PasswordError.notFound
            default:
                throw PasswordError.keychainError(error)
            }
        }
    }

    /// Checks if a password exists for the given connection
    /// - Parameters:
    ///   - host: The hostname or IP
    ///   - port: The port (default: 22)
    ///   - username: The username
    /// - Returns: true if a password is saved
    func hasPassword(host: String, port: Int = 22, username: String) -> Bool {
        let connectionKey = SSHSavedPassword.makeConnectionKey(host: host, port: port, username: username)
        return hasPassword(connectionKey: connectionKey)
    }

    /// Checks if a password exists for the given connection key
    /// - Parameter connectionKey: The connection key
    /// - Returns: true if a password is saved
    func hasPassword(connectionKey: String) -> Bool {
        savedPasswords.contains(where: { $0.connectionKey == connectionKey })
    }

    /// Deletes a saved password
    /// - Parameter connectionKey: The connection key to delete
    /// - Throws: Error if deletion fails
    func deletePassword(connectionKey: String) throws {
        Self.logger.info("Deleting password for \(connectionKey)")

        // Delete from Keychain
        try keychainManager.deleteSSHPassword(connectionKey: connectionKey)
        try keychainManager.deleteSSHPasswordMetadata(connectionKey: connectionKey)

        // Remove from in-memory list
        savedPasswords.removeAll(where: { $0.connectionKey == connectionKey })

        // Drop the device-local last-used timestamp.
        removeLastUsedDate(for: connectionKey)

        // Clear session auth
        sessionAuthenticatedPasswords.remove(connectionKey)

        // Strip any inline `.password(secret)` still held by a profile for this
        // connection so profile sanitization cannot re-migrate the secret back
        // into the Keychain (which would resurrect the entry we just deleted).
        ConnectionProfileManager.shared.stripInlinePassword(forConnectionKey: connectionKey)

        Self.logger.info("Deleted password for \(connectionKey)")
    }

    /// Deletes a saved password by ID
    /// - Parameter id: The password entry ID
    /// - Throws: Error if deletion fails
    func deletePassword(id: UUID) throws {
        guard let savedPassword = savedPasswords.first(where: { $0.id == id }) else {
            throw PasswordError.notFound
        }
        try deletePassword(connectionKey: savedPassword.connectionKey)
    }

    /// Refreshes the password list from Keychain. Runs `SecItemCopyMatching`
    /// off the main actor so a slow securityd cannot block the FrontBoard
    /// scene-update transaction during foreground resume; awaitable so callers
    /// know when the refresh has applied.
    ///
    /// `shouldApply` is an optional pre-apply guard called after the
    /// detached Keychain read returns, just before the `@Published
    /// savedPasswords` mutation. Lifecycle callers pass a `LifecycleEpoch`
    /// check so a backgrounding that lands during the Keychain read aborts
    /// the apply instead of publishing onto a backgrounded scene. Returning
    /// `false` leaves `savedPasswords` unchanged; the next refresh after the
    /// real foreground resume will pick up the latest Keychain state.
    func refreshPasswordsAsync(shouldApply: (@MainActor () -> Bool)? = nil) async {
        let oldSnapshot = savedPasswords
        let oldKeys = Set(oldSnapshot.map { $0.connectionKey })

        let loaded = await Task.detached(priority: .utility) {
            Self.loadPasswordsFromKeychain()
        }.value

        // Stale-result guard: if the user (or another refresh) mutated
        // `savedPasswords` while our Keychain read was in flight, do not
        // overwrite the newer state with our background snapshot.
        guard savedPasswords == oldSnapshot else {
            Self.logger.info("Skipping refreshPasswords apply: savedPasswords mutated during background read")
            return
        }

        // Caller-provided lifecycle guard — checked AFTER the await but
        // BEFORE the @Published mutation, closing the residual race that the
        // pre-await wrapper at the call site cannot cover.
        if let shouldApply, !shouldApply() {
            return
        }

        savedPasswords = loaded
        applyStoredLastUsedDates()
        let newKeys = Set(savedPasswords.map { $0.connectionKey })
        if oldKeys != newKeys {
            Self.logger.info("SSH passwords refreshed: \(self.savedPasswords.count) passwords")
        }
    }

    // MARK: - Private Methods

    private func loadPasswords() {
        savedPasswords = Self.loadPasswordsFromKeychain()
        applyStoredLastUsedDates()
    }

    /// Pure Keychain read for password metadata. Safe to invoke from any
    /// thread; caller is responsible for applying results on the main actor.
    private nonisolated static func loadPasswordsFromKeychain() -> [SSHSavedPassword] {
        let km = KeychainManager.shared
        let connectionKeys = km.listSSHPasswordConnectionKeys()
        var passwords: [SSHSavedPassword] = []

        for connectionKey in connectionKeys {
            do {
                let data = try km.loadSSHPasswordMetadata(connectionKey: connectionKey)
                let password = try JSONDecoder().decode(SSHSavedPassword.self, from: data)
                passwords.append(password)
            } catch {
                logger.warning("Failed to load password metadata \(connectionKey): \(error.localizedDescription)")
            }
        }

        logger.info("Loaded \(passwords.count) SSH passwords from Keychain")
        return passwords.sorted { $0.lastModifiedDate > $1.lastModifiedDate }
    }

    private func savePasswordMetadata(_ password: SSHSavedPassword) throws {
        let data = try JSONEncoder().encode(password)

        // Skip the write when the stored metadata is byte-identical. Avoids
        // re-touching the synchronizable Keychain item on no-op saves, which
        // would resurrect a password deleted on another device.
        if let existing = try? keychainManager.loadSSHPasswordMetadata(connectionKey: password.connectionKey),
           existing == data {
            return
        }

        // Try update first, fall back to save if not found
        do {
            try keychainManager.updateSSHPasswordMetadata(data, connectionKey: password.connectionKey)
        } catch KeychainManager.KeychainError.itemNotFound {
            try keychainManager.saveSSHPasswordMetadata(
                data,
                connectionKey: password.connectionKey,
                storageLevel: password.storageLevel
            )
        }
    }

    /// Reads the currently-stored password WITHOUT presenting authentication
    /// UI. Returns `nil` when the value can't be read non-interactively (an
    /// auth-gated item under `.perUse`/`.perSession`) or doesn't exist. Used by
    /// `savePassword` to detect a no-op save without prompting on a reconnect.
    private func currentStoredPasswordWithoutPrompt(
        connectionKey: String,
        authRequirement: KeyAuthRequirement
    ) -> String? {
        let context: LAContext?
        if authRequirement == .none {
            context = nil
        } else {
            let c = LAContext()
            c.interactionNotAllowed = true
            context = c
        }
        return try? keychainManager.loadSSHPassword(
            connectionKey: connectionKey,
            authRequirement: authRequirement,
            context: context
        )
    }

    // MARK: - Device-local last-used timestamps

    /// `connectionKey -> lastUsedDate`, persisted in `UserDefaults` (device
    /// local, never synced). Kept out of the synchronizable Keychain metadata
    /// so bumping "last used" on connect can't resurrect a deleted password.
    private static func loadLastUsedDates() -> [String: Date] {
        guard let raw = UserDefaults.standard.data(forKey: lastUsedDatesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: raw)) ?? [:]
    }

    private static func saveLastUsedDates(_ map: [String: Date]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: lastUsedDatesKey)
    }

    private func setLastUsedDate(_ date: Date, for connectionKey: String) {
        var map = Self.loadLastUsedDates()
        map[connectionKey] = date
        Self.saveLastUsedDates(map)
    }

    private func removeLastUsedDate(for connectionKey: String) {
        var map = Self.loadLastUsedDates()
        guard map.removeValue(forKey: connectionKey) != nil else { return }
        Self.saveLastUsedDates(map)
    }

    /// Populates `savedPasswords[*].lastUsedDate` from the device-local store
    /// after a Keychain load (which decodes `lastUsedDate` as `nil`).
    private func applyStoredLastUsedDates() {
        let map = Self.loadLastUsedDates()
        guard !map.isEmpty else { return }
        for index in savedPasswords.indices {
            savedPasswords[index].lastUsedDate = map[savedPasswords[index].connectionKey]
        }
    }

    private func needsAuthentication(for password: SSHSavedPassword) -> Bool {
        switch password.authRequirement {
        case .none:
            return false
        case .perSession:
            return !sessionAuthenticatedPasswords.contains(password.connectionKey)
        case .perUse:
            return true
        }
    }

    private func createContext(for password: SSHSavedPassword) -> LAContext {
        let context = LAContext()
        context.localizedReason = "Authenticate to use password for '\(password.displayName)'"

        // For perSession, allow reuse within this context
        if password.authRequirement == .perSession {
            context.touchIDAuthenticationAllowableReuseDuration = 300 // 5 minutes
        }

        return context
    }

    // MARK: - Error Types

    enum PasswordError: LocalizedError {
        case notFound
        case authenticationCancelled
        case authenticationFailed
        case keychainError(Error)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Password not found."
            case .authenticationCancelled:
                return "Authentication was cancelled."
            case .authenticationFailed:
                return "Authentication failed. Please try again."
            case .keychainError(let error):
                return "Keychain error: \(error.localizedDescription)"
            }
        }
    }
}
