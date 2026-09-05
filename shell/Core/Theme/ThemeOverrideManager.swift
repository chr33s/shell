//
//  ThemeOverrideManager.swift
//  shell
//
//  Manages per-window and per-tab theme overrides
//  Override hierarchy: Tab > Window > Global
//

import Foundation
import Combine
import os

/// Manages per-window and per-tab theme overrides.
///
/// Migrated from `ObservableObject` (with manual `objectWillChange.send()`) to
/// `@Observable`. The macro auto-tracks the `windowOverrides` and `tabOverrides`
/// dictionary mutations, so the explicit `objectWillChange.send()` calls
/// inside the setter methods are no longer required.
@MainActor
@Observable
final class ThemeOverrideManager {
    static let shared = ThemeOverrideManager()

    @ObservationIgnored private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "ThemeOverrideManager")

    /// Window-level theme overrides (keyed by windowId string)
    private(set) var windowOverrides: [String: String] = [:]

    /// Tab-level theme overrides (keyed by tab UUID)
    private(set) var tabOverrides: [UUID: String] = [:]

    /// Publisher for override changes - subscribers can react to specific changes
    @ObservationIgnored let overridesDidChange = PassthroughSubject<ThemeOverrideChange, Never>()

    /// Describes a change to theme overrides
    struct ThemeOverrideChange: Sendable {
        let scope: Scope
        let id: String  // windowId or tabId.uuidString
        let themeName: String?  // nil means override was cleared
    }

    /// The scope of a theme override
    enum Scope: Sendable {
        case window
        case tab
    }

    /// The source of an effective theme
    enum ThemeSource: Sendable {
        case global
        case window
        case tab
    }

    private init() {}

    // MARK: - Window Overrides

    /// Set a theme override for a window (all tabs in window share this theme)
    /// Pass nil to clear the override
    func setWindowTheme(windowId: String, themeName: String?) {
        guard windowOverrides[windowId] != themeName else { return }

        if let theme = themeName {
            windowOverrides[windowId] = theme
            Self.logger.info("Set window theme override: windowId=\(windowId), theme=\(theme)")
        } else {
            windowOverrides.removeValue(forKey: windowId)
            Self.logger.info("Cleared window theme override: windowId=\(windowId)")
        }
        overridesDidChange.send(ThemeOverrideChange(scope: .window, id: windowId, themeName: themeName))
    }

    /// Get the theme override for a window (nil if no override)
    func getWindowTheme(windowId: String) -> String? {
        windowOverrides[windowId]
    }

    /// Clear the theme override for a window
    func clearWindowOverride(windowId: String) {
        setWindowTheme(windowId: windowId, themeName: nil)
    }

    /// Check if a window has a theme override
    func hasWindowOverride(windowId: String) -> Bool {
        windowOverrides[windowId] != nil
    }

    // MARK: - Tab Overrides

    /// Set a theme override for a specific tab
    /// Pass nil to clear the override
    func setTabTheme(tabId: UUID, themeName: String?) {
        guard tabOverrides[tabId] != themeName else { return }

        if let theme = themeName {
            tabOverrides[tabId] = theme
            Self.logger.info("Set tab theme override: tabId=\(tabId), theme=\(theme)")
        } else {
            tabOverrides.removeValue(forKey: tabId)
            Self.logger.info("Cleared tab theme override: tabId=\(tabId)")
        }
        overridesDidChange.send(ThemeOverrideChange(scope: .tab, id: tabId.uuidString, themeName: themeName))
    }

    /// Get the theme override for a tab (nil if no override)
    func getTabTheme(tabId: UUID) -> String? {
        tabOverrides[tabId]
    }

    /// Clear the theme override for a tab
    func clearTabOverride(tabId: UUID) {
        setTabTheme(tabId: tabId, themeName: nil)
    }

    /// Check if a tab has a theme override
    func hasTabOverride(tabId: UUID) -> Bool {
        tabOverrides[tabId] != nil
    }

    // MARK: - Theme Resolution

    /// Resolve the effective theme for a given tab/window context
    /// Returns: (themeName, source) where source indicates where the theme came from
    ///
    /// Resolution order (highest priority first):
    /// 1. Tab override
    /// 2. Window override
    /// 3. Global default
    func resolveTheme(tabId: UUID?, windowId: String?) -> (themeName: String, source: ThemeSource) {
        // Check tab override first (highest priority)
        if let tabId = tabId, let tabTheme = tabOverrides[tabId] {
            return (tabTheme, .tab)
        }

        // Check window override
        if let windowId = windowId, let windowTheme = windowOverrides[windowId] {
            return (windowTheme, .window)
        }

        // Fall back to global theme
        return (ThemeManager.shared.currentTheme, .global)
    }

    // MARK: - Cleanup

    /// Remove all overrides for a window (call when window closes)
    func cleanupWindow(windowId: String) {
        guard windowOverrides[windowId] != nil else { return }

        if windowOverrides.removeValue(forKey: windowId) != nil {
            Self.logger.info("Cleaned up window overrides for windowId=\(windowId)")
        }
    }

    /// Remove override for a tab (call when tab closes)
    func cleanupTab(tabId: UUID) {
        guard tabOverrides[tabId] != nil else { return }

        if tabOverrides.removeValue(forKey: tabId) != nil {
            Self.logger.info("Cleaned up tab override for tabId=\(tabId)")
        }
    }

    /// Remove all overrides
    func clearAllOverrides() {
        let hadOverrides = !windowOverrides.isEmpty || !tabOverrides.isEmpty
        guard hadOverrides else { return }

        windowOverrides.removeAll()
        tabOverrides.removeAll()
        Self.logger.info("Cleared all theme overrides")
    }
}
