//
//  MainView+TabBarStyling.swift
//  shell
//
//  Tab bar color and styling computations for MainView.
//  Extracted for build parallelization.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Resolved Tab Bar Theme Bundle

/// Pre-resolved theme values for a single `MainView.body` evaluation.
///
/// Crash logs caught the main thread inside `MainView.effectiveThemeColors.getter`
/// repeatedly during scene-update transactions: every styling computed property
/// (`tabBarBackgroundColor`, `selectedTabBackgroundColor`, `tabTextColor`, etc.)
/// independently re-resolves the theme and re-extracts UIColor RGB
/// components for `isLight`/blend factors. Computing once per body and passing
/// the bundle through is byte-identical to the per-call path.
struct ResolvedTabBarTheme {
    let themeColors: ThemeManager.ThemeInfo.ThemeColors?
    let baseColor: Color?
    /// Theme background composited the same way as the terminal surface at
    /// the user's current background opacity. Integrated tabs use this rather
    /// than the opaque theme swatch so their active edge actually connects to
    /// the visible terminal.
    let terminalSurfaceBackground: Color?
    /// Catalyst can composite the terminal over the window backdrop. The
    /// existing theme-derived strip already has strong contrast in that case;
    /// opaque Catalyst and iOS need a larger deliberate separation.
    let terminalSurfaceIsTransparent: Bool
    let isLight: Bool
    let adaptivePrimaryBlend: CGFloat
    let adaptiveSecondaryBlend: CGFloat

    static let fallback = ResolvedTabBarTheme(
        themeColors: nil,
        baseColor: nil,
        terminalSurfaceBackground: nil,
        terminalSurfaceIsTransparent: false,
        isLight: false,
        adaptivePrimaryBlend: 0,
        adaptiveSecondaryBlend: 0
    )

    /// Resolved sheet styling for one `MainView.body` evaluation. The crash
    /// IPS files repeatedly catch main inside `MainView.effectiveThemeColors`
    /// during scene-update transactions because `applySheetModifiers` reads
    /// sheet theme + accent + color scheme once per attached `.themedSheet(...)`
    /// and per modifier; the chain has 8+ such attachments × 3 properties =
    /// 30+ effectiveThemeColors calls per body. Each call walks
    /// themeManager. Computing once and threading the bundle through
    /// collapses that to a single resolution.

    var tabBarBackground: Color {
        baseColor ?? Color(uiColor: .systemBackground)
    }

    /// Integrated tabs need a restrained frame behind transparent inactive
    /// tabs. Translucent Catalyst already gets some separation from the
    /// composited terminal, while opaque Catalyst and iOS need a slightly
    /// larger shift because both surfaces otherwise resolve to nearly the
    /// same color.
    var integratedStripBackground: Color {
        guard let baseColor else { return Color(uiColor: .systemBackground) }
        if terminalSurfaceIsTransparent {
            return isLight
                ? baseColor.blendedWithBlack(0.04)
                : baseColor.darkenedPreservingHue(0.06)
        }

        let terminalColor = terminalSurfaceBackground ?? baseColor
        if isLight {
            return terminalColor.blendedWithBlack(0.06)
        }
        return terminalColor.blendedWithWhite(0.06)
    }

    /// Optical edge colors come from the selected terminal surface rather
    /// than a theme accent. This keeps the rim native-looking while preserving
    /// chromatic backgrounds instead of washing them toward gray.
    var integratedEdgePalette: IntegratedTabEdgePalette {
        IntegratedTabEdgePalette(
            surfaceColor: terminalSurfaceBackground ?? baseColor,
            isLightTheme: isLight
        )
    }

    var selectedBackground: Color {
        guard let baseColor else { return Color(uiColor: .secondarySystemBackground) }
        if isLight {
            return baseColor.blendedWithBlack(0.20)
        }
        return baseColor.lightenedPreservingHue(adaptivePrimaryBlend)
    }

    var unselectedBackground: Color {
        guard let baseColor else { return Color(uiColor: .tertiarySystemBackground) }
        if isLight {
            return baseColor.blendedWithBlack(0.08)
        }
        return baseColor.lightenedPreservingHue(adaptiveSecondaryBlend)
    }

    /// Hovering an inactive tab needs to remain visible even when the theme's
    /// derived unselected color nearly matches the surface behind it (for
    /// example, Tango Dark over the integrated tab strip). Derive the default
    /// from the surface that is actually under the tab so the fill always
    /// moves a consistent distance darker or lighter.
    func inactiveHoverBackground(for style: TopTabStyle) -> Color {
        guard baseColor != nil else { return unselectedBackground }
        let surface = style == .integrated ? integratedStripBackground : tabBarBackground
        return isLight
            ? surface.blendedWithBlack(0.16)
            : surface.blendedWithWhite(0.16)
    }

    var tabText: Color {
        guard baseColor != nil else { return .primary }
        return isLight ? Color(white: 0.1) : Color(white: 0.95)
    }

    var tabSecondaryText: Color {
        guard baseColor != nil else { return .secondary }
        return isLight ? Color(white: 0.4) : Color(white: 0.6)
    }

    /// Ledger's selection bar is the only selection cue, so it takes the theme
    /// accent (same source as sheets and the sidebar) rather than the text
    /// color, which would read as a second keyline.
    var ledgerIndicator: Color {
        guard baseColor != nil else { return .accentColor }
        if let accent = themeColors?.vibrantAccentColor {
            return accent.adjustedSheetTint(on: tabBarBackground)
        }
        return tabText
    }
}

/// Pre-resolved sheet styling for one `MainView.body` evaluation. See
/// `ResolvedTabBarTheme` doc for context — same memoization pattern,
/// applied to the sheet/modifier chain.
struct ResolvedSheetTheme {
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?

