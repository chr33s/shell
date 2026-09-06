//
//  SettingsSyncCoordinator.swift
//  shell
//
//  Owns per-key sync metadata, device-local pins, outgoing batching, and
//  incoming per-key merge. CloudKitSyncManager is the transport: it hands
//  in AppSettingRecords from the zone and takes batches to push.
//

import Foundation
import UIKit
import os

nonisolated enum SettingPinState: Sendable, Equatable {
    case none
    case key
    case group
    case deviceOnly
}

nonisolated enum GroupPinState: Sendable, Equatable {
    case none
    case partial(pinned: Int, of: Int)
    case all
}

nonisolated enum UnpinResolution: Sendable {
    /// Take the iCloud value this device has been ignoring.
    case adoptCloud
    /// Keep this device's value and send it to iCloud.
    case pushLocal
}

nonisolated enum SettingsMergeChoice: Sendable {
    case useCloud
    case uploadLocal
}

/// What the first-enable merge sheet needs to show.
struct SettingsMergePreview: Sendable {
    let cloud: [AppSettingRecord]
    let cloudCount: Int
    let localCount: Int
    let overlapping: Int
    /// Cloud tombstones for keys this device has set; adopting cloud resets them.
    let resetCount: Int
    let newestCloudDate: Date?
    let cloudDeviceIDs: Set<String>
}

@MainActor @Observable
final class SettingsSyncCoordinator {
    static let shared = SettingsSyncCoordinator()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SettingsSyncCoordinator")
    static let outgoingDebounce: Duration = .milliseconds(1500)

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let registry: SettingsRegistry
    @ObservationIgnored private let sidecarStore = SettingsSyncSidecarStore()
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleToken: NSObjectProtocol?
    @ObservationIgnored private var outgoing: Set<String> = []
    @ObservationIgnored private var outgoingTask: Task<Void, Never>?

    /// Set by CloudKitSyncManager; gates pushes only. Incoming records are always merged.
    var isEnabled = false
    /// Receives debounced batches of changed records to push.
    @ObservationIgnored var onOutgoingBatch: (([AppSettingRecord]) -> Void)?
    /// Bumped on every pin change so views re-evaluate pin state.
    private(set) var pinGeneration = 0

    var sidecar: SettingsSyncSidecar { sidecarStore.sidecar }

    /// Whether the one-time first-enable merge has already run for the Apple
    /// Account this device is signed into.
    ///
    /// That merge is destructive by design — one side wins wholesale — and it
    /// exists only because neither side has per-key timestamps to compare the
    /// first time a device joins a settings zone. Once it has run the sidecar
    /// carries a `modifiedAt` and `deviceID` for every key this device has
    /// touched, so the ordinary resolver settles each key on its own.
    /// `CloudKitSyncManager.setAppSettingsSyncEnabled` reads this to decide
    /// whether the merge question is still worth asking; `completeInitialMerge`
    /// reads it to refuse a second wholesale overwrite either way.
    var hasCompletedInitialMerge: Bool { sidecar.initialMergeCompleted }

    init(store: SettingsStore = .shared, registry: SettingsRegistry = .shared) {
        self.store = store
        self.registry = registry
    }

