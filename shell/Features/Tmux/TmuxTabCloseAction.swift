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

    /// Longer explanation shown beneath the title in the picker list.
    var detail: String {
        switch self {
        case .closeWindow:
            return "Destroy the tmux window on the server. Anything running in it is terminated."
        case .detachSession:
            return "Leave the whole tmux session running on the server and return the gateway tab to its shell."
        case .detachSessionAndCloseGateway:
            return "Detach the session (it keeps running on the server), then also close the gateway tab."
        case .hideTab:
            return "Hide the tab locally. The tmux window keeps running and can be shown again later."
        case .ask:
            return "Prompt with these choices every time you close a tmux control-mode tab."
        }
    }

    var iconName: String {
        switch self {
        case .closeWindow: return "xmark.rectangle"
        case .detachSession: return "eject"
        case .detachSessionAndCloseGateway: return "eject.fill"
        case .hideTab: return "eye.slash"
        case .ask: return "questionmark.circle"
        }
    }
}
