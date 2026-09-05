//
//  SessionTracker.swift
//  shell
//
//  Tracks session counts across all windows:
//  - Remote sessions (SSH) for background keepalive accounting
//  - Total tabs for quit confirmation on Mac Catalyst
//

import Foundation
import Combine
import os.log

/// Notification posted by MainView when session counts change in a window
extension Notification.Name {
    static let sessionCountChanged = Notification.Name("sessionCountChanged")

    // Legacy name for compatibility
    static let remoteSessionCountChanged = Notification.Name("sessionCountChanged")

    /// Posted by TerminalView when its connectionConfig changes due to an embedded session transition
    static let terminalConnectionConfigChanged = Notification.Name("terminalConnectionConfigChanged")

    /// Posted by BackgroundTunnelManager when the count of active tunnels changes
    static let backgroundTunnelCountChanged = Notification.Name("backgroundTunnelCountChanged")
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

    /// Running background tunnel count (from BackgroundTunnelManager)
    private var backgroundTunnelCount: Int = 0

    /// Per-profile counts from background tunnels
    private var tunnelProfileCounts: [UUID: Int] = [:]

    /// Total tab counts per window (all terminals including local)
    private var windowTabCounts: [String: Int] = [:]

    /// Tab counts by scene session ID (for WindowAccessor lookups)
    private var sceneTabCounts: [String: Int] = [:]

    /// Total remote sessions across all windows
    @Published private(set) var totalRemoteSessionCount: Int = 0

    /// Total non-resilient sessions across all windows
    /// Includes SSH, K8s, Console, and local shells with active long-running tasks
    /// Excludes Roam/Mosh which survives network changes via UDP state-sync
    @Published private(set) var totalNonResilientSessionCount: Int = 0

    /// Total tabs across all windows
    @Published private(set) var totalTabCount: Int = 0

    /// Active session counts per profile ID (aggregated across all windows)
    @Published private(set) var profileSessionCounts: [UUID: Int] = [:]

    /// Per-window profile counts for aggregation
    private var windowProfileCounts: [String: [UUID: Int]] = [:]

    /// Per-window per-type session breakdown. Aggregated across all windows
    /// before being aggregated so the cached per-type
    /// counts reflect the real state, not just whichever window most
    /// recently fired notifySessionCountChanged. Without this aggregation,
    /// closing a window left the cache pointing at stale
    /// counts for the removed window's last update, which broke both
    /// end-on-empty (single SSH window close stayed visible) and
    /// stay-on-roam (TSSH-only filter showed wrong totals).
    private var windowSessionDetails: [String: WindowSessionDetails] = [:]

    struct WindowSessionDetails: Equatable {
        var sshCount: Int = 0
        var k8sCount: Int = 0
        var consoleCount: Int = 0
        var localTaskCount: Int = 0
        var roamCount: Int = 0
        var hostNames: [String] = []
        var roamHostNames: [String] = []
    }

    private func aggregatedSessionDetails() -> WindowSessionDetails {
        var agg = WindowSessionDetails()
        for d in windowSessionDetails.values {
            agg.sshCount += d.sshCount
            agg.k8sCount += d.k8sCount
            agg.consoleCount += d.consoleCount
            agg.localTaskCount += d.localTaskCount
            agg.roamCount += d.roamCount
            for h in d.hostNames where !agg.hostNames.contains(h) {
                agg.hostNames.append(h)
            }
            for h in d.roamHostNames where !agg.roamHostNames.contains(h) {
                agg.roamHostNames.append(h)
            }
        }
        return agg
    }

    /// Publisher that emits when any window's tab count changes
    /// Emits the windowId that changed
    let tabCountDidChange = PassthroughSubject<String, Never>()

    /// Whether there are any open tabs (for quit confirmation)
    var hasOpenTabs: Bool { totalTabCount > 0 }

    /// Get the tab count for a specific window by windowId
    func tabCount(forWindowId windowId: String) -> Int {
        windowTabCounts[windowId] ?? 0
    }

