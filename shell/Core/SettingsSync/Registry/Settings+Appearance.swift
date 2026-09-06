//
//  Settings+Appearance.swift
//  shell
//
//  Theme, font, and selection keys.
//

import Foundation

extension AppearanceManager.AppearanceMode: SettingValue {}
extension SelectionAppearanceMode: SettingValue {}
extension CursorStyle: SettingValue {}
extension CursorBlinkMode: SettingValue {}
extension CursorEffect: SettingValue {}
extension TransparencyManager.BlurStyle: SettingValue {}

nonisolated extension Settings {
    enum Theme {
        static let selected = SettingKey(
            "selectedTheme", default: ThemeManager.defaultThemeName, group: .theme, configKey: "theme",
            title: String(localized: "Theme", comment: "Setting title"))
        static let appearanceMode = SettingKey(
            "appearanceMode", default: AppearanceManager.AppearanceMode.automatic, group: .theme,
            configKey: "appearance-mode",
            title: String(localized: "Appearance", comment: "Setting title"))
        static let themedUI = SettingKey(
            "themedUI", default: true, group: .theme, configKey: "themed-ui",
            title: String(localized: "Theme-Aware UI", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            selected.erased, appearanceMode.erased, themedUI.erased,
        ]
    }

    enum Font {
        static let size = SettingKey(
            "fontSize", default: 13.0, group: .font, configKey: "font-size",
            title: String(localized: "Font Size", comment: "Setting title"))
        static let family = SettingKey<String?>(
            "fontFamily", default: nil, group: .font, configKey: "font-family",
            title: String(localized: "Font", comment: "Setting title"))
        static let ligatures = SettingKey(
            "ligaturesEnabled", default: true, group: .font, configKey: "ligatures-enabled",
            title: String(localized: "Enable Ligatures", comment: "Setting title"))
        static let featurePrefs = SettingKey<Data?>(
            "fontFeaturePrefs", default: nil, group: .font,
            title: String(localized: "Font Features", comment: "Setting title"))
        static let cellAdjustmentPrefs = SettingKey<Data?>(
            "cellAdjustmentPrefs", default: nil, group: .font,
            title: String(localized: "Cell Width & Height", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            size.erased, family.erased, ligatures.erased, featurePrefs.erased, cellAdjustmentPrefs.erased,
        ]
    }

    /// Cursor appearance. Fed straight into the Ghostty config; the fork has
    /// no cursor-effects UI, but the keys stay so a config file can set them.
    enum Cursor {
        static let style = SettingKey(
            "cursorStyle", default: CursorStyle.block, group: .cursor, configKey: "cursor-style",
            title: String(localized: "Cursor Style", comment: "Setting title"))
        static let blinkEnabled = SettingKey(
            "cursorBlinkEnabled", default: false, group: .cursor, configKey: "cursor-style-blink",
            title: String(localized: "Cursor Blinking", comment: "Setting title"))
        static let blinkMode = SettingKey(
            "cursorBlinkMode", default: CursorBlinkMode.normal, group: .cursor, configKey: "cursor-blink-mode",
            title: String(localized: "Blink Style", comment: "Setting title"))
        static let effect = SettingKey(
            "cursorEffect", default: CursorEffect.none, group: .cursor, configKey: "cursor-effect",
            title: String(localized: "Cursor Effect", comment: "Setting title"))
        static let color = SettingKey<String?>(
            "cursorColor", default: nil, group: .cursor, configKey: "cursor-color",
            title: String(localized: "Cursor Color", comment: "Setting title"))
        static let textColor = SettingKey<String?>(
            "cursorTextColor", default: nil, group: .cursor, configKey: "cursor-text",
            title: String(localized: "Text Under Cursor", comment: "Setting title"))
        static let opacity = SettingKey(
            "cursorOpacity", default: 0.8, group: .cursor, configKey: "cursor-opacity",
            title: String(localized: "Cursor Opacity", comment: "Setting title"))
        static let thickness = SettingKey(
            "cursorThickness", default: 0, group: .cursor, configKey: "cursor-thickness",
            title: String(localized: "Cursor Thickness", comment: "Setting title"))
        static let height = SettingKey(
            "cursorHeight", default: 0, group: .cursor, configKey: "cursor-height",
            title: String(localized: "Cursor Height", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            style.erased, blinkEnabled.erased, blinkMode.erased, effect.erased, color.erased,
            textColor.erased, opacity.erased, thickness.erased, height.erased,
        ]
    }

    enum Selection {
        static let appearanceMode = SettingKey(
            "selectionAppearanceMode", default: SelectionAppearanceMode.shell, group: .selection,
            configKey: "selection-appearance-mode",
            title: String(localized: "Selection Style", comment: "Setting title"))
        static let foregroundHex = SettingKey(
            "selectionForegroundHex", default: "1e1e2e", group: .selection, configKey: "selection-foreground",
            title: String(localized: "Selection Foreground", comment: "Setting title"))
        static let backgroundHex = SettingKey(
            "selectionBackgroundHex", default: "f5e0dc", group: .selection, configKey: "selection-background",
            title: String(localized: "Selection Background", comment: "Setting title"))
        static let copyOnSelect = SettingKey(
            "copyOnSelect", default: true, group: .selection, configKey: "copy-on-select",
            title: String(localized: "Copy on Select", comment: "Setting title"))
        static let useNativeLoupe = SettingKey(
            "useNativeSelectionLoupe", default: false, group: .selection, configKey: "use-native-selection-loupe",
            title: String(localized: "Use Native Selection Loupe", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            appearanceMode.erased, foregroundHex.erased, backgroundHex.erased, copyOnSelect.erased, useNativeLoupe.erased,
        ]
    }

    /// Terminal background opacity / blur, applied straight to the Ghostty surface.
    enum Transparency {
        static let backgroundOpacity = SettingKey(
            "backgroundOpacity", default: 0.92, group: .transparency, policy: .localByDefault,
            configKey: "background-opacity",
            title: String(localized: "Background Opacity", comment: "Setting title"))
        static let backgroundBlurRadius = SettingKey(
            "backgroundBlurRadius", default: 30.0, group: .transparency, policy: .localByDefault,
            configKey: "background-blur",
            title: String(localized: "Blur Radius", comment: "Setting title"))
        static let blurEnabled = SettingKey(
            "blurEnabled", default: true, group: .transparency, policy: .localByDefault,
            configKey: "blur-enabled",
            title: String(localized: "Background Blur", comment: "Setting title"))
        static let blurStyle = SettingKey(
            "blurStyle", default: TransparencyManager.BlurStyle.standard, group: .transparency,
            policy: .localByDefault, configKey: "blur-style",
            title: String(localized: "Blur Style", comment: "Setting title"))
        static let pinnedSidebarTransparency = SettingKey(
            "pinnedSidebarTransparencyEnabled", default: false, group: .transparency, policy: .localByDefault,
            configKey: "pinned-sidebar-transparency-enabled",
            title: String(localized: "Transparent Pinned Sidebar", comment: "Setting title"))

        static let all: [AnySettingDefinition] = [
            backgroundOpacity.erased, backgroundBlurRadius.erased, blurEnabled.erased, blurStyle.erased,
            pinnedSidebarTransparency.erased,
        ]
    }
}
