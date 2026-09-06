//
//  TerminalTypeSettings.swift
//
//  The TERM value advertised to local shells and remote hosts.
//

import Foundation

/// Resolves `TERM` for every session type.
///
/// Two independent globals, because the two sides have different terminfo
/// databases. A recent Linux host knows `xterm-ghostty`, but neither iOS nor
/// macOS ships that entry, so a value that works remotely can leave local
/// `vim`/`less` with no terminal capabilities at all. Both default to
/// `xterm-256color`, which every side understands.
///
/// A connection profile may override the remote value via
/// `SSHConfig.terminalType`; see `SSHConfig.effectiveTerminalType`.
///
/// This is deliberately separate from `TerminalIdentity`, which owns
/// `LC_TERMINAL` product identity rather than terminfo identity.
///
/// All members are `nonisolated` since they are read from NIO event loop contexts.
enum TerminalTypeSettings: Sendable {

    /// Used when nothing is configured, and when a configured value is rejected.
    nonisolated static let fallback = "xterm-256color"

    /// Default for the local shell.
    ///
    /// macOS ships a real ncurses that reads `TERMINFO`, and we bundle the
    /// compiled `xterm-ghostty` entry (`Resources/terminfo`), so the local shell
    /// can have full Ghostty capabilities out of the box — the same thing
    /// Ghostty.app does. iOS has no terminfo database at all and its bundled
    /// tools fall back to built-in termcap, so it stays on `xterm-256color`.
    nonisolated static var localFallback: String {
        #if targetEnvironment(macCatalyst)
        return "xterm-ghostty"
        #else
        return fallback
        #endif
    }

    /// Path to the bundled terminfo database, exported as `TERMINFO` so
    /// `xterm-ghostty` resolves. ncurses searches `TERMINFO` first and then
    /// falls through to the system database, so pointing at a directory that
    /// only holds `xterm-ghostty` never breaks lookups of other names.
    nonisolated static var terminfoPath: String? {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("terminfo"),
              FileManager.default.fileExists(atPath: resources.path) else {
            return nil
        }
        return resources.path
    }

    /// Offered in the settings UI. Custom values are still accepted.
    ///
    /// Deliberately excludes `tmux-256color` and `screen-256color`: those
    /// describe the terminal a multiplexer presents to programs *inside* a
    /// pane, and tmux/screen set them themselves from their own
    /// `default-terminal` / `term` option no matter what the outer terminal
    /// advertises. Offering them here would only tell tmux that its client is
    /// a tmux pane, understating what shell can actually render. `xterm` is
    /// the conservative choice, and `vt100` the last resort for old hosts.
    nonisolated static let presets = [
        "xterm-256color",
        "xterm-ghostty",
        "xterm",
        "vt100"
    ]

    /// `presets` with a scope's default moved to the front.
    ///
    /// The local and remote scopes have different defaults on macOS, so a
    /// single fixed order would put the local default in the middle of its own
    /// list for no visible reason.
    nonisolated static func presets(preferring defaultValue: String) -> [String] {
        guard let index = presets.firstIndex(of: defaultValue) else {
            // A default that isn't a preset shouldn't happen, but leading with
            // it keeps the list honest rather than hiding it.
            return [defaultValue] + presets
        }
        var ordered = presets
        ordered.remove(at: index)
        return [defaultValue] + ordered
    }

    // MARK: - Resolved Values

    /// `TERM` for the local shell: ios_system, the Catalyst process
    /// environment, and helper-spawned PTYs.
    nonisolated static var local: String {
        resolved(SettingsStore.shared.value(Settings.Terminal.terminalTypeLocal), fallingBackTo: localFallback)
    }

    /// Default `TERM` for remote sessions, absent a per-connection override.
    nonisolated static var remote: String {
        resolved(SettingsStore.shared.value(Settings.Terminal.terminalTypeRemote))
    }

    /// What a stored value actually resolves to. Trims, validates, and falls
    /// back rather than ever returning something unsafe to interpolate or
    /// meaningless to terminfo. Settings UI uses this so the summary shows what
    /// will really be sent, not what was typed.
    nonisolated static func resolved(_ raw: String?, fallingBackTo defaultValue: String = fallback) -> String {
        guard let raw else { return defaultValue }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValid(trimmed) ? trimmed : defaultValue
    }

    /// A per-connection override, falling back to the global remote default.
    nonisolated static func resolveRemote(_ override: String?) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return remote }
        return resolved(trimmed)
    }

    // MARK: - Validation

    /// Whether a value is a well-formed terminfo name.
    ///
    /// Terminfo names are drawn from `[A-Za-z0-9._+-]`. Enforcing that is not
    /// cosmetic: the mosh path interpolates this value into a shell command
    /// sent over SSH (`MoshConfig.serverCommand`), so it must never be able to
    /// carry shell metacharacters.
    nonisolated static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        return trimmed.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || "._+-".contains(char))
        }
    }

    /// Warning to surface under a custom value, or nil when it looks fine.
    nonisolated static func warning(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Empty, so the default will be used.",
                          comment: "Terminal type warning: no value entered")
        }
        if !isValid(trimmed) {
            return String(localized: "Not a valid terminfo name. Use letters, digits, and . _ + - only.",
                          comment: "Terminal type warning: illegal characters")
        }
        return nil
    }
}
