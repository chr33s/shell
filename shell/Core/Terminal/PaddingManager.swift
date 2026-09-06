//
//  PaddingManager.swift
//  shell
//
//  Centralized padding calculations for terminal content.
//  Ensures consistent spacing between text and edges/toolbars across all contexts.
//

import Foundation
import UIKit
import os

/// Manages padding calculations for terminal content.
/// Provides platform-tuned window padding for the Ghostty config.
@MainActor
@Observable
final class PaddingManager {
    static let shared = PaddingManager()

    @ObservationIgnored
    private let logger = Logger(subsystem: "dev.chr33s.shell", category: "PaddingManager")

    private static let ownedKeys: Set<String> = [
        Settings.Window.extendUnderHomeIndicator.name
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    @ObservationIgnored private var isReloading = false

    /// Master switch for the home-indicator bottom reservation.
    ///
    /// Default (false) reserves the home-indicator strip in every mode (including
    /// Full Screen), keeping a touch-safe gap so the system home-swipe gesture
    /// doesn't intercept touches meant for text selection near the bottom edge.
    /// When true the terminal runs edge-to-edge (flush) with no reservation. Only
    /// meaningful — and only surfaced in Settings — on devices with a home indicator.
    var extendUnderHomeIndicator: Bool {
        didSet {
            guard extendUnderHomeIndicator != oldValue else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Window.extendUnderHomeIndicator, extendUnderHomeIndicator) }
            NotificationCenter.default.post(name: .terminalBottomInsetInvalidated, object: nil)
        }
    }

    private init() {
        self.extendUnderHomeIndicator = SettingsStore.shared.get(Settings.Window.extendUnderHomeIndicator)

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if keys.contains(Settings.Window.extendUnderHomeIndicator.name) {
            extendUnderHomeIndicator = SettingsStore.shared.get(Settings.Window.extendUnderHomeIndicator)
        }
    }

    // MARK: - Padding

    /// Platform-tuned horizontal padding.
    /// Catalyst windows have larger rounded corner masks; phones stay snug.
    var effectivePaddingX: Int {
#if targetEnvironment(macCatalyst)
        return 10
#else
        return UIDevice.current.userInterfaceIdiom == .phone ? 6 : 8
#endif
    }

    /// Platform-tuned vertical padding.
    var effectivePaddingY: Int {
#if targetEnvironment(macCatalyst)
        return 6
#else
        return UIDevice.current.userInterfaceIdiom == .phone ? 3 : 4
#endif
    }

    // MARK: - Ghostty Config

    /// Calculate Ghostty config padding values.
    /// Returns the platform defaults chosen to keep text clear of rounded corners.
    ///
    /// Keep balance disabled so the grid stays pinned to the explicit top-left
    /// padding. Balanced padding redistributes the sub-cell remainder across both
    /// edges, which adds a top gap (content sits lower) and drifts the text during
    /// live resize.
    /// - Returns: Tuple of (x, y, balance) for window padding config keys.
    func configPadding() -> (x: Int, y: Int, balance: Bool) {
        return (effectivePaddingX, effectivePaddingY, false)
    }
}
