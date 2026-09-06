#if !targetEnvironment(macCatalyst)

import Foundation

// MARK: - Flag Specification

/// Describes which flags a command accepts and whether they take arguments.
struct FlagSpec {
    /// Short flags that consume the next token as their value (e.g., "-p" in `ssh -p 22`)
    let flagsWithArg: Set<String>
    /// Short flags that are boolean/standalone (e.g., "-A" in `ssh -A`)
    let booleanFlags: Set<String>
    /// Long flags that take `=value` or consume next token (e.g., `--option=value`)
    let longFlagsWithArg: Set<String>
    /// Long flags that are boolean/standalone (e.g., `--version`)
    let longBooleanFlags: Set<String>

    static let ssh = FlagSpec(
        flagsWithArg: ["-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J",
                        "-L", "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"],
        booleanFlags: ["-4", "-6", "-A", "-a", "-C", "-f", "-G", "-g", "-K", "-k",
                       "-M", "-N", "-n", "-q", "-s", "-T", "-t", "-V", "-v", "-X", "-x", "-Y", "-y"],
        longFlagsWithArg: [],
        longBooleanFlags: []
    )
}

// MARK: - Extraction Result

/// Where the cursor is relative to command arguments.
enum CursorContext: Equatable {
    /// Cursor is on a positional argument (the destination/host) being typed
    case inDestination
    /// Destination/positional already complete; cursor is past it (e.g., `ssh host cmd`)
    case pastDestination
    /// Cursor is right after a flag that expects a value (e.g., "ssh -p |")
    case afterFlag(String)
    /// Cursor is typing a flag value without trailing space (e.g., "ssh -p 22|")
    case typingFlagValue
    /// Cursor is typing a flag itself (e.g., "ssh -|")
    case typingFlag
    /// Nothing after the command yet
    case empty
}

/// Result of extracting the completable argument from a command line.
struct ExtractionResult {
    /// The text being completed (the positional argument being typed)
    let completableText: String
    /// Everything before the completable text (command + flags + spaces)
    let bufferPrefix: String
    /// What the cursor is positioned on
    let context: CursorContext
}

// MARK: - Command Argument Extractor

enum CommandArgumentExtractor {

    // MARK: Tokenizer

    /// True iff `text` ends in whitespace that's a real argument separator —
    /// i.e., the final character is whitespace AND it isn't sitting inside an
    /// open quote or consumed by a backslash escape. `scp My\ File\ <Tab>`
    /// ends in an *escaped* space, which is part of the filename; that should
    /// not flip us into "positional complete".
    private static func endsWithArgumentSeparator(_ text: String) -> Bool {
        var inQuote: Character?
        var escaped = false
        var lastWasSeparator = false
        for char in text {
            if escaped {
                // Char is part of the token (consumed by the escape).
                escaped = false
                lastWasSeparator = false
                continue
            }
            if let q = inQuote {
                if char == q {
                    inQuote = nil
                } else if char == "\\" && q == "\"" {
                    escaped = true
                }
                lastWasSeparator = false
                continue
            }
            if char == "\\" {
                escaped = true
                lastWasSeparator = false
                continue
            }
            if char == "\"" || char == "'" {
                inQuote = char
                lastWasSeparator = false
                continue
            }
            lastWasSeparator = char.isWhitespace
        }
        return lastWasSeparator
    }

