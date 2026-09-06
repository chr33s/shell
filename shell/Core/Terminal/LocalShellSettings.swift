//
//  LocalShellSettings.swift
//
//  The command launched for local shell tabs.
//

import Foundation

/// Resolves the shell command for local sessions.
///
/// A configured value is a whole command line, not just a path: the helper
/// interpolates it into `exec -l <value>` inside `bash -c`, so bash parses the
/// arguments and quoting. Unset means the helper falls back to the passwd login
/// shell, which is what `CreateShellRequest.shell == nil` already means.
///
/// Bash and Zsh are the shells this fork supports: they are the only ones with
/// bundled shell integration (`Resources/shell-integration`), so they are the
/// only ones that report the working directory and mark prompts. Any other
/// absolute executable still launches — validation checks syntax and
/// executability, not shell identity — it simply runs without integration.
///
/// Catalyst only; iOS local shells run the in-app interpreter and spawn nothing.
///
/// All members are `nonisolated` since session setup reads them off the main actor.
enum LocalShellSettings: Sendable {

    nonisolated static let fallbackCommand = "/bin/zsh -f"

    /// nil means "use the login shell".
    nonisolated static var command: String? {
        resolved(SettingsStore.shared.value(Settings.Terminal.localShellCommand))
    }

    /// What a stored value actually launches. Empty means the account login
    /// shell; invalid input uses a clean macOS zsh instead of killing the tab.
    nonisolated static func resolved(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return isValid(trimmed) ? trimmed : fallbackCommand
    }

    /// Settings row summary: what will really be launched.
    nonisolated static var summary: String {
        command ?? String(localized: "Login Shell",
                          comment: "Local shell setting: use the login shell from the passwd database")
    }

    // MARK: - Validation

    private nonisolated enum ValidationFailure {
        case illegalCharacters
        case unbalancedQuote
        case relativeExecutable
        case unavailableExecutable
    }

    /// A shell command must have safe shell syntax and begin with an absolute,
    /// executable file. Arguments and quoting remain supported.
    nonisolated static func isValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && validationFailure(in: trimmed) == nil
    }

    /// Warning to surface under a custom value, or nil when it looks fine.
    /// Invalid values remain visible for editing but launch clean macOS zsh.
    nonisolated static func warning(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Empty, so the login shell will be used.",
                          comment: "Local shell warning: no value entered")
        }
        switch validationFailure(in: trimmed) {
        case .illegalCharacters:
            return String(localized: "Too long or contains a control character. Clean macOS zsh will be used.",
                          comment: "Local shell warning: illegal characters use fallback")
        case .unbalancedQuote:
            return String(localized: "Contains an unbalanced quote. Clean macOS zsh will be used.",
                          comment: "Local shell warning: malformed quoting uses fallback")
        case .relativeExecutable:
            return String(localized: "The executable path must be absolute. Clean macOS zsh will be used.",
                          comment: "Local shell warning: relative command uses fallback")
        case .unavailableExecutable:
            return String(localized: "Nothing executable exists at that path. Clean macOS zsh will be used.",
                          comment: "Local shell warning: unavailable binary uses fallback")
        case nil:
            return nil
        }
    }

    private nonisolated static func validationFailure(in command: String) -> ValidationFailure? {
        guard command.count <= 1024,
              !command.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return .illegalCharacters }

        guard shellQuotesAreBalanced(command),
              let executable = executablePath(in: command)
        else { return .unbalancedQuote }

        guard executable.hasPrefix("/") else { return .relativeExecutable }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: executable)
        else { return .unavailableExecutable }

        return nil
    }

    /// Reject syntax that would prevent bash from reaching its zsh fallback.
    private nonisolated static func shellQuotesAreBalanced(_ command: String) -> Bool {
        var quote: Character?
        var escaped = false

        for character in command {
            if escaped {
                escaped = false
                continue
            }
            if quote == "'" {
                if character == "'" { quote = nil }
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            }
        }

        return quote == nil && !escaped
    }

    /// The executable from a command line, honouring a leading quoted path.
    /// Returns nil when a leading quote is never closed.
    nonisolated static func executablePath(in command: String) -> String? {
        var rest = Substring(command)
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { return nil }
            return String(rest[..<end])
        }
        return rest.split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    // MARK: - Ghostty Config

    /// The `command = ...` line written into the generated ghostty config.
    ///
    /// A configured command is used verbatim: `-l` cannot be appended to a
    /// command line that already carries its own arguments.
    nonisolated static var ghosttyConfigCommand: String {
        let raw = SettingsStore.shared.value(Settings.Terminal.localShellCommand)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return isValid(trimmed) ? trimmed : "\(fallbackCommand) -l"
        }

        if let shellEnv = getenv("SHELL"), let path = String(validatingUTF8: shellEnv) {
            if isValid(path) { return "\(path) -l" }
        }
        return "\(fallbackCommand) -l"
    }
}
