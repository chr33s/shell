//
//  ThemeUIColorDerivation.swift
//  shell
//
//  Single source of truth for the algorithm that derives non-terminal UI
//  chrome colors from a terminal theme when "Theme-Aware UI" is enabled.
//  Used both by the live derivation paths in `MainView` /
//  `MainViewTabBarStyling` and by the per-theme override editor's "default
//  value" display.
//

import SwiftUI

/// Fully derived UI chrome colors for one theme. Mirrors the slot layout of
/// `ThemeUIOverrides` — the resolver pairs the two element-wise (override
/// hex if present, else derived value).
struct DerivedThemeUIColors {
    let sheetBackground: Color
    let sheetRowBackground: Color
    let sheetAccent: Color?
    let tabBarBackground: Color
    let selectedTabBackground: Color
    let unselectedTabBackground: Color
    let tabText: Color
    let tabSecondaryText: Color
    let isLight: Bool
}

enum ThemeUIColorDerivation {
    @MainActor
    static func derive(from themeColors: ThemeManager.ThemeInfo.ThemeColors) -> DerivedThemeUIColors? {
        guard let base = Color(hex: themeColors.background) else { return nil }
        let isLight = base.isLight

        let sheetBg = isLight
            ? base.blendedWithBlack(0.08)
            : base.darkenedPreservingHue(0.12)
        let sheetRow = isLight
            ? base.blendedWithWhite(0.03)
            : base.lightenedPreservingHue(0.10)
        let sheetAccent = themeColors.sheetTintColor(for: sheetBg)

        let selectedTab: Color = isLight
            ? base.blendedWithBlack(0.20)
            : base.lightenedPreservingHue(base.adaptivePrimaryBlend)
        let unselectedTab: Color = isLight
            ? base.blendedWithBlack(0.08)
            : base.lightenedPreservingHue(base.adaptiveSecondaryBlend)
        let tabText: Color = isLight ? Color(white: 0.1) : Color(white: 0.95)
        let tabSecondaryText: Color = isLight ? Color(white: 0.4) : Color(white: 0.6)

        return DerivedThemeUIColors(
            sheetBackground: sheetBg,
            sheetRowBackground: sheetRow,
            sheetAccent: sheetAccent,
            tabBarBackground: base,
            selectedTabBackground: selectedTab,
            unselectedTabBackground: unselectedTab,
            tabText: tabText,
            tabSecondaryText: tabSecondaryText,
            isLight: isLight
        )
    }
}