    /// Tokenize arguments, handling single/double quotes and backslash escapes
    /// so that quoted strings (e.g., `"My File.txt"` or `'proxy cmd'`) and
    /// backslash-escaped sequences (e.g., `My\ File.txt`) are kept as single
    /// tokens. Raw escape/quote characters are preserved in the token text so
    /// completion can detect quote/escape context downstream.
    private static func tokenize(_ text: String) -> [(text: String, startOffset: Int)] {
        var tokens: [(text: String, startOffset: Int)] = []
        var current = ""
        var currentStart = 0
        var inQuote: Character?
        var escaped = false
        var i = 0

        for char in text {
            if escaped {
                // Escaped char is part of the current token, even if it's whitespace.
                // The backslash itself was appended on the previous iteration.
                current.append(char)
                escaped = false
            } else if let quote = inQuote {
                current.append(char)
                if char == quote {
                    inQuote = nil
                } else if char == "\\" && quote == "\"" {
                    // Inside double quotes, backslash escapes the next char.
                    escaped = true
                }
            } else if char == "\\" {
                if current.isEmpty {
                    currentStart = i
                }
                current.append(char)
                escaped = true
            } else if char == "\"" || char == "'" {
                if current.isEmpty {
                    currentStart = i
                }
                current.append(char)
                inQuote = char
            } else if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append((current, currentStart))
                    current = ""
                }
            } else {
                if current.isEmpty {
                    currentStart = i
                }
                current.append(char)
            }
            i += 1
        }
        if !current.isEmpty {
            tokens.append((current, currentStart))
        }
        return tokens
    }

    // MARK: Flag-walk helpers

    /// Result of classifying a single token as a flag or positional.
    private enum FlagClassification {
        /// Skip this many tokens (1 = boolean flag, 2 = flag + value)
        case skip(Int)
        /// Not a flag — this is a positional argument
        case positional
        /// Terminal state — return this extraction result immediately
        case terminal(ExtractionResult)
    }

    /// Classifies a token during the flag walk.
    private static func classifyFlag(
        token: String,
        isLastToken: Bool,
        endsWithSpace: Bool,
        buffer: String,
        flagSpec: FlagSpec
    ) -> FlagClassification {
        // Long flags with = (e.g., --option=value)
        if token.hasPrefix("--") && token.contains("=") {
            return .skip(1)
        }

        // Long flags
        if token.hasPrefix("--") {
            if flagSpec.longBooleanFlags.contains(token) {
                return .skip(1)
            }
            if flagSpec.longFlagsWithArg.contains(token) {
                if isLastToken && !endsWithSpace {
                    return .terminal(ExtractionResult(
                        completableText: "", bufferPrefix: buffer, context: .typingFlag))
                }
                if isLastToken && endsWithSpace {
                    return .terminal(ExtractionResult(
                        completableText: "", bufferPrefix: buffer, context: .afterFlag(token)))
                }
                return .skip(2)
            }
            // Unknown long flag — treat as boolean
            return .skip(1)
        }

        // Short flags
        if token.hasPrefix("-") && token.count >= 2 {
            if flagSpec.flagsWithArg.contains(token) {
                if isLastToken && !endsWithSpace {
                    return .terminal(ExtractionResult(
                        completableText: "", bufferPrefix: buffer, context: .typingFlag))
                }
                if isLastToken && endsWithSpace {
                    return .terminal(ExtractionResult(
                        completableText: "", bufferPrefix: buffer, context: .afterFlag(token)))
                }
                return .skip(2)
            }
            if flagSpec.booleanFlags.contains(token) {
                return .skip(1)
            }
            // Combined short flags like -Av (all characters are known boolean flags)
            if token.count > 2 && token.dropFirst().allSatisfy({ flagSpec.booleanFlags.contains("-\($0)") }) {
                return .skip(1)
            }
            // Unknown short flag — treat as boolean
            if isLastToken && !endsWithSpace {
                return .terminal(ExtractionResult(
                    completableText: "", bufferPrefix: buffer, context: .typingFlag))
            }
            return .skip(1)
        }

        // Not a flag — positional argument
        return .positional
    }

    // MARK: extractDestination (SSH)

    /// Extract the first positional argument (destination) from a command buffer, skipping flags.
    /// For single-destination commands like ssh.
    ///
    /// Returns `.pastDestination` if a positional has already been fully typed and there are
    /// more tokens or trailing space after it — tab should beep, not append.
    static func extractDestination(
        buffer: String,
        commandLength: Int,
        flagSpec: FlagSpec
    ) -> ExtractionResult {
        let afterCommand = String(buffer.dropFirst(commandLength))

        // commandLength includes the trailing space (e.g., 4 for "ssh "),
        // so empty afterCommand means the user typed "command " and is ready
        // to start typing the destination — return .inDestination, not .empty.
        guard !afterCommand.isEmpty else {
            return ExtractionResult(completableText: "", bufferPrefix: buffer, context: .inDestination)
        }

        let tokens = tokenize(afterCommand)
        let endsWithSpace = endsWithArgumentSeparator(afterCommand)

        var tokenIndex = 0
        while tokenIndex < tokens.count {
            let token = tokens[tokenIndex].text
            let isLastToken = (tokenIndex == tokens.count - 1)

            switch classifyFlag(token: token, isLastToken: isLastToken,
                                endsWithSpace: endsWithSpace, buffer: buffer, flagSpec: flagSpec) {
            case .terminal(let result):
                return result
            case .skip(let count):
                // Flag — check if the flag's VALUE token is the last and still being typed
                if count == 2 {
                    let valueIndex = tokenIndex + 1
                    if valueIndex < tokens.count {
                        let isValueLast = (valueIndex == tokens.count - 1)
                        if isValueLast && !endsWithSpace {
                            return ExtractionResult(
                                completableText: "", bufferPrefix: buffer, context: .typingFlagValue)
                        }
                    }
                }
                tokenIndex += count
                continue
            case .positional:
                break
            }

            // First positional found — this is the destination
            if isLastToken && !endsWithSpace {
                // Currently typing the destination
                let prefixEnd = commandLength + tokens[tokenIndex].startOffset
                let prefix = String(buffer.prefix(prefixEnd))
                return ExtractionResult(
                    completableText: token, bufferPrefix: prefix, context: .inDestination)
            } else {
                // Destination already complete — past it, no completion
                return ExtractionResult(
                    completableText: "", bufferPrefix: buffer, context: .pastDestination)
            }
        }

        // All tokens were flags, cursor is after them
        if endsWithSpace {
            return ExtractionResult(
                completableText: "", bufferPrefix: buffer, context: .inDestination)
        }

        return ExtractionResult(completableText: "", bufferPrefix: buffer, context: .empty)
    }
}

