//
//  TmuxSessionModels.swift
//  shell
//
//  Models and parsers for the tmux control-mode session dashboard. Unlike the
//  connect-time discovery models (TmuxSessionDiscovery.swift, name-keyed, run
//  over an SSH exec channel), these are id-keyed ("$N"/"@N") and parsed from
//  control-mode `%begin/%end` block bodies, which preserve bytes exactly — so
//  plain space delimiters with the (possibly space-containing) name LAST work.
//

import Foundation

// MARK: - Reply plumbing (ghostty_surface_tmux_command_with_reply)

/// A response to an app-issued tmux query, delivered via
/// GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE and correlated by tag.
nonisolated struct TmuxCommandReply: Sendable {
    let tag: UInt32
    let body: String
    let isError: Bool
}

nonisolated enum TmuxCommandError: Error, LocalizedError {
    /// No reply arrived before the app-side timeout (transport stalled).
    case timeout
    /// The gateway's control mode ended (or was reset) before tmux answered.
    case gatewayEnded
    /// tmux answered with %error; the message is tmux's human-readable text
    /// (e.g. "duplicate session: x").
    case serverError(String)
    /// A user-entered name contains control characters (e.g. a newline from
    /// a multi-line paste) that can't be embedded in a tmux command — see
    /// TmuxControlModeParser.isValidTmuxName. ROOTSHELL-TMUX (id=tmux-quote-c0)
    case invalidName

    var errorDescription: String? {
        switch self {
        case .timeout: return "tmux did not respond"
        case .gatewayEnded: return "tmux control mode ended"
        case let .serverError(message): return message.isEmpty ? "tmux error" : message
        case .invalidName: return "Name can't contain newlines or control characters"
        }
    }
}

// MARK: - Dashboard models

/// One session on the tmux server, from `list-sessions`.
nonisolated struct TmuxControlSession: Identifiable, Equatable, Sendable {
    /// Numeric part of the "$N" session id.
    let id: Int
    let name: String
    let windowCount: Int
    /// Number of clients attached to this session (any client, not just us).
    let attachedClients: Int

    var isAttachedSomewhere: Bool { attachedClients > 0 }
}

/// One window of a session, from `list-windows -t "$N"`.
nonisolated struct TmuxControlWindow: Identifiable, Equatable, Sendable {
    /// Numeric part of the "@N" window id.
    let id: Int
    let index: Int
    let name: String
    let isActive: Bool
}

// MARK: - Parser

nonisolated enum TmuxControlModeParser {
    /// Format for `list-sessions`. Name LAST: session names may contain
    /// spaces, so the remainder of the line after the fixed fields is the name.
    static let listSessionsFormat =
        "#{session_id} #{session_windows} #{session_attached} #{session_name}"

    /// Format for `list-windows -t "$N"`. Same trailing-name rule.
    static let listWindowsFormat =
        "#{window_id} #{window_index} #{window_active} #{window_name}"

    /// Split a control-mode block body into lines. The body arrives with CRLF
    /// line endings (the gateway PTY's ONLCR maps tmux's `\n` to `\r\n`), and
    /// in Swift a `\r\n` sequence is a SINGLE grapheme cluster that does NOT
    /// equal the Character "\n" — so `split(separator: "\n")` never splits a
    /// CRLF body and the whole reply parses as one line (every session merged
    /// into one row). `Character.isNewline` is true for "\n", "\r", and the
    /// CRLF cluster, so this handles all endings. The Zig-side parsers trim
    /// "\r" per line for the same reason (viewer.zig receivedListWindows).
    private static func lines(_ body: String) -> [Substring] {
        body.split(whereSeparator: \.isNewline)
    }

    /// Parse `list-sessions` output in `listSessionsFormat`.
    /// Lines that fail to parse are skipped (mirrors TmuxDiscoveryParser).
    static func parseSessions(_ body: String) -> [TmuxControlSession] {
        var sessions: [TmuxControlSession] = []
        for line in lines(body) {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 4,
                  fields[0].hasPrefix("$"),
                  let id = Int(fields[0].dropFirst()),
                  let windows = Int(fields[1]),
                  let attached = Int(fields[2])
            else { continue }
            sessions.append(TmuxControlSession(
                id: id,
                name: String(fields[3]),
                windowCount: windows,
                attachedClients: attached))
        }
        return sessions
    }

    /// Parse `list-windows` output in `listWindowsFormat`.
    static func parseWindows(_ body: String) -> [TmuxControlWindow] {
        var windows: [TmuxControlWindow] = []
        for line in lines(body) {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 4,
                  fields[0].hasPrefix("@"),
                  let id = Int(fields[0].dropFirst()),
                  let index = Int(fields[1]),
                  let active = Int(fields[2])
            else { continue }
            windows.append(TmuxControlWindow(
                id: id,
                index: index,
                name: String(fields[3]),
                isActive: active != 0))
        }
        return windows
    }

    /// Parse a `new-session -d -s x -PF "#{session_id}"` reply body ("$N").
    static func parseSessionId(_ body: String) -> Int? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("$") else { return nil }
        return Int(trimmed.dropFirst())
    }

    /// Quote an arbitrary string for use as a tmux command argument.
    /// Double-quoted with `\`, `"`, `$`, and backtick escaped (the characters
    /// tmux's cmd-parse expands/consumes inside double quotes).
    ///
    /// Control characters are STRIPPED: control mode is line-oriented, so an
    /// embedded `\n` (or `\r`) inside an argument would terminate this command
    /// and start a second, attacker-chosen one (`run-shell`, `new-window`, …
    /// = arbitrary shell on the server). Callers should reject such input up
    /// front via `isValidTmuxName`; stripping here is the backstop so quote()
    /// can never emit a command terminator no matter what a future call site
    /// passes. ROOTSHELL-TMUX (id=tmux-quote-c0)
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            if containsControlScalar(ch) { continue }
            switch ch {
            case "\\", "\"", "$", "`": out.append("\\")
            default: break
            }
            out.append(ch)
        }
        out.append("\"")
        return out
    }

    /// True when `name` can pass through `quote()` unmodified: no C0/C1
    /// control characters or DEL (most importantly no `\n`/`\r`, which would
    /// terminate the line-oriented control-mode command — see `quote()`).
    /// Sinks that embed user-entered names in tmux commands must check this
    /// and surface a validation error rather than silently mangling the name.
    /// Empty strings are valid here; callers needing non-empty check that
    /// separately. ROOTSHELL-TMUX (id=tmux-quote-c0)
    static func isValidTmuxName(_ name: String) -> Bool {
        !name.contains(where: containsControlScalar)
    }

    /// C0 (0x00–0x1F), DEL (0x7F), and C1 (0x80–0x9F) detection. Operates on
    /// unicode scalars because Swift groups `\r\n` into a single Character
    /// that doesn't equal "\n" (same gotcha as `lines(_:)` above).
    private static func containsControlScalar(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
    }

    /// True when `name` is safe to embed in the single-quoted `sh -c '...'`
    /// reconnect exec command (SSHConfig.tmuxExecCommand). Conservative:
    /// only `[A-Za-z0-9_.-]`. tmux itself allows almost any name; we just
    /// won't persist non-embeddable ones for reconnect.
    static func isEmbeddableSessionName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "-")
        }
    }
}
