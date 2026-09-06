//
//  WindowSessionCensus.swift
//  shell
//
//  Pure, per-window census of terminal sessions, extracted from
//  MainViewLifecycle. Stateless value computation over the tab tree; the
//  single impure edge is `publish`, which forwards the remote, non-resilient
//  and tab counts to SessionTracker.
//

import SwiftUI

/// Per-window session census. MainActor by the project's default isolation
/// (inputs are MainActor-bound view models); no stored state.
enum WindowSessionCensus {

    /// Count remote sessions in this window.
    static func remoteSessionCount(in tabs: [TabModel]) -> Int {
        tabs.flatMap { $0.splitTree.terminalLeaves }.filter { terminal in
            switch terminal.connectionConfig {
            case .ssh, .shellLaunchedSSH:
                return true
            case .local:
                return false
            }
        }.count
    }

    /// Count sessions that require background execution: remote sessions and
    /// local shells with an active long-running task.
    static func nonResilientSessionCount(in tabs: [TabModel]) -> Int {
        tabs.flatMap { $0.splitTree.terminalLeaves }.filter { terminal in
            switch terminal.connectionConfig {
            case .ssh, .shellLaunchedSSH:
                return true
            case .local:
                return terminal.hasActiveLocalTask
            }
        }.count
    }

    /// Count total tabs (including splits) in this window.
    static func totalTabCount(in tabs: [TabModel]) -> Int {
        tabs.count
    }

    /// Measure the window's sessions and forward the counts to SessionTracker.
    static func publish(tabs: [TabModel], windowId: String, sceneSessionId: String?) {
        let remoteCount = remoteSessionCount(in: tabs)
        let nonResilientCount = nonResilientSessionCount(in: tabs)
        let tabCount = totalTabCount(in: tabs)

        SessionTracker.shared.updateWindowCounts(
            remoteCount: remoteCount,
            nonResilientCount: nonResilientCount,
            tabCount: tabCount,
            windowId: windowId,
            sceneSessionId: sceneSessionId
        )
    }
}
