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
            "rubberBandScrollbackEnabled": true,
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
