//
//  TabTitleLine.swift
//  shell
//
//  One-line tab identity: roam/tmux badges, optional attention dot, title,
//  optional ⌘N hint. Shared by the hidden-tab-bar indicator HUD and the tab
//  exposé captions so both render a tab the same way.
//

import SwiftUI

struct TabTitleLine: View {
    let tab: TabModel
    let allTabs: [TabModel]
    let tmuxBadgePalette: TmuxTabBadgePalette
    var keyboardShortcut: String?
    var titleFont: Font = .system(size: 16, weight: .semibold)
    var shortcutFont: Font = .system(size: 14, weight: .medium)
    var textColor: Color = .white
    var showsBadges = true

    var body: some View {
        HStack(spacing: 8) {
            if showsBadges {
                if let tmuxBadge = TmuxTabBadgeResolver.badge(for: tab, allTabs: allTabs) {
                    TmuxTabBadgeView(badge: tmuxBadge, palette: tmuxBadgePalette)
                }

            }

            Text(tab.title)
                .font(titleFont)
                .foregroundColor(textColor)
                .lineLimit(1)

            if let keyboardShortcut {
                Text(keyboardShortcut)
                    .font(shortcutFont)
                    .foregroundColor(textColor.opacity(0.7))
            }
        }
    }
}