    /// Get the tab count for a specific window by scene session ID
    func tabCount(forSceneSessionId sceneId: String) -> Int {
        sceneTabCounts[sceneId] ?? 0
    }

    private init() {
        Self.logger.info("SessionTracker init starting")

        // Subscribe to session count change notifications
        NotificationCenter.default.addObserver(
            forName: .sessionCountChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract Sendable values before entering Task to avoid capturing Notification
            guard let self,
                  let windowId = notification.userInfo?["windowId"] as? String else {
                Self.logger.warning("Notification received but failed to extract windowId")
                return
            }

            let remoteCount = notification.userInfo?["remoteCount"] as? Int ?? 0
            let nonResilientCount = notification.userInfo?["nonResilientCount"] as? Int ?? 0
            let tabCount = notification.userInfo?["tabCount"] as? Int ?? 0
            let sceneSessionId = notification.userInfo?["sceneSessionId"] as? String
            let sshCount = notification.userInfo?["sshCount"] as? Int ?? 0
            let k8sCount = notification.userInfo?["k8sCount"] as? Int ?? 0
            let consoleCount = notification.userInfo?["consoleCount"] as? Int ?? 0
            let hostNames = notification.userInfo?["hostNames"] as? [String] ?? []
            let localTaskCount = notification.userInfo?["localTaskCount"] as? Int ?? 0
            let roamCount = notification.userInfo?["roamCount"] as? Int ?? 0
            let roamHostNames = notification.userInfo?["roamHostNames"] as? [String] ?? []
            let profileCounts = notification.userInfo?["profileCounts"] as? [UUID: Int] ?? [:]

            Self.logger.info("Notification received: window \(windowId), remote=\(remoteCount), nonResilient=\(nonResilientCount), tabs=\(tabCount), sceneId=\(sceneSessionId ?? "nil")")
            Task { @MainActor [self] in
                self.updateWindowCounts(
                    remoteCount: remoteCount,
                    nonResilientCount: nonResilientCount,
                    tabCount: tabCount,
                    windowId: windowId,
                    sceneSessionId: sceneSessionId,
                    sshCount: sshCount,
                    k8sCount: k8sCount,
                    consoleCount: consoleCount,
                    hostNames: hostNames,
                    localTaskCount: localTaskCount,
                    roamCount: roamCount,
                    roamHostNames: roamHostNames,
                    profileCounts: profileCounts
                )
            }
        }

        // Subscribe to background tunnel count changes
        NotificationCenter.default.addObserver(
            forName: .backgroundTunnelCountChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let tunnelCount = notification.userInfo?["runningCount"] as? Int ?? 0
            let tunnelProfileCounts = notification.userInfo?["profileCounts"] as? [UUID: Int] ?? [:]
            Task { @MainActor [self] in
                self.handleBackgroundTunnelCountChanged(tunnelCount, profileCounts: tunnelProfileCounts)
            }
        }

        Self.logger.info("SessionTracker initialized, observer registered")
    }

    func updateWindowCounts(
        remoteCount: Int,
        nonResilientCount: Int,
        tabCount: Int,
        windowId: String,
        sceneSessionId: String?,
        sshCount: Int = 0,
        k8sCount: Int = 0,
        consoleCount: Int = 0,
        hostNames: [String] = [],
        localTaskCount: Int = 0,
        roamCount: Int = 0,
        roamHostNames: [String] = [],
        profileCounts: [UUID: Int] = [:]
    ) {
        handleCountChanged(
            remoteCount: remoteCount,
            nonResilientCount: nonResilientCount,
            tabCount: tabCount,
            windowId: windowId,
            sceneSessionId: sceneSessionId,
            sshCount: sshCount,
            k8sCount: k8sCount,
            consoleCount: consoleCount,
            hostNames: hostNames,
            localTaskCount: localTaskCount,
            roamCount: roamCount,
            roamHostNames: roamHostNames,
            profileCounts: profileCounts
        )
    }

