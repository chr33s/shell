//
//  MainView+SheetTheme.swift
//  shell
//
//  Sheet theme environment key and MainView's sheet-theme resolution
//  helpers, extracted for build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Sheet Theme Colors Environment Key

/// Theme colors for sheet content. When set, views should clear their scroll content
/// background and use these colors instead. Only set in the fullScreenCover path (iPad/Catalyst).
struct SheetThemeColors: Equatable {
    /// Background for the gaps between list sections (replaces systemGroupedBackground)
    let background: Color
    /// Background for list row cells (replaces secondarySystemGroupedBackground)
    let rowBackground: Color
    /// Accent color derived from the terminal theme (cursor/palette), propagated to sub-sheets
    let accentColor: Color?
}

private struct SheetThemeColorsKey: EnvironmentKey {
    static let defaultValue: SheetThemeColors? = nil
}

extension EnvironmentValues {
    var sheetThemeColors: SheetThemeColors? {
        get { self[SheetThemeColorsKey.self] }
        set { self[SheetThemeColorsKey.self] = newValue }
    }
}

// MARK: - Sheet Theme Helpers

extension MainView {

    var sheetAccentColor: Color? {
        guard themedUIEnabled,
              let themeColors = effectiveThemeColors,
              let derived = ThemeUIColorDerivation.derive(from: themeColors) else {
            return nil
        }
        return derived.sheetAccent
    }

    var sheetColorSchemeForSheets: ColorScheme? {
        guard themedUIEnabled, let themeColors = effectiveThemeColors else { return nil }
        guard let base = Color(hex: themeColors.background) else { return nil }
        return base.isLight ? .light : .dark
    }

    /// Resolve all three sheet-styling properties once per body evaluation.
    /// `applySheetModifiers` previously read sheet theme + accent + color
    /// scheme independently for every `.themedSheet(...)` and modifier —
    /// 8+ attachments × 3 properties = 30+ `effectiveThemeColors` calls per
    /// body, each re-resolving the theme through `themeManager`. Single
    /// resolution, threaded through the modifier chain via
    /// `ResolvedSheetTheme`.
    func resolvedSheetTheme() -> ResolvedSheetTheme {
        guard themedUIEnabled,
              let themeColors = effectiveThemeColors,
              let derived = ThemeUIColorDerivation.derive(from: themeColors) else {
            return .none
        }
        let row = derived.sheetRowBackground.opacity(0.92)
        return ResolvedSheetTheme(
            themeColors: SheetThemeColors(
                background: derived.sheetBackground,
                rowBackground: row,
                accentColor: derived.sheetAccent
            ),
            accentColor: derived.sheetAccent,
            colorScheme: derived.isLight ? .light : .dark
        )
    }
}
