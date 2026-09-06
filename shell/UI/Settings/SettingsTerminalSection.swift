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
                .onChange(of: scrollbackLimit) { _, _ in
                    // A local write does not reach SettingsRefreshHub (it skips
                    // `.local` origins), so rewrite and push the Ghostty config here.
                    Ghostty.App.shared?.reloadGlobalConfig()
                }
            } header: {
                SettingGroupHeader("Scrollback", group: .scrollback)
            } footer: {
                Text("Lines of history kept per terminal. Applies to terminals opened from now on; open terminals keep their current history.")
            }

            // MARK: - Session
            Section {
                SettingToggle(
                    Settings.SessionRestore.sessionPersistence,
                    title: "Restore Sessions on Launch"
                )
                .themedRow()
                SettingToggle(
                    Settings.SessionRestore.scrollbackPersistence,
                    title: "Persist Scrollback History"
                ) { newValue in
                    if !newValue {
                        ScrollbackPersistenceManager.shared.removeAllScrollbackFiles()
                    }
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Session", group: .sessionRestore)
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
                SettingToggle(
                    Settings.Keyboard.forceASCIIKeyboard,
                    title: "Force ASCII Keyboard"
                )
                .themedRow()
            } header: {
                SettingGroupHeader("Keyboard", group: .keyboard)
            } footer: {
                Text("Restricts the software keyboard to ASCII input, hiding emoji and other non-ASCII input modes. Open terminals switch immediately.")
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
