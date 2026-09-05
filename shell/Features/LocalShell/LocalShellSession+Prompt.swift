#if !targetEnvironment(macCatalyst)

import Foundation

extension LocalShellSession {
    var promptAddNewline: Bool {
        SettingsStore.shared.value(Settings.Prompt.addNewline)
    }

    /// Formats a path for display in tab title
    /// Converts to ~ notation and truncates long paths to last 3 components
    func formatPathForTitle(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath

        // Get the Documents directory (our "home" on iOS)
        let homeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let home = (homeURL.path as NSString).standardizingPath

        var displayPath = standardized

        // Replace home directory with ~/
        if standardized == home {
            displayPath = "~/"
        } else if standardized.hasPrefix(home + "/") {
            let remainder = String(standardized.dropFirst(home.count + 1))
            displayPath = "~/" + remainder
        }

        // Truncate to last 3 components if path is too long
        let components = displayPath.split(separator: "/", omittingEmptySubsequences: false)
        if components.count > 4 {
            // Keep ~ or first component, then …/last/two/components
            let lastThree = components.suffix(3)
            if displayPath.hasPrefix("~") {
                displayPath = "~/…/" + lastThree.joined(separator: "/")
            } else {
                displayPath = "…/" + lastThree.joined(separator: "/")
            }
        }

        return displayPath.isEmpty ? "~/" : displayPath
    }

    /// Displays command prompt — generates fresh prompt and caches it for redrawLine reuse
    func displayPrompt(ensureAtLineStart: Bool = false) {
        // A stopped session must not emit output or touch prompt state —
        // sessionCurrentDirectory would allocate a fresh ios_system key
        // after teardown released the old one.
        guard isRunning else { return }

        // During script execution, suppress prompt display entirely.
        // If a script command is waiting for completion, signal it.
        if activeShellInterpreter != nil {
            if let completion = scriptCommandCompletion {
                scriptCommandCompletion = nil
                completion()
            }
            return
        }

        // Sync `$?` for native app commands (git/ping/ssh/...), which report
        // only success/failure. Only correct the env when the *sign* disagrees:
        // paths with precise codes (interpreter scripts, ios_system commands)
        // write them directly and must not be degraded to 1 here.
        let envCode = sharedShellEnvironment.getLastExitCode()
        if (envCode == 0) != lastCommandSucceeded {
            sharedShellEnvironment.setLastExitCode(lastCommandSucceeded ? 0 : 1)
        }

        // Update tab title with current working directory (per-session, not process-global)
        let currentPath = sessionCurrentDirectory
        currentWorkingDirectory = currentPath
        onWorkingDirectoryChange?(currentPath)
        let formattedPath = formatPathForTitle(currentPath)
        onTitleChange?(formattedPath)

        // Full-screen programs can restore the primary screen with the cursor
        // partway across its row. Return to column zero without adding a line.
        if ensureAtLineStart {
            onOutput?("\r")
        }

        let prompt = generateFreshPrompt()

        // Count lines the prompt occupies (for transient prompt replacement later)
        let visibleText = PromptStyle.stripANSI(prompt.text)
        lastPromptLineCount = max(1, visibleText.components(separatedBy: "\n").count)

        // Styled prompts opt into visual separation from prior output. The
        // single-line "$ " fallback renders directly on the next available row.
        if prompt.addsLeadingSeparator {
            onOutput?("\r\n")
        }

        // Render the prompt with optional right-aligned component
        if prompt.rightPromptWidth > 0 {
            onOutput?(renderPromptWithRightAlign(prompt))
        } else {
            onOutput?(prompt.text)
        }
    }

    /// Replace the current prompt with a transient (simplified) version before executing a command.
    /// Called from handleCommandSubmission AFTER handleEnter has already output \n,
    /// so cursor is one line below the input line.
    func applyTransientPrompt(command: String) {
        guard shouldUseTransientPrompt() else { return }

        let transient = PromptStyle.PromptResult(text: PromptStyle.simple(), secondLinePrefix: 2)

        // Cursor is on a blank line below the input line (handleEnter already output \n).
        // Calculate how many terminal rows to move up to reach the info bar start:
        //   - infoBarLines: logical lines before the input line (lastPromptLineCount - 1)
        //   - inputRows: terminal rows the input line occupies (prompt prefix + typed text)
        //   - +1 for the blank line we're currently on (from handleEnter's \n)
        let terminalWidth = max(1, Int(pty.windowSize.cols))
        let promptPrefix = getCurrentPromptResult().secondLinePrefix
        // Measure in display cells, not characters — a CJK/emoji command wraps to
        // more rows than its character count suggests, and undercounting here moves
        // the cursor up too few lines before the clear-to-end-of-screen.
        let inputCols = promptPrefix + DisplayWidth.width(of: command)
        let inputRows = max(1, (inputCols + terminalWidth - 1) / terminalWidth)
        let infoBarLines = max(0, lastPromptLineCount - 1)  // lines before input line
        let totalRowsUp = infoBarLines + inputRows  // from blank line to info bar start

        var output = ""

        if totalRowsUp > 0 {
            output += "\u{1b}[\(totalRowsUp)A"  // Move up to info bar
        }
        output += "\r"                             // Column 0
        output += "\u{1b}[J"                       // Clear from cursor to end of screen

        // Write transient prompt + the command the user typed + newline
        output += transient.text
        output += command
        output += "\r\n"

        onOutput?(output)
    }

