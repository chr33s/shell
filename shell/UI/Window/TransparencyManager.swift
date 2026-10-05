import Foundation
import Combine

/// Manages window transparency settings (Mac Catalyst only).
///
/// Migrated from `ObservableObject + @Published` to `@Observable` so SwiftUI
/// tracks per-property reads — slider drags on `backgroundOpacity` no longer
/// invalidate views that only read `blurEnabled` (and vice-versa).
@MainActor
@Observable
final class TransparencyManager {
    static let shared = TransparencyManager()

    /// How the window background behind the terminal is blurred.
    enum BlurStyle: String, CaseIterable, Identifiable {
        /// NSVisualEffectView.
        case standard
        /// macOS 26 Liquid Glass (NSGlassEffectView).
        case glassRegular
        case glassClear

        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: return String(localized: "Standard")
            case .glassRegular: return String(localized: "Glass")
            case .glassClear: return String(localized: "Clear Glass")
            }
        }
    }

    private static let ownedKeys: Set<String> = [
        Settings.Transparency.backgroundOpacity.name,
        Settings.Transparency.blurEnabled.name, Settings.Transparency.blurStyle.name,
        Settings.Transparency.pinnedSidebarTransparency.name
    ]
    // Defaults mirror `Settings.Transparency`; keep both in step. Glass at 0.8
    // is the macOS 26 look out of the box: 0.92 over a dark theme is visually
    // indistinguishable from opaque.
    private static let defaultBackgroundOpacity: Double = 0.8
    private static let defaultBlurEnabled: Bool = true
    private static let defaultBlurStyle: BlurStyle = .glassRegular
    private static let defaultPinnedSidebarTransparencyEnabled: Bool = false

    /// Current background opacity (0.0 = fully transparent, 1.0 = opaque)
    var backgroundOpacity: Double {
        didSet {
            guard backgroundOpacity != oldValue else { return }
            saveBackgroundOpacity()
            transparencyDidChange.send()
        }
    }

    /// Whether blur is enabled (sandbox mode only - simple on/off toggle)
    var blurEnabled: Bool {
        didSet {
            guard blurEnabled != oldValue else { return }
            saveBlurEnabled()
            transparencyDidChange.send()
        }
    }

    /// Stored blur style preference.
    var blurStyle: BlurStyle {
        didSet {
            guard blurStyle != oldValue else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Transparency.blurStyle, blurStyle) }
            transparencyDidChange.send()
        }
    }

    var usesGlass: Bool { blurStyle != .standard }

    /// Whether the pinned vertical tab sidebar uses the window's background
    /// opacity instead of its normal opaque fill.
    var pinnedSidebarTransparencyEnabled: Bool {
        didSet {
            guard pinnedSidebarTransparencyEnabled != oldValue, !isReloading else { return }
            SettingsStore.shared.set(Settings.Transparency.pinnedSidebarTransparency, pinnedSidebarTransparencyEnabled)
        }
    }

    /// Set while `reload(keys:)` re-assigns properties so didSet skips the store write.
    @ObservationIgnored private var isReloading = false

    /// Whether transparency is currently disabled (forced to 1.0)
    /// Used by toggle transparency keyboard shortcut
    private(set) var isTransparencyDisabled: Bool = false

    /// Saved opacity when transparency is toggled off
    @ObservationIgnored private var savedOpacity: Double?

    /// Publisher that emits when transparency settings change
    @ObservationIgnored let transparencyDidChange = PassthroughSubject<Void, Never>()

    private init() {
        self.backgroundOpacity = Self.storedBackgroundOpacity()
        self.blurEnabled = SettingsStore.shared.get(Settings.Transparency.blurEnabled)
        self.blurStyle = SettingsStore.shared.get(Settings.Transparency.blurStyle)
        self.pinnedSidebarTransparencyEnabled = SettingsStore.shared.get(Settings.Transparency.pinnedSidebarTransparency)
        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// A stored opacity of 0 (or less) falls back to the default.
    private static func storedBackgroundOpacity() -> Double {
        let saved = SettingsStore.shared.get(Settings.Transparency.backgroundOpacity)
        return saved > 0 ? saved : defaultBackgroundOpacity
    }

    /// Re-read owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        if keys.contains(Settings.Transparency.backgroundOpacity.name) {
            backgroundOpacity = Self.storedBackgroundOpacity()
        }
        if keys.contains(Settings.Transparency.blurEnabled.name) {
            blurEnabled = SettingsStore.shared.get(Settings.Transparency.blurEnabled)
        }
        if keys.contains(Settings.Transparency.blurStyle.name) {
            blurStyle = SettingsStore.shared.get(Settings.Transparency.blurStyle)
        }
        if keys.contains(Settings.Transparency.pinnedSidebarTransparency.name) {
            pinnedSidebarTransparencyEnabled = SettingsStore.shared.get(Settings.Transparency.pinnedSidebarTransparency)
        }
    }

    private func saveBackgroundOpacity() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Transparency.backgroundOpacity, backgroundOpacity)
    }

    private func saveBlurEnabled() {
        guard !isReloading else { return }
        SettingsStore.shared.set(Settings.Transparency.blurEnabled, blurEnabled)
    }

    /// Reset to default transparency settings
    func resetToDefaults() {
        backgroundOpacity = Self.defaultBackgroundOpacity
        blurEnabled = Self.defaultBlurEnabled
        blurStyle = Self.defaultBlurStyle
        pinnedSidebarTransparencyEnabled = Self.defaultPinnedSidebarTransparencyEnabled
    }

    /// Toggle transparency on/off (Mac Catalyst only)
    /// When toggling off, saves current opacity and sets to fully opaque.
    /// When toggling on, restores the saved opacity value.
    func toggleTransparency() {
        if isTransparencyDisabled {
            // Restore saved opacity
            if let saved = savedOpacity {
                backgroundOpacity = saved
            }
            isTransparencyDisabled = false
        } else {
            // Save current opacity and set to fully opaque
            savedOpacity = backgroundOpacity
            backgroundOpacity = 1.0
            isTransparencyDisabled = true
        }
    }
}
