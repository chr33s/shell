//
//  Settings+Tabs.swift
//  shell
//
//  Tab bar and window chrome keys.
//

import Foundation

extension TopTabStyle: SettingValue {}
extension SplitFocusBorderStyle: SettingValue {}
extension SplitFocusBorderColor: SettingValue {}
extension PowerManager.RefreshRateSetting: SettingValue {}
extension PowerManager.BatteryRefreshRate: SettingValue {}

nonisolated extension Settings {
    enum Tabs {
        static let barHidden = SettingKey(
            "tabBarHidden", default: false, group: .tabs, configKey: "tab-bar-hidden",
            title: String(localized: "Show Top Tab Bar", comment: "Setting title"))
        static let barAnimationsDisabled = SettingKey(
            "tabBarAnimationsDisabled", default: false, group: .tabs, configKey: "tab-bar-animations-disabled",
            title: String(localized: "Disable Tab Animations", comment: "Setting title"))
        static let topTabStyle = SettingKey(
            "topTabStyle", default: TopTabStyle.pills, group: .tabs, configKey: "top-tab-style",
            title: String(localized: "Tab Style", comment: "Setting title"))
        static let compactPillSpacing = SettingKey(
            "compactPillTabSpacing", default: false, group: .tabs, configKey: "compact-pill-tab-spacing",
            title: String(localized: "Compact Tab Spacing", comment: "Setting title"))
        static let showScopeMenu = SettingKey(
            "showTabScopeMenu", default: true, group: .tabs, configKey: "show-tab-scope-menu",
            title: String(localized: "Show Group Menu", comment: "Setting title"))
        static let showShortcutIndicators = SettingKey(
            "showTabShortcutIndicators", default: false, group: .tabs, configKey: "show-tab-shortcut-indicators",
            title: String(localized: "Show Tab Shortcuts", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            barHidden.erased, barAnimationsDisabled.erased, topTabStyle.erased, compactPillSpacing.erased,
            showScopeMenu.erased, showShortcutIndicators.erased,
        ]
    }

    enum Window {
        static let hideTitleBar = SettingKey(
            "hideWindowTitleBar", default: false, group: .window, policy: .localByDefault,
            configKey: "hide-window-title-bar",
            title: String(localized: "Hide Title Bar", comment: "Setting title"))
        static let tabsInTitlebar = SettingKey(
            "tabsInTitlebarEnabled", default: true, group: .window, policy: .localByDefault,
            configKey: "tabs-in-titlebar-enabled",
            title: String(localized: "Tabs in Title Bar", comment: "Setting title"))
        static let fullScreenMode = SettingKey(
            "fullScreenModeEnabled", default: false, group: .window, policy: .localByDefault,
            configKey: "full-screen-mode-enabled",
            title: String(localized: "Full Screen Mode", comment: "Setting title"))
        static let extendUnderHomeIndicator = SettingKey(
            "extendUnderHomeIndicator", default: false, group: .window, policy: .localByDefault,
            configKey: "extend-under-home-indicator",
            title: String(localized: "Extend Under Home Indicator", comment: "Setting title"))
        static let splitFocusBorderStyle = SettingKey(
            "splitFocusBorderStyle", default: SplitFocusBorderStyle.standard, group: .window,
            configKey: "split-focus-border-style",
            title: String(localized: "Split Focus Border", comment: "Setting title"))
        static let splitFocusBorderColor = SettingKey(
            "splitFocusBorderColor", default: SplitFocusBorderColor.accent, group: .window,
            configKey: "split-focus-border-color",
            title: String(localized: "Split Border Color", comment: "Setting title"))
        static let splitFocusBorderCustomColor = SettingKey(
            "splitFocusBorderCustomColor", default: "007AFF", group: .window,
            configKey: "split-focus-border-custom-color",
            title: String(localized: "Split Border Custom Color", comment: "Setting title"))
        static let lastWidth = SettingKey(
            "lastWindowWidth", default: 0.0, group: .window, policy: .deviceOnly,
            title: String(localized: "Last Window Width", comment: "Setting title"))
        static let lastHeight = SettingKey(
            "lastWindowHeight", default: 0.0, group: .window, policy: .deviceOnly,
            title: String(localized: "Last Window Height", comment: "Setting title"))
        static let lastOriginX = SettingKey(
            "lastWindowOriginX", default: 0.0, group: .window, policy: .deviceOnly,
            title: String(localized: "Last Window Origin X", comment: "Setting title"))
        static let lastOriginY = SettingKey(
            "lastWindowOriginY", default: 0.0, group: .window, policy: .deviceOnly,
            title: String(localized: "Last Window Origin Y", comment: "Setting title"))
        static let lastHasOrigin = SettingKey(
            "lastWindowHasOrigin", default: false, group: .window, policy: .deviceOnly,
            title: String(localized: "Last Window Has Origin", comment: "Setting title"))
        static let titlebarLeadingInset = SettingKey(
            "titlebarLeadingInset", default: 0.0, group: .window, policy: .deviceOnly,
            title: String(localized: "Titlebar Leading Inset", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            hideTitleBar.erased, tabsInTitlebar.erased, fullScreenMode.erased, extendUnderHomeIndicator.erased,
            splitFocusBorderStyle.erased, splitFocusBorderColor.erased, splitFocusBorderCustomColor.erased,
            lastWidth.erased, lastHeight.erased, lastOriginX.erased, lastOriginY.erased, lastHasOrigin.erased,
            titlebarLeadingInset.erased,
        ]
    }

    /// Frame-rate / battery behaviour for the Metal renderer.
    enum Power {
        static let autoSaver = SettingKey(
            "powerAutoSaver", default: true, group: .power, policy: .localByDefault,
            configKey: "power-auto-saver",
            title: String(localized: "Automatic Battery Saver", comment: "Setting title"))
        static let maxRefreshRate = SettingKey(
            "powerMaxRefreshRate", default: PowerManager.RefreshRateSetting.auto, group: .power, policy: .localByDefault,
            configKey: "power-max-refresh-rate",
            title: String(localized: "Maximum Refresh Rate", comment: "Setting title"))
        static let batteryRefreshRate = SettingKey(
            "powerBatteryRefreshRate", default: PowerManager.BatteryRefreshRate.sixty, group: .power, policy: .localByDefault,
            configKey: "power-battery-refresh-rate",
            title: String(localized: "Refresh Rate on Battery", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            autoSaver.erased, maxRefreshRate.erased, batteryRefreshRate.erased,
        ]
    }
}
