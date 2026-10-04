//
//  SessionTracker.swift
//  shell
//
//  Tracks per-window tab counts and publishes tab-count changes so window
//  chrome can reconfigure.
//

import Observation
import Foundation
import Combine
import os.log

extension Notification.Name {
    /// Posted by TerminalView when its connectionConfig changes due to an embedded session transition
    static let terminalConnectionConfigChanged = Notification.Name("terminalConnectionConfigChanged")
}

/// Global tracker that aggregates tab counts from all windows
@MainActor
@Observable
final class SessionTracker {
    static let shared = SessionTracker()

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SessionTracker")

    /// Total tab counts per window (all terminals including local)
    private var windowTabCounts: [String: Int] = [:]

    /// Tab counts by scene session ID (for WindowAccessor lookups)
    private var sceneTabCounts: [String: Int] = [:]

    /// The scene session each window last reported, so closing the window
    /// also drops its scene count.
    private var sceneIdByWindow: [String: String] = [:]

    /// Publisher that emits when any window's tab count changes
    /// Emits the windowId that changed
    let tabCountDidChange = PassthroughSubject<String, Never>()

    /// Get the tab count for a specific window by windowId
    func tabCount(forWindowId windowId: String) -> Int {
        windowTabCounts[windowId] ?? 0
    }

    /// Get the tab count for a specific window by scene session ID
    func tabCount(forSceneSessionId sceneId: String) -> Int {
        sceneTabCounts[sceneId] ?? 0
    }

    private init() {
        Self.logger.info("SessionTracker initialized")
    }

    func updateTabCount(_ tabCount: Int, windowId: String, sceneSessionId: String?) {
        let oldTabCount = windowTabCounts[windowId] ?? 0
        windowTabCounts[windowId] = tabCount

        // Also store by scene session ID for WindowAccessor lookups
        if let sceneId = sceneSessionId {
            sceneTabCounts[sceneId] = tabCount
            sceneIdByWindow[windowId] = sceneId
        }

        // Notify window-specific tab count change for drag blocker configuration
        if oldTabCount != tabCount {
            Self.logger.info("Window \(windowId) tabs \(oldTabCount)->\(tabCount)")
            tabCountDidChange.send(windowId)
        }
    }

    /// Called when a window is closed to remove its counts
    func removeWindow(_ windowId: String) {
        if let sceneId = sceneIdByWindow.removeValue(forKey: windowId) {
            sceneTabCounts.removeValue(forKey: sceneId)
        }
        guard let removedTabs = windowTabCounts.removeValue(forKey: windowId), removedTabs > 0 else { return }
        Self.logger.info("Window \(windowId) removed (had \(removedTabs) tabs)")
        tabCountDidChange.send(windowId)
    }
}
