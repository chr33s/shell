import Foundation

/// A line editor that provides readline-like functionality for command-line input
@MainActor
class LineEditor {
    // MARK: - Properties

    /// Current input buffer
    private(set) var buffer: String = ""

    /// Cursor position (0 = before first char, buffer.count = after last char)
    private(set) var cursorPosition: Int = 0

    /// Search mode state
    private var searchMode: Bool = false
    private var searchBuffer: String = ""

    // MARK: - Computed Properties

    /// Text before cursor
    var textBeforeCursor: String {
        guard cursorPosition > 0 else { return "" }
        let index = buffer.index(buffer.startIndex, offsetBy: min(cursorPosition, buffer.count))
        return String(buffer[..<index])
    }

    /// Text after cursor
    var textAfterCursor: String {
        guard cursorPosition < buffer.count else { return "" }
        let index = buffer.index(buffer.startIndex, offsetBy: cursorPosition)
        return String(buffer[index...])
    }

    /// Current line with cursor indicator
    var lineWithCursor: String {
        let before = textBeforeCursor
        let after = textAfterCursor
        return before + "│" + after  // Using │ to show cursor position
    }

    // MARK: - Display Width

    // The cursor model above is character-based (correct for editing — moving one
    // grapheme at a time). The terminal, however, positions the cursor in display
    // cells: CJK and most emoji occupy 2 cells but count as 1 Character. These
    // accessors translate the character model into display columns for redrawing.

    /// Display-cell column of the cursor (sum of cell widths of text before it).
    var cursorColumn: Int { DisplayWidth.width(of: textBeforeCursor) }

    /// Total display-cell width of the buffer.
    var displayWidth: Int { DisplayWidth.width(of: buffer) }

    /// Display-cell width of the text after the cursor.
    var widthAfterCursor: Int { DisplayWidth.width(of: textAfterCursor) }

    // MARK: - Initialization

    init() {}

    // MARK: - Buffer Management

    /// Set the buffer content (used for history navigation)
    func setBuffer(_ text: String) {
        buffer = text
        cursorPosition = buffer.count
    }

    /// Clear the buffer
    func clear() {
        buffer = ""
        cursorPosition = 0
    }

    /// Get current buffer and clear
    func consume() -> String {
        let result = buffer
        clear()
        return result
    }

    // MARK: - Cursor Movement

    /// Move cursor left by count characters
    @discardableResult
    func moveCursorLeft(count: Int = 1) -> Bool {
        let newPos = max(0, cursorPosition - count)
        if newPos != cursorPosition {
            cursorPosition = newPos
            return true
        }
        return false
    }

    /// Move cursor right by count characters
    @discardableResult
    func moveCursorRight(count: Int = 1) -> Bool {
        let newPos = min(buffer.count, cursorPosition + count)
        if newPos != cursorPosition {
            cursorPosition = newPos
            return true
        }
        return false
    }

    /// Move cursor to beginning of line
    @discardableResult
    func moveCursorToStart() -> Bool {
        if cursorPosition > 0 {
            cursorPosition = 0
            return true
        }
        return false
    }

    /// Move cursor to end of line
    @discardableResult
    func moveCursorToEnd() -> Bool {
        if cursorPosition < buffer.count {
            cursorPosition = buffer.count
            return true
        }
        return false
    }

    /// Move cursor to previous word
    @discardableResult
    func moveCursorToPreviousWord() -> Bool {
        guard cursorPosition > 0 else { return false }

        // Skip any whitespace before cursor
        var pos = cursorPosition - 1
        while pos > 0 && buffer[buffer.index(buffer.startIndex, offsetBy: pos)].isWhitespace {
            pos -= 1
        }

        // Find start of word
        while pos > 0 && !buffer[buffer.index(buffer.startIndex, offsetBy: pos - 1)].isWhitespace {
            pos -= 1
        }

        if pos != cursorPosition {
            cursorPosition = pos
            return true
        }
        return false
    }

