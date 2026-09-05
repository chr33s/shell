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

    private init() {}

    func update(sceneSessionId: String, isKey: Bool) {
        guard !sceneSessionId.isEmpty else { return }
        keyStateBySceneId[sceneSessionId] = isKey
        if isKey {
            lastKeySceneId = sceneSessionId
        } else if lastKeySceneId == sceneSessionId {
            lastKeySceneId = keyStateBySceneId.first(where: { $0.value })?.key
        }
    }

    func remove(sceneSessionId: String) {
        guard !sceneSessionId.isEmpty else { return }
        keyStateBySceneId.removeValue(forKey: sceneSessionId)
        if lastKeySceneId == sceneSessionId {
            lastKeySceneId = keyStateBySceneId.first(where: { $0.value })?.key
        }
    }

    func activeSceneSessionId() -> String? {
        if let lastKeySceneId, keyStateBySceneId[lastKeySceneId] == true {
            return lastKeySceneId
        }
        return keyStateBySceneId.first(where: { $0.value })?.key
    }
}
