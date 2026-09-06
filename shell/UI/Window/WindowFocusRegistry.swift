//
//  WindowFocusRegistry.swift
//  shell
//
//  Tracks per-window focus state for routing commands and focus updates.
//

import Foundation

@MainActor
final class WindowFocusRegistry {
    static let shared = WindowFocusRegistry()

    private var keyStateBySceneId: [String: Bool] = [:]
    private var lastKeySceneId: String?
    /// See `notifyMenuFocusChanged()`: the menu-bar hook re-enters this registry.
    private var isNotifyingMenuFocus = false

    private init() {}

    func update(sceneSessionId: String, isKey: Bool) {
        guard !sceneSessionId.isEmpty else { return }
        keyStateBySceneId[sceneSessionId] = isKey
        if isKey {
            lastKeySceneId = sceneSessionId
        } else if lastKeySceneId == sceneSessionId {
            lastKeySceneId = keyStateBySceneId.first(where: { $0.value })?.key
        }
        notifyMenuFocusChanged()
    }

    func remove(sceneSessionId: String) {
        guard !sceneSessionId.isEmpty else { return }
        keyStateBySceneId.removeValue(forKey: sceneSessionId)
        if lastKeySceneId == sceneSessionId {
            lastKeySceneId = keyStateBySceneId.first(where: { $0.value })?.key
        }
        notifyMenuFocusChanged()
    }

    func activeSceneSessionId() -> String? {
        if let lastKeySceneId, keyStateBySceneId[lastKeySceneId] == true {
            return lastKeySceneId
        }
        return keyStateBySceneId.first(where: { $0.value })?.key
    }

    /// Tells the menu bar its key-window answer may have changed. Called at the
    /// end of every mutation, once this registry's own state has settled, so
    /// `MenuFocusState` always re-resolves against the final answer.
    ///
    /// Guarded because the notification re-enters here: `noteWindowFocusChanged()`
    /// re-resolves through `UIApplication.ghostty_activeWindowSceneSessionID()`,
    /// which prunes an entry whose scene is gone by calling `remove` right back.
    /// That nesting is finite — each level drops one entry — but the outermost
    /// call re-resolves after those prunes land, so the inner ones would only
    /// repeat work it is about to do anyway.
    private func notifyMenuFocusChanged() {
        guard !isNotifyingMenuFocus else { return }
        isNotifyingMenuFocus = true
        defer { isNotifyingMenuFocus = false }
        MenuFocusState.shared.noteWindowFocusChanged()
    }
}
