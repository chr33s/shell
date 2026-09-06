import Foundation
#if !targetEnvironment(macCatalyst)
import ios_system
#endif

/// Result of a tab completion attempt
enum CompletionResult {
    /// Exactly one match — insert it and stay idle
    case singleMatch(text: String, range: Range<Int>)
    /// Multiple matches with a longer common prefix — extend to that prefix
    case extendedToCommonPrefix(text: String, range: Range<Int>, allMatches: [String], displayNames: [String])
    /// Multiple matches with no further common prefix — show them all
    case showAllMatches(allMatches: [String], displayNames: [String], range: Range<Int>)
    /// No matches at all
    case noMatch
}

/// Provides tab completion for commands and file paths
@MainActor
class CompletionProvider {
    // MARK: - Properties

    /// Cached list of available commands
    private lazy var availableCommands: [String] = {
        var commands: [String] = []

        // Get commands from ios_system (iOS/visionOS only)
        #if !targetEnvironment(macCatalyst)
        if let commandList = commandsAsArray() as? [String] {
            commands = commandList.sorted()
        }
        #endif

        // Add built-in shell commands that ios_system does not list.
        // Every entry must name something that actually runs on the interactive
        // path. This list used to advertise "hx", "imgcat", "mosh", "roam",
        // "tssh", "trzsz" and "ssh-copy-id" — none of which exist as commands —
        // while omitting "ssh", so `ssh<Tab>` matched only "ssh-copy-id" and
        // silently rewrote the line to a command that fails. "ssh" belongs here
        // because the session intercepts it before ios_system is consulted
        // (LocalShellSession+Input routes "ssh"/"ssh …" to handleSSHCommand), so
        // it is absent from commandDictionary.plist.
        commands.append(contentsOf: [
            "exit", "clear", "reset", "history", "help", "source", "editrc", "reloadconfig",
            "ssh",
            // Shell interpreter builtins
            "sleep", "printf", "test", "read", "true", "false",
            "unset", "local", "return", "break", "continue",
            "shift", "set", "trap", "eval", "type", "let"
        ])

        // De-duplicate. Entries that also ship as ios_system commands (cd, pwd,
        // export, git, …) previously appeared twice, which turned an exact
        // single match into a spurious "multiple matches" result — ringing the
        // bell and listing the command name twice on the second Tab.
        return Array(Set(commands)).sorted()
    }()

    // MARK: - Types

    private struct CompletionContext {
        let matchPrefix: String     // Unescaped text for filesystem matching
        let range: Range<Int>       // Buffer range to replace (includes quotes/escapes)
        let quoteChar: Character?   // nil, '"', or '\'' if inside a quote
        let type: CompletionType    // .command or .path
    }

    private struct CompletionMatch {
        let relativePath: String    // Display path (e.g., "sub/file.txt", "~/Documents")
        let isDirectory: Bool
    }

    private enum CompletionType {
        case command
        case path
    }

    // MARK: - Completion

    /// Attempt completion for the given line and cursor position.
    /// Stateless — all cycling/display logic is managed by the caller.
    func complete(line: String, cursorPosition: Int, workingDirectory: String? = nil) -> CompletionResult {
        let context = parseCompletionContext(line: line, cursorPosition: cursorPosition)

        guard !context.matchPrefix.isEmpty || context.type == .path else { return .noMatch }

        let encoded: [String]
        let displayNames: [String]

        switch context.type {
        case .command:
            let matches = completeCommand(prefix: context.matchPrefix)
            encoded = matches.map { $0 + " " }
            displayNames = matches
        case .path:
            let matches = completePath(prefix: context.matchPrefix, workingDirectory: workingDirectory)
            encoded = matches.map {
                encodeForInsertion(
                    rawPath: $0.relativePath,
                    isDirectory: $0.isDirectory,
                    quoteChar: context.quoteChar
                )
            }
            // Display names: short filenames (last path component), dirs get trailing /
            displayNames = matches.map { match in
                let name = (match.relativePath as NSString).lastPathComponent
                return match.isDirectory ? name + "/" : name
            }
        }

        guard !encoded.isEmpty else { return .noMatch }

        if encoded.count == 1 {
            return .singleMatch(text: encoded[0], range: context.range)
        }

        // Multiple matches — check for a common prefix longer than what's typed
        if let commonPrefix = findCommonPrefix(encoded), commonPrefix.count > context.range.count {
            return .extendedToCommonPrefix(
                text: commonPrefix,
                range: context.range,
                allMatches: encoded,
                displayNames: displayNames
            )
        }

        return .showAllMatches(
            allMatches: encoded,
            displayNames: displayNames,
            range: context.range
        )
    }

