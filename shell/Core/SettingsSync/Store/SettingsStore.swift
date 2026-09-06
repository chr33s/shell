//
//  SettingsStore.swift
//  shell
//
//  Typed front door for every registered setting. UserDefaults stays the
//  persisted source of truth; the store adds a thread-safe cache, per-key
//  observation for SwiftUI, batched application of external values, and one
//  change event per batch.
//

import Foundation
import UIKit
import os

/// Per-key observable cell so SwiftUI views invalidate only for keys they read.
@MainActor @Observable
final class SettingBox {
    let name: String
    var value: CodableValue?

    init(name: String, value: CodableValue?) {
        self.name = name
        self.value = value
    }
}

@MainActor
final class SettingsStore {
    /// Nonisolated so hot paths can reach the nonisolated `value(_:)` without hopping actors.
    nonisolated static let shared = SettingsStore()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SettingsStore")

    let registry: SettingsRegistry
    nonisolated let cache: SettingsCache

    private(set) var isReady = false
    /// True while values from outside this process (iCloud, restore, config file) are being written.
    private(set) var isApplyingBatch = false
    /// Mirror of `isApplyingBatch` for nonisolated observers.
    private let applyingBatchFlag = OSAllocatedUnfairLock(initialState: false)
    nonisolated var isApplyingBatchAtomic: Bool { applyingBatchFlag.withLock { $0 } }

    private var boxes: [String: SettingBox] = [:]
    private var continuations: [UUID: AsyncStream<SettingsChange>.Continuation] = [:]
    private var observer: SettingsLocalChangeObserver?
    /// Held while protected data is unavailable; later values win per key.
    private var deferredBatch: [String: CodableValue?] = [:]
    private var deferredOrigin: SettingsChangeOrigin = .remote

    /// Only stores nonisolated values, so the singleton can be created off the main actor.
    nonisolated init(registry: SettingsRegistry = .shared) {
        self.registry = registry
        self.cache = SettingsCache(registry: registry)
    }

    // MARK: - Bootstrap

    /// Prime the cache from the persisted domain. Call once protected data is available.
    func bootstrap() {
        guard !isReady else { return }
        guard ProtectedDataGuard.isAvailable else {
            Self.logger.warning("bootstrap called before protected data is available; deferring")
            ProtectedDataGuard.whenAvailable { [weak self] in self?.bootstrap() }
            return
        }
        let domain = persistedDomain()
        if domain.isEmpty && Self.looksCorrupted() {
            Self.logger.fault("Defaults domain empty while sentinels are missing; refusing to prime cache")
            scheduleBootstrapRetry()
            return
        }
        cache.replaceAll(Self.decode(domain, registry: registry))
        for (name, box) in boxes {
            box.value = cache.raw(name)
        }
        observer = SettingsLocalChangeObserver(store: self)
        isReady = true
        Self.logger.info("Primed \(self.cache.snapshot().count) registered values")
        if !deferredBatch.isEmpty {
            let batch = deferredBatch
            deferredBatch = [:]
            _ = applyBatch(batch, origin: deferredOrigin)
        }
    }

