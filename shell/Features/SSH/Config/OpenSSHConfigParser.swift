//
//  OpenSSHConfigParser.swift
//  shell
//
//  Pure-Swift parser for ~/.ssh/config. Supports the directive subset that
//  covers virtually every real-world config: Host blocks (single + multiple
//  patterns), HostName, Port, User, IdentityFile (multiple), ProxyJump,
//  ProxyCommand, IdentitiesOnly, Include. Match blocks and unknown directives
//  are reported as warnings, never crash the parse.
//

import Foundation

/// A single concrete or wildcard `Host` entry from an ssh_config file.
struct OpenSSHHostEntry: Hashable, Sendable {
    /// All patterns from the `Host` line (e.g. ["prod-web"] or ["prod1", "prod2"]).
    var aliases: [String]
    /// `HostName` directive value, if present.
    var hostName: String?
    /// `Port` directive value, if present.
    var port: Int?
    /// `User` directive value, if present.
    var user: String?
    /// Every `IdentityFile` line in the order they appeared (after `none`
    /// resets are applied within the block).
    var identityFiles: [String]
    /// True if the block contained `IdentityFile none` — OpenSSH's sentinel
    /// to discard any IdentityFile entries inherited from wildcard blocks.
    var identityFilesCleared: Bool
    /// First `ProxyJump` value, if present (later occurrences are ignored).
    var proxyJump: String?
    /// First `ProxyCommand` value, if present.
    var proxyCommand: String?
    /// True if any alias contains a wildcard character (`*`, `?`, `!`).
    var isWildcard: Bool
    /// Source file the entry came from (for diagnostics).
    var sourceFile: URL
    /// Line number in `sourceFile` where the `Host` line lives.
    var sourceLine: Int
}

/// Result of a successful parse.
struct OpenSSHConfigParseResult: Sendable {
    /// All Host entries in declaration order (including wildcards).
    var entries: [OpenSSHHostEntry]
    /// Human-readable warnings (unknown directives, Match blocks, cycle detection, etc.).
    var warnings: [String]
}

