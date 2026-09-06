//
//  Settings+System.swift
//  shell
//
//  Device-only system keys (sync state, system toggles), prefix
//  rules, and the area list the registry is assembled from.
//

import Foundation

nonisolated extension Settings {
    enum System {
        static let cloudKitSyncEnabled = SettingKey(
            "cloudKitSyncEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Enable iCloud Sync", comment: "Setting title"))
        static let cloudKitSyncKnownHosts = SettingKey(
            "cloudKitSyncKnownHosts", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Known Hosts", comment: "Setting title"))
        static let cloudKitSyncProfiles = SettingKey(
            "cloudKitSyncProfiles", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Profiles", comment: "Setting title"))
        static let cloudKitSyncAppSettings = SettingKey(
            "cloudKitSyncAppSettings", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Settings", comment: "Setting title"))
        /// Public SSH identity metadata (key type, fingerprint, public key,
        /// attached OpenSSH certificate). Never private key material.
        static let cloudKitSyncIdentityMetadata = SettingKey(
            "cloudKitSyncIdentityMetadata", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Identity Metadata", comment: "Setting title"))
        /// Whether newly created software keys are marked for iCloud Keychain
        /// synchronization. Secure Enclave keys are always device-bound and are
        /// never affected by this switch.
        static let syncSoftwareKeys = SettingKey(
            "syncSoftwareSSHKeys", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Software Keys", comment: "Setting title"))
        static let cloudKitDeviceID = SettingKey<String?>(
            "cloudKitDeviceID", default: nil, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Device ID", comment: "Setting title"))
        static let cloudKitZoneChangeToken = SettingKey<Data?>(
            "cloudKitZoneChangeToken", default: nil, group: .system, policy: .deviceOnly,
            title: String(localized: "Sync Change Token", comment: "Setting title"))
        static let cloudKitLastSyncDate = AnySettingDefinition.opaque(
            "cloudKitLastSyncDate", title: String(localized: "Last Sync", comment: "Setting title"))
        static let applePressAndHold = SettingKey(
            "ApplePressAndHoldEnabled", default: false, group: .system, policy: .deviceOnly,
            title: String(localized: "Press and Hold (system)", comment: "Setting title"))

        /// Key families whose full names are composed at runtime.
        static let prefixRules: [SettingsRegistry.PrefixRule] = [
            .init(prefix: "cloudKitEmptyRecoveryAttempted.", valueType: .bool, policy: .deviceOnly, group: .system,
                  title: String(localized: "Sync Empty-Store Recovery", comment: "Setting title")),
        ]

        static let all: [AnySettingDefinition] = [
            cloudKitSyncEnabled.erased, cloudKitSyncKnownHosts.erased,
            cloudKitSyncProfiles.erased, cloudKitSyncAppSettings.erased,
            cloudKitSyncIdentityMetadata.erased, syncSoftwareKeys.erased,
            cloudKitDeviceID.erased,
            cloudKitZoneChangeToken.erased, cloudKitLastSyncDate,
            applePressAndHold.erased,
        ]
    }

    /// Every area the registry assembles. Add new areas here.
    static let allAreas: [[AnySettingDefinition]] = [
        Theme.all, Font.all, Cursor.all, Selection.all, Transparency.all,
        Tabs.all, Window.all, Power.all,
        Terminal.all, Gestures.all, Prompt.all, Locale.all, SessionRestore.all,
        Keyboard.all, KeyboardToolbar.all, Keybinds.all,
        Connections.all, Tmux.all,
        System.all,
    ]
}
