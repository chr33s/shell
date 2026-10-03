//
//  UserDefaultsMigration.swift
//  shell
//
//  Registration-domain defaults and the protected-data readiness announcement.
//

import Foundation

enum LaunchDefaults {
    /// Volatile registered defaults. Safe to call before protected data is available
    /// because `register(defaults:)` writes only to the volatile registration domain
    /// and never touches the on-disk plist. Must run before any code reads these keys
    /// (TerminalView gesture setup, scene construction, etc.), so call from
    /// `application(_:didFinishLaunchingWithOptions:)` outside the protected-data gate.
    static func registerVolatileDefaults() {
        UserDefaults.standard.register(defaults: [
            "scrollModeEnabled": true,
            "lineScrollbackEnabled": false,
            "rubberBandScrollbackEnabled": true
        ])
    }

    /// Announce that the persisted touch/scroll preferences are now readable.
    ///
    /// Called once from the protected-data gate. A `TerminalView` constructed while the
    /// device was still locked saw only the registered defaults above, because the
    /// preferences plist was undecryptable at that point. Posting `.touchModeChanged`
    /// makes it re-run `applyTouchMode()` (and `TerminalScrollView` re-read its scrollback
    /// gesture flags) against the real persisted values.
    static func announceProtectedDataAvailable() {
        NotificationCenter.default.post(name: .touchModeChanged, object: nil)
    }
}

/// Clears the persisted state of the removed local SSH agent bridge.
///
/// The bridge (and its Connections > Local SSH Agent setting and per-key
/// "Allow in Local SSH Agent" grants) was removed with the bundled OpenSSH
/// clients. Deleting the keys makes an older build read its defaults — agent
/// Off, no granted identities — so a downgrade never resurrects a credential
/// grant. Nothing is migrated into another permission.
///
/// Delete this once no supported build can read these keys (any build after
/// the release that follows the one shipping this cleanup).
enum LegacyLocalSSHAgentCleanup {
    static let legacyKeys = [
        "localSSHAgentEnabled",        // V1 opt-in
        "localSSHAgentV2Enabled",      // V2 opt-in
        "localSSHAgentAllowedKeyIDs"   // V2 per-key allowlist
    ]

    /// Must run after protected data is available, so the removal reaches the
    /// on-disk plist rather than a locked, empty view of it.
    static func run(defaults: UserDefaults = .standard) {
        for key in legacyKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }
    }
}
