//
//  WindowSizeManager.swift
//  shell
//
//  Tracks and persists the last focused window size for new window creation
//

import Foundation

#if targetEnvironment(macCatalyst)

/// Manages window size and position persistence for Mac Catalyst.
/// New windows open with the geometry of the last focused window.
@MainActor
class WindowSizeManager {
    static let shared = WindowSizeManager()

    private static let defaultWidth: CGFloat = 800
    private static let defaultHeight: CGFloat = 600
    private static let minWidth: CGFloat = 400
    private static let minHeight: CGFloat = 300

    private(set) var lastWindowSize: CGSize
    private(set) var lastWindowOrigin: CGPoint?

    private init() {
        let store = SettingsStore.shared
        let savedWidth = store.get(Settings.Window.lastWidth)
        let savedHeight = store.get(Settings.Window.lastHeight)

        if savedWidth >= Self.minWidth && savedHeight >= Self.minHeight {
            self.lastWindowSize = CGSize(width: savedWidth, height: savedHeight)
        } else {
            self.lastWindowSize = CGSize(width: Self.defaultWidth, height: Self.defaultHeight)
        }

        if store.get(Settings.Window.lastHasOrigin) {
            let x = store.get(Settings.Window.lastOriginX)
            let y = store.get(Settings.Window.lastOriginY)
            self.lastWindowOrigin = CGPoint(x: x, y: y)
        } else {
            self.lastWindowOrigin = nil
        }
    }

    /// Persist the full frame (size and origin) for the focused window.
    func updateWindowFrame(_ frame: CGRect) {
        let size = frame.size
        guard size.width >= Self.minWidth && size.height >= Self.minHeight else { return }

        if size != lastWindowSize {
            lastWindowSize = size
            SettingsStore.shared.set(Settings.Window.lastWidth, Double(size.width))
            SettingsStore.shared.set(Settings.Window.lastHeight, Double(size.height))
        }

        let origin = frame.origin
        if origin != lastWindowOrigin {
            lastWindowOrigin = origin
            SettingsStore.shared.set(Settings.Window.lastOriginX, Double(origin.x))
            SettingsStore.shared.set(Settings.Window.lastOriginY, Double(origin.y))
            SettingsStore.shared.set(Settings.Window.lastHasOrigin, true)
        }
    }

    /// Stored size and (optional) origin for a new window.
    func frameForNewWindow() -> (origin: CGPoint?, size: CGSize) {
        return (lastWindowOrigin, lastWindowSize)
    }
}

#endif
