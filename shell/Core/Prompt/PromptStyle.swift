//
//  PromptStyle.swift
//  shell
//
//  ANSI helpers and the local shell's prompt.
//
//  spec.md §2 keeps one default theme and no configurable prompt system, so
//  this is deliberately a single fixed style: a two-line prompt showing the
//  working directory above a chevron that turns red when the last command
//  failed.
//

import Foundation

struct PromptStyle {

    // MARK: - Palette

    private static let accent = (r: 141, g: 166, b: 206)   // #8DA6CE
    private static let green = (r: 97, g: 206, b: 60)      // #61CE3C
    private static let redError = (r: 191, g: 57, b: 42)   // #BF392A

    // MARK: - ANSI Escape Helpers

    /// ANSI escape sequence start
    static let esc = "\u{1b}"

    /// Set foreground color to RGB true color
    static func fg(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\(esc)[38;2;\(r);\(g);\(b)m"
    }

    /// Set background color to RGB true color
    static func bg(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\(esc)[48;2;\(r);\(g);\(b)m"
    }

    /// Reset all attributes
    static let ansiReset = "\u{1b}[0m"

    // MARK: - Banner Accents

    /// Accent color for the local shell welcome banner.
    static let bannerAccent: (r: Int, g: Int, b: Int) = accent

    /// Dim color for banner sublines.
    static let bannerDim: (r: Int, g: Int, b: Int) = (127, 144, 170)

    // MARK: - Data Helpers

    /// Get current username
    static func username() -> String {
        UserPreferences.effectiveUsername
    }

    /// Get shortened directory path with ~ substitution and truncation
    static func shortenedPath(directory: String) -> String {
        // Standardize paths to resolve symlinks (/var vs /private/var)
        let path = (directory as NSString).standardizingPath

        // Use Documents directory as HOME (same as LocalShellSession sets for ios_system)
        let homeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let home = (homeURL.path as NSString).standardizingPath

        // Replace home directory with ~
        var displayPath = path
        if path.hasPrefix(home) {
            let remainder = String(path.dropFirst(home.count))
            displayPath = remainder.isEmpty ? "~" : "~" + remainder
        }

        // Truncate to last 3 components if needed
        let components = displayPath.split(separator: "/", omittingEmptySubsequences: false)
        if components.count > 3 {
            let lastThree = components.suffix(3)
            displayPath = "…/" + lastThree.joined(separator: "/")
        }

        return displayPath.isEmpty ? "~" : displayPath
    }

    /// Strip ANSI escape sequences, leaving the visible text.
    static func stripANSI(_ text: String) -> String {
        // Remove all ANSI escape sequences: ESC[ ... m, ESC[ ... A/B/C/D/H/J/K, etc.
        var result = ""
        var inEscape = false
        var chars = text.makeIterator()

        while let ch = chars.next() {
            if ch == "\u{1b}" {
                inEscape = true
                continue
            }
            if inEscape {
                // CSI sequences end with a letter
                if ch == "[" {
                    // Consume until we hit a letter (terminator)
                    while let next = chars.next() {
                        if next.isLetter || next == "m" { break }
                    }
                } else {
                    // Non-CSI escape (e.g. ESC O ...) — consume one more char
                    _ = chars.next()
                }
                inEscape = false
                continue
            }
            result.append(ch)
        }

        return result
    }

    // MARK: - Prompt Generation

    /// Result of prompt generation
    struct PromptResult {
        /// The full prompt text with ANSI escape codes
        let text: String
        /// Visible width of the second line prefix (for cursor positioning)
        let secondLinePrefix: Int
        /// Right-aligned prompt ANSI text (empty = no right prompt)
        var rightPromptText: String = ""
        /// Visible width of the right prompt (for cursor positioning)
        var rightPromptWidth: Int = 0
        /// Number of visible lines in the info bar (above the input line)
        var infoLineCount: Int = 1
        /// Whether to leave a blank row between prior output and this prompt.
        var addsLeadingSeparator: Bool = false
    }

    /// The prompt: a directory line, then a chevron input line.
    /// - Parameters:
    ///   - lastCommandSucceeded: Whether the last command succeeded (affects chevron color)
    ///   - directory: The session's current working directory (avoids reading process-global CWD)
    /// - Returns: PromptResult with text and cursor positioning info
    static func prompt(lastCommandSucceeded: Bool = true, directory: String) -> PromptResult {
        let path = shortenedPath(directory: directory)
        let pathColor = fg(accent.r, accent.g, accent.b)
        let chevronRGB = lastCommandSucceeded ? green : redError
        let chevronColor = fg(chevronRGB.r, chevronRGB.g, chevronRGB.b)

        let text = pathColor + path + ansiReset + "\r\n"
            + "\u{1b}[1m" + chevronColor + "❯" + ansiReset + " "

        return PromptResult(
            text: text,
            secondLinePrefix: 2,
            infoLineCount: 1,
            addsLeadingSeparator: true
        )
    }

    /// Minimal fallback prompt used when no directory context is available.
    static func simple() -> String {
        "\u{1b}[1m" + fg(green.r, green.g, green.b) + "❯" + ansiReset + " "
    }
}
