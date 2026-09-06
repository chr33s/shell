//
//  SessionTracker.swift
//  shell
//
//  Tracks per-window session counts (remote, non-resilient, tabs) and
//  publishes tab-count changes so window chrome can reconfigure.
//

import Foundation
import Combine
import os.log

extension Notification.Name {
    /// Posted by TerminalView when its connectionConfig changes due to an embedded session transition
    static let terminalConnectionConfigChanged = Notification.Name("terminalConnectionConfigChanged")
}

/// Global tracker that aggregates session counts from all windows
@MainActor
class SessionTracker: ObservableObject {
    static let shared = SessionTracker()

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SessionTracker")

    /// Remote session counts per window (SSH, Kubernetes, Console, etc.)
    private var windowRemoteCounts: [String: Int] = [:]

    /// Non-resilient session counts per window (SSH, K8s, Console, active local tasks - excludes Roam/Mosh)
    private var windowNonResilientCounts: [String: Int] = [:]

    /// Total tab counts per window (all terminals including local)
    private var windowTabCounts: [String: Int] = [:]

    /// Tab counts by scene session ID (for WindowAccessor lookups)
    private var sceneTabCounts: [String: Int] = [:]

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

    func updateWindowCounts(
        remoteCount: Int,
        nonResilientCount: Int,
        tabCount: Int,
        windowId: String,
        sceneSessionId: String?,
        sshCount: Int = 0,
        hostNames: [String] = [],
        localTaskCount: Int = 0,
        profileCounts: [UUID: Int] = [:]
    ) {
        handleCountChanged(
            remoteCount: remoteCount,
            nonResilientCount: nonResilientCount,
            tabCount: tabCount,
            windowId: windowId,
            sceneSessionId: sceneSessionId
        )
    }

    private func handleCountChanged(remoteCount: Int, nonResilientCount: Int, tabCount: Int, windowId: String, sceneSessionId: String?) {
        // Update remote session counts
        let oldRemoteCount = windowRemoteCounts[windowId] ?? 0
        windowRemoteCounts[windowId] = remoteCount
        let newRemoteTotal = windowRemoteCounts.values.reduce(0, +)

        // Update non-resilient session counts (SSH, K8s, Console - excludes Roam)
        let oldNonResilientCount = windowNonResilientCounts[windowId] ?? 0
        windowNonResilientCounts[windowId] = nonResilientCount
        let newNonResilientTotal = windowNonResilientCounts.values.reduce(0, +)

        // Update tab counts by windowId
        let oldTabCount = windowTabCounts[windowId] ?? 0
        windowTabCounts[windowId] = tabCount
        let newTabTotal = windowTabCounts.values.reduce(0, +)

        // Also store by scene session ID for WindowAccessor lookups
        if let sceneId = sceneSessionId {
            sceneTabCounts[sceneId] = tabCount
        }

        Self.logger.info("handleCountChanged: window \(windowId), remote \(oldRemoteCount)->\(remoteCount) (total \(newRemoteTotal)), nonResilient \(oldNonResilientCount)->\(nonResilientCount) (total \(newNonResilientTotal)), tabs \(oldTabCount)->\(tabCount) (total \(newTabTotal))")

        // Notify window-specific tab count change for drag blocker configuration
        if oldTabCount != tabCount {
            tabCountDidChange.send(windowId)
        }
    }

    /// Called when a window is closed to remove its counts
    func removeWindow(_ windowId: String) {
        let removedRemote = windowRemoteCounts.removeValue(forKey: windowId) ?? 0
        let removedNonResilient = windowNonResilientCounts.removeValue(forKey: windowId) ?? 0
        let removedTabs = windowTabCounts.removeValue(forKey: windowId) ?? 0

        guard removedRemote > 0 || removedNonResilient > 0 || removedTabs > 0 else { return }

        let newRemoteTotal = windowRemoteCounts.values.reduce(0, +)
        let newNonResilientTotal = windowNonResilientCounts.values.reduce(0, +)
        let newTabTotal = windowTabCounts.values.reduce(0, +)

        Self.logger.info("Window \(windowId) removed (had \(removedRemote) remote, \(removedNonResilient) nonResilient, \(removedTabs) tabs), totals now remote=\(newRemoteTotal), nonResilient=\(newNonResilientTotal), tabs=\(newTabTotal)")

        if removedTabs > 0 {
            tabCountDidChange.send(windowId)
        }
    }
}

/// Type alias for backwards compatibility
typealias RemoteSessionTracker = SessionTracker