    private func handleCountChanged(remoteCount: Int, nonResilientCount: Int, tabCount: Int, windowId: String, sceneSessionId: String?, sshCount: Int = 0, k8sCount: Int = 0, consoleCount: Int = 0, hostNames: [String] = [], localTaskCount: Int = 0, roamCount: Int = 0, roamHostNames: [String] = [], profileCounts: [UUID: Int] = [:]) {
        // Update profile session counts
        windowProfileCounts[windowId] = profileCounts
        rebuildProfileSessionCounts()

        // Update remote session counts
        let oldRemoteCount = windowRemoteCounts[windowId] ?? 0
        windowRemoteCounts[windowId] = remoteCount
        let newRemoteTotal = windowRemoteCounts.values.reduce(0, +)
        let oldRemoteTotal = totalRemoteSessionCount

        // Update non-resilient session counts (SSH, K8s, Console - excludes Roam)
        // Include background tunnel count in the total so LocationDiary stays active for tunnels
        let oldNonResilientCount = windowNonResilientCounts[windowId] ?? 0
        windowNonResilientCounts[windowId] = nonResilientCount
        let newWindowNonResilientTotal = windowNonResilientCounts.values.reduce(0, +)
        let newNonResilientTotal = newWindowNonResilientTotal + backgroundTunnelCount
        let oldNonResilientTotal = totalNonResilientSessionCount

        // Update tab counts by windowId
        let oldTabCount = windowTabCounts[windowId] ?? 0
        windowTabCounts[windowId] = tabCount
        let newTabTotal = windowTabCounts.values.reduce(0, +)
        let oldTabTotal = totalTabCount

        // Also store by scene session ID for WindowAccessor lookups
        if let sceneId = sceneSessionId {
            sceneTabCounts[sceneId] = tabCount
        }

        Self.logger.info("handleCountChanged: window \(windowId), remote \(oldRemoteCount)->\(remoteCount) (total \(oldRemoteTotal)->\(newRemoteTotal)), nonResilient \(oldNonResilientCount)->\(nonResilientCount) (total \(oldNonResilientTotal)->\(newNonResilientTotal)), tabs \(oldTabCount)->\(tabCount) (total \(oldTabTotal)->\(newTabTotal))")

        // Notify window-specific tab count change for drag blocker configuration
        if oldTabCount != tabCount {
            tabCountDidChange.send(windowId)
        }

        // Update remote session count (for general tracking)
        if newRemoteTotal != oldRemoteTotal {
            totalRemoteSessionCount = newRemoteTotal
        }

        // Update the non-resilient session count
        // Only non-resilient sessions (SSH, K8s, Console) need location services
        // Roam/Mosh uses UDP state-sync that survives network changes
        if newNonResilientTotal != oldNonResilientTotal {
            totalNonResilientSessionCount = newNonResilientTotal

            // Window-only count, excluding tunnels:
            // tunnels do not drive Live Activity (no widget UI for them).
            // updateSessionDetails below is the authoritative start path.
        }

        // Store this window's per-type breakdown then push aggregates so
        // the per-type cache reflects all windows, not
        // just whichever window most recently fired notifySessionCountChanged.
        windowSessionDetails[windowId] = WindowSessionDetails(
            sshCount: sshCount, k8sCount: k8sCount, consoleCount: consoleCount,
            localTaskCount: localTaskCount, roamCount: roamCount,
            hostNames: hostNames, roamHostNames: roamHostNames
        )


        // Update tab count and notify for drag blocker configuration
        if newTabTotal != oldTabTotal {
            totalTabCount = newTabTotal
            tabCountDidChange.send(windowId)
        }
    }

