//
//  CloudKitSyncState.swift
//  shell
//
//  State tracking for CloudKit sync operations
//

import Foundation
import CloudKit

/// Current state of the CloudKit sync system
enum CloudKitSyncState: Equatable, Sendable {
    /// Sync is disabled
    case disabled

    /// Sync is enabled and idle (no active operations)
    case idle

    /// Checking iCloud account status
    case checkingAccount

    /// Fetching changes from the server
    case fetchingChanges

    /// Applying remote changes to local data
    case applyingChanges

    /// Pushing local changes to the server
    case pushingChanges

    /// Resolving conflicts between local and remote
    case resolvingConflicts

    /// Sync encountered an error
    case error(CloudKitSyncError)

    /// Human-readable description
    var description: String {
        switch self {
        case .disabled:
            return String(localized: "Sync disabled")
        case .idle:
            return String(localized: "Up to date")
        case .checkingAccount:
            return String(localized: "Checking account...")
        case .fetchingChanges:
            return String(localized: "Downloading changes...")
        case .applyingChanges:
            return String(localized: "Applying changes...")
        case .pushingChanges:
            return String(localized: "Uploading changes...")
        case .resolvingConflicts:
            return String(localized: "Resolving conflicts...")
        case .error(let error):
            return error.localizedDescription
        }
    }

    /// Whether sync is currently active
    var isActive: Bool {
        switch self {
        case .checkingAccount, .fetchingChanges, .applyingChanges,
             .pushingChanges, .resolvingConflicts:
            return true
        case .disabled, .idle, .error:
            return false
        }
    }

    /// Whether sync is in an error state
    var hasError: Bool {
        if case .error = self {
            return true
        }
        return false
    }

    // Equatable conformance
    static func == (lhs: CloudKitSyncState, rhs: CloudKitSyncState) -> Bool {
        switch (lhs, rhs) {
        case (.disabled, .disabled),
             (.idle, .idle),
             (.checkingAccount, .checkingAccount),
             (.fetchingChanges, .fetchingChanges),
             (.applyingChanges, .applyingChanges),
             (.pushingChanges, .pushingChanges),
             (.resolvingConflicts, .resolvingConflicts):
            return true
        case (.error, .error):
            // Compare error descriptions for equality
            return true
        default:
            return false
        }
    }
}

/// Settings keys for sync preferences
enum CloudKitSyncSettings {
    /// Master sync enabled toggle (default: false)
    static let enabledKey = "cloudKitSyncEnabled"

    /// SSH history sync enabled (default: false when master enabled)
    static let syncHistoryKey = "cloudKitSyncHistory"

    /// Known hosts sync enabled (default: false when master enabled)
    static let syncKnownHostsKey = "cloudKitSyncKnownHosts"

    /// Connection profiles sync enabled (default: false when master enabled)
    static let syncProfilesKey = "cloudKitSyncProfiles"

    /// App settings sync enabled. Opt-in; never auto-enabled for existing sync users.
    static let syncAppSettingsKey = "cloudKitSyncAppSettings"

    /// Last successful sync date
    static let lastSyncDateKey = "cloudKitLastSyncDate"

    /// Server change token (stored as Data)
    static let changeTokenKey = "cloudKitZoneChangeToken"

    /// One-time migration flag for moving from default zone to custom zone
    static let migratedToCustomZoneKey = "cloudKitMigratedToCustomZone"

    /// Custom record zone name for sync data
    static let zoneName = "ShellSync"

    /// Custom record zone ID for sync data
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    /// Device identifier for this device
    static let deviceIDKey = "cloudKitDeviceID"

    /// Get or create a stable device ID.
    /// Guards against generating a new ID when protected data is unavailable (device locked),
    /// which would overwrite the real device ID once the plist decrypts.
    static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) {
            return existing
        }
        guard ProtectedDataGuard.isAvailable else {
            // Return a transient ID rather than persisting a new one that would
            // overwrite the real device ID after unlock.
            return "transient-\(ProcessInfo.processInfo.processIdentifier)"
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: deviceIDKey)
        return newID
    }
}
