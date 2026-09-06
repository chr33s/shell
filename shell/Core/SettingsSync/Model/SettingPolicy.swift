//
//  SettingPolicy.swift
//  shell
//
//  Sync policy and grouping metadata for registered settings.
//

import Foundation

/// How a setting participates in iCloud settings sync.
nonisolated enum SyncPolicy: String, Codable, Sendable {
    /// Synced unless the user pins it to this device.
    case synced
    /// Syncable, but starts pinned: device-shape or platform specific.
    case localByDefault
    /// Never leaves the device and has no pin UI.
    case deviceOnly
}

/// Pin granularity. Roughly one group per settings screen or sub-section.
nonisolated enum SettingGroup: String, Codable, Sendable {
    case theme, font, cursor, selection, transparency
    case tabs, window, power
    case terminal, scrollback, prompt, locale, sessionRestore
    case keyboard, keyboardToolbar, keybinds, gestures
    case connections, tmux
    case system

    var title: String {
        switch self {
        case .theme: String(localized: "Theme", comment: "Setting group title")
        case .font: String(localized: "Font", comment: "Setting group title")
        case .cursor: String(localized: "Cursor", comment: "Setting group title")
        case .selection: String(localized: "Selection", comment: "Setting group title")
        case .transparency: String(localized: "Transparency", comment: "Setting group title")
        case .tabs: String(localized: "Tabs", comment: "Setting group title")
        case .window: String(localized: "Window", comment: "Setting group title")
        case .power: String(localized: "Battery & Display", comment: "Setting group title")
        case .terminal: String(localized: "Terminal", comment: "Setting group title")
        case .scrollback: String(localized: "Scrollback", comment: "Setting group title")
        case .prompt: String(localized: "Prompt", comment: "Setting group title")
        case .locale: String(localized: "Locale", comment: "Setting group title")
        case .sessionRestore: String(localized: "Session", comment: "Setting group title")
        case .keyboard: String(localized: "Keyboard", comment: "Setting group title")
        case .keyboardToolbar: String(localized: "Toolbar Keys", comment: "Setting group title")
        case .keybinds: String(localized: "Keyboard Shortcuts", comment: "Setting group title")
        case .gestures: String(localized: "Gestures", comment: "Setting group title")
        case .connections: String(localized: "Connections", comment: "Setting group title")
        case .tmux: String(localized: "tmux", comment: "Setting group title")
        case .system: String(localized: "System", comment: "Setting group title")
        }
    }
}
