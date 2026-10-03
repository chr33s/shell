//
//  CursorManager.swift
//  shell
//
//  Manages cursor appearance settings: style, blinking, color, and size
//

import Foundation
import SwiftUI
import os

extension Notification.Name {
    static let cursorConfigChanged = Notification.Name("cursorConfigChanged")
}

enum CursorStyle: String, CaseIterable, Codable {
    case block
    case bar
    case underline
    case blockHollow = "block_hollow"

    var displayName: String {
        switch self {
        case .block: return String(localized: "Block", comment: "Cursor style: solid block")
        case .bar: return String(localized: "Bar", comment: "Cursor style: vertical bar")
        case .underline: return String(localized: "Underline", comment: "Cursor style: underline")
        case .blockHollow: return String(localized: "Hollow Block", comment: "Cursor style: hollow block outline")
        }
    }

    var configValue: String { rawValue }
}

enum CursorBlinkMode: String, CaseIterable, Codable {
    case normal
    case breathing
    case heartbeat
    case neonFlicker = "neon_flicker"
    case pulse
    case candle
    case shell

    var displayName: String {
        switch self {
        case .normal: return String(localized: "Normal", comment: "Cursor blink mode: standard on/off")
        case .breathing: return String(localized: "Breathing", comment: "Cursor blink mode: smooth fade")
        case .heartbeat: return String(localized: "Heartbeat", comment: "Cursor blink mode: double-pulse rhythm")
        case .neonFlicker: return String(localized: "Neon Flicker", comment: "Cursor blink mode: random brightness dips")
        case .pulse: return String(localized: "Pulse", comment: "Cursor blink mode: sharp snap, slow decay")
        case .candle: return String(localized: "Candle", comment: "Cursor blink mode: gentle irregular flicker")
        case .shell: return String(localized: "Shell", comment: "Cursor blink mode: # cursor with pulse")
        }
    }

    var description: String {
        switch self {
        case .normal: return String(localized: "Classic on/off blink", comment: "Cursor blink mode description")
        case .breathing: return String(localized: "Smooth fade in and out", comment: "Cursor blink mode description")
        case .heartbeat: return String(localized: "Double-pulse rhythm like a heartbeat", comment: "Cursor blink mode description")
        case .neonFlicker: return String(localized: "Random flickers like a neon sign", comment: "Cursor blink mode description")
        case .pulse: return String(localized: "Sharp flash then slow fade", comment: "Cursor blink mode description")
        case .candle: return String(localized: "Gentle irregular flicker like a candle", comment: "Cursor blink mode description")
        case .shell: return String(localized: "# symbol cursor with pulse animation", comment: "Cursor blink mode description")
        }
    }

    var configValue: String { rawValue }
}

