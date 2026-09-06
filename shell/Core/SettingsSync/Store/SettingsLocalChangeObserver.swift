//
//  SettingsLocalChangeObserver.swift
//  shell
//
//  Detects writes made through any UserDefaults path by diffing the persisted
//  domain against the cache once per runloop turn that had a write.
//

import Foundation
import os

@MainActor
final class SettingsLocalChangeObserver {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SettingsLocalChangeObserver")

    private unowned let store: SettingsStore
    private var token: NSObjectProtocol?
    private var pending = false

    init(store: SettingsStore) {
        self.store = store
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    private func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.diff()
        }
    }

    private func diff() {
        guard !store.isApplyingBatch, ProtectedDataGuard.isAvailable,
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let domain = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        let registry = store.registry
        let before = store.cache.snapshot()
        var after: [String: CodableValue] = [:]
        for (key, raw) in domain {
            guard let def = registry.definition(for: key), def.valueType != nil else { continue }
            if let cv = def.read(raw) { after[key] = cv }
        }

        var changed: Set<String> = []
        for (key, value) in after where before[key] != value {
            changed.insert(key)
        }
        let removed = Set(before.keys).subtracting(after.keys)

        // Any disappearance with every sentinel gone is the locked-read
        // corruption case; never propagate it. Do NOT reintroduce the old
        // `removed.count >= max(10, before.count / 2)` floor: `before` holds only
        // registered keys that have persisted values, so on a device where the
        // user changed fewer than ten settings the whole domain can vanish and
        // `n >= max(10, n / 2)` still stays false — the guard was unreachable for
        // exactly the population it protects, and the wipe went out as a CloudKit
        // tombstone per key. `looksCorrupted()` is already decisive on its own: it
        // needs a backup file AND all four sentinels nil, a pair `saveSnapshot`
        // never lets a fresh install reach.
        if !removed.isEmpty, SettingsStore.looksCorrupted() {
            Self.logger.fault("Ignoring \(removed.count) simultaneous removals; defaults look unreadable")
            return
        }
        changed.formUnion(removed)
        guard !changed.isEmpty else { return }

        for key in changed {
            store.cache.update(key, after[key])
        }
        store.noteLocalChanges(changed)
    }
}
