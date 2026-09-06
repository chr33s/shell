//
//  SettingsChange.swift
//  shell
//
//  Change event emitted by SettingsStore. One event per batch, never per key.
//

import Foundation

nonisolated enum SettingsChangeOrigin: String, Sendable {
    /// Written by this process through any UserDefaults path.
    case local
    /// Applied from iCloud.
    case remote
    /// Applied by Backup & Restore.
    case restore
    /// Adopted an iCloud value after unpinning.
    case unpin
}

nonisolated struct SettingsChange: Sendable {
    let keys: Set<String>
    let origin: SettingsChangeOrigin

    func contains(_ name: String) -> Bool { keys.contains(name) }
    func intersects(_ names: Set<String>) -> Bool { !keys.isDisjoint(with: names) }
}

extension Notification.Name {
    /// Posted once per settings batch; userInfo carries `keys: [String]` and `origin: String`.
    static let settingsDidChange = Notification.Name("settingsDidChange")
}

extension SettingsChange {
    static let userInfoKeys = "keys"
    static let userInfoOrigin = "origin"

    var userInfo: [String: Any] {
        [Self.userInfoKeys: Array(keys), Self.userInfoOrigin: origin.rawValue]
    }
}
