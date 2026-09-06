//
//  ConnectionProfileManager.swift
//  shell
//
//  Persistent storage for saved SSH profiles.
//

import Foundation
import Observation
import os.log

/// Manages persistent storage of SSH connection profiles.
@MainActor
@Observable
final class ConnectionProfileManager {
    static let shared = ConnectionProfileManager()
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHProfiles")

    /// File store for sync-ready per-record storage
    private var store: SyncableFileStore<SSHProfile>

    /// Sorted profiles (by name), excluding deleted
    private(set) var profiles: [SSHProfile] = []

    /// All records including tombstones (for CloudKit sync)
    var allRecordsForSync: [SSHProfile] {
        store.allRecords
    }

    /// Whether the last disk load failed to list the store directory
    var lastDiskLoadFailed: Bool {
        store.lastLoadFailed
    }

    /// Callback for CloudKit sync integration
    var onLocalChange: ((SSHProfile, SyncOperation) -> Void)? {
        didSet {
            store.onLocalChange = onLocalChange
        }
    }

    private init() {
        self.store = SyncableFileStore<SSHProfile>(storeName: "ssh_profiles")
        sanitizePersistedProfiles()
        updateProfilesFromStore()
    }

    // MARK: - CRUD

    /// Create and persist a new profile.
    @discardableResult
    func createProfile(name: String, sshConfig: SSHConfig) throws -> SSHProfile {
        let profile = SSHProfile(name: name, sshConfig: sshConfig)
        try persistProfile(profile)
        updateProfilesFromStore()
        Self.logger.info("Created profile '\(name)'")
        return store.record(for: profile.id) ?? sanitizeProfileForPersistence(profile)
    }

    /// Update an existing profile
    func updateProfile(_ profile: SSHProfile) throws {
        guard store.record(for: profile.id) != nil else {
            Self.logger.warning("Attempted to update non-existent profile \(profile.id.uuidString)")
            return
        }

        try persistProfile(profile)
        updateProfilesFromStore()

        Self.logger.info("Updated profile '\(profile.name)'")
    }

    /// Delete a profile (soft delete for sync)
    func deleteProfile(id: UUID) throws {
        try store.softDelete(id: id)
        updateProfilesFromStore()

        Self.logger.info("Deleted profile \(id.uuidString)")
    }

    /// Duplicate a profile
    @discardableResult
    func duplicateProfile(id: UUID, newName: String? = nil) throws -> SSHProfile? {
        guard let original = store.record(for: id), !original.isDeleted else {
            Self.logger.warning("Attempted to duplicate non-existent profile \(id.uuidString)")
            return nil
        }

        let duplicateName = newName ?? "\(original.name) (Copy)"
        let duplicate = SSHProfile(name: duplicateName, sshConfig: original.sshConfig)

        try persistProfile(duplicate)
        updateProfilesFromStore()

        Self.logger.info("Duplicated profile '\(original.name)' as '\(duplicateName)'")
        return store.record(for: duplicate.id) ?? sanitizeProfileForPersistence(duplicate)
    }

    /// Record that a profile was used
    func recordUsage(id: UUID) {
        guard var profile = store.record(for: id) else { return }

        profile.lastUsedAt = Date()
        profile.useCount += 1
        try? persistProfile(profile, updateTimestamp: false, notifySync: false)
        updateProfilesFromStore()
    }

    // MARK: - Queries

    func profile(for id: UUID) -> SSHProfile? {
        profiles.first { $0.id == id }
    }

    func profiles(matching searchText: String) -> [SSHProfile] {
        searchText.isEmpty ? profiles : profiles.filter { $0.matches(searchText) }
    }

