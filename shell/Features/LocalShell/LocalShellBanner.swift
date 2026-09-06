#if !targetEnvironment(macCatalyst)
//
//  LocalShellBanner.swift
//  shell
//
//  Width-aware, theme-styled welcome banner for the local shell.
//

import Foundation

/// Renders the local shell welcome banner.
///
/// Picks one of two layouts based on terminal width:
/// - default (>= 36 cols): left accent bar (▎) in the current theme's signature
///   color, followed by the brand, a command hint, and a customize hint
/// - narrow (< 36 cols): stacked minimal — no bar, one short item per line —
///   for very cramped widths where the bar version would wrap
///
/// All truecolor sequences come from `PromptStyle.fg` / `PromptStyle.ansiReset`,
/// so the banner automatically inherits the same palette as the user's prompt.
enum LocalShellBanner {

    // MARK: - Public API

    /// Returns an ANSI-styled banner terminated with two trailing newlines.
    /// Uses `\n` line endings — the caller is responsible for CR/LF normalization.
    static func render(columns: Int) -> String {
        let cols = max(columns, 1)
        if cols >= 36 {
            return renderBar(columns: cols)
        } else {
            return renderNarrow(columns: cols)
        }
    }

    // MARK: - Bar layout (columns >= 36)

    private static func renderBar(columns: Int) -> String {
        let accent = PromptStyle.bannerAccent
        let dim = PromptStyle.bannerDim
        let fgAccent = PromptStyle.fg(accent.r, accent.g, accent.b)
        let fgDim = PromptStyle.fg(dim.r, dim.g, dim.b)
        let reset = PromptStyle.ansiReset

        let barPrefix = "\(fgAccent)▎\(reset) "  // 2 visible columns
        let barOnly = "\(fgAccent)▎\(reset)"
        let contentWidth = max(columns - 2, 1)

        let labelWidth = max(tryLabel.count, editLabel.count) + 2

        // --- Header: "shell · local shell (sandboxed)" ---
        let headerColored: String
        if brand.count + 3 + subtitleLong.count <= contentWidth {
            headerColored = "\(fgAccent)\(bold(brand))\(reset) \(fgDim)· \(subtitleLong)\(reset)"
        } else if brand.count + 3 + subtitleShort.count <= contentWidth {
            headerColored = "\(fgAccent)\(bold(brand))\(reset) \(fgDim)· \(subtitleShort)\(reset)"
        } else {
            headerColored = "\(fgAccent)\(bold(brand))\(reset)"
        }

        // --- Try line: "Try   help · ls · cd · ..." ---
        let tryCommandWidth = max(contentWidth - labelWidth, 1)
        let tryJoined = fittingCommands(commandHints, separator: " · ", maxWidth: tryCommandWidth)
        let tryColored =
            "\(fgAccent)\(tryLabel)\(reset)"
            + String(repeating: " ", count: labelWidth - tryLabel.count)
            + tryJoined

        // --- Edit line: "Edit  ~/.shellrc to customize" ---
        let editHint: String
        if labelWidth + customizeHintLong.count <= contentWidth {
            editHint = customizeHintLong
        } else {
            editHint = customizeHintShort
        }
        let editColored =
            "\(fgAccent)\(editLabel)\(reset)"
            + String(repeating: " ", count: labelWidth - editLabel.count)
            + fgDim + editHint + reset

        let lines = [
            "\(barPrefix)\(headerColored)",
            barOnly,
            "\(barPrefix)\(tryColored)",
            "\(barPrefix)\(editColored)",
        ]
        return lines.joined(separator: "\n") + "\n\n"
    }

    // MARK: - Narrow layout (columns < 36)

    private static func renderNarrow(columns: Int) -> String {
        let accent = PromptStyle.bannerAccent
        let dim = PromptStyle.bannerDim
        let fgAccent = PromptStyle.fg(accent.r, accent.g, accent.b)
        let fgDim = PromptStyle.fg(dim.r, dim.g, dim.b)
        let reset = PromptStyle.ansiReset

        let contentWidth = max(columns - 1, 1)  // 1 char of left margin

        var lines: [String] = []

        // Title (bold accent)
        lines.append(" \(fgAccent)\(bold(brand))\(reset)")

        // Subtitle (dim) — only if it fits on its own line
        if 1 + subtitleShort.count <= contentWidth {
            lines.append(" \(fgDim)\(subtitleShort)\(reset)")
        }

        // Spacer
        lines.append("")

        // Commands (no label, shrinks down to a single item if needed)
        let commandsFit = fittingCommands(commandHints, separator: " · ", maxWidth: contentWidth - 1)
        lines.append(" \(commandsFit)")

        // Customize hint — always the short form in this tier
        let editHint = customizeHintShort
        if 1 + editLabel.count + 1 + editHint.count <= contentWidth {
            lines.append(" \(fgAccent)\(editLabel)\(reset) \(fgDim)\(editHint)\(reset)")
        } else {
            lines.append(" \(fgDim)\(editHint)\(reset)")
        }

        return lines.joined(separator: "\n") + "\n\n"
    }

    // MARK: - Content (localized)

    /// Brand name — intentionally not localized.
    private static let brand = "shell"

    private static var subtitleLong: String {
        String(localized: "local shell (sandboxed)")
    }

    private static var subtitleShort: String {
        String(localized: "local shell")
    }

    private static var tryLabel: String {
        String(localized: "Try")
    }

    private static var editLabel: String {
        String(localized: "Edit")
    }

    private static var customizeHintLong: String {
        String(localized: "~/.shellrc to customize")
    }

    private static var customizeHintShort: String {
        String(localized: "editrc to customize")
    }

    /// Built-in shell commands suggested in the banner.
    /// Trailing entries are dropped first when the terminal is too narrow.
    /// The list shrinks all the way to a single command if needed.
    ///
    /// Every entry MUST be something this fork can actually run: a builtin, `SELF`,
    /// or a command whose `commandDictionary.plist` entry points at a framework we
    /// link (awk / files / ios_system / shell / text). The upstream list suggested
    /// `git`, `vim`, `curl` and `mtr`: git and mtr map to `MAIN` (which needs an
    /// in-binary `git_main` / `mtr_main`, and this fork has no `@_cdecl` shims),
    /// vim maps to the unlinked vim.framework and curl to the unlinked
    /// curl_ios.framework — so four of the eight commands the banner recommended
    /// failed the moment a user typed them. Re-check the plist against the linked
    /// frameworks before adding anything here.
    /// help → builtin, ls → files, cd → SELF, cat/grep → text, find → shell.
    private static let commandHints = ["help", "ls", "cd", "cat", "grep", "find"]

    // MARK: - Small helpers

    /// Bold on/off bracketed around a string. `[1m` = bold on, `[22m` = normal intensity.
    private static func bold(_ text: String) -> String {
        "\u{1b}[1m\(text)\u{1b}[22m"
    }

    /// Pick the longest prefix of `commands` whose joined form fits in `maxWidth`.
    /// Shrinks all the way down to a single item if necessary.
    private static func fittingCommands(
        _ commands: [String],
        separator: String,
        maxWidth: Int
    ) -> String {
        var items = commands
        while items.count > 1 {
            let joined = items.joined(separator: separator)
            if joined.count <= maxWidth { return joined }
            items.removeLast()
        }
        return items.first ?? ""
    }
}

#endif