// MARK: - Completion State

/// Consolidates the 4 repeated properties per SSH-family command for tab completion.
struct HostCompletionState {
    var suggestions: [AnyQuickConnectSuggestion] = []
    var suggestionIndex = 0
    var matchingMode: MatchingMode = .prefix
    var lastTabTime: Date?

    /// Handle double-tab timing to switch between prefix and substring matching.
    /// Returns true if the mode changed (cache should be rebuilt).
    mutating func handleTabTiming() -> Bool {
        let now = Date()
        defer { lastTabTime = now }

        if let lastTab = lastTabTime, now.timeIntervalSince(lastTab) < 0.5 {
            if matchingMode == .prefix {
                matchingMode = .substring
                suggestions = []
                return true
            }
        } else if matchingMode != .prefix {
            // Slow Tab after a substring session: return to prefix matching and
            // drop the cache so the caller rebuilds it in the new mode.
            matchingMode = .prefix
            suggestions = []
            suggestionIndex = 0
            return true
        }
        // A slow Tab that changes nothing must NOT reset `suggestionIndex`: the
        // caller only rebuilds `suggestions` when the cache is empty, so zeroing
        // the index here re-served suggestions[0] on every Tab at normal typing
        // speed and made cycling past the first host impossible.
        return false
    }

    mutating func reset() {
        suggestions = []
        suggestionIndex = 0
        matchingMode = .prefix
    }

    /// Advance to the next suggestion, wrapping around. Returns current before advancing.
    mutating func nextSuggestion() -> AnyQuickConnectSuggestion? {
        guard !suggestions.isEmpty else { return nil }
        // The index now survives a no-op Tab, so clamp it rather than trusting
        // every caller to zero it whenever `suggestions` is replaced.
        if suggestionIndex >= suggestions.count { suggestionIndex = 0 }
        let suggestion = suggestions[suggestionIndex]
        suggestionIndex = (suggestionIndex + 1) % suggestions.count
        return suggestion
    }
}

#endif // !targetEnvironment(macCatalyst)
