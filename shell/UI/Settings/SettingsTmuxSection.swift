//
//  SettingsTmuxSection.swift
//  shell
//
//  tmux settings: default mode, default session name, close-window behavior
//  (spec section 12).
//

import SwiftUI

struct SettingsTmuxSection: View {
    @Setting(Settings.Tmux.defaultMode) private var defaultMode: TmuxMode
    @Setting(Settings.Tmux.defaultSessionName) private var defaultSessionName: String
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