    private func persistedDomain() -> [String: Any] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [:] }
        return UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
    }

    /// All sentinels absent while a backup exists means the plist was read while locked.
    /// A fresh install has neither and must prime normally.
    static func looksCorrupted() -> Bool {
        guard UserDefaultsBackup.hasBackup else { return false }
        let sentinels = ["selectedTheme", "fontSize", "cursorStyle", "cloudKitDeviceID"]
        return sentinels.allSatisfy { UserDefaults.standard.object(forKey: $0) == nil }
    }

    private var bootstrapRetryObserver: NSObjectProtocol?

    /// One more attempt on the next activation; a locked-launch read usually clears by then.
    private func scheduleBootstrapRetry() {
        guard bootstrapRetryObserver == nil else { return }
        bootstrapRetryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.bootstrapRetryObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                self.bootstrapRetryObserver = nil
                self.bootstrap()
            }
        }
    }

    nonisolated static func decode(_ domain: [String: Any], registry: SettingsRegistry) -> [String: CodableValue] {
        var out: [String: CodableValue] = [:]
        out.reserveCapacity(domain.count)
        for (key, raw) in domain {
            guard let def = registry.definition(for: key), def.valueType != nil else { continue }
            if let cv = def.read(raw) {
                out[key] = cv
            }
        }
        return out
    }

    // MARK: - Typed access

    func get<V: SettingValue>(_ key: SettingKey<V>) -> V {
        cache.value(key)
    }

    /// Hot-path read; safe from any thread.
    nonisolated func value<V: SettingValue>(_ key: SettingKey<V>) -> V {
        cache.value(key)
    }

    func set<V: SettingValue>(_ key: SettingKey<V>, _ value: V) {
        guard ProtectedDataGuard.isAvailable else {
            Self.logger.warning("Ignoring write to \(key.name, privacy: .public) while protected data is unavailable")
            return
        }
        let cv = value.codableValue
        write(key.name, cv)
        if cache.update(key.name, cv) || !cache.isPrimed {
            box(for: key.name).value = cv
            emit(SettingsChange(keys: [key.name], origin: .local))
        }
    }

    func reset<V: SettingValue>(_ key: SettingKey<V>) {
        guard ProtectedDataGuard.isAvailable else { return }
        UserDefaults.standard.removeObject(forKey: key.name)
        if cache.update(key.name, nil) {
            box(for: key.name).value = nil
            emit(SettingsChange(keys: [key.name], origin: .local))
        }
    }

    /// Reads through to UserDefaults until the cache is primed, so early manager inits agree with the old checks.
    func isUserSet(_ name: String) -> Bool {
        if cache.isPrimed { return cache.raw(name) != nil }
        return UserDefaults.standard.object(forKey: name) != nil
    }

    func codableValue(_ name: String) -> CodableValue? {
        if cache.isPrimed { return cache.raw(name) }
        guard let def = registry.definition(for: name),
              let raw = UserDefaults.standard.object(forKey: name) else { return nil }
        return def.read(raw)
    }

    func snapshot(keys: Set<String>) -> [String: CodableValue] {
        cache.snapshot().filter { keys.contains($0.key) }
    }

    /// Every user-set value under a syncable definition or prefix rule.
    func syncableSnapshot() -> [String: CodableValue] {
        cache.snapshot().filter { registry.isSyncable($0.key) }
    }

    /// Observable cell for SwiftUI; created on first use.
    func box(for name: String) -> SettingBox {
        if let existing = boxes[name] { return existing }
        let initial: CodableValue?
        if cache.isPrimed {
            initial = cache.raw(name)
        } else if let def = registry.definition(for: name), let raw = UserDefaults.standard.object(forKey: name) {
            initial = def.read(raw)
        } else {
            initial = nil
        }
        let box = SettingBox(name: name, value: initial)
        boxes[name] = box
        return box
    }

    private func write(_ name: String, _ value: CodableValue?) {
        if let value {
            UserDefaults.standard.set(value.anyValue, forKey: name)
        } else {
            UserDefaults.standard.removeObject(forKey: name)
        }
    }

    // MARK: - External batches

    /// Apply values from iCloud, a restore, or the config file. `nil` removes the key.
    /// Returns the keys whose stored value changed.
    @discardableResult
    func applyBatch(_ changes: [String: CodableValue?], origin: SettingsChangeOrigin) -> Set<String> {
        guard isReady, ProtectedDataGuard.isAvailable else {
            for (key, value) in changes { deferredBatch[key] = value }
            deferredOrigin = origin
            Self.logger.info("Deferred \(changes.count) external values until protected data is available")
            return []
        }
        var changed: Set<String> = []
        isApplyingBatch = true
        applyingBatchFlag.withLock { $0 = true }
        for (name, value) in changes {
            guard let def = registry.definition(for: name), def.valueType != nil else {
                Self.logger.warning("Skipping unregistered key \(name, privacy: .public)")
                continue
            }
            if let value, !def.validate(value) {
                Self.logger.warning("Skipping \(name, privacy: .public): value does not match declared type")
                continue
            }
            guard cache.update(name, value) else { continue }
            write(name, value)
            boxes[name]?.value = value
            changed.insert(name)
        }
        let change = SettingsChange(keys: changed, origin: origin)
        if !changed.isEmpty {
            SettingsRefreshHub.shared.dispatch(change)
        }
        isApplyingBatch = false
        applyingBatchFlag.withLock { $0 = false }
        if !changed.isEmpty {
            emit(change)
        }
        return changed
    }

    /// Called by the local change observer after diffing the persisted domain.
    func noteLocalChanges(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        for key in keys {
            boxes[key]?.value = cache.raw(key)
        }
        emit(SettingsChange(keys: keys, origin: .local))
    }

    // MARK: - Events

    func changes() -> AsyncStream<SettingsChange> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    private func emit(_ change: SettingsChange) {
        // External batches already went through the hub inside `applyBatch`,
        // while `isApplyingBatch` was still set (managers and GhosttyApp rely on
        // that flag). Local writes never reached it at all, which is why every
        // setting whose consumer is a view or a session — rather than a manager
        // that writes the key itself — only took effect on the next launch.
        if change.origin == .local {
            SettingsRefreshHub.shared.dispatch(change)
        }
        for continuation in continuations.values {
            continuation.yield(change)
        }
        NotificationCenter.default.post(name: .settingsDidChange, object: self, userInfo: change.userInfo)
    }
}
