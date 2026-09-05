//
//  SettingsTerminalSection.swift
//  shell
//
//  Terminal settings: font size, theme, scrollback, TERM, keyboard shortcuts.
//

import SwiftUI

struct SettingsTerminalSection: View {
    @Setting(Settings.Font.size) private var fontSize: Double
    @Setting(Settings.Theme.selected) private var themeName: String
    @Setting(Settings.Terminal.scrollbackLimit) private var scrollbackLimit: Int
    @Setting(Settings.Terminal.terminalTypeLocal) private var terminalTypeLocal: String
    @Setting(Settings.Terminal.terminalTypeRemote) private var terminalTypeRemote: String

    @State private var themeManager = ThemeManager.shared

    private static let scrollbackChoices = [1_000, 5_000, 10_000, 50_000, 100_000]

    var body: some View {
        List {
            Section {
                Stepper(value: $fontSize, in: 8...32, step: 1) {
                    LabeledContent("Font Size", value: fontSize, format: .number.precision(.fractionLength(0)))
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Font", group: .font)
            }

            Section {
                Picker("Theme", selection: $themeName) {
                    ForEach(themeManager.availableThemes, id: \.name) { theme in
                        Text(theme.displayName).tag(theme.name)
                    }
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Theme", group: .theme)
            } footer: {
                Text("Shell ships one default theme; any theme file present in the bundle can be selected here.")
            }

            Section {
                Picker("Scrollback Lines", selection: $scrollbackLimit) {
                    ForEach(Self.scrollbackChoices, id: \.self) { limit in
                        Text(limit, format: .number).tag(limit)
                    }
                }
                .themedRow()
                SettingToggle(
                    Settings.SessionRestore.scrollbackPersistence,
                    title: "Persist Scrollback History"
                )
                .themedRow()
            } header: {
                SettingGroupHeader("Scrollback", group: .scrollback)
            }

            Section {
                LabeledContent("Local") {
                    TextField("TERM", text: $terminalTypeLocal)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .themedRow()
                LabeledContent("Remote") {
                    TextField("TERM", text: $terminalTypeRemote)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("TERM", group: .terminal)
            } footer: {
                Text("The terminal type advertised to the shell. Defaults to \(TerminalTypeSettings.fallback).")
            }

            Section {
                NavigationLink {
                    KeyboardShortcutsSettingsView()
                } label: {
                    Label("Keyboard Shortcuts", systemImage: "command")
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await themeManager.ensureThemesLoaded()
        }
    }
}
