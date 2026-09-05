//
//  SwipeGestureManager.swift
//  shell
//
//  Stores user-customized horizontal-swipe bindings for the terminal.
//  Single source of truth for both the iOS direct-touch swipe gestures and
//  the Mac Catalyst trackpad swipe pan gesture.
//

import Foundation
import SwiftUI
import Observation
import os

@MainActor
@Observable
final class SwipeGestureManager {
    static let shared = SwipeGestureManager()

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SwipeGestureManager")

    static let bindingsDidChangeNotification = Notification.Name("SwipeGestureBindingsDidChange")

    // MARK: - Defaults

    static let defaultLeftBinding: SwipeGestureBinding = .preset(.nextTab)
    static let defaultRightBinding: SwipeGestureBinding = .preset(.previousTab)

    // MARK: - Observable Properties

    /// When true, didSet skips `save()` so a batch update can save once at the end.
    private var isBatching = false

    private(set) var leftBinding: SwipeGestureBinding {
        didSet { if !isBatching { save() } }
    }

    private(set) var rightBinding: SwipeGestureBinding {
        didSet { if !isBatching { save() } }
    }

    var isCustomized: Bool {
        leftBinding != Self.defaultLeftBinding || rightBinding != Self.defaultRightBinding
    }

    // MARK: - Init

    private init() {
        let stored = Self.load()
        leftBinding = stored?.left ?? Self.defaultLeftBinding
        rightBinding = stored?.right ?? Self.defaultRightBinding

        SettingsRefreshHub.shared.register(keys: [Settings.Gestures.swipeBindings.name]) { [weak self] keys in
            self?.reload(keys: keys)
        }

        // Observe toolbar custom-key changes so we can clear any swipe binding
        // that referenced a now-deleted custom key. Without this the recognizer
        // would stay enabled and silently consume the gesture. Singleton lives
        // for the app's lifetime so we don't track the observer for removal.
        NotificationCenter.default.addObserver(
            forName: KeyboardToolbarManager.layoutDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearOrphanedReferences()
            }
        }
    }

    /// Reset any `customKeyRef` binding whose target has been deleted from
    /// KeyboardToolbarManager. Called whenever the toolbar layout changes.
    private func clearOrphanedReferences() {
        let manager = KeyboardToolbarManager.shared
        if case .customKeyRef(let id) = leftBinding, manager.customKey(for: id) == nil {
            leftBinding = .preset(.none)
        }
        if case .customKeyRef(let id) = rightBinding, manager.customKey(for: id) == nil {
            rightBinding = .preset(.none)
        }
    }

    // MARK: - Public API

    func binding(for direction: SwipeDirection) -> SwipeGestureBinding {
        switch direction {
        case .left: return leftBinding
        case .right: return rightBinding
        }
    }

    func setBinding(_ binding: SwipeGestureBinding, for direction: SwipeDirection) {
        switch direction {
        case .left: leftBinding = binding
        case .right: rightBinding = binding
        }
    }

    /// Set both bindings in one operation. Saves and posts the change
    /// notification once instead of twice — important so the gesture
    /// recognizer doesn't rebuild itself in the middle of the update.
    func setBindings(left: SwipeGestureBinding, right: SwipeGestureBinding) {
        guard left != leftBinding || right != rightBinding else { return }
        isBatching = true
        leftBinding = left
        rightBinding = right
        isBatching = false
        save()
    }

    /// Swap the left and right bindings.
    func swapBindings() {
        setBindings(left: rightBinding, right: leftBinding)
    }

    func resetToDefaults() {
        setBindings(left: Self.defaultLeftBinding, right: Self.defaultRightBinding)
    }

    // MARK: - Persistence

    private struct StoredBindings: Codable {
        let left: SwipeGestureBinding
        let right: SwipeGestureBinding
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        guard keys.contains(Settings.Gestures.swipeBindings.name) else { return }
        isBatching = true
        let stored = Self.load()
        leftBinding = stored?.left ?? Self.defaultLeftBinding
        rightBinding = stored?.right ?? Self.defaultRightBinding
        isBatching = false
        NotificationCenter.default.post(name: Self.bindingsDidChangeNotification, object: nil)
    }

    private func save() {
        let stored = StoredBindings(left: leftBinding, right: rightBinding)
        do {
            let data = try JSONEncoder().encode(stored)
            SettingsStore.shared.set(Settings.Gestures.swipeBindings, data)
        } catch {
            Self.logger.error("Failed to save swipe gesture bindings: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: Self.bindingsDidChangeNotification, object: nil)
    }

    private static func load() -> StoredBindings? {
        guard let data = SettingsStore.shared.get(Settings.Gestures.swipeBindings) else { return nil }
        do {
            return try JSONDecoder().decode(StoredBindings.self, from: data)
        } catch {
            logger.error("Failed to load swipe gesture bindings: \(error.localizedDescription)")
            return nil
        }
    }
}
