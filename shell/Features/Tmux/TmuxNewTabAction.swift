//
//  TmuxNewTabAction.swift
//  shell
//
//  What ⌘T (the "new local shell" command) does WHILE attached to a tmux
//  control-mode (-CC) session. Outside tmux, ⌘T always opens a local shell;
//  this setting only changes behavior when the selected tab is a live tmux
//  context. Global preference, surfaced in Settings → Connections →
//  Multiplexers. Default preserves the historical behavior (local shell).
//  (id=tmux-new-tab-action)
//

import Foundation

enum TmuxNewTabAction: String, CaseIterable, Codable, Sendable {
    /// Always open a local shell tab, even inside a tmux session. Default —
    /// the only behavior before this setting existed.
    case localShell

    /// While attached to a tmux session, open a new window in that session
    /// (the equivalent of "New tmux Tab") instead of a local shell.
    case tmuxTab

    /// While attached to a tmux session, prompt: local shell vs new tmux window.
    case ask

    static let storageKey = "tmuxNewTabAction"

    /// The user's current preference, defaulting to `.localShell`.
    static var current: TmuxNewTabAction {
        SettingsStore.shared.value(Settings.Tmux.newTabAction)
    }

    var displayName: String {
        switch self {
        case .localShell: return "Local Shell"
        case .tmuxTab: return "New tmux Tab"
        case .ask: return "Ask Each Time"
        }
    }

    /// Longer explanation shown beneath the title in the picker list.
    var detail: String {
        switch self {
        case .localShell:
            return "Open a local shell tab, even while attached to a tmux session."
        case .tmuxTab:
            return "While attached to a tmux session, open a new window in that session instead of a local shell."
        case .ask:
            return "While attached to a tmux session, ask whether to open a local shell or a new tmux window."
        }
    }

    var iconName: String {
        switch self {
        case .localShell: return "terminal"
        case .tmuxTab: return "plus.rectangle.on.rectangle"
        case .ask: return "questionmark.circle"
        }
    }
}
