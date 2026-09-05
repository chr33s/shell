//
//  WindowSessionCensus.swift
//  shell
//
//  Pure, per-window census of terminal sessions, extracted from
//  MainViewLifecycle. Stateless value computation over the tab tree; the
//  single impure edge is `publish`, which forwards the counts to
//  SessionTracker for background-task bookkeeping.
//

import SwiftUI

/// Per-window session census. MainActor by the project's default isolation
/// (inputs are MainActor-bound view models); no stored state.
enum WindowSessionCensus {

    /// Per-type counts and host names for all session types.
    struct Details {
        var sshCount: Int
        var hostNames: [String]
        var localTaskCount: Int
        var profileCounts: [UUID: Int]
    }

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

    /// Gather per-type counts and host names for all session types.
    static func details(in tabs: [TabModel]) -> Details {
        var sshCount = 0
        var hostNames: [String] = []
        var localTaskCount = 0
        var profileCounts: [UUID: Int] = [:]

        for terminal in tabs.flatMap({ $0.splitTree.terminalLeaves }) {
            if let profileID = terminal.sourceProfileID {
                profileCounts[profileID, default: 0] += 1
            }

            switch terminal.connectionConfig {
            case .ssh(let config):
                sshCount += 1
                if !hostNames.contains(config.host) {
                    hostNames.append(config.host)
                }
            case .shellLaunchedSSH(let sshConfig, _):
                sshCount += 1
                if !hostNames.contains(sshConfig.host) {
                    hostNames.append(sshConfig.host)
                }
            case .local:
                if terminal.hasActiveLocalTask {
                    localTaskCount += 1
                }
            }
        }

        // hostNames capped at 3 — SessionTracker displays depend on this truncation.
        return Details(
            sshCount: sshCount,
            hostNames: Array(hostNames.prefix(3)),
            localTaskCount: localTaskCount,
            profileCounts: profileCounts
        )
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
        let details = details(in: tabs)

        SessionTracker.shared.updateWindowCounts(
            remoteCount: remoteCount,
            nonResilientCount: nonResilientCount,
            tabCount: tabCount,
            windowId: windowId,
            sceneSessionId: sceneSessionId,
            sshCount: details.sshCount,
            hostNames: details.hostNames,
            localTaskCount: details.localTaskCount,
            profileCounts: details.profileCounts
        )
    }
}
