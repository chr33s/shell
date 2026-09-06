//
//  SelectionManager.swift
//  shell
//
//  Manages text selection appearance settings (colors and mode)
//

import Foundation
import os

extension Notification.Name {
    static let selectionConfigChanged = Notification.Name("selectionConfigChanged")
}

enum SelectionAppearanceMode: String, CaseIterable, Codable {
    case shell
    case themeDefault
    case invertFgBg
    case custom
}

@MainActor
@Observable
class SelectionManager {
    static let shared = SelectionManager()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SelectionManager")

    // MARK: - Settings keys

    private static let ownedKeys: Set<String> = [
        Settings.Selection.appearanceMode.name,
        Settings.Selection.foregroundHex.name,
        Settings.Selection.backgroundHex.name,
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    @ObservationIgnored private var isReloading = false

    // MARK: - Observable Properties

    var selectionMode: SelectionAppearanceMode {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Selection.appearanceMode, selectionMode) }
            NotificationCenter.default.post(name: .selectionConfigChanged, object: nil)
        }
    }

    var customForegroundHex: String {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Selection.foregroundHex, customForegroundHex) }
            NotificationCenter.default.post(name: .selectionConfigChanged, object: nil)
        }
    }

    var customBackgroundHex: String {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Selection.backgroundHex, customBackgroundHex) }
            NotificationCenter.default.post(name: .selectionConfigChanged, object: nil)
        }
    }

    // MARK: - Initialization

    private init() {
        let store = SettingsStore.shared
        self.selectionMode = store.get(Settings.Selection.appearanceMode)
        self.customForegroundHex = store.get(Settings.Selection.foregroundHex)
        self.customBackgroundHex = store.get(Settings.Selection.backgroundHex)

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Selection.appearanceMode.name) { selectionMode = store.get(Settings.Selection.appearanceMode) }
        if keys.contains(Settings.Selection.foregroundHex.name) { customForegroundHex = store.get(Settings.Selection.foregroundHex) }
        if keys.contains(Settings.Selection.backgroundHex.name) { customBackgroundHex = store.get(Settings.Selection.backgroundHex) }
    }

    // MARK: - Preset Colors

    static let selectionForegroundHex = "F8F8F8"
    static let selectionBackgroundHex = "253B76"

    // MARK: - Config Generation

    /// Generates the Ghostty config lines for the current selection mode
    func generateSelectionConfigLines() -> [String] {
        switch selectionMode {
        case .shell:
            return [
                "selection-foreground = \"#\(Self.selectionForegroundHex)\"",
                "selection-background = \"#\(Self.selectionBackgroundHex)\"",
                "selection-invert-fg-bg = false",
            ]

        case .themeDefault:
            // Omit selection-foreground/background entirely so the theme's values take effect
            return []

        case .invertFgBg:
            return ["selection-invert-fg-bg = true"]

        case .custom:
            return [
                "selection-foreground = \"#\(customForegroundHex)\"",
                "selection-background = \"#\(customBackgroundHex)\"",
                "selection-invert-fg-bg = false",
            ]
        }
    }
}
