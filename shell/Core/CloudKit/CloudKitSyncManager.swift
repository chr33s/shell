//
//  CloudKitSyncManager.swift
//  shell
//
//  Main orchestrator for CloudKit sync operations
//

import Foundation
import CloudKit
import Network
import Observation
import os.log

/// Main manager for CloudKit sync operations
@MainActor
@Observable
final class CloudKitSyncManager {
    /// Shared singleton instance
    static let shared = CloudKitSyncManager()

    /// The fork's own CloudKit container (spec section 8). Read from
    /// `Info.plist` so the value tracks `Configuration/Base.xcconfig`.
    static let containerIdentifier: String = {
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "ShellCloudKitContainer") as? String
        let trimmed = fromPlist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "iCloud.dev.chr33s.shell" : trimmed
    }()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "CloudKitSync")

    // MARK: - Observable State

    /// Whether sync is enabled
    private(set) var isSyncEnabled: Bool = false

    /// Whether SSH history sync is enabled
    private(set) var isIdentityMetadataSyncEnabled: Bool = false

    /// Whether known hosts sync is enabled
    private(set) var isKnownHostsSyncEnabled: Bool = false

    /// Whether connection profiles sync is enabled
    private(set) var isProfilesSyncEnabled: Bool = false

    /// Whether app settings sync is enabled (opt-in, never auto-enabled)
    private(set) var isAppSettingsSyncEnabled: Bool = false

    /// Current sync state
    private(set) var syncState: CloudKitSyncState = .disabled

    /// Last successful sync date
    private(set) var lastSyncDate: Date?

    /// Number of pending changes
    var pendingChangesCount: Int {
        offlineQueue.count
    }

    // MARK: - CloudKit Components

    /// CloudKit container
    private let container: CKContainer

    /// Private database
    private let database: CKDatabase

    /// Offline queue for pending changes
    private let offlineQueue = CloudKitOfflineQueue()

    /// Last known server copies of AppSetting records, keyed by record name, so
    /// saves carry a change tag and conflicts surface instead of overwriting.
    @ObservationIgnored
    private var settingServerRecords: [String: CKRecord] = [:]

    /// Bumped whenever settings sync state is torn down (disable, master
    /// disable, account switch). In-flight saves compare it after each await
    /// and drop their results if it moved.
    @ObservationIgnored
    private var settingsSyncGeneration = 0

    private func invalidateSettingsSync() {
        settingsSyncGeneration += 1
        offlineQueue.removeAll(recordType: AppSettingRecord.recordType)
        settingServerRecords = [:]
    }

    /// JSON decoder for pending change payloads
    private let payloadDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Network path monitor
    @ObservationIgnored
    private var pathMonitor: NWPathMonitor?

    /// Whether network is available
    @ObservationIgnored
    private var isNetworkAvailable = true

    /// Record zone change token for incremental fetches
    @ObservationIgnored
    private var zoneChangeToken: CKServerChangeToken?

    // MARK: - Initialization

    private init() {
        self.container = CKContainer(identifier: Self.containerIdentifier)
        self.database = container.privateCloudDatabase

        // Load settings
        loadSettings()

        // Load change token
        loadChangeToken()

        // Start network monitoring
        startNetworkMonitoring()

        // Set up manager callbacks for sync integration
        setupManagerCallbacks()

        startAccountChangeObservation()
    }

    /// Set up callbacks to receive local changes from managers
    private func setupManagerCallbacks() {
        // SSH identity metadata changes (public halves only)
        SSHIdentityMetadataStore.shared.onLocalChange = { [weak self] metadata, operation in
            self?.recordLocalChange(metadata, operation: operation)
        }
        // The key manager's launch-time backfill runs here, immediately after
        // the callback above exists, rather than from `SSHKeyManager.init()`.
        // The store skips a record whose content is unchanged, so only the
        // first publish can fire `onLocalChange`: backfilling from that init
        // meant a device that touched `SSHKeyManager.shared` first wrote the
        // metadata to disk with no callback attached and pushed nothing.
        SSHKeyManager.shared.publishInitialIdentityMetadata()

        // Known Hosts changes
        KnownHostsManager.shared.onLocalChange = { [weak self] host, operation in
            self?.recordLocalChange(host, operation: operation)
        }

        // Connection Profiles changes
        ConnectionProfileManager.shared.onLocalChange = { [weak self] profile, operation in
            self?.recordLocalChange(profile, operation: operation)
        }

        // App settings: batched by the coordinator, pushed here
        let coordinator = SettingsSyncCoordinator.shared
        coordinator.isEnabled = isSyncEnabled && isAppSettingsSyncEnabled
        coordinator.onOutgoingBatch = { [weak self] records in
            self?.recordLocalSettingChanges(records)
        }
    }

    // MARK: - Account identity

    /// Set when the signed-in Apple Account changed under an enabled settings sync.
    private(set) var settingsSyncPausedForAccountChange = false

    @ObservationIgnored
    private var accountChangeObserver: NSObjectProtocol?

    private func startAccountChangeObservation() {
        guard accountChangeObserver == nil else { return }
        accountChangeObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                await CloudKitSyncManager.shared.checkAccountIdentity()
            }
        }
    }

    /// Detect an Apple Account switch. `ubiquityIdentityToken` is unreliable
    /// with CloudKit-only entitlements, so compare the user record ID.
    func checkAccountIdentity() async {
        guard isSyncEnabled else { return }
        let identity: String
        do {
            identity = try await container.userRecordID().recordName
        } catch {
            Self.logger.debug("Account identity unavailable: \(error.localizedDescription)")
            return
        }
        let coordinator = SettingsSyncCoordinator.shared
        let previous = coordinator.sidecar.accountIdentity
        guard let previous else {
            coordinator.setAccountIdentity(identity)
            return
        }
        guard previous != identity else { return }

        Self.logger.warning("Apple Account changed; resetting sync state and pausing settings sync")
        zoneChangeToken = nil
        saveChangeToken()
        offlineQueue.clearAll()
        invalidateSettingsSync()
        coordinator.resetSyncState()
        coordinator.setAccountIdentity(identity)
        if isAppSettingsSyncEnabled {
            isAppSettingsSyncEnabled = false
            coordinator.isEnabled = false
            settingsSyncPausedForAccountChange = true
            saveSettings()
        }
    }

    // MARK: - App Settings Sync

    enum SettingsSyncEnableOutcome {
        case enabled
        case needsMergeChoice(SettingsMergePreview)
    }

    /// Push a batch of changed setting records, or queue them offline.
    private func recordLocalSettingChanges(_ records: [AppSettingRecord]) {
        guard isSyncEnabled, isAppSettingsSyncEnabled else { return }
        if isNetworkAvailable && !isRateLimitBackoff {
            Task { await pushRecords(records) }
        } else {
            for record in records {
                offlineQueue.enqueue(record, operation: record.isDeleted ? .delete : .update)
            }
        }
    }

    /// Enable settings sync. When both this device and iCloud already hold
    /// settings the caller must present the merge choice and complete it.
    func setAppSettingsSyncEnabled(_ enabled: Bool) async throws -> SettingsSyncEnableOutcome {
        let coordinator = SettingsSyncCoordinator.shared
        guard enabled else {
            isAppSettingsSyncEnabled = false
            coordinator.isEnabled = false
            coordinator.resetSyncState()
            // Queued edits must not drain later under a disabled toggle.
            invalidateSettingsSync()
            saveSettings()
            return .enabled
        }
        guard isSyncEnabled else { throw CloudKitSyncError.notEnabled }
        guard !isAppSettingsSyncEnabled else { return .enabled }
        settingsSyncPausedForAccountChange = false

        syncState = .fetchingChanges
        do {
            _ = try await ensureCustomZoneReady()
            // The decision ahead is only about AppSetting records, and the user
            // has not answered the merge dialog yet — so read those and nothing
            // else, and leave every other record class (and the change token)
            // to the regular sync path.
            let settingRecords = try await fetchSettingRecordsFromScratch()
            // Replace the cache rather than merge into it. An entry left behind
            // by an earlier attempt the user cancelled may name a record that
            // has since been deleted server-side, and this read — taken with
            // the toggle still off, so no save is relying on those change tags
            // — is the authority on what the zone holds now.
            settingServerRecords = Dictionary(
                settingRecords.map { ($0.recordID.recordName, $0) },
                uniquingKeysWith: { $1 })
            let cloud = settingRecords.compactMap { AppSettingRecord.from($0) }
            let preview = coordinator.mergePreview(cloud: cloud)

            // A cloud holding only resets still conflicts with local values.
            //
            // Asked at most once per account. The merge question exists only
            // because a device joining a settings zone for the first time has
            // no per-key timestamps to compare, so one side has to win
            // wholesale. A device that has already merged does have them, and
            // `completeInitialMerge` routes it to the ordinary per-key resolver
            // instead — re-asking there would offer the user a destructive
            // overwrite of settings that are already reconciled.
            if !coordinator.hasCompletedInitialMerge,
               preview.cloudCount > 0 || preview.resetCount > 0,
               preview.localCount > 0 {
                syncState = .idle
                return .needsMergeChoice(preview)
            }
            // Ignored once the merge has run; see `completeInitialMerge`.
            let choice: SettingsMergeChoice = preview.cloudCount > 0 ? .useCloud : .uploadLocal
            try await completeAppSettingsSyncEnable(preview: preview, choice: choice)
            return .enabled
        } catch let error as CloudKitSyncError {
            syncState = .error(error)
            throw error
        } catch let ckError as CKError {
            let syncError = CloudKitSyncError.from(ckError)
            syncState = .error(syncError)
            throw syncError
        }
    }

    /// The merge dialog was dismissed without a choice: the toggle snaps back
    /// and the flag stays false. Drop the record cache the preview fetch filled,
    /// because `completeAppSettingsSyncEnable` prefers that cache over
    /// `preview.cloud` — a record deleted server-side between this attempt and
    /// a later confirm would otherwise linger there and be merged back in as a
    /// cloud value. Cleared here, a later confirm re-reads the zone.
    func cancelAppSettingsSyncEnable() {
        // Only a cancel that leaves sync off may clear this: once the toggle is
        // on, the cache holds the change tags that keep saves conditional.
        guard !isAppSettingsSyncEnabled else { return }
        settingServerRecords = [:]
    }

    /// Finish enabling after the merge choice (or automatically when one side was empty).
    func completeAppSettingsSyncEnable(preview: SettingsMergePreview, choice: SettingsMergeChoice) async throws {
        let coordinator = SettingsSyncCoordinator.shared
        syncState = .pushingChanges
        // Fetches while the sheet was open updated the record cache but were
        // otherwise dropped, so merge from the cache rather than the preview.
        let cloud = settingServerRecords.isEmpty
            ? preview.cloud
            : settingServerRecords.values.compactMap { AppSettingRecord.from($0) }
        let toPush = coordinator.completeInitialMerge(cloud: cloud, choice: choice)
        isAppSettingsSyncEnabled = true
        coordinator.isEnabled = true
        saveSettings()
        if !toPush.isEmpty {
            await pushRecords(toPush)
        }
        syncState = .idle
        Self.logger.info("App settings sync enabled (\(toPush.count) records pushed)")
    }

    /// Batched save with per-record results; conflicts are merged per key.
    private func pushRecords(_ records: [AppSettingRecord]) async {
        guard !records.isEmpty, isSyncEnabled, isAppSettingsSyncEnabled else { return }
        let coordinator = SettingsSyncCoordinator.shared
        let generation = settingsSyncGeneration
        for chunk in stride(from: 0, to: records.count, by: 200).map({ Array(records[$0..<min($0 + 200, records.count)]) }) {
            do {
                let outcome = try await saveRecords(chunk)
                guard generation == settingsSyncGeneration, isAppSettingsSyncEnabled else {
                    Self.logger.info("Dropping results of a settings push that outlived its sync session")
                    return
                }
                coordinator.markPushed(outcome.saved)
                if !outcome.serverWins.isEmpty {
                    coordinator.applyRemote(outcome.serverWins)
                }
                for record in outcome.failed {
                    offlineQueue.enqueue(record, operation: record.isDeleted ? .delete : .update)
                }
            } catch is CancellationError {
                return
            } catch let error as CKError where error.code == .requestRateLimited {
                guard generation == settingsSyncGeneration else { return }
                let retryAfter = error.retryAfterSeconds ?? 30
                Self.logger.warning("Rate limited pushing settings, queuing \(chunk.count) and backing off \(retryAfter)s")
                for record in chunk { offlineQueue.enqueue(record, operation: record.isDeleted ? .delete : .update) }
                isRateLimitBackoff = true
                scheduleRateLimitedRetry(after: retryAfter)
                return
            } catch {
                guard generation == settingsSyncGeneration else { return }
                Self.logger.warning("Failed to push settings batch, queuing: \(error.localizedDescription)")
                for record in chunk { offlineQueue.enqueue(record, operation: record.isDeleted ? .delete : .update) }
            }
        }
    }

    private struct SettingsSaveOutcome {
        var saved: [AppSettingRecord] = []
        var serverWins: [AppSettingRecord] = []
        var failed: [AppSettingRecord] = []
    }

    /// Saves are conditional on the server change tag, so an older offline edit
    /// can never overwrite newer cloud state; conflicts are settled per key.
    private func saveRecords(_ records: [AppSettingRecord]) async throws -> SettingsSaveOutcome {
        let byName = Dictionary(records.map { (AppSettingRecord.recordName(for: $0), $0) }, uniquingKeysWith: { $1 })
        let toSave: [CKRecord] = byName.map { name, local in
            if let known = settingServerRecords[name] {
                local.apply(to: known)
                return known
            }
            return local.toCKRecord()
        }
        let generation = settingsSyncGeneration
        let (saveResults, _) = try await database.modifyRecords(
            saving: toSave,
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: false
        )
        // Sync was torn down while the request was in flight; touch nothing.
        guard generation == settingsSyncGeneration else { throw CancellationError() }
        var outcome = SettingsSaveOutcome()
        var retry: [CKRecord] = []
        for (recordID, result) in saveResults {
            guard let local = byName[recordID.recordName] else { continue }
            switch result {
            case .success(let saved):
                settingServerRecords[recordID.recordName] = saved
                outcome.saved.append(local)
            case .failure(let error):
                if let ckError = error as? CKError, ckError.code == .serverRecordChanged,
                   let serverRecord = ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                    settingServerRecords[recordID.recordName] = serverRecord
                    guard let serverModel = AppSettingRecord.from(serverRecord) else {
                        // Unreadable server copy: replace it with the local value.
                        local.apply(to: serverRecord)
                        retry.append(serverRecord)
                        continue
                    }
                    let decision = SettingsMergeResolver.resolve(
                        local: .init(value: local.isDeleted ? nil : local.payload, modifiedAt: local.modifiedAt, deviceID: local.deviceID),
                        remote: .init(value: serverModel.payload, modifiedAt: serverModel.modifiedAt, deviceID: serverModel.deviceID),
                        alreadyPushed: false)
                    switch decision {
                    case .keepLocalAndPush, .keepLocal:
                        local.apply(to: serverRecord)
                        retry.append(serverRecord)
                    case .applyRemote:
                        outcome.serverWins.append(serverModel)
                    case .noop:
                        outcome.saved.append(local)
                    }
                } else if let ckError = error as? CKError, ckError.code == .requestRateLimited {
                    throw ckError
                } else {
                    Self.logger.warning("Setting record \(local.key, privacy: .public) failed: \(error.localizedDescription)")
                    outcome.failed.append(local)
                }
            }
        }
        if !retry.isEmpty {
            let (retryResults, _) = try await database.modifyRecords(
                saving: retry, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            guard generation == settingsSyncGeneration else { throw CancellationError() }
            for (recordID, result) in retryResults {
                guard let local = byName[recordID.recordName] else { continue }
                switch result {
                case .success(let saved):
                    settingServerRecords[recordID.recordName] = saved
                    outcome.saved.append(local)
                case .failure:
                    // Lost a second race; the queue retries and the next fetch brings the winner.
                    outcome.failed.append(local)
                }
            }
        }
        return outcome
    }

    // MARK: - Public API

    /// Revalidate subscriptions on app launch (ensures correct subscription type is registered)
    /// Call this from app startup when sync is already enabled
    func revalidateSubscriptionsIfNeeded() async {
        guard isSyncEnabled else {
            Self.logger.debug("Subscription revalidation skipped: sync not enabled")
            return
        }

        Self.logger.info("Revalidating CloudKit subscriptions on app launch")
        await checkAccountIdentity()
        await recoverEmptyLocalStoresIfNeeded()
        do {
            let shouldPushAll = try await ensureCustomZoneReady()
            try await registerSubscriptions()

            // If the zone was created during revalidation, push records now.
            // The push-all decision must be forwarded: performSync re-runs
            // ensureCustomZoneReady, which returns false now that the zone
            // exists.
            if shouldPushAll {
                Self.logger.info("Zone created during revalidation, triggering sync")
                try await performSync(forcePushAll: true)
            } else {
                // Log current state for debugging
                Self.logger.debug("Revalidation complete. Identity metadata enabled: \(self.isIdentityMetadataSyncEnabled), KnownHosts enabled: \(self.isKnownHostsSyncEnabled), Profiles enabled: \(self.isProfilesSyncEnabled)")
            }
        } catch {
            Self.logger.warning("Failed to revalidate subscriptions: \(error.localizedDescription)")
        }
    }

    /// Whether empty-store recovery already ran this process
    @ObservationIgnored
    private var didAttemptEmptyStoreRecovery = false

    /// Self-heal for stores that load empty despite having synced before.
    ///
    /// The launch-time sync is delta-only (change token), so if a local store
    /// comes up empty — e.g. the directory listing failed transiently on first
    /// launch after an app update — nothing repopulates it and the UI shows no
    /// records until the user cycles the iCloud sync toggle. Detect that state,
    /// retry the disk load, and if a store is still empty perform the same full
    /// zone refetch that re-enabling sync does.
    ///
    /// Stores that are empty but hold tombstones do NOT trigger this: a user
    /// who deleted all their records keeps tombstones on disk, so this cannot
    /// resurrect deliberate deletions. The refetch itself is last-write-wins
    /// and applies remote tombstones, so it is safe to run against any state.
    private func recoverEmptyLocalStoresIfNeeded() async {
        guard !didAttemptEmptyStoreRecovery else { return }
        didAttemptEmptyStoreRecovery = true

        guard isSyncEnabled else { return }
        // Only recover stores that have synced before — a fresh enable goes
        // through performInitialSync and needs no help.
        guard zoneChangeToken != nil || lastSyncDate != nil else { return }

        let stores: [(recordType: String, enabled: Bool, count: () -> Int, loadFailed: () -> Bool, reload: () -> Void)] = [
            (ConnectionProfile.recordType,
             isProfilesSyncEnabled,
             { ConnectionProfileManager.shared.allRecordsForSync.count },
             { ConnectionProfileManager.shared.lastDiskLoadFailed },
             { ConnectionProfileManager.shared.reloadFromDisk() }),
            (SSHIdentityMetadata.recordType,
             isIdentityMetadataSyncEnabled,
             { SSHIdentityMetadataStore.shared.allRecordsForSync.count },
             { SSHIdentityMetadataStore.shared.lastDiskLoadFailed },
             { SSHIdentityMetadataStore.shared.reload() }),
            (KnownHost.recordType,
             isKnownHostsSyncEnabled,
             { KnownHostsManager.shared.allRecordsForSync.count },
             { KnownHostsManager.shared.lastDiskLoadFailed },
             { KnownHostsManager.shared.reload() }),
        ]

        var refetchCandidates: [(recordType: String, count: () -> Int)] = []
        for store in stores where store.enabled && store.count() == 0 {
            let recordType = store.recordType
            let initialLoadFailed = store.loadFailed()
            store.reload()
            let recovered = store.count()
            if recovered > 0 {
                Self.logger.fault("\(recordType) store was empty at launch (listing failed: \(initialLoadFailed)) but disk reload recovered \(recovered) records")
                continue
            }

            // A failed directory listing is a hard signal that the data is
            // unreadable, not absent — always recover. An empty store with a
            // clean listing may be legitimately empty (e.g. no known hosts
            // yet), so refetch for it at most once rather than every launch.
            let loadFailed = initialLoadFailed || store.loadFailed()
            let attemptKey = Self.emptyRecoveryAttemptKey(recordType)
            if !loadFailed && UserDefaults.standard.bool(forKey: attemptKey) {
                continue
            }

            Self.logger.fault("\(recordType) store is empty with no tombstones (listing failed: \(loadFailed)) but sync ran before — forcing full CloudKit refetch")
            refetchCandidates.append((recordType, store.count))
        }

        guard !refetchCandidates.isEmpty else { return }

        do {
            syncState = .fetchingChanges
            let shouldPushAll = try await ensureCustomZoneReady()
            let changes = try await fetchZoneChanges(resetToken: true)
            await processChangedRecords(changes.records)
            await processDeletedRecords(changes.deletedRecords)

            if shouldPushAll {
                // ensureCustomZoneReady may have just created the zone —
                // push now or the local records never reach the custom zone.
                syncState = .pushingChanges
                try await pushAllLocalRecords()
            }

            for candidate in refetchCandidates {
                let attemptKey = Self.emptyRecoveryAttemptKey(candidate.recordType)
                if candidate.count() > 0 {
                    // Records came back, so the empty store was abnormal —
                    // allow recovery to run again if it ever recurs.
                    UserDefaults.standard.removeObject(forKey: attemptKey)
                } else {
                    UserDefaults.standard.set(true, forKey: attemptKey)
                }
            }

            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: CloudKitSyncSettings.lastSyncDateKey)
            syncState = .idle
            Self.logger.info("Empty-store recovery refetch completed")
        } catch {
            // Leave the state usable for the regular sync paths that follow.
            // Attempt flags are untouched so the refetch retries next launch.
            syncState = .idle
            let desc = error.localizedDescription
            Self.logger.error("Empty-store recovery refetch failed: \(desc)")
        }
    }

    private static func emptyRecoveryAttemptKey(_ recordType: String) -> String {
        "cloudKitEmptyRecoveryAttempted.\(recordType)"
    }

    /// Enable or disable sync
    func setEnabled(_ enabled: Bool) async throws {
        guard enabled != isSyncEnabled else { return }

        if enabled {
            syncState = .checkingAccount

            // Check iCloud account status
            let status = try await container.accountStatus()
            guard status == .available else {
                syncState = .error(.accountNotAvailable)
                throw CloudKitSyncError.accountNotAvailable
            }

            // Set flags BEFORE initial sync so pushAllLocalRecords knows what to push.
            isSyncEnabled = true
            // The three per-class toggles default on, but only the first time
            // sync is enabled. Thereafter an explicit choice wins: a user who
            // turned "Sync Profiles" off and later cycled the master toggle
            // used to get profile sync back without being asked.
            let firstEnable = Self.firstEnableFlags()
            isIdentityMetadataSyncEnabled = firstEnable.identityMetadata
            isKnownHostsSyncEnabled = firstEnable.knownHosts
            isProfilesSyncEnabled = firstEnable.profiles

            do {
                // Ensure custom zone exists
                _ = try await ensureCustomZoneReady()

                // Register subscriptions
                try await registerSubscriptions()

                // Record the account before any data moves, so a later switch is detected.
                await checkAccountIdentity()

                // Perform initial sync
                syncState = .fetchingChanges
                try await performInitialSync()

                // Save settings (flags already set above)
                saveSettings()

                syncState = .idle
                Self.logger.info("CloudKit sync enabled")
            } catch {
                // Reset flags on failure
                isSyncEnabled = false
                isIdentityMetadataSyncEnabled = false
                isKnownHostsSyncEnabled = false
                isProfilesSyncEnabled = false
                throw error
            }

        } else {
            // Cancel active operations
            syncState = .disabled

            // Remove subscriptions
            try? await removeSubscriptions()

            // Clear change token
            zoneChangeToken = nil
            saveChangeToken()

            // Clear offline queue
            offlineQueue.clearAll()
            invalidateSettingsSync()

            // Save settings. The in-memory per-class flags go false so nothing
            // can push while sync is off; `saveSettings()` keeps their stored
            // preferences exactly as the user left them.
            isSyncEnabled = false
            isIdentityMetadataSyncEnabled = false
            isKnownHostsSyncEnabled = false
            isProfilesSyncEnabled = false
            isAppSettingsSyncEnabled = false
            SettingsSyncCoordinator.shared.isEnabled = false
            SettingsSyncCoordinator.shared.resetSyncState()
            saveSettings()

            Self.logger.info("CloudKit sync disabled")
        }
    }

    /// Set whether SSH identity metadata sync is enabled
    func setIdentityMetadataSyncEnabled(_ enabled: Bool) {
        guard enabled != isIdentityMetadataSyncEnabled else { return }
        isIdentityMetadataSyncEnabled = enabled
        // Both names are written so the UI-facing key and the inherited
        // rootshell name can never disagree; `loadSettings()` prefers the
        // former and falls back to the latter.
        UserDefaults.standard.set(enabled, forKey: CloudKitSyncSettings.syncHistoryKey)
        UserDefaults.standard.set(enabled, forKey: CloudKitSyncSettings.syncIdentityMetadataKey)
        guard enabled, isSyncEnabled else { return }
        Task { await backfill(SSHIdentityMetadataStore.shared.allRecordsForSync) }
    }

    /// Set whether known hosts sync is enabled
    func setKnownHostsSyncEnabled(_ enabled: Bool) {
        guard enabled != isKnownHostsSyncEnabled else { return }
        isKnownHostsSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: CloudKitSyncSettings.syncKnownHostsKey)
        guard enabled, isSyncEnabled else { return }
        Task { await backfill(KnownHostsManager.shared.allRecordsForSync) }
    }

    /// Set whether connection profiles sync is enabled
    func setProfilesSyncEnabled(_ enabled: Bool) {
        guard enabled != isProfilesSyncEnabled else { return }
        isProfilesSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: CloudKitSyncSettings.syncProfilesKey)
        guard enabled, isSyncEnabled else { return }
        Task { await backfill(ConnectionProfileManager.shared.allRecordsForSync) }
    }

    /// Re-push a record class that was just switched back on, so edits made
    /// while it was off are not silently missing from iCloud. Uses the same
    /// per-record path as `pushAllLocalRecords()`, which already diverts to the
    /// offline queue under rate-limit backoff.
    private func backfill<T: CloudKitSyncable>(_ records: [T]) async {
        guard !records.isEmpty else { return }
        Self.logger.info("Backfilling \(records.count) \(T.recordType) records after re-enable")
        for record in records {
            await pushRecord(record, operation: .create)
        }
    }

    /// Trigger a manual sync
    func syncNow() async throws {
        guard isSyncEnabled else { return }
        guard syncState == .idle || syncState.hasError else { return }

        try await performSync()
    }

    /// Log diagnostic information for debugging sync issues
    func logDiagnostics() async {
        Self.logger.info("=== CloudKit Sync Diagnostics ===")
        Self.logger.info("Sync enabled: \(self.isSyncEnabled)")
        Self.logger.info("Identity metadata sync enabled: \(self.isIdentityMetadataSyncEnabled)")
        Self.logger.info("Known hosts sync enabled: \(self.isKnownHostsSyncEnabled)")
        Self.logger.info("Profiles sync enabled: \(self.isProfilesSyncEnabled)")
        Self.logger.info("App settings sync enabled: \(self.isAppSettingsSyncEnabled)")
        let coordinator = SettingsSyncCoordinator.shared
        let registry = SettingsRegistry.shared
        Self.logger.info("Settings registry: \(registry.definitions.count) keys, \(registry.syncableKeys.count) syncable, \(coordinator.pinnedDefinitions().count) pinned, \(coordinator.sidecar.pinnedGroups.count) pinned groups, \(coordinator.sidecar.deferredRemote.count) deferred remote")
        Self.logger.info("Current state: \(String(describing: self.syncState))")
        Self.logger.info("Last sync: \(self.lastSyncDate?.description ?? "never")")
        Self.logger.info("Pending changes: \(self.pendingChangesCount)")
        Self.logger.info("Has change token: \(self.zoneChangeToken != nil)")
        Self.logger.info("Network available: \(self.isNetworkAvailable)")

        if isSyncEnabled {
            // Check iCloud account status
            do {
                let status = try await container.accountStatus()
                Self.logger.info("iCloud account status: \(String(describing: status))")
            } catch {
                Self.logger.warning("Failed to check iCloud account: \(error.localizedDescription)")
            }

            // Check zone exists
            do {
                let zone = try await fetchRecordZone(CloudKitSyncSettings.zoneID)
                Self.logger.info("Custom zone exists: \(zone != nil)")
            } catch {
                Self.logger.warning("Failed to check zone: \(error.localizedDescription)")
            }

            // Check subscription
            do {
                let subscription = try await database.subscription(for: "shell-sync-zone-changes")
                Self.logger.info("Zone subscription exists: \(subscription is CKRecordZoneSubscription)")
            } catch {
                Self.logger.info("Zone subscription: not found")
            }
        } else {
            Self.logger.info("CloudKit sync disabled, skipping remote diagnostics")
        }

        // Log local record counts (active vs total including tombstones)
        let identityActive = SSHIdentityMetadataStore.shared.entries.count
        let identityTotal = SSHIdentityMetadataStore.shared.allRecordsForSync.count
        let hostsActive = KnownHostsManager.shared.allHosts.count
        let hostsTotal = KnownHostsManager.shared.allRecordsForSync.count
        let profilesActive = ConnectionProfileManager.shared.profiles.count
        let profilesTotal = ConnectionProfileManager.shared.allRecordsForSync.count
        Self.logger.info("Local SSH identity metadata: \(identityActive) active, \(identityTotal) total (including \(identityTotal - identityActive) tombstones)")
        Self.logger.info("Local known hosts: \(hostsActive) active, \(hostsTotal) total (including \(hostsTotal - hostsActive) tombstones)")
        Self.logger.info("Local profiles: \(profilesActive) active, \(profilesTotal) total (including \(profilesTotal - profilesActive) tombstones)")

        Self.logger.info("=== End Diagnostics ===")
    }

    /// Handle a remote notification (called from AppDelegate)
    func handleRemoteNotification() async {
        guard isSyncEnabled else {
            Self.logger.debug("Remote notification ignored: sync not enabled")
            return
        }
        guard syncState == .idle else {
            Self.logger.debug("Remote notification ignored: sync state is \(String(describing: self.syncState))")
            return
        }

        Self.logger.info("Handling remote notification, waiting for CloudKit propagation...")

        // Delay to allow CloudKit to propagate the change across servers
        // Push notifications often arrive before data is queryable
        try? await Task.sleep(for: .seconds(2))

        Self.logger.info("Starting sync after delay")
        do {
            try await performSync()
            Self.logger.info("Remote notification sync completed successfully")
        } catch {
            Self.logger.warning("Remote notification sync failed: \(error.localizedDescription)")
        }

        // Schedule a follow-up sync in case CloudKit was still propagating
        // This catches records that weren't available on first fetch
        Task {
            try? await Task.sleep(for: .seconds(5))
            guard syncState == .idle else { return }
            Self.logger.info("Running follow-up sync for late-arriving CloudKit data")
            try? await performSync()
        }
    }

    /// Record a local change for sync
    func recordLocalChange<T: CloudKitSyncable>(_ record: T, operation: SyncOperation) {
        guard isSyncEnabled else { return }

        // Check if this record type should be synced
        switch T.recordType {
        case SSHIdentityMetadata.recordType:
            guard isIdentityMetadataSyncEnabled else { return }
        case KnownHost.recordType:
            guard isKnownHostsSyncEnabled else { return }
        case ConnectionProfile.recordType:
            guard isProfilesSyncEnabled else { return }
        case AppSettingRecord.recordType:
            guard isAppSettingsSyncEnabled else { return }
        default:
            break
        }

        if isNetworkAvailable {
            // Try to sync immediately
            Task {
                await pushRecord(record, operation: operation)
            }
        } else {
            // Queue for later
            offlineQueue.enqueue(record, operation: operation)
        }
    }

    // MARK: - Sync Operations

    /// Perform a full sync cycle
    /// - Parameter forcePushAll: Push all local records even if the zone was
    ///   already ready (used when the caller observed zone creation in its
    ///   own ensureCustomZoneReady call).
    private func performSync(forcePushAll: Bool = false) async throws {
        syncState = .fetchingChanges

        do {
            // Ensure custom zone exists
            let zoneRequiresPush = try await ensureCustomZoneReady()
            let shouldPushAll = forcePushAll || zoneRequiresPush

            // Fetch remote changes from the custom zone
            let changes = try await fetchZoneChanges()
            await processChangedRecords(changes.records)
            await processDeletedRecords(changes.deletedRecords)

            // Push local changes
            syncState = .pushingChanges

            if shouldPushAll {
                // Zone was just created - push all local records
                Self.logger.info("Pushing all local records to custom zone")
                try await pushAllLocalRecords()
            } else {
                // Normal sync - just push pending changes from offline queue
                try await pushPendingChanges()
            }

            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: CloudKitSyncSettings.lastSyncDateKey)

            syncState = .idle
            Self.logger.info("Sync completed successfully")

        } catch let error as CloudKitSyncError {
            syncState = .error(error)
            throw error
        } catch let ckError as CKError {
            let syncError = CloudKitSyncError.from(ckError)
            syncState = .error(syncError)
            throw syncError
        } catch {
            let syncError = CloudKitSyncError.unknown(error)
            syncState = .error(syncError)
            throw syncError
        }
    }

    /// Perform initial sync when first enabling
    private func performInitialSync() async throws {
        // Ensure custom zone exists
        _ = try await ensureCustomZoneReady()

        // Fetch all existing records from the custom zone
        let changes = try await fetchZoneChanges(resetToken: true)
        await processChangedRecords(changes.records)
        await processDeletedRecords(changes.deletedRecords)

        // Push all local records to seed the zone
        try await pushAllLocalRecords()

        lastSyncDate = Date()
        UserDefaults.standard.set(lastSyncDate, forKey: CloudKitSyncSettings.lastSyncDateKey)
    }

    private struct DeletedRecord {
        let recordID: CKRecord.ID
        let recordType: CKRecord.RecordType
    }

    private struct ZoneChanges {
        let records: [CKRecord]
        let deletedRecords: [DeletedRecord]
        let newChangeToken: CKServerChangeToken?
    }

    /// Ensure the custom record zone exists
    /// - Returns: true if the zone was just created and local records should be pushed
    private func ensureCustomZoneReady() async throws -> Bool {
        let zoneID = CloudKitSyncSettings.zoneID
        let existingZone = try await fetchRecordZone(zoneID)

        var zoneCreated = false
        if existingZone == nil {
            try await saveRecordZone(CKRecordZone(zoneID: zoneID))
            zoneCreated = true
            zoneChangeToken = nil
            saveChangeToken()
            Self.logger.info("Created custom CloudKit zone: \(zoneID.zoneName)")
        }

        return zoneCreated
    }

    /// Fetch a record zone by ID
    private func fetchRecordZone(_ zoneID: CKRecordZone.ID) async throws -> CKRecordZone? {
        do {
            let results = try await database.recordZones(for: [zoneID])
            if let result = results[zoneID] {
                switch result {
                case .success(let zone):
                    return zone
                case .failure(let error):
                    throw error
                }
            }
            return nil
        } catch let error as CKError where error.code == .zoneNotFound {
            return nil
        }
    }

    /// Save a record zone (no-op if it already exists)
    private func saveRecordZone(_ zone: CKRecordZone) async throws {
        do {
            _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Zone already exists (server rejected), ignore
        } catch let error as CKError where error.code == .partialFailure {
            // Check if the partial failure is due to zone already existing
            if let partialErrors = error.partialErrorsByItemID,
               partialErrors.values.allSatisfy({ ($0 as? CKError)?.code == .serverRejectedRequest }) {
                // All failures are "already exists" type, ignore
            } else {
                throw error
            }
        }
    }

    /// Fetch incremental changes from the custom zone
    private func fetchZoneChanges(resetToken: Bool = false) async throws -> ZoneChanges {
        if resetToken {
            zoneChangeToken = nil
            saveChangeToken()
        }

        do {
            let changes = try await fetchZoneChangesInternal(previousToken: zoneChangeToken)
            zoneChangeToken = changes.newChangeToken
            saveChangeToken()
            return changes
        } catch let ckError as CKError where ckError.code == .changeTokenExpired {
            Self.logger.warning("Zone change token expired, refetching from scratch")
            zoneChangeToken = nil
            saveChangeToken()
            let changes = try await fetchZoneChangesInternal(previousToken: nil)
            zoneChangeToken = changes.newChangeToken
            saveChangeToken()
            return changes
        } catch let ckError as CKError where ckError.code == .zoneNotFound {
            Self.logger.warning("Custom CloudKit zone not found, recreating")
            _ = try await ensureCustomZoneReady()
            return ZoneChanges(records: [], deletedRecords: [], newChangeToken: zoneChangeToken)
        }
    }

    /// Read every `AppSetting` record currently in the zone, without disturbing
    /// the stored change token or any other record class.
    ///
    /// A from-scratch read is genuinely needed: an existing change token has
    /// already consumed past `AppSetting` records, and while settings sync was
    /// off `processChangedRecords` dropped them. CloudKit cannot narrow a
    /// zone-changes fetch to one record type — `CKFetchRecordZoneChangesOperation`'s
    /// per-zone configuration selects a *previous token* and *desired keys*,
    /// never a record type — so the whole zone crosses the wire and the
    /// filtering happens here. (Querying by record type instead would need a
    /// queryable index on a schema this app creates implicitly, so it is not a
    /// safer alternative.)
    ///
    /// What this does avoid is the wider side effects. Nothing but settings is
    /// applied, so the caller cannot replay every remote profile, known host
    /// and identity-metadata record before the user has even answered the merge
    /// dialog. And `zoneChangeToken` is left exactly as it was: adopting the
    /// token this read produces would mark those other classes' pending changes
    /// as seen without ever applying them, and clearing it would make the next
    /// sync replay the entire zone. Untouched, the regular delta sync resumes
    /// from where it was, and a cancelled merge leaves no trace at all.
    private func fetchSettingRecordsFromScratch() async throws -> [CKRecord] {
        do {
            let changes = try await fetchZoneChangesInternal(previousToken: nil)
            return changes.records.filter { $0.recordType == AppSettingRecord.recordType }
        } catch let ckError as CKError where ckError.code == .zoneNotFound {
            // `ensureCustomZoneReady()` runs first, so this means the zone was
            // removed underneath us: there are no cloud settings to merge.
            Self.logger.warning("Zone not found while reading settings records")
            return []
        }
    }

    private func fetchZoneChangesInternal(previousToken: CKServerChangeToken?) async throws -> ZoneChanges {
        let zoneID = CloudKitSyncSettings.zoneID
        var changedRecords: [CKRecord] = []
        var deletedRecords: [DeletedRecord] = []

        Self.logger.debug("Fetching zone changes (hasToken: \(previousToken != nil))")

        var currentToken = previousToken
        var moreComing = true
        var fetchCount = 0

        while moreComing {
            fetchCount += 1
            let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: currentToken)
            Self.logger.debug("Zone changes fetch #\(fetchCount): \(changes.modificationResultsByID.count) modifications, \(changes.deletions.count) deletions, moreComing: \(changes.moreComing)")

            for (recordID, result) in changes.modificationResultsByID {
                switch result {
                case .success(let modification):
                    changedRecords.append(modification.record)
                    Self.logger.debug("Received changed record: \(modification.record.recordType)/\(recordID.recordName)")
                case .failure(let error):
                    Self.logger.warning("Record modification fetch failed for \(recordID.recordName): \(error.localizedDescription)")
                }
            }

            for deletion in changes.deletions {
                deletedRecords.append(DeletedRecord(recordID: deletion.recordID, recordType: deletion.recordType))
                Self.logger.debug("Received deleted record: \(deletion.recordType)/\(deletion.recordID.recordName)")
            }

            currentToken = changes.changeToken
            moreComing = changes.moreComing

            // Long-lived zones page through a change log where most entries are
            // superseded, so a walk from an old token can take hundreds of
            // near-empty pages. Stopping early leaves the newest records
            // unreached while the sync still reports success, so only guard
            // against a runaway loop.
            if fetchCount % 100 == 0 {
                Self.logger.info("Zone changes fetch still paging: \(fetchCount) fetches, \(changedRecords.count) records so far")
            }
            if fetchCount >= 5000 {
                Self.logger.error("Zone changes fetch hit safety limit of \(fetchCount) iterations")
                break
            }
        }

        Self.logger.info("Zone changes complete: \(changedRecords.count) total modified, \(deletedRecords.count) total deleted after \(fetchCount) fetches")

        return ZoneChanges(
            records: changedRecords,
            deletedRecords: deletedRecords,
            newChangeToken: currentToken
        )
    }

    /// Process changed records from CloudKit
    private func processChangedRecords(_ records: [CKRecord]) async {
        // Settings are merged as one batch so managers reload and the terminal
        // config rewrites once, not once per key.
        var settingRecords: [AppSettingRecord] = []
        for record in records {
            switch record.recordType {
            case AppSettingRecord.recordType:
                settingServerRecords[record.recordID.recordName] = record
                guard isAppSettingsSyncEnabled else { continue }
                if let setting = AppSettingRecord.from(record) {
                    settingRecords.append(setting)
                }
            case SSHIdentityMetadata.recordType:
                guard isIdentityMetadataSyncEnabled else { continue }
                if let entry = SSHIdentityMetadata.from(record) {
                    applyRemoteRecords([entry], type: SSHIdentityMetadata.self)
                }
            case KnownHost.recordType:
                guard isKnownHostsSyncEnabled else { continue }
                if let host = KnownHost.from(record) {
                    applyRemoteRecords([host], type: KnownHost.self)
                }
            case ConnectionProfile.recordType:
                guard isProfilesSyncEnabled else { continue }
                if let profile = ConnectionProfile.from(record) {
                    applyRemoteRecords([profile], type: ConnectionProfile.self)
                }
            default:
                Self.logger.warning("Unknown record type: \(record.recordType)")
            }
        }
        if !settingRecords.isEmpty {
            applyRemoteRecords(settingRecords, type: AppSettingRecord.self)
        }
    }

    /// Process deleted records from CloudKit
    private func processDeletedRecords(_ records: [DeletedRecord]) async {
        guard !records.isEmpty else { return }

        var identityDeletions: Set<String> = []
        var hostDeletions: Set<String> = []
        var profileDeletions: Set<String> = []

        for record in records {
            switch record.recordType {
            case SSHIdentityMetadata.recordType:
                guard isIdentityMetadataSyncEnabled else { continue }
                identityDeletions.insert(record.recordID.recordName)
            case KnownHost.recordType:
                guard isKnownHostsSyncEnabled else { continue }
                hostDeletions.insert(record.recordID.recordName)
            case ConnectionProfile.recordType:
                guard isProfilesSyncEnabled else { continue }
                profileDeletions.insert(record.recordID.recordName)
            case AppSettingRecord.recordType:
                // Hard deletes only come from dashboard cleanup; tombstones carry the semantics.
                offlineQueue.dequeueRecord(record.recordID.recordName)
                settingServerRecords[record.recordID.recordName] = nil
            default:
                Self.logger.warning("Unknown deleted record type: \(record.recordType)")
            }
        }

        if !identityDeletions.isEmpty {
            for recordName in identityDeletions {
                offlineQueue.dequeueRecord(recordName)
            }
            SSHIdentityMetadataStore.shared.applyRemoteDeletions(recordNames: identityDeletions)
        }

        if !hostDeletions.isEmpty {
            for recordName in hostDeletions {
                offlineQueue.dequeueRecord(recordName)
            }
            KnownHostsManager.shared.applyRemoteDeletions(recordNames: hostDeletions)
        }

        if !profileDeletions.isEmpty {
            for recordName in profileDeletions {
                offlineQueue.dequeueRecord(recordName)
            }
            ConnectionProfileManager.shared.applyRemoteDeletions(recordNames: profileDeletions)
        }
    }

    /// Apply remote records to local stores
    private func applyRemoteRecords<T: CloudKitSyncable>(_ records: [T], type: T.Type) {
        // Restore whatever state the caller was in: this is also reached from
        // the standalone push path's conflict resolution, which manages no
        // sync state of its own and would otherwise stay on "Applying changes".
        let previousState = syncState
        defer { syncState = previousState }
        syncState = .applyingChanges

        switch T.recordType {
        case SSHIdentityMetadata.recordType:
            if let entries = records as? [SSHIdentityMetadata] {
                SSHIdentityMetadataStore.shared.applyRemoteChanges(entries)
            }
        case KnownHost.recordType:
            if let hosts = records as? [KnownHost] {
                KnownHostsManager.shared.applyRemoteChanges(hosts)
            }
        case ConnectionProfile.recordType:
            if let profiles = records as? [ConnectionProfile] {
                ConnectionProfileManager.shared.applyRemoteChanges(profiles)
            }
        case AppSettingRecord.recordType:
            if let settings = records as? [AppSettingRecord] {
                SettingsSyncCoordinator.shared.applyRemote(settings)
            }
        default:
            break
        }
    }

    /// Whether we're currently backing off from rate limiting
    @ObservationIgnored
    private var isRateLimitBackoff = false

    /// Push a single record to CloudKit
    private func pushRecord<T: CloudKitSyncable>(_ record: T, operation: SyncOperation) async {
        // If rate-limited, queue instead of hitting CloudKit again
        if isRateLimitBackoff {
            offlineQueue.enqueue(record, operation: operation)
            return
        }

        do {
            try await saveRecord(record)
            Self.logger.debug("Pushed \(T.recordType)/\(record.id.uuidString)")
        } catch let error as CKError where error.code == .requestRateLimited {
            let retryAfter = error.retryAfterSeconds ?? 30
            Self.logger.warning("Rate limited pushing record, queuing and backing off for \(retryAfter)s")
            offlineQueue.enqueue(record, operation: operation)
            isRateLimitBackoff = true
            scheduleRateLimitedRetry(after: retryAfter)
        } catch {
            Self.logger.warning("Failed to push record, queuing: \(error.localizedDescription)")
            offlineQueue.enqueue(record, operation: operation)
        }
    }

    /// Save a record with conflict resolution
    private func saveRecord<T: CloudKitSyncable>(_ record: T) async throws {
        let ckRecord = record.toCKRecord()

        do {
            let (saveResults, _) = try await database.modifyRecords(
                saving: [ckRecord],
                deleting: [],
                savePolicy: .allKeys
            )
            for (_, result) in saveResults {
                if case .failure(let error) = result {
                    throw error
                }
            }
        } catch let ckError as CKError where ckError.code == .serverRecordChanged {
            try await resolveServerRecordConflict(ckError, localRecord: record)
        }
    }

    /// Resolve server record conflicts using server modification dates
    private func resolveServerRecordConflict<T: CloudKitSyncable>(
        _ error: CKError,
        localRecord: T
    ) async throws {
        guard let serverRecord = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
              let serverModel = T.from(serverRecord) else {
            throw error
        }

        if localRecord.modifiedAt > serverModel.modifiedAt {
            // Local is newer - apply local fields onto the server record and retry save
            localRecord.apply(to: serverRecord)
            let (saveResults, _) = try await database.modifyRecords(
                saving: [serverRecord],
                deleting: [],
                savePolicy: .allKeys
            )
            for (_, result) in saveResults {
                if case .failure(let error) = result {
                    throw error
                }
            }
        } else {
            // Server is newer - accept server record and update local store
            applyRemoteRecords([serverModel], type: T.self)
        }
    }

    /// Push all pending changes from offline queue
    private func pushPendingChanges() async throws {
        let batch = offlineQueue.nextBatch(limit: 100)
        guard !batch.isEmpty else { return }

        Self.logger.info("Pushing \(batch.count) pending changes")

        // Settings go out as one batched save; the rest one at a time.
        let settingChanges = batch.filter { $0.recordType == AppSettingRecord.recordType }
        if !settingChanges.isEmpty {
            for change in settingChanges { offlineQueue.dequeue(change.id) }
            if isAppSettingsSyncEnabled {
                let records = settingChanges.compactMap { try? payloadDecoder.decode(AppSettingRecord.self, from: $0.payload) }
                await pushRecords(records)
            }
        }

        for change in batch where change.recordType != AppSettingRecord.recordType {
            do {
                try await pushPendingChange(change)
                offlineQueue.dequeue(change.id)
            } catch let error as CKError where error.code == .requestRateLimited {
                let retryAfter = error.retryAfterSeconds ?? 30
                Self.logger.warning("Rate limited by CloudKit, backing off for \(retryAfter)s with \(batch.count - 1) changes remaining")
                offlineQueue.incrementRetry(change.id)
                scheduleRateLimitedRetry(after: retryAfter)
                return
            } catch {
                offlineQueue.incrementRetry(change.id)
                Self.logger.warning("Failed to push pending change: \(error.localizedDescription)")
            }
        }

        // Prune failed changes
        offlineQueue.pruneFailedChanges()
    }

    /// Schedule a retry after rate limiting
    private func scheduleRateLimitedRetry(after seconds: Double) {
        Task {
            Self.logger.info("Waiting \(seconds)s before retrying rate-limited push")
            try? await Task.sleep(for: .seconds(seconds))
            isRateLimitBackoff = false
            guard isSyncEnabled, syncState == .idle || syncState == .pushingChanges else { return }
            Self.logger.info("Retrying pending changes after rate limit backoff")
            syncState = .pushingChanges
            try? await pushPendingChanges()
            if syncState == .pushingChanges {
                syncState = .idle
            }
        }
    }

    /// Push a single pending change
    private func pushPendingChange(_ change: PendingChange) async throws {
        switch change.recordType {
        case SSHIdentityMetadata.recordType:
            guard let entry = try? payloadDecoder.decode(SSHIdentityMetadata.self, from: change.payload) else {
                throw CloudKitSyncError.invalidPayload("SSHIdentityMetadata payload decode failed")
            }
            try await saveRecord(entry)
        case KnownHost.recordType:
            guard let host = try? payloadDecoder.decode(KnownHost.self, from: change.payload) else {
                throw CloudKitSyncError.invalidPayload("KnownHost payload decode failed")
            }
            try await saveRecord(host)
        case ConnectionProfile.recordType:
            guard let profile = try? payloadDecoder.decode(ConnectionProfile.self, from: change.payload) else {
                throw CloudKitSyncError.invalidPayload("ConnectionProfile payload decode failed")
            }
            try await saveRecord(profile)
        case AppSettingRecord.recordType:
            guard let setting = try? payloadDecoder.decode(AppSettingRecord.self, from: change.payload) else {
                throw CloudKitSyncError.invalidPayload("AppSetting payload decode failed")
            }
            await pushRecords([setting])
        default:
            Self.logger.warning("Unknown record type in pending change: \(change.recordType)")
        }
    }

    /// Push all local records to CloudKit (for initial sync)
    private func pushAllLocalRecords() async throws {
        if isIdentityMetadataSyncEnabled {
            let entries = SSHIdentityMetadataStore.shared.allRecordsForSync
            Self.logger.info("Pushing \(entries.count) SSH identity metadata records to CloudKit")

            for entry in entries {
                await pushRecord(entry, operation: .create)
            }
        }

        if isKnownHostsSyncEnabled {
            let hosts = KnownHostsManager.shared.allRecordsForSync
            Self.logger.info("Pushing \(hosts.count) known host records to CloudKit")

            for host in hosts {
                await pushRecord(host, operation: .create)
            }
        }

        if isProfilesSyncEnabled {
            let profiles = ConnectionProfileManager.shared.allRecordsForSync
            Self.logger.info("Pushing \(profiles.count) connection profile records to CloudKit")

            for profile in profiles {
                await pushRecord(profile, operation: .create)
            }
        }

        if isAppSettingsSyncEnabled {
            let settings = SettingsSyncCoordinator.shared.recordsForInitialPush()
            Self.logger.info("Pushing \(settings.count) app setting records to CloudKit")
            await pushRecords(settings)
        }
    }

    // MARK: - Subscriptions

    /// Register CloudKit subscriptions for real-time updates
    /// Uses CKRecordZoneSubscription for the custom zone
    private func registerSubscriptions() async throws {
        let subscriptionID = "shell-sync-zone-changes"
        let zoneID = CloudKitSyncSettings.zoneID

        Self.logger.debug("Registering subscriptions for zone: \(zoneID.zoneName)")

        // Check if zone subscription already exists
        var needsCreation = false
        do {
            let existing = try await database.subscription(for: subscriptionID)
            if let zoneSubscription = existing as? CKRecordZoneSubscription {
                // Verify it's for the correct zone
                if zoneSubscription.zoneID == zoneID {
                    Self.logger.info("Zone subscription \(subscriptionID) already exists for zone \(zoneID.zoneName)")
                } else {
                    Self.logger.warning("Zone subscription exists but for wrong zone, recreating")
                    _ = try? await database.deleteSubscription(withID: subscriptionID)
                    needsCreation = true
                }
            } else {
                // Wrong subscription type - delete and recreate
                Self.logger.info("Found non-zone subscription \(subscriptionID), recreating as CKRecordZoneSubscription")
                _ = try? await database.deleteSubscription(withID: subscriptionID)
                needsCreation = true
            }
        } catch let error as CKError where error.code == .unknownItem {
            Self.logger.debug("Subscription \(subscriptionID) not found, will create")
            needsCreation = true
        } catch {
            Self.logger.warning("Error checking subscription: \(error.localizedDescription)")
            needsCreation = true
        }

        if needsCreation {
            let subscription = CKRecordZoneSubscription(
                zoneID: zoneID,
                subscriptionID: subscriptionID
            )

            let notificationInfo = CKSubscription.NotificationInfo()
            notificationInfo.shouldSendContentAvailable = true
            notificationInfo.shouldBadge = false
            subscription.notificationInfo = notificationInfo

            _ = try await database.save(subscription)
            Self.logger.info("Created zone subscription: \(subscriptionID) for zone: \(zoneID.zoneName)")
        }
    }

    /// Remove CloudKit subscriptions
    private func removeSubscriptions() async throws {
        let subscriptionIDs = ["shell-sync-zone-changes"]

        for subscriptionID in subscriptionIDs {
            do {
                try await database.deleteSubscription(withID: subscriptionID)
                Self.logger.info("Removed subscription: \(subscriptionID)")
            } catch {
                Self.logger.warning("Failed to remove subscription \(subscriptionID): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Settings & State

    /// The three per-record-class sync preferences, in the order they are
    /// applied to the published flags.
    typealias PerClassSyncFlags = (identityMetadata: Bool, knownHosts: Bool, profiles: Bool)

    /// The stored value of a per-record-class sync preference, or `nil` when
    /// the user has never made a choice. `bool(forKey:)` alone cannot tell
    /// "absent" from "explicitly off", and the first-enable defaults depend on
    /// exactly that distinction, so the presence check comes first.
    ///
    /// `defaults` is a parameter only so tests can drive a throwaway suite;
    /// every caller in the app uses `.standard`.
    static func storedChoice(_ key: String, defaults: UserDefaults = .standard) -> Bool? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    /// The identity-metadata preference under either of its two names.
    ///
    /// The UI writes `cloudKitSyncIdentityMetadata`; the inherited rootshell
    /// name is `cloudKitSyncHistory`. Prefer the UI key when it has ever been
    /// written and fall back to the legacy one, so a device that only holds the
    /// legacy value is not read as "never chosen".
    static func storedIdentityMetadataChoice(defaults: UserDefaults = .standard) -> Bool? {
        storedChoice(CloudKitSyncSettings.syncIdentityMetadataKey, defaults: defaults)
            ?? storedChoice(CloudKitSyncSettings.syncHistoryKey, defaults: defaults)
    }

    /// The per-class flags a *first* enable adopts. A preference that was never
    /// written means "not asked yet", which here — and only here — defaults on.
    /// An explicit `false` survives the master toggle being cycled.
    static func firstEnableFlags(defaults: UserDefaults = .standard) -> PerClassSyncFlags {
        (
            identityMetadata: storedIdentityMetadataChoice(defaults: defaults) ?? true,
            knownHosts: storedChoice(CloudKitSyncSettings.syncKnownHostsKey, defaults: defaults) ?? true,
            profiles: storedChoice(CloudKitSyncSettings.syncProfilesKey, defaults: defaults) ?? true
        )
    }

    /// The per-class flags restored at launch. The asymmetry with
    /// `firstEnableFlags` is deliberate: a preference that was never written
    /// means off at launch, so a device that has not been asked syncs nothing
    /// until it is.
    static func launchFlags(syncEnabled: Bool, defaults: UserDefaults = .standard) -> PerClassSyncFlags {
        (
            identityMetadata: syncEnabled && (storedIdentityMetadataChoice(defaults: defaults) ?? false),
            knownHosts: syncEnabled && (storedChoice(CloudKitSyncSettings.syncKnownHostsKey, defaults: defaults) ?? false),
            profiles: syncEnabled && (storedChoice(CloudKitSyncSettings.syncProfilesKey, defaults: defaults) ?? false)
        )
    }

    private func loadSettings() {
        isSyncEnabled = UserDefaults.standard.bool(forKey: CloudKitSyncSettings.enabledKey)
        // Absent means off here: this is launch state, and a device that has
        // never enabled sync syncs nothing. `setEnabled(true)` is the only
        // place a missing preference means "default on", and it re-reads these
        // keys rather than trusting the flags below.
        let launch = Self.launchFlags(syncEnabled: isSyncEnabled)
        isIdentityMetadataSyncEnabled = launch.identityMetadata
        isKnownHostsSyncEnabled = launch.knownHosts
        isProfilesSyncEnabled = launch.profiles
        lastSyncDate = UserDefaults.standard.object(forKey: CloudKitSyncSettings.lastSyncDateKey) as? Date

        // Settings sync is opt-in and is never auto-enabled.
        isAppSettingsSyncEnabled = isSyncEnabled && UserDefaults.standard.bool(forKey: CloudKitSyncSettings.syncAppSettingsKey)

        syncState = isSyncEnabled ? .idle : .disabled
    }

    /// Persists the sync flags.
    ///
    /// The three per-record-class preferences are written only while sync is
    /// enabled — while it is off the in-memory flags are all false for gating
    /// purposes and say nothing about what the user wants. Turning the master
    /// toggle off means "stop syncing", not "the user wants profiles off", and
    /// writing false over those keys would leave the next enable unable to tell
    /// a real choice from the master switch's own bookkeeping.
    private func saveSettings() {
        UserDefaults.standard.set(isSyncEnabled, forKey: CloudKitSyncSettings.enabledKey)
        if isSyncEnabled {
            // Both identity-metadata names are written so the UI-facing key and
            // the inherited rootshell name can never disagree.
            UserDefaults.standard.set(isIdentityMetadataSyncEnabled, forKey: CloudKitSyncSettings.syncHistoryKey)
            UserDefaults.standard.set(isIdentityMetadataSyncEnabled, forKey: CloudKitSyncSettings.syncIdentityMetadataKey)
            UserDefaults.standard.set(isKnownHostsSyncEnabled, forKey: CloudKitSyncSettings.syncKnownHostsKey)
            UserDefaults.standard.set(isProfilesSyncEnabled, forKey: CloudKitSyncSettings.syncProfilesKey)
        }
        UserDefaults.standard.set(isAppSettingsSyncEnabled, forKey: CloudKitSyncSettings.syncAppSettingsKey)
    }

    private func loadChangeToken() {
        if let tokenData = UserDefaults.standard.data(forKey: CloudKitSyncSettings.changeTokenKey) {
            zoneChangeToken = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self,
                from: tokenData
            )
        }
    }

    private func saveChangeToken() {
        if let token = zoneChangeToken {
            let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            UserDefaults.standard.set(data, forKey: CloudKitSyncSettings.changeTokenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CloudKitSyncSettings.changeTokenKey)
        }
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard !Ghostty.isAppBackgroundedAtomic,
                  !ForegroundActivationGate.shared.isUnsafeForSceneMutation else { return }
            Task { @MainActor in
                guard !Ghostty.isAppBackgroundedAtomic,
                      !ForegroundActivationGate.shared.isUnsafeForSceneMutation else { return }
                let wasAvailable = self?.isNetworkAvailable ?? false
                self?.isNetworkAvailable = path.status == .satisfied

                // If network became available, flush offline queue
                if !wasAvailable && self?.isNetworkAvailable == true {
                    Self.logger.info("Network restored, flushing offline queue")
                    try? await self?.pushPendingChanges()
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    func pauseNetworkMonitoringForBackground() {
        guard pathMonitor != nil else { return }
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func resumeNetworkMonitoringAfterForeground() {
        guard pathMonitor == nil else { return }
        startNetworkMonitoring()
    }
}
