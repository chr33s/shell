//
//  TmuxTabCloseAction.swift
//  shell
//
//  What CMD-W / the tab "X" does when closing a tmux control-mode (-CC)
//  window tab. Global preference, surfaced in Settings → Connections →
//  tmux. Default preserves the historical behavior (destroy the
//  tmux window on the server). (id=tmux-tab-close-action)
//

import Foundation

enum TmuxTabCloseAction: String, CaseIterable, Codable, Sendable {
    /// Destroy the tmux window on the server (`kill-window`). Default —
    /// the only behavior before this setting existed.
    case closeWindow

    /// Gracefully detach the whole tmux session for this gateway. Every
    /// window keeps running on the server; the gateway tab returns to its shell.
    case detachSession

    /// Graceful detach, then also close the gateway tab once control mode
    /// tears down — fully leave tmux from the app. Session survives on the server.
    case detachSessionAndCloseGateway

    /// UI-only hide of the tab (the tmux window stays alive on the server).
    case hideTab

    /// Prompt with an action sheet on every close.
    case ask

    static let storageKey = "tmuxTabCloseAction"

    /// The user's current preference, defaulting to `.closeWindow`.
    static var current: TmuxTabCloseAction {
        SettingsStore.shared.value(Settings.Tmux.tabCloseAction)
    }

    var displayName: String {
        switch self {
        case .closeWindow: return "Close tmux Window"
        case .detachSession: return "Detach Session"
        case .detachSessionAndCloseGateway: return "Detach Session & Close Gateway"
        case .hideTab: return "Hide Tab"
        case .ask: return "Ask Each Time"
        }
    }
}