    static let none = ResolvedSheetTheme(themeColors: nil, accentColor: nil, colorScheme: nil)
}

// MARK: - Tab Bar Styling

extension MainView {

    /// Background color for selected tab - needs to stand out from the tab bar
    var selectedTabBackgroundColor: Color {
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            if baseColor.isLight {
                return baseColor.blendedWithBlack(0.20)
            } else {
                return baseColor.lightenedPreservingHue(baseColor.adaptivePrimaryBlend)
            }
        }
        return Color(uiColor: .secondarySystemBackground)
    }

    /// Background color for the tab bar itself
    var tabBarBackgroundColor: Color {
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor
        }
        return Color(uiColor: .systemBackground)
    }

    /// Primary text color for tabs - adapts to theme background
    var tabTextColor: Color {
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight ? Color(white: 0.1) : Color(white: 0.95)
        }
        return .primary
    }

    /// Secondary text color for tabs - adapts to theme background
    var tabSecondaryTextColor: Color {
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            return baseColor.isLight ? Color(white: 0.4) : Color(white: 0.6)
        }
        return .secondary
    }

    /// Background color for unselected tabs - subtle but visible
    var unselectedTabBackgroundColor: Color {
        if let themeColors = effectiveThemeColors,
           let baseColor = Color(hex: themeColors.background) {
            if baseColor.isLight {
                return baseColor.blendedWithBlack(0.08)
            } else {
                return baseColor.lightenedPreservingHue(baseColor.adaptiveSecondaryBlend)
            }
        }
        return Color(uiColor: .tertiarySystemBackground)
    }

    /// Compute all derived tab bar styling values once for the current body
    /// evaluation. Replaces the previous pattern of calling 5+ independent
    /// computed properties (`tabBarBackgroundColor`, `tabTextColor`, etc.) that
    /// each re-resolved the theme and re-extracted UIColor RGB components.
    /// Per body run this collapses ~7 theme lookups + ~8 UIColor conversions
    /// into 1 of each.
    func resolvedTabBarTheme() -> ResolvedTabBarTheme {
        let themeColors = effectiveThemeColors
        let baseColor = themeColors.flatMap { Color(hex: $0.background) }
        guard let baseColor else {
            return ResolvedTabBarTheme(
                themeColors: themeColors,
                baseColor: nil,
                terminalSurfaceBackground: nil,
                terminalSurfaceIsTransparent: false,
                isLight: false,
                adaptivePrimaryBlend: 0,
                adaptiveSecondaryBlend: 0
            )
        }
        #if targetEnvironment(macCatalyst)
        let terminalSurfaceIsTransparent = transparencyManager.backgroundOpacity < 0.999
        let terminalSurfaceBackground = baseColor.blendedWithWhite(
            1 - CGFloat(transparencyManager.backgroundOpacity)
        )
        #else
        // The iOS/visionOS terminal is composited over the same theme-colored
        // root fill, so opacity does not change its visible base color.
        let terminalSurfaceIsTransparent = false
        let terminalSurfaceBackground = baseColor
        #endif
        return ResolvedTabBarTheme(
            themeColors: themeColors,
            baseColor: baseColor,
            terminalSurfaceBackground: terminalSurfaceBackground,
            terminalSurfaceIsTransparent: terminalSurfaceIsTransparent,
            isLight: baseColor.isLight,
            adaptivePrimaryBlend: baseColor.adaptivePrimaryBlend,
            adaptiveSecondaryBlend: baseColor.adaptiveSecondaryBlend
        )
    }

    /// Theme colors that chrome derives from. The fork has a single global
    /// theme — per-tab and per-window overrides are out of scope — so this
    /// reads the cached `ThemeInfo` for the selected theme and never scans
    /// the catalog during a body evaluation.
    var effectiveThemeColors: ThemeManager.ThemeInfo.ThemeColors? {
        themeManager.currentThemeInfo?.colors
    }

    /// Name of the theme the chrome is currently rendering.
    var effectiveThemeName: String? {
        themeManager.currentTheme
    }

    /// Whether tabs are displayed in the titlebar (Catalyst only)
    var usesTitlebarTabs: Bool {
        #if targetEnvironment(macCatalyst)
        return tabsInTitlebarEnabled
        #else
        return false
        #endif
    }

    /// Whether the horizontal row physically occupies the window's top edge.
    /// Hidden-titlebar mode is top-attached even when the separate
    /// "Tabs in Title Bar" preference is off.
    var topTabBarAttachedToWindow: Bool {
        #if targetEnvironment(macCatalyst)
        return usesTitlebarTabs || hideWindowTitleBar
        #else
        return false
        #endif
    }

    func tabBarChromeBackground(_ theme: ResolvedTabBarTheme) -> Color {
        topTabStyle == .integrated
            ? theme.integratedStripBackground
            : theme.tabBarBackground
    }

    /// Leading padding for tab bar content (accounts for window controls on Catalyst)
    var tabBarLeadingPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        let basePadding: CGFloat = 8
        let controlClearance: CGFloat
        if usesTitlebarTabs && !hideWindowTitleBar {
            // The measured value arrives after AppKit creates the buttons.
            // Keep enough launch-time clearance for the larger Catalyst
            // traffic-light geometry seen on current macOS releases.
            let titlebarMinimum: CGFloat = 100
            let measuredInset = titlebarLayoutManager.leadingInset
            controlClearance = max(titlebarMinimum, measuredInset)
        } else {
            controlClearance = basePadding
        }
        let dragClearance = topTabBarAttachedToWindow ? Self.catalystWindowDragWidth : 0
        return controlClearance + dragClearance
        #else
        return 0
        #endif
    }
}
