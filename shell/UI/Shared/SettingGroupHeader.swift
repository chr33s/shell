//
//  SettingGroupHeader.swift
//  shell
//
//  Section header carrying the group's pin tag and a menu for pinning the
//  whole group. SwiftUI section headers have no context menu, so the menu
//  button is the entry point there; screens without headers use the
//  toolbar variant.
//

import SwiftUI

struct SettingGroupHeader: View {
    let title: LocalizedStringKey
    let group: SettingGroup
    @State private var syncManager = CloudKitSyncManager.shared

    init(_ title: LocalizedStringKey, group: SettingGroup) {
        self.title = title
        self.group = group
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            SettingPinTag(group: group)
            Spacer()
            if syncManager.isAppSettingsSyncEnabled, SettingGroupPinActions.hasActions(for: group) {
                Menu {
                    SettingGroupPinActions(group: group)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
                .textCase(nil)
                .accessibilityLabel(Text(String(localized: "Pin options for \(group.title)", comment: "Group header menu accessibility label")))
            }
        }
    }
}

/// Toolbar menu for sub-screens that map to one or more groups and have no section headers.
struct SettingsScreenPinMenu: ToolbarContent {
    let groups: [SettingGroup]
    @State private var syncManager = CloudKitSyncManager.shared

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if syncManager.isAppSettingsSyncEnabled, groups.contains(where: { SettingGroupPinActions.hasActions(for: $0) }) {
                Menu {
                    ForEach(groups, id: \.self) { group in
                        if groups.count > 1 {
                            Section(group.title) { SettingGroupPinActions(group: group) }
                        } else {
                            SettingGroupPinActions(group: group)
                        }
                    }
                } label: {
                    Image(systemName: "pin.circle")
                }
            }
        }
    }
}
