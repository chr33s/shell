//
//  ThemeUIColorDerivation.swift
//  shell
//
//  Derives the non-terminal sheet chrome colors from a terminal theme when
//  "Theme-Aware UI" is enabled. Used by the sheet styling path in
//  `MainView+SheetTheme`.
//

import SwiftUI

/// Derived sheet chrome colors for one theme.
struct DerivedThemeUIColors {
    let sheetBackground: Color
    let sheetRowBackground: Color
    let sheetAccent: Color?
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

        return DerivedThemeUIColors(
            sheetBackground: sheetBg,
            sheetRowBackground: sheetRow,
            sheetAccent: sheetAccent,
            isLight: isLight
        )
    }
}
