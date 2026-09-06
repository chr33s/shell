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

    /// Whether each TERM row shows its free-text field, seeded on first render
    /// from whether the stored value is one of `TerminalTypeSettings.presets`
    /// and thereafter following what the user picked. Deriving this from the
    /// value on every keystroke instead would snap the field shut the moment a
    /// half-typed name happened to match a preset.
    @State private var localTypeIsCustom: Bool?
    @State private var remoteTypeIsCustom: Bool?

    private static let scrollbackChoices = [1_000, 5_000, 10_000, 50_000, 100_000]

    /// Picker tag for the "Custom…" row. Contains spaces, which
    /// `TerminalTypeSettings.isValid` rejects, so it can never collide with a
    /// preset or with anything the user is able to store.
    private static let customTerminalTypeTag = "custom terminal type"

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
                terminalTypeRows(
                    title: "Local",
                    defaultValue: TerminalTypeSettings.localFallback,
                    value: $terminalTypeLocal,
                    isCustom: $localTypeIsCustom
                )
                terminalTypeRows(
                    title: "Remote",
                    defaultValue: TerminalTypeSettings.fallback,
                    value: $terminalTypeRemote,
                    isCustom: $remoteTypeIsCustom
                )
            } header: {
                SettingGroupHeader("TERM", group: .terminal)
            } footer: {
                // The Local field is bound to `terminalTypeLocal`, whose registered
                // default is `TerminalTypeSettings.localFallback` — "xterm-ghostty"
                // on Mac Catalyst, where the bundled terminfo makes it resolvable.
                // A single `fallback` sentence claimed "xterm-256color" for both
                // fields there, contradicting what the Local field already shows.
                // Off Catalyst the two are the same value, so keep one sentence.
                #if targetEnvironment(macCatalyst)
                Text("The terminal type advertised to the shell. Local defaults to \(TerminalTypeSettings.localFallback), remote to \(TerminalTypeSettings.fallback).")
                #else
                Text("The terminal type advertised to the shell. Defaults to \(TerminalTypeSettings.fallback).")
                #endif
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

    // MARK: - TERM

    /// One TERM scope: a preset picker with a "Custom…" escape and, while
    /// custom, a free-text field carrying `TerminalTypeSettings.warning(for:)`.
    ///
    /// Both halves were written for this row and had no caller. The plain text
    /// fields this replaces accepted `xterm-256colr` silently: `resolved(_:)`
    /// rejects it and substitutes the default, so the typo cost the user the
    /// terminal type they asked for with nothing said. The picker makes the
    /// four names that actually work one tap away, and the warning names the
    /// two ways a hand-typed value fails.
    @ViewBuilder
    private func terminalTypeRows(
        title: LocalizedStringKey,
        defaultValue: String,
        value: Binding<String>,
        isCustom: Binding<Bool?>
    ) -> some View {
        let trimmed = value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let showsCustomField = isCustom.wrappedValue ?? !TerminalTypeSettings.presets.contains(trimmed)

        Picker(
            title,
            selection: Binding(
                get: { showsCustomField ? Self.customTerminalTypeTag : trimmed },
                set: { selected in
                    if selected == Self.customTerminalTypeTag {
                        // Leave the stored value alone so the field opens on
                        // what is configured rather than blank.
                        isCustom.wrappedValue = true
                    } else {
                        isCustom.wrappedValue = false
                        value.wrappedValue = selected
                    }
                }
            )
        ) {
            ForEach(TerminalTypeSettings.presets(preferring: defaultValue), id: \.self) { preset in
                Text(preset).tag(preset)
            }
            Text("Custom…", comment: "TERM picker option: type a terminfo name by hand")
                .tag(Self.customTerminalTypeTag)
        }
        .themedRow()

        if showsCustomField {
            TextField(defaultValue, text: value)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .themedRow()

            if let warning = TerminalTypeSettings.warning(for: value.wrappedValue) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.appHighlight)
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }
        }
    }
}
