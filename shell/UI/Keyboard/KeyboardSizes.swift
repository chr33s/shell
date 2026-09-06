//
//  KeyboardSizes.swift
//  shell
//
//  Device-specific sizing for keyboard toolbar
//

import UIKit

struct KeyboardSizes {
    // MARK: - Nested Types

    struct Toolbar {
        let height: CGFloat
        let padding: CGFloat  // Vertical padding
        let spacing: CGFloat  // Horizontal spacing between buttons
        let cornerRadius: CGFloat
        let drawerHeight: CGFloat  // Height of expandable drawer row (0 on iPad)
    }

    struct Button {
        let height: CGFloat
        let iconWidth: CGFloat    // For arrow cluster, copy/paste icons
        let normalWidth: CGFloat  // For Tab, symbols
        let wideWidth: CGFloat    // For Esc, Ctrl, Alt, Cmd
        let cornerRadius: CGFloat
        let fontSize: CGFloat
        let symbolSize: CGFloat
    }

    // MARK: - Properties

    let toolbar: Toolbar
    let button: Button

    // MARK: - Device Presets

    /// iPhone portrait (small)
    static let iPhonePortrait = KeyboardSizes(
        toolbar: Toolbar(height: 44, padding: 0, spacing: 0, cornerRadius: 16, drawerHeight: 44),
        button: Button(
            height: 38,
            iconWidth: 48,
            normalWidth: 33,
            wideWidth: 48,
            cornerRadius: 10,
            fontSize: 15,
            symbolSize: 16
        )
    )

    /// iPhone landscape (compact)
    static let iPhoneLandscape = KeyboardSizes(
        toolbar: Toolbar(height: 38, padding: 0, spacing: 0, cornerRadius: 14, drawerHeight: 38),
        button: Button(
            height: 32,
            iconWidth: 44,
            normalWidth: 30,
            wideWidth: 44,
            cornerRadius: 9,
            fontSize: 14,
            symbolSize: 15
        )
    )

    /// iPad (all orientations)
    static let iPad = KeyboardSizes(
        toolbar: Toolbar(height: 55, padding: 6, spacing: 0, cornerRadius: 18, drawerHeight: 55),
        button: Button(
            height: 43,
            iconWidth: 58,
            normalWidth: 48,
            wideWidth: 68,
            cornerRadius: 12,
            fontSize: 17,
            symbolSize: 18
        )
    )

    // MARK: - Device Detection

    static func current(traitCollection: UITraitCollection? = nil) -> KeyboardSizes {
        let idiom = traitCollection?.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom

        #if os(visionOS)
        // visionOS doesn't have device orientation, use iPad sizes
        return .iPad
        #else
        switch idiom {
        case .pad:
            return .iPad
        case .phone:
            return isPhoneLandscape(traitCollection: traitCollection) ? .iPhoneLandscape : .iPhonePortrait
        default:
            return .iPhonePortrait
        }
        #endif
    }

    #if !os(visionOS)
    private static func isPhoneLandscape(traitCollection: UITraitCollection?) -> Bool {
        if let traitCollection {
            if traitCollection.verticalSizeClass == .compact {
                return true
            }
            if traitCollection.verticalSizeClass == .regular {
                return false
            }
        }

        let orientation = UIDevice.current.orientation
        if orientation.isValidInterfaceOrientation {
            return orientation.isLandscape
        }

        // Last resort: no size class and no valid device orientation. Read the
        // screen off the scene this app is showing in - `UIScreen.main` is
        // deprecated and need not be the display this window is on. Nothing
        // connected means no landscape evidence, so keep the portrait default.
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let screenBounds = activeScene?.screen.bounds else { return false }
        return screenBounds.width > screenBounds.height
    }
    #endif
}