    /// Move cursor to next word
    @discardableResult
    func moveCursorToNextWord() -> Bool {
        guard cursorPosition < buffer.count else { return false }

        // Skip current word
        var pos = cursorPosition
        while pos < buffer.count && !buffer[buffer.index(buffer.startIndex, offsetBy: pos)].isWhitespace {
            pos += 1
        }

        // Skip whitespace
        while pos < buffer.count && buffer[buffer.index(buffer.startIndex, offsetBy: pos)].isWhitespace {
            pos += 1
        }

        if pos != cursorPosition {
            cursorPosition = pos
            return true
        }
        return false
    }

    // MARK: - Text Insertion

    /// Insert text at cursor position
    @discardableResult
    func insertText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let index = buffer.index(buffer.startIndex, offsetBy: cursorPosition)
        buffer.insert(contentsOf: text, at: index)
        cursorPosition += text.count
        return true
    }

    // MARK: - Text Deletion

    /// Delete character before cursor (backspace)
    @discardableResult
    func deleteBackward(count: Int = 1) -> Bool {
        guard cursorPosition > 0 else { return false }

        let deleteCount = min(count, cursorPosition)
        let startIndex = buffer.index(buffer.startIndex, offsetBy: cursorPosition - deleteCount)
        let endIndex = buffer.index(buffer.startIndex, offsetBy: cursorPosition)
        buffer.removeSubrange(startIndex..<endIndex)
        cursorPosition -= deleteCount
        return true
    }

    /// Delete character at cursor (delete key)
    @discardableResult
    func deleteForward(count: Int = 1) -> Bool {
        guard cursorPosition < buffer.count else { return false }

        let deleteCount = min(count, buffer.count - cursorPosition)
        let startIndex = buffer.index(buffer.startIndex, offsetBy: cursorPosition)
        let endIndex = buffer.index(startIndex, offsetBy: deleteCount)
        buffer.removeSubrange(startIndex..<endIndex)
        return true
    }

    /// Delete from cursor to end of line (Ctrl-K)
    @discardableResult
    func deleteToEnd() -> Bool {
        guard cursorPosition < buffer.count else { return false }

        let startIndex = buffer.index(buffer.startIndex, offsetBy: cursorPosition)
        buffer.removeSubrange(startIndex...)
        return true
    }

    /// Delete from start to cursor (Ctrl-U)
    @discardableResult
    func deleteToStart() -> Bool {
        guard cursorPosition > 0 else { return false }

        let endIndex = buffer.index(buffer.startIndex, offsetBy: cursorPosition)
        buffer.removeSubrange(..<endIndex)
        cursorPosition = 0
        return true
    }

    /// Delete entire line
    @discardableResult
    func deleteLine() -> Bool {
        guard !buffer.isEmpty else { return false }

        buffer = ""
        cursorPosition = 0
        return true
    }

    /// Delete word before cursor (Ctrl-W)
    @discardableResult
    func deleteWordBackward() -> Bool {
        guard cursorPosition > 0 else { return false }

        let originalPos = cursorPosition
        moveCursorToPreviousWord()

        let startIndex = buffer.index(buffer.startIndex, offsetBy: cursorPosition)
        let endIndex = buffer.index(buffer.startIndex, offsetBy: originalPos)
        buffer.removeSubrange(startIndex..<endIndex)

        return true
    }

    // MARK: - Completion Support

    /// Replace text in range (used for completion)
    func replaceText(in range: Range<Int>, with text: String) {
        guard range.lowerBound >= 0,
              range.upperBound <= buffer.count,
              range.lowerBound <= range.upperBound else {
            return
        }
        let startIndex = buffer.index(buffer.startIndex, offsetBy: range.lowerBound)
        let endIndex = buffer.index(buffer.startIndex, offsetBy: range.upperBound)

        buffer.replaceSubrange(startIndex..<endIndex, with: text)
        cursorPosition = range.lowerBound + text.count
    }
}
