//
//  UserDefaultsBackup.swift
//  shell
//
//  Backup and recovery mechanism for UserDefaults.
//  Detects corruption from background launches when protected data was unavailable,
//  and restores sentinel keys from a snapshot saved during normal app usage.
//

import Foundation
import os.log

enum UserDefaultsBackup {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "UserDefaultsBackup")

    /// Keys that are virtually always set after first use. If ALL of them are nil simultaneously,
    /// the defaults plist was likely read while encrypted (device locked).
    private static let sentinelKeys = [
        "selectedTheme",
        "fontSize",
        "cursorStyle",
        "cloudKitDeviceID",
    ]

    /// Latched for the rest of the process the first time `detectAndRecover()` sees the
    /// corruption signature (all sentinels nil while a backup exists).
    ///
    /// Was missing: `detectAndRecover()` runs before `SettingsStore.bootstrap()` and writes the
    /// sentinel keys back, so every later attempt to *infer* corruption from live state
    /// (`SettingsStore.looksCorrupted()`, and the empty-domain check in `bootstrap()`) saw a
    /// healthy-looking domain and disarmed itself. That silently skipped the bootstrap retry —
    /// priming the cache from only these four keys and marking the store ready — and disarmed
    /// `SettingsSyncCoordinator.recordsForInitialPush()`'s identical guard, which then pushed a
    /// tombstone for every setting that read back nil. The detection must be recorded at the
    /// moment it happens, not re-derived after the restore has erased the evidence.
    private nonisolated static let corruptionLatch = OSAllocatedUnfairLock(initialState: false)

    /// True if this launch detected a corrupt (locked-read) defaults plist. Never cleared:
    /// the restore below repairs only the sentinels, so the rest of the domain stays suspect
    /// for the life of the process.
    nonisolated static var detectedCorruptionThisLaunch: Bool { corruptionLatch.withLock { $0 } }

    private static var backupURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(".ghostty", isDirectory: true)
        return dir.appendingPathComponent("defaults_backup.json")
    }

    /// Written on the first unlocked activation, so its absence means a fresh install.
    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    /// Save current sentinel values to disk. Call when the app becomes active (device is unlocked).
    static func saveSnapshot() {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]

        for key in sentinelKeys {
            if let value = defaults.object(forKey: key) {
                // Store as property-list-safe types
                if let stringVal = value as? String {
                    snapshot[key] = stringVal
                } else if let numberVal = value as? NSNumber {
                    snapshot[key] = numberVal.doubleValue
                }
            }
        }

        // Don't save an empty snapshot — nothing to recover from
        guard !snapshot.isEmpty else { return }

        do {
            let dir = backupURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: .prettyPrinted)
            try data.write(to: backupURL, options: .atomic)
        } catch {
            logger.error("Failed to save defaults backup: \(error.localizedDescription)")
        }
    }

    /// Detect if all sentinel keys are nil (corruption) and restore from backup if possible.
    /// Call early in app launch, AFTER confirming protected data is available.
    static func detectAndRecover() {
        let defaults = UserDefaults.standard

        // Check if ALL sentinel keys are nil
        let allNil = sentinelKeys.allSatisfy { defaults.object(forKey: $0) == nil }
        guard allNil else { return }

        // No backup file → fresh install, nothing to recover
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return }

        // All sentinels are nil but we have a backup → corruption detected.
        // Latch BEFORE restoring: the writes below make this state undetectable afterwards.
        corruptionLatch.withLock { $0 = true }
        logger.critical("All sentinel keys are nil but backup exists — UserDefaults corruption detected!")

        do {
            let data = try Data(contentsOf: backupURL)
            guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("Backup file is not a valid dictionary")
                return
            }

            var restoredCount = 0
            for (key, value) in snapshot {
                defaults.set(value, forKey: key)
                restoredCount += 1
            }

            logger.critical("Restored \(restoredCount) sentinel keys from backup")
        } catch {
            logger.error("Failed to restore from backup: \(error.localizedDescription)")
        }
    }
}