/// Parser for OpenSSH `ssh_config` files. Pure functions, no shared state.
nonisolated enum OpenSSHConfigParser {
    /// Maximum depth for `Include` directive recursion. Matches OpenSSH's own limit.
    private static let maxIncludeDepth = 16

    enum ParseError: LocalizedError {
        case fileUnreadable(URL, underlying: Error?)

        var errorDescription: String? {
            switch self {
            case .fileUnreadable(let url, let underlying):
                let base = "Could not read \(url.lastPathComponent)"
                if let underlying { return "\(base): \(underlying.localizedDescription)" }
                return base
            }
        }
    }

    /// Parse a config file. `sshDirectory` is the base used to resolve relative
    /// `IdentityFile` and `Include` paths (typically the directory containing
    /// the config file).
    static func parse(fileURL: URL, sshDirectory: URL) throws -> OpenSSHConfigParseResult {
        var state = ParserState(sshDirectory: sshDirectory)
        try parseInto(state: &state, fileURL: fileURL, depth: 0)
        state.flushCurrentBlock()
        return OpenSSHConfigParseResult(entries: state.entries, warnings: state.warnings)
    }

    // MARK: - Internal state

    private struct ParserState {
        let sshDirectory: URL
        var entries: [OpenSSHHostEntry] = []
        var warnings: [String] = []
        var includedFiles: Set<String> = []  // canonicalized absolute paths, for cycle detection
        var currentBlock: OpenSSHHostEntry?

        mutating func flushCurrentBlock() {
            if let block = currentBlock {
                entries.append(block)
                currentBlock = nil
            }
        }
    }

    // MARK: - File reading + dispatch

    private static func parseInto(state: inout ParserState, fileURL: URL, depth: Int) throws {
        let canonical = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        if state.includedFiles.contains(canonical) {
            state.warnings.append("Skipped \(fileURL.lastPathComponent): include cycle")
            return
        }
        state.includedFiles.insert(canonical)

        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            // Try Latin-1 as a fallback for legacy configs with non-UTF8 bytes.
            if let data = try? Data(contentsOf: fileURL),
               let fallback = String(data: data, encoding: .isoLatin1) {
                text = fallback
            } else {
                throw ParseError.fileUnreadable(fileURL, underlying: error)
            }
        }

        parseLines(state: &state, text: text, sourceFile: fileURL, depth: depth)
    }

    private static func parseLines(state: inout ParserState, text: String, sourceFile: URL, depth: Int) {
        // In Swift a CRLF pair is ONE Character (extended grapheme cluster), so
        // splitting on "\n" finds no separator at all in a CRLF config: the whole
        // file collapsed into a single bogus "line" and the import silently produced
        // zero hosts. `Character.isNewline` matches the CRLF cluster as well as a
        // lone \n or \r, so CR-only and mixed files parse and the CR is consumed as
        // part of the separator instead of leaking into values.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            guard let (keyword, value) = splitKeywordValue(trimmed) else {
                state.warnings.append("\(sourceFile.lastPathComponent):\(lineNumber): unparseable line")
                continue
            }

            switch keyword.lowercased() {
            case "host":
                state.flushCurrentBlock()
                let patterns = tokenize(value)
                guard !patterns.isEmpty else {
                    state.warnings.append("\(sourceFile.lastPathComponent):\(lineNumber): Host with no patterns")
                    continue
                }
                state.currentBlock = OpenSSHHostEntry(
                    aliases: patterns,
                    hostName: nil,
                    port: nil,
                    user: nil,
                    identityFiles: [],
                    identityFilesCleared: false,
                    proxyJump: nil,
                    proxyCommand: nil,
                    isWildcard: patterns.contains(where: containsWildcard),
                    sourceFile: sourceFile,
                    sourceLine: lineNumber
                )

            case "match":
                state.flushCurrentBlock()
                state.warnings.append("\(sourceFile.lastPathComponent):\(lineNumber): Match blocks are not supported")
                state.currentBlock = nil

            case "include":
                let paths = expandIncludePaths(value: value, sshDirectory: state.sshDirectory)
                if depth + 1 > maxIncludeDepth {
                    state.warnings.append("\(sourceFile.lastPathComponent):\(lineNumber): Include depth limit reached")
                    continue
                }
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    do {
                        try parseInto(state: &state, fileURL: url, depth: depth + 1)
                    } catch {
                        state.warnings.append("Include \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }

            default:
                applyDirective(keyword: keyword, value: value, to: &state, line: lineNumber, sourceFile: sourceFile)
            }
        }
    }

    // MARK: - Directive application

    private static func applyDirective(
        keyword: String,
        value: String,
        to state: inout ParserState,
        line: Int,
        sourceFile: URL
    ) {
        guard state.currentBlock != nil else {
            // Pre-Host directives apply to "Host *" implicitly in real ssh_config.
            // For our import use case we just skip them and emit a warning.
            state.warnings.append("\(sourceFile.lastPathComponent):\(line): \(keyword) outside Host block, ignored")
            return
        }

        switch keyword.lowercased() {
        case "hostname":
            state.currentBlock?.hostName = unquote(value)
        case "port":
            if let port = Int(unquote(value)) { state.currentBlock?.port = port }
        case "user":
            state.currentBlock?.user = unquote(value)
        case "identityfile":
            let path = unquote(value)
            if path.isEmpty { break }
            // `IdentityFile none` is OpenSSH's sentinel for "discard any
            // identities inherited from wildcard blocks." We clear the
            // current block's list AT THIS POINT (subsequent IdentityFile
            // lines in the same block can still append after the reset)
            // and remember the clear so wildcard inheritance is suppressed.
            if path.caseInsensitiveCompare("none") == .orderedSame {
                state.currentBlock?.identityFiles.removeAll()
                state.currentBlock?.identityFilesCleared = true
            } else {
                state.currentBlock?.identityFiles.append(path)
            }
        case "proxyjump":
            if state.currentBlock?.proxyJump == nil {
                state.currentBlock?.proxyJump = unquote(value)
            }
        case "proxycommand":
            if state.currentBlock?.proxyCommand == nil {
                state.currentBlock?.proxyCommand = unquote(value)
            }
        case "identitiesonly":
            // Recognized but no action needed — we always honor IdentityFile entries.
            break
        default:
            // Quietly ignore directives we don't translate. Real configs are
            // full of options that don't map onto our profile model
            // (ServerAliveInterval, StrictHostKeyChecking, etc.).
            break
        }
    }

    // MARK: - Helpers

    /// Detect wildcard characters in a Host pattern.
    private static func containsWildcard(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?") || pattern.contains("!")
    }

    /// Strip `#`-prefixed comments, respecting double-quoted strings.
    private static func stripComment(_ line: String) -> String {
        var inQuote = false
        var result = ""
        for ch in line {
            if ch == "\"" { inQuote.toggle() }
            if ch == "#" && !inQuote { break }
            result.append(ch)
        }
        return result
    }

    /// Split a directive line into `(keyword, value)`. Keyword and value can be
    /// separated by whitespace or `=`.
    private static func splitKeywordValue(_ line: String) -> (String, String)? {
        let scalars = Array(line)
        var idx = 0
        // Skip leading whitespace (already trimmed but harmless).
        while idx < scalars.count, scalars[idx].isWhitespace { idx += 1 }
        let keywordStart = idx
        while idx < scalars.count, !scalars[idx].isWhitespace, scalars[idx] != "=" { idx += 1 }
        guard idx > keywordStart else { return nil }
        let keyword = String(scalars[keywordStart..<idx])
        // Skip separator (whitespace and/or single `=`).
        var sawEquals = false
        while idx < scalars.count {
            let ch = scalars[idx]
            if ch.isWhitespace { idx += 1; continue }
            if ch == "=" && !sawEquals { sawEquals = true; idx += 1; continue }
            break
        }
        let value = String(scalars[idx...]).trimmingCharacters(in: .whitespaces)
        return (keyword, value)
    }

    /// Tokenize a value into whitespace-separated, quote-aware tokens.
    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""

        for ch in input {
            if inQuote {
                if ch == quoteChar {
                    inQuote = false
                } else {
                    current.append(ch)
                }
            } else {
                switch ch {
                case "\"", "'":
                    inQuote = true
                    quoteChar = ch
                case " ", "\t":
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                default:
                    current.append(ch)
                }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Strip surrounding quotes from a single value.
    private static func unquote(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2 {
            let first = v.first!
            let last = v.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                return String(v.dropFirst().dropLast())
            }
        }
        return v
    }

    /// Expand an `Include` directive value into concrete file URLs (resolving
    /// `~` and supporting basic `*` globs via FileManager).
    private static func expandIncludePaths(value: String, sshDirectory: URL) -> [String] {
        let tokens = tokenize(value).map(unquote)
        var results: [String] = []
        for token in tokens {
            let expanded = expandTilde(token, sshDirectory: sshDirectory)
            // Resolve relative paths against the ssh directory.
            let absolute: String
            if expanded.hasPrefix("/") {
                absolute = expanded
            } else {
                absolute = sshDirectory.appendingPathComponent(expanded).path
            }
            // Expand glob `*` and `?` via NSString filtering on the parent directory.
            if absolute.contains("*") || absolute.contains("?") {
                let parent = (absolute as NSString).deletingLastPathComponent
                let pattern = (absolute as NSString).lastPathComponent
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: parent) {
                    for entry in entries where fnmatch(pattern: pattern, name: entry) {
                        results.append((parent as NSString).appendingPathComponent(entry))
                    }
                }
            } else {
                results.append(absolute)
            }
        }
        return results
    }

    /// Tilde expansion: `~` -> `sshDirectory.deletingLastPathComponent()` (the
    /// real home, since `.ssh` is its child); `~/foo` -> `home/foo`.
    private static func expandTilde(_ path: String, sshDirectory: URL) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = sshDirectory.deletingLastPathComponent().path
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// Minimal `fnmatch`-style glob (supports `*` and `?` only). OpenSSH's
    /// `Include` directive uses very simple globs in practice.
    private static func fnmatch(pattern: String, name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        var pi = 0
        var ni = 0
        var starPi = -1
        var starNi = -1
        while ni < n.count {
            if pi < p.count, p[pi] == "?" {
                pi += 1; ni += 1
            } else if pi < p.count, p[pi] == "*" {
                starPi = pi
                starNi = ni
                pi += 1
            } else if pi < p.count, p[pi] == n[ni] {
                pi += 1; ni += 1
            } else if starPi >= 0 {
                pi = starPi + 1
                starNi += 1
                ni = starNi
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