    /// Most-recently-used profiles first, for the launch screen and pickers.
    func getSuggestions(matching searchText: String, limit: Int = 10) -> [SSHProfile] {
        profiles(matching: searchText)
            .sorted { p1, p2 in
                if let d1 = p1.lastUsedAt, let d2 = p2.lastUsedAt {
                    return d1 > d2
                }
                if p1.lastUsedAt != nil { return true }
                if p2.lastUsedAt != nil { return false }
                return p1.useCount > p2.useCount
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Sync Support

    /// Apply changes from remote sync
    @discardableResult
    func applyRemoteChanges(_ remoteProfiles: [SSHProfile]) -> Int {
        applyRemoteChangesWithFailures(remoteProfiles).applied
    }

    /// Apply changes from remote sync, returning both successful applies and any persistence failures.
    func applyRemoteChangesWithFailures(
        _ remoteProfiles: [SSHProfile]
    ) -> (applied: Int, failures: [(id: UUID, error: Error)]) {
        Self.logger.info("applyRemoteChanges called with \(remoteProfiles.count) profiles")
        var applied = 0
        var failures: [(id: UUID, error: Error)] = []

        for remote in remoteProfiles {
            let needsPersist: Bool
            if let existing = store.record(for: remote.id) {
                needsPersist = remote.modifiedAt > existing.modifiedAt
            } else {
                needsPersist = true
            }
            guard needsPersist else { continue }

            do {
                try persistProfile(remote, updateTimestamp: false, notifySync: false)
                applied += 1
            } catch {
                failures.append((id: remote.id, error: error))
                let idString = remote.id.uuidString
                let name = remote.name
                let desc = error.localizedDescription
                Self.logger.error("Failed to persist remote profile \(idString) '\(name)': \(desc)")
            }
        }

        let failureCount = failures.count
        Self.logger.info("Applied \(applied) remote changes to profiles (\(failureCount) failures)")
        updateProfilesFromStore()
        return (applied, failures)
    }

    /// Apply remote deletions from CloudKit change sets
    func applyRemoteDeletions(recordNames: Set<String>) {
        guard !recordNames.isEmpty else { return }

        var deletedCount = 0

        for profile in profiles {
            let recordName = CloudKitRecordName.make(
                recordType: SSHProfile.recordType,
                identity: profile.id.uuidString
            )
            if recordNames.contains(recordName) {
                var deleted = profile
                deleted.isDeleted = true
                deleted.modifiedAt = Date()
                try? persistProfile(deleted, updateTimestamp: false, notifySync: false)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            Self.logger.info("Applied \(deletedCount) remote deletions to profiles")
            updateProfilesFromStore()
        }
    }

    /// Get profiles modified after a given date (for sync)
    func profilesModifiedAfter(_ date: Date) -> [SSHProfile] {
        store.recordsModifiedAfter(date)
    }

    /// Reload all records from disk
    func reload() {
        store.reload()
        updateProfilesFromStore()
    }

    /// Reload all profiles from disk (recovery path when the initial load failed)
    func reloadFromDisk() {
        reload()
    }

    /// Removes any inline `.password(secret)` a profile still holds for the
    /// given connection (`host:port:username`), in both the main config and a
    /// jump host. Called by `SSHPasswordManager.deletePassword` so that profile
    /// sanitization can't later re-migrate the secret into the Keychain and
    /// resurrect the password the user just deleted.
    func stripInlinePassword(forConnectionKey connectionKey: String) {
        for profile in store.allRecords {
            var updated = profile
            var changed = false

            if Self.inlinePasswordMatches(updated.sshConfig.authMethod,
                                          host: updated.sshConfig.host,
                                          port: updated.sshConfig.port,
                                          username: updated.sshConfig.username,
                                          connectionKey: connectionKey) {
                updated.sshConfig.authMethod = .password("")
                changed = true
            }

            if var jump = updated.sshConfig.jumpHost,
               Self.inlinePasswordMatches(jump.authMethod,
                                          host: jump.host,
                                          port: jump.port,
                                          username: jump.username,
                                          connectionKey: connectionKey) {
                jump.authMethod = .password("")
                updated.sshConfig.jumpHost = jump
                changed = true
            }

            guard changed else { continue }
            // Saved directly, bypassing sanitization (which would re-create the
            // Keychain entry we are trying to drop).
            try? store.save(updated, updateTimestamp: true, notifySync: true)
        }
        updateProfilesFromStore()
    }

    private static func inlinePasswordMatches(
        _ authMethod: SSHConfig.AuthMethod,
        host: String,
        port: Int,
        username: String,
        connectionKey: String
    ) -> Bool {
        guard case .password(let secret) = authMethod, !secret.isEmpty else { return false }
        return SSHSavedPassword.makeConnectionKey(host: host, port: port, username: username) == connectionKey
    }

    // MARK: - Persistence

    private func updateProfilesFromStore() {
        profiles = store.activeRecords
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func persistProfile(
        _ profile: SSHProfile,
        updateTimestamp: Bool = true,
        notifySync: Bool = true
    ) throws {
        let sanitized = sanitizeProfileForPersistence(profile)
        try store.save(sanitized, updateTimestamp: updateTimestamp, notifySync: notifySync)
    }

    private func sanitizePersistedProfiles() {
        var rewrittenProfiles = 0

        for profile in store.allRecords {
            let sanitized = sanitizeProfileForPersistence(profile)
            guard sanitized != profile else { continue }

            do {
                try store.save(sanitized, updateTimestamp: false, notifySync: false)
                rewrittenProfiles += 1
            } catch {
                let profileID = profile.id.uuidString
                Self.logger.error("Failed to sanitize persisted profile \(profileID): \(error.localizedDescription)")
            }
        }

        if rewrittenProfiles > 0 {
            Self.logger.info("Sanitized \(rewrittenProfiles) persisted profile records to remove JSON passwords")
        }
    }

    private func sanitizeProfileForPersistence(_ profile: SSHProfile) -> SSHProfile {
        var sanitized = profile
        sanitized.sshConfig = sanitizeSSHConfigForPersistence(profile.sshConfig)
        return sanitized
    }

    private func sanitizeSSHConfigForPersistence(_ config: SSHConfig) -> SSHConfig {
        var sanitized = config
        sanitized.authMethod = sanitizeAuthMethod(
            sanitized.authMethod,
            host: sanitized.host,
            port: sanitized.port,
            username: sanitized.username
        )

        if var jumpHost = sanitized.jumpHost {
            jumpHost.authMethod = sanitizeAuthMethod(
                jumpHost.authMethod,
                host: jumpHost.host,
                port: jumpHost.port,
                username: jumpHost.username
            )
            sanitized.jumpHost = jumpHost
        }

        // Stamp cross-device key-resolution hints (fingerprint, name, algorithm)
        // for the identities this device holds. Merge rather than replace: a
        // hint that arrived from another device names an identity we may not
        // have, and a wholesale overwrite here would destroy it on the first
        // local re-save — which is exactly the case the hints exist for.
        var hints = sanitized.keyResolutionHints ?? [:]
        hints.merge(KeyResolutionHint.hints(for: sanitized) ?? [:]) { _, local in local }
        sanitized.keyResolutionHints = hints.isEmpty ? nil : hints

        return sanitized
    }

    /// Inline passwords never reach disk: they move to the Keychain and the
    /// profile keeps a `.savedPassword` reference instead.
    private func sanitizeAuthMethod(
        _ authMethod: SSHConfig.AuthMethod,
        host: String,
        port: Int,
        username: String
    ) -> SSHConfig.AuthMethod {
        guard case .password(let password) = authMethod else {
            return authMethod
        }

        guard !password.isEmpty else {
            return .password("")
        }

        let connectionKey = SSHSavedPassword.makeConnectionKey(host: host, port: port, username: username)

        // If a saved password already exists, just reference it — don't re-save
        // the inline secret. A re-save re-touches the synchronizable Keychain
        // item and can resurrect a password deleted on another device.
        if SSHPasswordManager.shared.hasPassword(connectionKey: connectionKey) {
            return .savedPassword
        }

        do {
            try SSHPasswordManager.shared.savePassword(
                password,
                host: host,
                port: port,
                username: username
            )
            return .savedPassword
        } catch {
            Self.logger.error("Failed to migrate inline password for \(connectionKey): \(error.localizedDescription)")
            return .password("")
        }
    }
}