    /// Whether transient prompt should be applied
    private func shouldUseTransientPrompt() -> Bool {
        SettingsStore.shared.value(Settings.Prompt.useTransientPrompt)
    }

    /// Render a prompt with right-aligned text on the info bar line.
    /// Uses ANSI cursor positioning (CHA) to place the right prompt at an absolute
    /// column, avoiding fragile width measurement of the left prompt.
    func renderPromptWithRightAlign(_ prompt: PromptStyle.PromptResult) -> String {
        let columns = Int(pty.windowSize.cols)
        let rightWidth = prompt.rightPromptWidth
        guard columns > 0, rightWidth > 0, rightWidth < columns else { return prompt.text }

        // Write the full left prompt first (terminal handles rendering)
        var output = prompt.text

        // Cursor is now at the end of the input line (after "❯ ").
        // Move up to the info bar line, write right prompt at absolute column, move back.
        let visibleText = PromptStyle.stripANSI(prompt.text)
        let lineCount = visibleText.components(separatedBy: "\n").count
        let linesUp = lineCount - 1

        if linesUp > 0 {
            output += "\u{1b}[\(linesUp)A"  // CUU — move up to info bar
        }

        // CHA — Cursor Horizontal Absolute (1-based column)
        let rightCol = columns - rightWidth + 1
        output += "\u{1b}[\(rightCol)G"

        // Write the right prompt
        output += prompt.rightPromptText
        output += PromptStyle.ansiReset

        // Move cursor back down to input line
        if linesUp > 0 {
            output += "\u{1b}[\(linesUp)B"  // CUD — move down
        }

        // Restore cursor to input position (start of input area)
        output += "\r"
        if prompt.secondLinePrefix > 0 {
            output += "\u{1b}[\(prompt.secondLinePrefix)C"  // CUF — move forward
        }

        return output
    }

    /// Generate a fresh prompt (called from displayPrompt only — caches result for redraw)
    private func generateFreshPrompt() -> PromptStyle.PromptResult {
        let currentPath = sessionCurrentDirectory
        var result = promptCache.getPrompt(
            directory: currentPath,
            commandSucceeded: lastCommandSucceeded
        )
        result.addsLeadingSeparator = promptAddNewline
        // PromptCache stores its own copy before this edit — write back so
        // redraw sites (Ctrl+L) see the same separator.
        promptCache.cachedPrompt = result
        return result
    }

    /// Get the cached prompt result for redraw operations (redrawLine, handleCtrlL, etc.)
    /// Returns the same prompt that displayPrompt generated — never regenerates on keystroke.
    func getCurrentPromptResult() -> PromptStyle.PromptResult {
        // Return cached prompt if available (set by displayPrompt/generateFreshPrompt)
        if let cached = promptCache.cachedPrompt {
            return cached
        }
        // Fallback: generate fresh (shouldn't normally happen)
        return generateFreshPrompt()
    }
}

// MARK: - Prompt Cache

/// Cache for the prompt so it is not regenerated on every keystroke.
struct PromptCache {
    /// Cached prompt result
    var cachedPrompt: PromptStyle.PromptResult?

    /// Invalidation triggers
    var lastDirectory: String?
    var lastCommandSucceeded: Bool?
    var lastUsername: String?

    /// Check if cache is valid for current state
    func isValid(directory: String, commandSucceeded: Bool) -> Bool {
        guard cachedPrompt != nil else { return false }
        guard lastDirectory == directory else { return false }
        guard lastCommandSucceeded == commandSucceeded else { return false }
        return lastUsername == UserPreferences.effectiveUsername
    }

    /// Get cached prompt or regenerate if stale
    mutating func getPrompt(directory: String, commandSucceeded: Bool) -> PromptStyle.PromptResult {
        if isValid(directory: directory, commandSucceeded: commandSucceeded),
           let cached = cachedPrompt {
            return cached
        }

        let prompt = PromptStyle.prompt(lastCommandSucceeded: commandSucceeded, directory: directory)
        cachedPrompt = prompt
        lastDirectory = directory
        lastCommandSucceeded = commandSucceeded
        lastUsername = UserPreferences.effectiveUsername
        return prompt
    }

    /// Force cache invalidation (e.g., after directory change)
    mutating func invalidate() {
        cachedPrompt = nil
    }
}

// `CursorTracker` (display-column line-wrap math) now lives in the
// platform-independent `Core/Utilities/CursorTracker.swift` so the embedded
// sftp prompt can share it on Mac Catalyst too.

#endif // !targetEnvironment(macCatalyst)