    func start() {
        guard listenTask == nil else { return }
        listenTask = Task { [weak self] in
            guard let stream = self?.store.changes() else { return }
            for await change in stream {
                self?.handle(change)
            }
        }
        lifecycleToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushOutgoingNow()
                self?.sidecarStore.saveNow()
            }
        }
        flushDeferredRemote()
    }

    private var deviceID: String { CloudKitSyncSettings.deviceID }

    // MARK: - Local changes

    private func handle(_ change: SettingsChange) {
        guard change.origin == .local || change.origin == .restore else { return }
        let now = Date()
        let device = deviceID
        var toPush: [String] = []
        sidecarStore.mutate { sidecar in
            for key in change.keys where registry.isSyncable(key) {
                var meta = sidecar.meta[key] ?? SettingSyncMeta()
                meta.modifiedAt = now
                meta.deviceID = device
                sidecar.meta[key] = meta
                toPush.append(key)
            }
        }
        guard isEnabled else { return }
        for key in toPush where !isPinned(key) {
            outgoing.insert(key)
        }
        scheduleOutgoingFlush()
    }

    func meta(for key: String) -> SettingSyncMeta? {
        sidecar.meta[key]
    }

    // MARK: - Outgoing

    private func scheduleOutgoingFlush() {
        guard !outgoing.isEmpty else { return }
        outgoingTask?.cancel()
        outgoingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.outgoingDebounce)
            guard !Task.isCancelled else { return }
            self?.flushOutgoingNow()
        }
    }

    /// Build records for every queued key whose content differs from the last push.
    func flushOutgoingNow() {
        outgoingTask?.cancel()
        outgoingTask = nil
        guard isEnabled, !outgoing.isEmpty, let sink = onOutgoingBatch else { return }
        let keys = outgoing
        outgoing = []
        var records: [AppSettingRecord] = []
        for key in keys {
            guard let record = record(for: key) else { continue }
            if let pushed = sidecar.meta[key]?.lastPushedHash, pushed == record.contentHash { continue }
            guard record.payloadSizeOK else {
                Self.logger.error("Skipping \(key, privacy: .public): payload exceeds CloudKit limit")
                continue
            }
            records.append(record)
        }
        guard !records.isEmpty else { return }
        Self.logger.info("Pushing \(records.count) setting records")
        sink(records)
    }

    /// Current value as a record, or a tombstone when the key is unset but was once synced.
    func record(for key: String) -> AppSettingRecord? {
        guard registry.isSyncable(key) else { return nil }
        let meta = sidecar.meta[key]
        let modifiedAt = meta?.modifiedAt ?? Date()
        let device = meta?.deviceID ?? deviceID
        if let value = store.codableValue(key) {
            return AppSettingRecord(key: key, payload: value, modifiedAt: modifiedAt, isDeleted: false, deviceID: device)
        }
        guard meta != nil else { return nil }
        return AppSettingRecord(key: key, payload: nil, modifiedAt: modifiedAt, isDeleted: true, deviceID: device)
    }

    /// Keys reset locally after they were once stamped; they go out as tombstones.
    private func localTombstoneKeys() -> [String] {
        sidecar.meta.compactMap { key, meta in
            guard meta.modifiedAt != nil, registry.isSyncable(key), !isPinned(key),
                  store.codableValue(key) == nil else { return nil }
            return key
        }
    }

    /// Every user-set syncable, unpinned key plus local reset tombstones.
    /// Unknown-age values are stamped now so they win on other devices.
    func recordsForInitialPush(stampUnknownAs stamp: Date = Date()) -> [AppSettingRecord] {
        guard !SettingsStore.looksCorrupted() else {
            Self.logger.fault("Refusing initial push: defaults look unreadable")
            return []
        }
        // Pin checks read the sidecar, so resolve them before taking exclusive access in mutate.
        let snapshot = store.syncableSnapshot().filter { !isPinned($0.key) }
        let tombstones = localTombstoneKeys()
        var out: [AppSettingRecord] = []
        let device = deviceID
        sidecarStore.mutate { sidecar in
            for (key, value) in snapshot {
                var meta = sidecar.meta[key] ?? SettingSyncMeta()
                if meta.modifiedAt == nil {
                    meta.modifiedAt = stamp
                    meta.deviceID = device
                    sidecar.meta[key] = meta
                }
                let record = AppSettingRecord(
                    key: key, payload: value, modifiedAt: meta.modifiedAt ?? stamp,
                    isDeleted: false, deviceID: meta.deviceID ?? device)
                if record.payloadSizeOK { out.append(record) }
            }
            for key in tombstones {
                guard let meta = sidecar.meta[key], let modifiedAt = meta.modifiedAt else { continue }
                out.append(AppSettingRecord(
                    key: key, payload: nil, modifiedAt: modifiedAt,
                    isDeleted: true, deviceID: meta.deviceID ?? device))
            }
        }
        return out
    }

    func markPushed(_ records: [AppSettingRecord]) {
        sidecarStore.mutate { sidecar in
            for record in records {
                var meta = sidecar.meta[record.key] ?? SettingSyncMeta()
                meta.lastPushedHash = record.contentHash
                sidecar.meta[record.key] = meta
            }
        }
    }

    // MARK: - Incoming

    /// Merge records from iCloud: drop unknown keys, shadow pinned ones, LWW the rest, apply once.
    func applyRemote(_ records: [AppSettingRecord]) {
        guard !records.isEmpty else { return }
        guard store.isReady else {
            deferRemote(records)
            return
        }
        var batch: [String: CodableValue?] = [:]
        var pushBack: [String] = []
        var accepted: [AppSettingRecord] = []
        var shadowed = 0
        var keptLocal = 0
        var unchanged = 0

        for record in records {
            let key = record.key
            guard let def = registry.definition(for: key), def.isSyncable else { continue }
            if let payload = record.payload, !def.validate(payload) {
                Self.logger.warning("Ignoring \(key, privacy: .public): remote value has the wrong type")
                continue
            }
            if isPinned(key) {
                shadowed += 1
                sidecarStore.mutate { sidecar in
                    var meta = sidecar.meta[key] ?? SettingSyncMeta()
                    meta.shadowCloud = ShadowValue(payload: record.payload, modifiedAt: record.modifiedAt, deviceID: record.deviceID)
                    sidecar.meta[key] = meta
                }
                continue
            }
            let meta = sidecar.meta[key]
            let localValue = store.codableValue(key)
            let local = SettingsMergeResolver.Local(value: localValue, modifiedAt: meta?.modifiedAt, deviceID: meta?.deviceID)
            let remote = SettingsMergeResolver.Remote(value: record.payload, modifiedAt: record.modifiedAt, deviceID: record.deviceID)
            let alreadyPushed = meta?.lastPushedHash == AppSettingRecord.contentHash(of: localValue)
            switch SettingsMergeResolver.resolve(local: local, remote: remote, alreadyPushed: alreadyPushed) {
            case .applyRemote:
                batch[key] = record.payload
                accepted.append(record)
            case .keepLocalAndPush:
                pushBack.append(key)
            case .keepLocal:
                keptLocal += 1
                Self.logger.info("Kept local \(key, privacy: .public): local \(meta?.modifiedAt?.description ?? "unknown", privacy: .public) vs remote \(record.modifiedAt.description, privacy: .public) from \(record.deviceID, privacy: .public)")
            case .noop:
                unchanged += 1
                sidecarStore.mutate { sidecar in
                    var m = sidecar.meta[key] ?? SettingSyncMeta()
                    m.lastPushedHash = record.contentHash
                    if m.modifiedAt == nil { m.modifiedAt = record.modifiedAt; m.deviceID = record.deviceID }
                    sidecar.meta[key] = m
                }
            }
        }

        if !batch.isEmpty {
            store.applyBatch(batch, origin: .remote)
            sidecarStore.mutate { sidecar in
                for record in accepted {
                    var meta = sidecar.meta[record.key] ?? SettingSyncMeta()
                    meta.modifiedAt = record.modifiedAt
                    meta.deviceID = record.deviceID
                    meta.lastPushedHash = record.contentHash
                    meta.shadowCloud = nil
                    sidecar.meta[record.key] = meta
                }
            }
        }
        if !pushBack.isEmpty, isEnabled {
            outgoing.formUnion(pushBack)
            scheduleOutgoingFlush()
        }
        Self.logger.info("Merged \(records.count) remote settings: \(batch.count) applied, \(pushBack.count) pushed back, \(keptLocal) kept local, \(unchanged) unchanged, \(shadowed) shadowed")
    }

    private func deferRemote(_ records: [AppSettingRecord]) {
        sidecarStore.mutate { sidecar in
            for record in records {
                sidecar.deferredRemote[record.key] = ShadowValue(
                    payload: record.payload, modifiedAt: record.modifiedAt, deviceID: record.deviceID)
            }
        }
        Self.logger.info("Deferred \(records.count) remote settings until the store is ready")
    }

    /// Re-play records received before protected data was available.
    func flushDeferredRemote() {
        guard store.isReady, !sidecar.deferredRemote.isEmpty else { return }
        let deferred = sidecar.deferredRemote
        sidecarStore.mutate { $0.deferredRemote = [:] }
        applyRemote(deferred.map { key, shadow in
            AppSettingRecord(key: key, payload: shadow.payload, modifiedAt: shadow.modifiedAt,
                             isDeleted: shadow.payload == nil, deviceID: shadow.deviceID)
        })
    }

    // MARK: - First enable

    func mergePreview(cloud: [AppSettingRecord]) -> SettingsMergePreview {
        let live = cloud.filter { !$0.isDeleted && registry.isSyncable($0.key) }
        // Same set the initial push sends: live values plus local reset tombstones.
        let liveLocal = Set(store.syncableSnapshot().keys).filter { !isPinned($0) }
        let localKeys = liveLocal.union(localTombstoneKeys())
        let cloudKeys = Set(live.map(\.key))
        let tombstoneKeys = Set(cloud.filter { $0.isDeleted && registry.isSyncable($0.key) }.map(\.key))
        return SettingsMergePreview(
            cloud: cloud,
            cloudCount: live.count,
            localCount: localKeys.count,
            overlapping: localKeys.intersection(cloudKeys).count,
            resetCount: liveLocal.intersection(tombstoneKeys).count,
            newestCloudDate: live.map(\.modifiedAt).max(),
            cloudDeviceIDs: Set(live.map(\.deviceID))
        )
    }

    /// Resolve the first-enable merge. Returns the records this device must push.
    ///
    /// Runs at most once per account. A device that has already merged goes
    /// through `resumeMerge` instead, whatever `choice` says: turning iCloud
    /// Sync off and back on used to re-run this from scratch, and a `.useCloud`
    /// pass then overwrote every local setting with whatever the zone happened
    /// to hold — every time.
    func completeInitialMerge(cloud: [AppSettingRecord], choice: SettingsMergeChoice) -> [AppSettingRecord] {
        guard !sidecar.initialMergeCompleted else { return resumeMerge(cloud: cloud) }
        let now = Date()
        let cloudByKey = Dictionary(cloud.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        switch choice {
        case .useCloud:
            // Cloud wins for every key it knows; local-only keys are uploaded.
            var batch: [String: CodableValue?] = [:]
            var accepted: [AppSettingRecord] = []
            for record in cloud where registry.isSyncable(record.key) && !isPinned(record.key) {
                if let payload = record.payload, let def = registry.definition(for: record.key), !def.validate(payload) { continue }
                batch[record.key] = record.payload
                accepted.append(record)
            }
            if !batch.isEmpty { store.applyBatch(batch, origin: .remote) }
            sidecarStore.mutate { sidecar in
                for record in accepted {
                    var meta = sidecar.meta[record.key] ?? SettingSyncMeta()
                    meta.modifiedAt = record.modifiedAt
                    meta.deviceID = record.deviceID
                    meta.lastPushedHash = record.contentHash
                    sidecar.meta[record.key] = meta
                }
                sidecar.initialMergeCompleted = true
            }
            return recordsForInitialPush(stampUnknownAs: now).filter { cloudByKey[$0.key] == nil }

        case .uploadLocal:
            // Local wins: stamp everything now so it beats cloud everywhere; adopt cloud-only keys.
            // Local resets count as local state, so cloud must not resurrect them.
            var batch: [String: CodableValue?] = [:]
            let localKeys = Set(store.syncableSnapshot().keys).union(localTombstoneKeys())
            for record in cloud where !record.isDeleted && !localKeys.contains(record.key)
                && registry.isSyncable(record.key) && !isPinned(record.key) {
                if let payload = record.payload, let def = registry.definition(for: record.key), def.validate(payload) {
                    batch[record.key] = payload
                }
            }
            if !batch.isEmpty { store.applyBatch(batch, origin: .remote) }
            sidecarStore.mutate { sidecar in
                for key in localKeys {
                    var meta = sidecar.meta[key] ?? SettingSyncMeta()
                    meta.modifiedAt = now
                    meta.deviceID = deviceID
                    sidecar.meta[key] = meta
                }
                sidecar.initialMergeCompleted = true
            }
            return recordsForInitialPush(stampUnknownAs: now)
        }
    }

    /// Re-enable settings sync on a device that has already merged with this
    /// account: run the ordinary per-key merge instead of the wholesale one.
    ///
    /// `resetSyncState()` clears push bookkeeping but deliberately keeps every
    /// key's `modifiedAt`, which is exactly what the resolver needs — so each
    /// key can be settled on its own and neither side is overwritten. The
    /// returned records carry their real timestamps rather than being stamped
    /// `now`, so `saveRecords`' conditional save keeps whichever side is newer.
    private func resumeMerge(cloud: [AppSettingRecord]) -> [AppSettingRecord] {
        applyRemote(cloud)
        // Anything the cloud just won (or that already matches) now has a
        // matching `lastPushedHash`; pushing it again would only burn a write.
        let toPush = recordsForInitialPush().filter {
            sidecar.meta[$0.key]?.lastPushedHash != $0.contentHash
        }
        Self.logger.info(
            "Settings sync re-enabled after an earlier merge: per-key merge over \(cloud.count) cloud records, \(toPush.count) to push"
        )
        return toPush
    }

    func setAccountIdentity(_ identity: String) {
        sidecarStore.mutate { sidecar in
            // A different Apple Account is a different settings zone, and this
            // device has never reconciled against it — the one-time merge has
            // to be offered again. This is the only place the flag is cleared;
            // `resetSyncState()` deliberately keeps it, because disabling sync
            // does not un-merge anything.
            if let previous = sidecar.accountIdentity, previous != identity {
                sidecar.initialMergeCompleted = false
            }
            sidecar.accountIdentity = identity
        }
    }

    // MARK: - Reset

    /// Forget push bookkeeping and shadows; keep timestamps, pins, and the
    /// mark that this device has already merged with the account.
    func resetSyncState() {
        outgoingTask?.cancel()
        outgoing = []
        sidecarStore.mutate { sidecar in
            for key in sidecar.meta.keys {
                sidecar.meta[key]?.lastPushedHash = nil
                sidecar.meta[key]?.shadowCloud = nil
            }
            // `initialMergeCompleted` is NOT cleared here. Turning sync off
            // does not un-merge this device from the account, and clearing it
            // is what made a later re-enable replay the destructive
            // first-enable merge. Only an account switch clears it, in
            // `setAccountIdentity`.
            sidecar.deferredRemote = [:]
        }
    }

    // MARK: - Pins

    func pinState(for key: String) -> SettingPinState {
        _ = pinGeneration
        guard let def = registry.definition(for: key) else { return .deviceOnly }
        if def.policy == .deviceOnly { return .deviceOnly }
        if sidecar.pinnedGroups.contains(def.group) { return .group }
        if isPinned(key) { return .key }
        return .none
    }

    func isPinned(_ key: String) -> Bool {
        guard let def = registry.definition(for: key), def.policy != .deviceOnly else { return true }
        if sidecar.pinnedGroups.contains(def.group) { return true }
        switch def.policy {
        case .synced: return sidecar.pinnedKeys.contains(key)
        case .localByDefault: return !sidecar.unpinnedKeys.contains(key)
        case .deviceOnly: return true
        }
    }

    func pinState(for group: SettingGroup) -> GroupPinState {
        _ = pinGeneration
        if sidecar.pinnedGroups.contains(group) { return .all }
        let keys = syncableKeyNames(in: group)
        guard !keys.isEmpty else { return .none }
        let pinned = keys.filter { isPinned($0) }.count
        if pinned == 0 { return .none }
        if pinned == keys.count { return .all }
        return .partial(pinned: pinned, of: keys.count)
    }

    /// Explicit definitions plus prefix-rule keys this device has stored or shadowed.
    private func syncableKeyNames(in group: SettingGroup) -> [String] {
        var names = registry.keys(in: group).filter(\.isSyncable).map(\.name)
        let dynamic = Set(store.syncableSnapshot().keys).union(sidecar.meta.keys)
        for key in dynamic where registry.definitions[key] == nil {
            guard let rule = registry.prefixRule(for: key), rule.group == group, rule.policy != .deviceOnly else { continue }
            names.append(key)
        }
        return names
    }

    func shadowValue(for key: String) -> ShadowValue? {
        sidecar.meta[key]?.shadowCloud
    }

    /// True when any syncable key in the group has an iCloud value shadowed behind a pin,
    /// i.e. unpinning the group is a real choice between the two sides.
    func hasCloudShadow(in group: SettingGroup) -> Bool {
        _ = pinGeneration
        return syncableKeyNames(in: group).contains { sidecar.meta[$0]?.shadowCloud != nil }
    }

    func setPinned(_ key: String, _ pinned: Bool, resolution: UnpinResolution = .adoptCloud) {
        guard let def = registry.definition(for: key), def.policy != .deviceOnly else { return }
        // Group members read the sidecar, so resolve them before mutate takes exclusive access.
        let siblings = syncableKeyNames(in: def.group)
            .filter { $0 != key }
            .compactMap { name in registry.definition(for: name).map { (name, $0.policy) } }
        sidecarStore.mutate { sidecar in
            switch def.policy {
            case .synced:
                if pinned { sidecar.pinnedKeys.insert(key) } else { sidecar.pinnedKeys.remove(key) }
            case .localByDefault:
                if pinned { sidecar.unpinnedKeys.remove(key) } else { sidecar.unpinnedKeys.insert(key) }
            case .deviceOnly:
                break
            }
            if !pinned, sidecar.pinnedGroups.contains(def.group) {
                // Dissolve the group pin into per-key pins so the others stay pinned.
                sidecar.pinnedGroups.remove(def.group)
                for (name, policy) in siblings {
                    if policy == .synced { sidecar.pinnedKeys.insert(name) }
                    if policy == .localByDefault { sidecar.unpinnedKeys.remove(name) }
                }
            }
        }
        pinGeneration += 1
        if !pinned { resolveUnpin([key], resolution: resolution) }
    }

    func setPinned(group: SettingGroup, _ pinned: Bool, resolution: UnpinResolution = .adoptCloud) {
        let keys = syncableKeyNames(in: group)
        let policies = keys.compactMap { name in registry.definition(for: name).map { (name, $0.policy) } }
        sidecarStore.mutate { sidecar in
            if pinned {
                sidecar.pinnedGroups.insert(group)
            } else {
                sidecar.pinnedGroups.remove(group)
                for (name, policy) in policies {
                    sidecar.pinnedKeys.remove(name)
                    if policy == .localByDefault { sidecar.unpinnedKeys.insert(name) }
                }
            }
        }
        pinGeneration += 1
        if !pinned { resolveUnpin(keys, resolution: resolution) }
    }

    private func resolveUnpin(_ keys: [String], resolution: UnpinResolution) {
        switch resolution {
        case .adoptCloud:
            var batch: [String: CodableValue?] = [:]
            var adopted: [String: ShadowValue] = [:]
            for key in keys {
                guard let shadow = sidecar.meta[key]?.shadowCloud else { continue }
                if let payload = shadow.payload, let def = registry.definition(for: key), !def.validate(payload) { continue }
                batch[key] = shadow.payload
                adopted[key] = shadow
            }
            if !batch.isEmpty { store.applyBatch(batch, origin: .unpin) }
            sidecarStore.mutate { sidecar in
                for (key, shadow) in adopted {
                    var meta = sidecar.meta[key] ?? SettingSyncMeta()
                    meta.modifiedAt = shadow.modifiedAt
                    meta.deviceID = shadow.deviceID
                    meta.lastPushedHash = AppSettingRecord.contentHash(of: shadow.payload)
                    meta.shadowCloud = nil
                    sidecar.meta[key] = meta
                }
            }
        case .pushLocal:
            let now = Date()
            let device = deviceID
            sidecarStore.mutate { sidecar in
                for key in keys {
                    var meta = sidecar.meta[key] ?? SettingSyncMeta()
                    meta.modifiedAt = now
                    meta.deviceID = device
                    meta.shadowCloud = nil
                    sidecar.meta[key] = meta
                }
            }
            if isEnabled {
                outgoing.formUnion(keys)
                scheduleOutgoingFlush()
            }
        }
    }

    /// Syncable keys currently pinned by any rule, for the pinned-settings list.
    func pinnedDefinitions() -> [AnySettingDefinition] {
        _ = pinGeneration
        var defs = registry.definitions.values.filter { $0.isSyncable && isPinned($0.name) }
        // Prefix-rule keys have no static definition; cover every one this device knows.
        let dynamic = Set(store.syncableSnapshot().keys).union(sidecar.meta.keys).union(sidecar.pinnedKeys)
        for name in dynamic where registry.definitions[name] == nil {
            if let def = registry.definition(for: name), def.isSyncable, isPinned(name) {
                defs.append(def)
            }
        }
        return defs.sorted { $0.name < $1.name }
    }
}