    // MARK: - Context Parsing

    /// Forward-scan from line start to cursor, tracking quotes and escapes
    private func parseCompletionContext(line: String, cursorPosition: Int) -> CompletionContext {
        var inQuote: Character?     // Active quote delimiter (' or ")
        var escaped = false         // Previous char was backslash (outside single quotes)
        var argStart = 0            // Start of current argument in buffer
        var argIndex = 0            // 0 = command position, 1+ = argument

        let chars = Array(line.prefix(cursorPosition))

        for (i, char) in chars.enumerated() {
            if escaped {
                // This char is escaped — it's part of the current argument
                escaped = false
                continue
            }

            if let q = inQuote {
                // Inside quotes
                if char == q {
                    // Closing quote
                    inQuote = nil
                } else if char == "\\" && q == "\"" {
                    // Backslash only escapes inside double quotes
                    escaped = true
                }
                continue
            }

            // Outside quotes
            if char == "\\" {
                escaped = true
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = char
                continue
            }

            if char.isWhitespace {
                // Argument boundary
                argIndex += 1
                argStart = i + 1
                continue
            }
        }

        let rawArg = String(chars[argStart...].map { $0 })
        let matchPrefix = unescapeForMatching(rawArg)

        // Position 0 is normally command completion, but if the prefix looks like
        // a path (starts with ./, /, or ~/), use path completion instead.
        // This enables tab-completing script files like ./test.sh
        let type: CompletionType
        if argIndex == 0 && (matchPrefix.hasPrefix("./") || matchPrefix.hasPrefix("/") || matchPrefix.hasPrefix("~/")) {
            type = .path
        } else {
            type = argIndex == 0 ? .command : .path
        }

        return CompletionContext(
            matchPrefix: matchPrefix,
            range: argStart..<cursorPosition,
            quoteChar: inQuote,
            type: type
        )
    }

    /// Strip quote delimiters and resolve backslash escapes for filesystem matching
    private func unescapeForMatching(_ raw: String) -> String {
        var result = ""
        var escaped = false
        var inQuote: Character?

        for char in raw {
            if escaped {
                result.append(char)
                escaped = false
                continue
            }

            if let q = inQuote {
                if char == q {
                    inQuote = nil
                } else if char == "\\" && q == "\"" {
                    escaped = true
                } else {
                    result.append(char)
                }
                continue
            }

            if char == "\\" {
                escaped = true
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = char
                continue
            }

            result.append(char)
        }

        return result
    }

    // MARK: - Command Completion

    private func completeCommand(prefix: String) -> [String] {
        if prefix.isEmpty {
            return availableCommands
        }

        return availableCommands.filter { $0.hasPrefix(prefix) }
    }

    // MARK: - Path Completion

