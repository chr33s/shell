//
//  CursorTracker.swift
//  shell
//
//  Display-column cursor/line-wrap arithmetic shared by the local shell prompt
//  and the embedded sftp prompt. Pure integer math, no platform APIs — compiles
//  on iOS, visionOS, and Mac Catalyst.
//

import Foundation

// MARK: - Cursor Tracking for Line Wraps

/// Utility for calculating cursor position accounting for terminal width and line wraps.
///
/// All offsets are measured in terminal **display columns**, not Swift characters —
/// callers must pre-convert via `DisplayWidth` / `LineEditor.cursorColumn` so that
/// wide glyphs (CJK, emoji) advance the cursor by their true cell width.
enum CursorTracker {
    /// Calculate cursor row/column position accounting for line wraps
    /// - Parameters:
    ///   - promptSecondLinePrefix: Display width of prompt on input line (2 for "❯ ")
    ///   - bufferCursorPosition: Cursor offset from input start, in display columns
    ///   - terminalWidth: Terminal width in columns
    /// - Returns: (row, col) relative to start of input area (0-indexed)
    static func calculateCursorPosition(
        promptSecondLinePrefix: Int,
        bufferCursorPosition: Int,
        terminalWidth: Int
    ) -> (row: Int, col: Int) {
        guard terminalWidth > 0 else { return (0, 0) }

        // Total offset from line start = prompt prefix + cursor position in buffer
        let totalOffset = promptSecondLinePrefix + bufferCursorPosition

        // Calculate which row (0-indexed from input start)
        let row = totalOffset / terminalWidth

        // Calculate column (0-indexed)
        let col = totalOffset % terminalWidth

        return (row, col)
    }

    /// Calculate how many rows the full buffer occupies
    /// - Parameters:
    ///   - promptSecondLinePrefix: Display width of prompt on input line (2 for "❯ ")
    ///   - bufferLength: Total buffer width in display columns (not characters)
    ///   - terminalWidth: Terminal width in columns
    static func calculateTotalRows(
        promptSecondLinePrefix: Int,
        bufferLength: Int,
        terminalWidth: Int
    ) -> Int {
        guard terminalWidth > 0 else { return 1 }

        let totalChars = promptSecondLinePrefix + bufferLength
        // Add 1 because even 0 chars takes 1 row, use ceiling division
        return max(1, (totalChars + terminalWidth - 1) / terminalWidth)
    }

    /// Generate escape sequence to position cursor correctly after redraw
    /// - Parameters:
    ///   - totalRows: Total rows of content drawn on input line(s)
    ///   - targetRow: Target row (0-indexed from input start)
    ///   - targetCol: Target column (0-indexed)
    /// - Returns: ANSI escape sequence to position cursor
    static func cursorPositionSequence(
        totalRows: Int,
        targetRow: Int,
        targetCol: Int
    ) -> String {
        // After drawing, cursor is at end of last row
        // Need to move to (targetRow, targetCol)

        var sequence = ""

        // Calculate rows to move up (from end of content to target row)
        let rowsUp = totalRows - 1 - targetRow
        if rowsUp > 0 {
            sequence += "\u{1B}[\(rowsUp)A"  // CUU - cursor up
        }

        // Move to beginning of line, then to target column
        sequence += "\r"  // Carriage return to column 0
        if targetCol > 0 {
            sequence += "\u{1B}[\(targetCol)C"  // CUF - cursor forward
        }

        return sequence
    }
}
