//
//  SettingsTmuxSection.swift
//  shell
//
//  tmux settings: default mode, default session name, new-tab action,
//  close-window behavior (spec section 12).
//

import SwiftUI

struct SettingsTmuxSection: View {
    @Setting(Settings.Tmux.defaultMode) private var defaultMode: TmuxMode
    @Setting(Settings.Tmux.defaultSessionName) private var defaultSessionName: String
    @Setting(Settings.Tmux.newTabAction) private var newTabAction: TmuxNewTabAction
    @Setting(Settings.Tmux.tabCloseAction) private var tabCloseAction: TmuxTabCloseAction

    var body: some View {
        List {
            Section {
                Picker("Default Mode", selection: $defaultMode) {
                    ForEach(TmuxMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .themedRow()
            } footer: {
                Text("Control mode runs `tmux -CC`, mapping tmux windows to tabs and panes to splits.")
            }

            Section {
                LabeledContent("Session Name") {
                    TextField("main", text: $defaultSessionName)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .themedRow()
            } footer: {
                Text("Used when a profile does not pin its own session name.")
            }

            // The only writer for `tmuxNewTabAction`. ⌘T branches on
            // `TmuxNewTabAction.current` (MainView+TabManagement), and the
            // "Ask Each Time" confirmation dialog is already wired in
            // MainView+Presentation — without this row neither `.tmuxTab` nor
            // `.ask` was reachable. (id=tmux-new-tab-action)
            Section {
                Picker("New Tab Action", selection: $newTabAction) {
                    ForEach(TmuxNewTabAction.allCases, id: \.self) { action in
                        Label(action.displayName, systemImage: action.iconName).tag(action)
                    }
                }
                .themedRow()
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What ⌘T does while the selected tab is attached to a tmux control-mode session. Outside tmux it always opens a local shell.")
                    Text(newTabAction.detail)
                }
            }

            Section {
                Picker("Closing a Tab", selection: $tabCloseAction) {
                    ForEach(TmuxTabCloseAction.allCases, id: \.self) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Close-Window Behavior", group: .tmux)
            }
        }
        .themedList()
        .navigationTitle("tmux")
        .navigationBarTitleDisplayMode(.inline)
    }
}