    private func completePath(prefix: String, workingDirectory: String? = nil) -> [CompletionMatch] {
        // Use HOME env var (set to Documents by LocalShellSession) rather than
        // NSHomeDirectory() which returns the app sandbox root on iOS.
        let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var expandedPrefix = prefix

        // Expand leading ~ only
        if expandedPrefix.hasPrefix("~") {
            expandedPrefix = homeDir + expandedPrefix.dropFirst()
        }

        // Separate directory from filename prefix using last "/"
        let directory: String
        let filePrefix: String
        let userDirPrefix: String  // The directory part as the user typed it

        if let lastSlash = expandedPrefix.lastIndex(of: "/") {
            let dirPart = String(expandedPrefix[...lastSlash])  // includes trailing "/"
            filePrefix = String(expandedPrefix[expandedPrefix.index(after: lastSlash)...])

            // Resolve to absolute path
            if dirPart.hasPrefix("/") {
                directory = dirPart
            } else {
                // Relative path: prepend CWD
                let cwd = workingDirectory ?? FileManager.default.currentDirectoryPath
                directory = (cwd as NSString).appendingPathComponent(dirPart)
            }

            // Reconstruct user's original directory prefix for output
            if prefix.hasPrefix("~") {
                // User typed ~/..., preserve that
                let afterTilde = String(prefix[prefix.index(after: prefix.startIndex)...])
                if let userSlash = afterTilde.lastIndex(of: "/") {
                    userDirPrefix = "~" + String(afterTilde[...userSlash])
                } else {
                    userDirPrefix = "~/"
                }
            } else if let userSlash = prefix.lastIndex(of: "/") {
                userDirPrefix = String(prefix[...userSlash])
            } else {
                userDirPrefix = ""
            }
        } else {
            // No path separator, search current directory
            directory = workingDirectory ?? FileManager.default.currentDirectoryPath
            filePrefix = expandedPrefix
            userDirPrefix = ""
        }

        // List directory contents
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }

        // Filter hidden files: only show entries starting with "." if filePrefix starts with "."
        let showHidden = filePrefix.hasPrefix(".")

        let fm = FileManager.default
        let matches: [CompletionMatch] = contents
            .filter { entry in
                // Hidden file filter
                if entry.hasPrefix(".") && !showHidden { return false }
                // Prefix filter
                if !filePrefix.isEmpty && !entry.hasPrefix(filePrefix) { return false }
                return true
            }
            .sorted()
            .map { entry in
                let fullPath = (directory as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                let relativePath = userDirPrefix + entry
                return CompletionMatch(relativePath: relativePath, isDirectory: isDir.boolValue)
            }

        return matches
    }

    // MARK: - Encoding Helpers

    /// Backslash-escape characters that are special in shell contexts
    private func shellEscape(_ name: String) -> String {
        var result = ""
        let specialChars: Set<Character> = [" ", "\"", "'", "$", "`", "\\", "(", ")", "&", "|", ";", "<", ">", "!", "{", "}", "[", "]", "?", "*", "#"]
        for char in name {
            if specialChars.contains(char) {
                result.append("\\")
            }
            result.append(char)
        }
        return result
    }

    /// Encode a raw path for insertion into the line buffer
    private func encodeForInsertion(rawPath: String, isDirectory: Bool, quoteChar: Character?) -> String {
        if let q = quoteChar {
            let escapedPath: String
            if q == "\"" {
                // Double quotes: $, `, \, " still have special meaning
                escapedPath = escapeForDoubleQuotes(rawPath)
            } else {
                // Single quotes: only ' itself needs handling — end the quote,
                // insert escaped quote, reopen: it's → it'\''s
                escapedPath = rawPath.replacingOccurrences(of: "'", with: "'\\''")
            }
            if isDirectory {
                return String(q) + escapedPath + "/"
            } else {
                return String(q) + escapedPath + String(q) + " "
            }
        } else {
            // No quote context — shell-escape the path
            if isDirectory {
                return shellEscape(rawPath) + "/"
            } else {
                return shellEscape(rawPath) + " "
            }
        }
    }

    /// Escape characters that are special inside double quotes
    private func escapeForDoubleQuotes(_ name: String) -> String {
        var result = ""
        for char in name {
            if char == "$" || char == "`" || char == "\\" || char == "\"" {
                result.append("\\")
            }
            result.append(char)
        }
        return result
    }

    // MARK: - Utilities

    private func findCommonPrefix(_ strings: [String]) -> String? {
        guard !strings.isEmpty else { return nil }
        guard strings.count > 1 else { return strings[0] }

        var commonPrefix = strings[0]
        for string in strings.dropFirst() {
            while !string.hasPrefix(commonPrefix) {
                commonPrefix = String(commonPrefix.dropLast())
                if commonPrefix.isEmpty {
                    return nil
                }
            }
        }

        return commonPrefix.isEmpty ? nil : commonPrefix
    }
}