    /// Called when a window is closed to remove its counts
    func removeWindow(_ windowId: String) {
        let removedRemote = windowRemoteCounts.removeValue(forKey: windowId) ?? 0
        let removedNonResilient = windowNonResilientCounts.removeValue(forKey: windowId) ?? 0
        let removedTabs = windowTabCounts.removeValue(forKey: windowId) ?? 0
        let hadProfileCounts = windowProfileCounts.removeValue(forKey: windowId) != nil
        _ = windowSessionDetails.removeValue(forKey: windowId)

        if hadProfileCounts {
            rebuildProfileSessionCounts()
        }

        // Push fresh aggregates whenever this window
        // had any per-type details. This is the path that was previously
        // missing — without it, closing a TSSH-only or local-task-only
        // window left the per-type cache showing the
        // closed window's last counts, so the activity stayed visible
        // even with no remaining sessions. Routing through
        // updateSessionDetails (which calls reconcileActivityLifecycle)
        // also lets the activity end correctly for the SSH-only single-
        // window close case via the standard reconcile path.

        guard removedRemote > 0 || removedNonResilient > 0 || removedTabs > 0 else { return }

        let newRemoteTotal = windowRemoteCounts.values.reduce(0, +)
        let newWindowNonResilientTotal = windowNonResilientCounts.values.reduce(0, +)
        let newNonResilientTotal = newWindowNonResilientTotal + backgroundTunnelCount
        let newTabTotal = windowTabCounts.values.reduce(0, +)

        Self.logger.info("Window \(windowId) removed (had \(removedRemote) remote, \(removedNonResilient) nonResilient, \(removedTabs) tabs), totals now remote=\(newRemoteTotal), nonResilient=\(newNonResilientTotal), tabs=\(newTabTotal)")

        if removedRemote > 0 {
            totalRemoteSessionCount = newRemoteTotal
        }

        if removedNonResilient > 0 {
            totalNonResilientSessionCount = newNonResilientTotal

            // Window-only count, excluding tunnels:
            // tunnels deliberately do not drive Live Activity (no widget UI for
            // them). Without this, closing the last session window while a
            // tunnel is still running would leave a stale activity visible
            // because the combined total stays > 0.
        }

        if removedTabs > 0 {
            totalTabCount = newTabTotal
            tabCountDidChange.send(windowId)
        }
    }
    // MARK: - Background Tunnel Integration

    /// Handle background tunnel count changes and include in non-resilient total.
    ///
    /// Tunnels count toward background keepalive but
    /// are not surfaced anywhere else: the
    /// SessionActivityAttributes ContentState has no tunnel field and the
    /// widget renders no tunnel UI, so a tunnel-only signal can't produce a
    /// visible activity. Window-backed sessions and VPN are the things that
    /// drive Live Activity start/end via updateSessionDetails / updateVPNState.
    private func handleBackgroundTunnelCountChanged(_ tunnelCount: Int, profileCounts: [UUID: Int]) {
        let oldTunnelCount = backgroundTunnelCount
        backgroundTunnelCount = tunnelCount
        tunnelProfileCounts = profileCounts
        rebuildProfileSessionCounts()

        guard oldTunnelCount != tunnelCount else { return }

        let windowNonResilientTotal = windowNonResilientCounts.values.reduce(0, +)
        let combinedTotal = windowNonResilientTotal + tunnelCount

        Self.logger.info("Background tunnel count \(oldTunnelCount)->\(tunnelCount), combined non-resilient total: \(combinedTotal)")

        totalNonResilientSessionCount = combinedTotal
    }

    /// Rebuild aggregated profile session counts from window and tunnel sources
    private func rebuildProfileSessionCounts() {
        var aggregated: [UUID: Int] = [:]
        for counts in windowProfileCounts.values {
            for (id, count) in counts {
                aggregated[id, default: 0] += count
            }
        }
        for (id, count) in tunnelProfileCounts {
            aggregated[id, default: 0] += count
        }
        if aggregated != profileSessionCounts {
            profileSessionCounts = aggregated
        }
    }
}

/// Type alias for backwards compatibility
typealias RemoteSessionTracker = SessionTracker
