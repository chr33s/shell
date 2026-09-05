//
//  UserDefaultsMigration.swift
//  shell
//
//  One-time migrations for UserDefaults key changes.
//

import Foundation

enum UserDefaultsMigration {
    /// Volatile registered defaults. Safe to call before protected data is available
    /// because `register(defaults:)` writes only to the volatile registration domain
    /// and never touches the on-disk plist. Must run before any code reads these keys
    /// (TerminalView gesture setup, scene construction, etc.), so call from
    /// `application(_:didFinishLaunchingWithOptions:)` outside the protected-data gate.
    static func registerVolatileDefaults() {
        UserDefaults.standard.register(defaults: [
            "scrollModeEnabled": true,
            "lineScrollbackEnabled": false,
            "rubberBandScrollbackEnabled": true,
        ])
    }

    static func migrateIfNeeded() {
        migrateTouchScrollMode()
        // The migration may have written an explicit value to `scrollModeEnabled`.
        // Notify any TerminalView constructed during the deferred-launch window so it
        // re-runs `applyTouchMode()` against the new value.
        NotificationCenter.default.post(name: .touchModeChanged, object: nil)
    }

    /// Migrate "touchScrollMode" (default false) → "scrollModeEnabled" (default true).
    ///
    /// - Old key present: user explicitly chose a value — copy it to the new key.
    /// - Old key absent, new key absent: fresh install or user never changed it — defaults to true.
    /// - New key already present in the persistent domain: already migrated — no-op.
    ///
    /// We check the persistent domain explicitly because `registerVolatileDefaults()` runs
    /// before this and makes `object(forKey: "scrollModeEnabled")` return the registered
    /// `true`. The standard read APIs cannot distinguish "user has not chosen a value" from
    /// "registered default is in effect", which would cause this migration to silently skip
    /// legacy users whose `touchScrollMode` was explicitly `false`.
    private static func migrateTouchScrollMode() {
        let defaults = UserDefaults.standard
        guard !persistentDomainContains("scrollModeEnabled") else { return }

        if defaults.object(forKey: "touchScrollMode") != nil {
            defaults.set(defaults.bool(forKey: "touchScrollMode"), forKey: "scrollModeEnabled")
        }

        defaults.removeObject(forKey: "touchScrollMode")
    }

    private static func persistentDomainContains(_ key: String) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return UserDefaults.standard.persistentDomain(forName: bundleID)?[key] != nil
    }
}
