//
//  SwipeGestureManager.swift
//  shell
//
//  The horizontal-swipe bindings for the terminal: swipe left for the next
//  tab, swipe right for the previous one. Single source of truth for both the
//  iOS direct-touch swipe gestures and the Mac Catalyst trackpad swipe pan
//  gesture, so the two platforms resolve a swipe identically.
//
//  The bindings are fixed. They were briefly persisted under the
//  `swipeGestureBindings` setting, but no build ever shipped an editor or any
//  other writer for that key, so it could only ever read back the defaults it
//  was seeded with. The persistence was removed rather than given an editor.
//

import Foundation

@MainActor
final class SwipeGestureManager {
    static let shared = SwipeGestureManager()

    // MARK: - Bindings

    let leftBinding: SwipeGestureBinding = .preset(.nextTab)
    let rightBinding: SwipeGestureBinding = .preset(.previousTab)

    private init() {}

    // MARK: - Public API

    func binding(for direction: SwipeDirection) -> SwipeGestureBinding {
        switch direction {
        case .left: return leftBinding
        case .right: return rightBinding
        }
    }
}