@MainActor
@Observable
final class CursorManager {
    static let shared = CursorManager()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "CursorManager")

    // MARK: - Settings keys

    private static let ownedKeys: Set<String> = [
        Settings.Cursor.blinkEnabled.name, Settings.Cursor.blinkMode.name, Settings.Cursor.style.name,
        Settings.Cursor.color.name, Settings.Cursor.textColor.name,
        Settings.Cursor.opacity.name, Settings.Cursor.thickness.name, Settings.Cursor.height.name
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    @ObservationIgnored private var isReloading = false

    // MARK: - Observable Properties

    var cursorBlinkEnabled: Bool {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.blinkEnabled, cursorBlinkEnabled) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    var cursorBlinkMode: CursorBlinkMode {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.blinkMode, cursorBlinkMode) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    var cursorStyle: CursorStyle {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.style, cursorStyle) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    /// Custom cursor color as hex string (e.g. "#FF0000"), nil for default
    var cursorColor: String? {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                if let color = cursorColor {
                    SettingsStore.shared.set(Settings.Cursor.color, color)
                } else {
                    SettingsStore.shared.reset(Settings.Cursor.color)
                }
            }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    /// Custom cursor text color as hex string, nil for default
    var cursorTextColor: String? {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading {
                if let color = cursorTextColor {
                    SettingsStore.shared.set(Settings.Cursor.textColor, color)
                } else {
                    SettingsStore.shared.reset(Settings.Cursor.textColor)
                }
            }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    /// Cursor opacity (0.0–1.0)
    var cursorOpacity: Double {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.opacity, cursorOpacity) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    /// Cursor thickness adjustment in pixels (0 = default)
    var cursorThickness: Int {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.thickness, cursorThickness) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    /// Cursor height adjustment in pixels (0 = default)
    var cursorHeight: Int {
        didSet {
            guard ProtectedDataGuard.isAvailable else { return }
            if !isReloading { SettingsStore.shared.set(Settings.Cursor.height, cursorHeight) }
            NotificationCenter.default.post(name: .cursorConfigChanged, object: nil)
        }
    }

    // MARK: - Initialization

    private init() {
        let store = SettingsStore.shared
        self.cursorBlinkEnabled = store.get(Settings.Cursor.blinkEnabled)
        self.cursorBlinkMode = store.get(Settings.Cursor.blinkMode)
        self.cursorStyle = store.get(Settings.Cursor.style)

        self.cursorColor = store.get(Settings.Cursor.color)
        self.cursorTextColor = store.get(Settings.Cursor.textColor)
        self.cursorOpacity = store.get(Settings.Cursor.opacity)
        self.cursorThickness = store.get(Settings.Cursor.thickness)
        self.cursorHeight = store.get(Settings.Cursor.height)

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    // MARK: - External refresh

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Cursor.blinkEnabled.name) { cursorBlinkEnabled = store.get(Settings.Cursor.blinkEnabled) }
        if keys.contains(Settings.Cursor.blinkMode.name) { cursorBlinkMode = store.get(Settings.Cursor.blinkMode) }
        if keys.contains(Settings.Cursor.style.name) { cursorStyle = store.get(Settings.Cursor.style) }
        if keys.contains(Settings.Cursor.color.name) { cursorColor = store.get(Settings.Cursor.color) }
        if keys.contains(Settings.Cursor.textColor.name) { cursorTextColor = store.get(Settings.Cursor.textColor) }
        if keys.contains(Settings.Cursor.opacity.name) { cursorOpacity = store.get(Settings.Cursor.opacity) }
        if keys.contains(Settings.Cursor.thickness.name) { cursorThickness = store.get(Settings.Cursor.thickness) }
        if keys.contains(Settings.Cursor.height.name) { cursorHeight = store.get(Settings.Cursor.height) }
    }

    // MARK: - Cursor Config Generation

    /// Generates config lines for all cursor settings
    func generateCursorConfigLines() -> [String] {
        var lines: [String] = []
        lines.append("cursor-style = \(cursorStyle.configValue)")
        lines.append("cursor-style-blink = \(cursorBlinkEnabled)")
        if cursorBlinkEnabled {
            // Animated blink modes wake the renderer at ~30fps continuously;
            // in battery saver, fall back to classic blink (600ms toggles)
            // without persisting the override — the user's choice returns
            // when the saver tier lifts.
            let effectiveMode: CursorBlinkMode =
                PowerManager.shared.throttleAnimatedCursor ? .normal : cursorBlinkMode
            lines.append("cursor-blink-mode = \(effectiveMode.configValue)")
        }
        lines.append("cursor-opacity = \(cursorOpacity)")

        if let color = cursorColor {
            lines.append("cursor-color = \(color)")
        }
        if let textColor = cursorTextColor {
            lines.append("cursor-text = \(textColor)")
        }
        if cursorThickness != 0 {
            lines.append("adjust-cursor-thickness = \(cursorThickness)")
        }
        if cursorHeight != 0 {
            lines.append("adjust-cursor-height = \(cursorHeight)")
        }
        return lines
    }
}
