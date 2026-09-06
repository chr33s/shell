//
//  UserPreferences.swift
//  shell
//
//  User-configurable display name and clock format preferences
//

import Foundation

/// Visual treatment for the horizontal tab bar. Pills preserves the existing
/// Shell appearance; Integrated connects the selected tab to the terminal
/// and uses browser-style sizing and controls; Ledger is text-only with a
/// sliding accent indicator on the strip keyline; Trough is a segmented
/// control: one shared well with the selected tab as a sliding glass knob.
enum TopTabStyle: String, CaseIterable, Identifiable {
    case pills
    case integrated
    case ledger
    case trough

    static let storageKey = "topTabStyle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pills: return String(localized: "Pills")
        case .integrated: return String(localized: "Integrated")
        case .ledger: return String(localized: "Ledger")
        case .trough: return String(localized: "Trough")
        }
    }

    /// Tabs sit on a keylined strip (edge rule, "+" separator, no AppKit separator).
    var usesStripLayout: Bool { self == .integrated || self == .ledger }

    /// Equal-width, zero-spacing tab sizing.
    var usesEqualWidthTabs: Bool { self != .pills }

    static func resolve(_ rawValue: String) -> TopTabStyle {
        TopTabStyle(rawValue: rawValue) ?? .pills
    }
}

/// User-facing combinations of top-tab appearance and spacing. Persistence
/// remains split between `TopTabStyle` and the compact-pills boolean so the
/// rendering code can vary layout without changing the pill appearance.
enum TopTabLayout: String, CaseIterable, Identifiable {
    case pills
    case compactPills
    case integrated
    case ledger
    case trough

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pills: return String(localized: "Pills")
        case .compactPills: return String(localized: "Compact Pills")
        case .integrated: return String(localized: "Integrated")
        case .ledger: return String(localized: "Ledger")
        case .trough: return String(localized: "Trough")
        }
    }

    var style: TopTabStyle {
        switch self {
        case .pills, .compactPills: return .pills
        case .integrated: return .integrated
        case .ledger: return .ledger
        case .trough: return .trough
        }
    }

    var usesCompactPillSpacing: Bool { self == .compactPills }

    static func resolve(style: TopTabStyle, compactPills: Bool) -> TopTabLayout {
        switch style {
        case .integrated: return .integrated
        case .ledger: return .ledger
        case .trough: return .trough
        case .pills: return compactPills ? .compactPills : .pills
        }
    }
}

/// Namespace for user preferences that affect prompts and SSH defaults
nonisolated enum UserPreferences {

    // MARK: - Text Selection

    /// Custom is the default; the system loupe is an explicit iOS/iPadOS opt-in.
    static var useNativeSelectionLoupe: Bool {
        SettingsStore.shared.value(Settings.Selection.useNativeLoupe)
    }

    // MARK: - Background Keepalive

    /// Whether eligible TCP SSH sessions, active local tasks and live Screen
    /// Sharing panes should request a short UIKit background grace task when
    /// the app backgrounds.
    static var backgroundSessionKeepaliveEnabled: Bool {
        SettingsStore.shared.value(Settings.Connections.backgroundKeepalive)
    }

    // MARK: - Username

    /// The username used as the default for new SSH connections.
    static var effectiveUsername: String {
        NSUserName()
    }

    // MARK: - Clock Format

    /// Clock display format for prompt themes
    enum ClockFormat: String, CaseIterable, Sendable {
        case system = "system"
        case twelveHour = "twelveHour"
        case twentyFourHour = "twentyFourHour"

        var displayName: String {
            switch self {
            case .system: return String(localized: "System Default", comment: "Clock format: system default")
            case .twelveHour: return String(localized: "12-Hour", comment: "Clock format: 12-hour")
            case .twentyFourHour: return String(localized: "24-Hour", comment: "Clock format: 24-hour")
            }
        }
    }
}
