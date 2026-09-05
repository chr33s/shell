#if !targetEnvironment(macCatalyst)

import Foundation

/// Shared truecolor ANSI styling engine for terminal command output.
///
/// All colors use 24-bit truecolor sequences (`\e[38;2;R;G;Bm`) for consistent
/// appearance across any terminal theme.  Command-specific colors and icons
/// are added via extensions (e.g. `TerminalStyle+Git.swift`).
nonisolated enum TerminalStyle {

    // MARK: - Color type

    struct Color: Sendable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    // MARK: - Shared palette

    static let success  = Color(r: 80,  g: 200, b: 120)   // green
    static let error    = Color(r: 240, g: 80,  b: 80)     // red
    static let warning  = Color(r: 240, g: 200, b: 80)     // golden
    static let info     = Color(r: 100, g: 180, b: 255)    // light blue
    static let dim      = Color(r: 100, g: 100, b: 110)    // dark gray
    static let accent   = Color(r: 180, g: 140, b: 255)    // purple
    static let cyan     = Color(r: 100, g: 200, b: 200)    // cyan

    // MARK: - Shared Nerd Font icons

    static let checkIcon   = "\u{f00c}"   //  checkmark
    static let crossIcon   = "\u{f00d}"   //  cross
    static let arrowUp     = "\u{f062}"   //  upload/send
    static let arrowDown   = "\u{f063}"   //  download/receive
    static let warningIcon = "\u{f071}"   //  warning triangle
    static let folderIcon  = "\u{f07b}"   //  folder
    static let fileIcon    = "\u{f15b}"   //  file
    static let lockIcon    = "\u{f023}"   //  lock (secure)

    // MARK: - ANSI formatting

    static func fg(_ color: Color, _ text: String) -> String {
        "\u{1b}[38;2;\(color.r);\(color.g);\(color.b)m\(text)\u{1b}[0m"
    }

    static func bold(_ text: String) -> String {
        "\u{1b}[1m\(text)\u{1b}[0m"
    }

    static func boldFg(_ color: Color, _ text: String) -> String {
        "\u{1b}[1;38;2;\(color.r);\(color.g);\(color.b)m\(text)\u{1b}[0m"
    }

    static func dim(_ text: String) -> String {
        "\u{1b}[2m\(text)\u{1b}[0m"
    }

    static func italic(_ text: String) -> String {
        "\u{1b}[3m\(text)\u{1b}[0m"
    }

    static func underline(_ text: String) -> String {
        "\u{1b}[4m\(text)\u{1b}[0m"
    }

    static func bg(_ color: Color, _ text: String) -> String {
        "\u{1b}[48;2;\(color.r);\(color.g);\(color.b)m\(text)\u{1b}[0m"
    }

    static let reset = "\u{1b}[0m"

    /// Clear to end of line.
    static let clearLine = "\u{1b}[K"

    /// Batch a terminal repaint so renderers never present its intermediate cursor positions.
    static let syncOutputStart = "\u{1b}[?2026h"
    static let syncOutputEnd = "\u{1b}[?2026l"

    // MARK: - Progress bar

    /// Render a colored progress bar: `████████░░░░░░`
    static func progressBar(current: Int, total: Int, width: Int = 30, barColor: Color = success) -> String {
        guard total > 0 else { return "" }
        let percent = min(100, (current * 100) / total)
        let filled = (percent * width) / 100
        let empty = width - filled

        let filledStr = String(repeating: "█", count: filled)
        let emptyStr = String(repeating: "░", count: empty)

        return "\(fg(barColor, filledStr))\(fg(dim, emptyStr))"
    }

    /// Render a complete progress line that fits within `cols` terminal columns.
    ///
    /// Output: `sync-start \r\e[K{label} {bar} {pct}%{suffix} sync-end`
    static func formatProgressLine(
        label: String,
        current: Int,
        total: Int,
        cols: UInt16,
        suffix: String = "",
        barColor: Color = success
    ) -> String {
        guard total > 0 else { return "" }
        let termWidth = cols > 0 ? Int(cols) : 80
        let percent = min(100, (current * 100) / total)
        let pctStr = " \(percent)%"

        let fixedWithSuffix = label.count + 1 + pctStr.count + suffix.count
        var barWidth = termWidth - fixedWithSuffix
        var activeSuffix = suffix

        barWidth = min(barWidth, 60)

        if barWidth < 5 && !suffix.isEmpty {
            activeSuffix = ""
            let fixedNoSuffix = label.count + 1 + pctStr.count
            barWidth = min(termWidth - fixedNoSuffix, 60)
        }

        if barWidth < 5 {
            return "\(syncOutputStart)\r\(clearLine)\(label)\(pctStr)\(syncOutputEnd)"
        }

        let bar = progressBar(current: current, total: total, width: barWidth, barColor: barColor)
        return "\(syncOutputStart)\r\(clearLine)\(label) \(bar)\(pctStr)\(activeSuffix)\(syncOutputEnd)"
    }
}

#endif
