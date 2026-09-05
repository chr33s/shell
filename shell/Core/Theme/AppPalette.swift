//
//  AppPalette.swift
//  shell
//
//  Semantic app-chrome colors drawn from the bundled Blackboard theme, so
//  non-terminal UI reads as part of the same palette instead of falling back
//  to the stock system blues, greens and reds.
//
//  Light values come from `Resources/themes/Blackboard Light`, dark values
//  from `Resources/themes/Blackboard Dark`. Each color resolves per trait
//  collection, so it follows the active interface style automatically.
//

import SwiftUI
import UIKit

enum AppPalette {
    // Blackboard Light / Blackboard Dark, palette index 4 (blue).
    static var accent: UIColor { dynamic(light: 0x3D639C, dark: 0x8DA6CE) }
    // Palette index 2 (green).
    static var success: UIColor { dynamic(light: 0x2E7D1B, dark: 0x61CE3C) }
    // Palette index 3 (yellow).
    static var warning: UIColor { dynamic(light: 0x8F6F00, dark: 0xFBDE2D) }
    // Palette index 1 (red).
    static var danger: UIColor { dynamic(light: 0xB03028, dark: 0xD74E41) }
    // Palette index 5 (orange).
    static var highlight: UIColor { dynamic(light: 0xBF4D00, dark: 0xFF6400) }

    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        }
    }
}

/// Constrained to `ShapeStyle` (the way SwiftUI declares `.blue` and friends)
/// so these work in leading-dot position for `foregroundStyle` as well as for
/// plain `Color` parameters such as `tint` and `foregroundColor`.
extension ShapeStyle where Self == Color {
    /// Blackboard blue. Matches the `AccentColor` asset, for the places that
    /// need an explicit color rather than the inherited tint.
    static var appAccent: Color { Color(AppPalette.accent) }
    static var appSuccess: Color { Color(AppPalette.success) }
    static var appWarning: Color { Color(AppPalette.warning) }
    static var appDanger: Color { Color(AppPalette.danger) }
    static var appHighlight: Color { Color(AppPalette.highlight) }
}

extension UIColor {
    static var appAccent: UIColor { AppPalette.accent }
    static var appSuccess: UIColor { AppPalette.success }
    static var appWarning: UIColor { AppPalette.warning }
    static var appDanger: UIColor { AppPalette.danger }
    static var appHighlight: UIColor { AppPalette.highlight }

    fileprivate convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
