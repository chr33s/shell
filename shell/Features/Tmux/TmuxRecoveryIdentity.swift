//
//  TmuxRecoveryIdentity.swift
//  shell
//
//  Verified tmux session continuity for the recovery path
//  (spec.connectivity.md §9.1, CON-05).
//
//  The rule this file exists to enforce: on a recovery path Shell attaches to
//  an *exact existing session* and never uses create-or-attach. The connect
//  path may still create — that is a user asking for a session. A reconnect
//  that silently creates a fresh session and calls it "restored" is the
//  misleading automatic restore the spec forbids; the safe fallback is
//  explicit user action.
//
//  Continuity is proved with server-instance and session-creation metadata,
//  never with a display name. tmux hands out `$0` again after a server
//  restart, and a user can rename a session at any time, so a name is neither
//  necessary nor sufficient.
//

import Foundation

/// Result of checking stored evidence against what a freshly-attached server
/// actually reports.
enum TmuxContinuityVerdict: Equatable, Sendable {
    /// Same session. Reattachment may be reported as a restored session.
    case continuous
    /// The session id exists but the evidence disagrees (server restarted, or
    /// the name was reused by a different session). Requires explicit choice.
    case differentSession
    /// The intended session is not on this server at all.
    case sessionMissing
    /// Not enough evidence on either side to decide. Legacy name-only records
    /// land here, and they require rediscovery and explicit selection.
    case insufficientEvidence
}

nonisolated enum TmuxRecoveryIdentity {

    /// tmux format that yields every continuity field in one round trip.
    ///
    /// `#{pid}` and `#{start_time}` describe the *server* process;
    /// `#{session_id}` and `#{session_created}` describe the session. Name
    /// last, because session names may contain spaces.
    static let continuityFormat =
        "#{pid}\t#{start_time}\t#{session_id}\t#{session_created}\t#{socket_path}\t#{session_name}"

    /// Parse one `display-message -p` / `list-sessions` line in
    /// `continuityFormat`. Server-derived text is untrusted: it is parsed into
    /// typed fields and never interpreted as an instruction.
    @MainActor static func parseContinuity(_ body: String) -> TmuxContinuityEvidence? {
        guard let line = body.split(whereSeparator: \.isNewline).first else { return nil }
        let fields = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
        guard fields.count >= 6 else { return nil }
        guard fields[2].hasPrefix("$"), let sessionID = Int(fields[2].dropFirst()) else { return nil }

        var evidence = TmuxContinuityEvidence()
        evidence.serverPID = Int(fields[0])
        evidence.serverStartTime = fields[1].isEmpty ? nil : String(fields[1])
        evidence.sessionID = sessionID
        evidence.sessionCreated = fields[3].isEmpty ? nil : String(fields[3])
        evidence.socketPath = fields[4].isEmpty ? nil : String(fields[4])
        evidence.lastObservedName = String(fields[5])
        return evidence
    }

    /// Compare stored evidence against freshly discovered evidence.
    ///
    /// `discovered` is what the server reports for the session id we intended
    /// to reattach to; `nil` means that id is not present.
    @MainActor static func verify(
        stored: TmuxContinuityEvidence?,
        discovered: TmuxContinuityEvidence?
    ) -> TmuxContinuityVerdict {
        guard let stored, stored.isSufficientForContinuity else { return .insufficientEvidence }
        guard let discovered else { return .sessionMissing }
        guard discovered.isSufficientForContinuity else { return .insufficientEvidence }
        return stored.matches(discovered) ? .continuous : .differentSession
    }

    // MARK: - Command construction

    /// The remote `sh -c '…'` line for reattaching an existing session over a
    /// fresh SSH connection.
    ///
    /// There is deliberately no `command -v tmux || exec $SHELL` fallback the
    /// way the connect-time launcher has one: falling back to a login shell
    /// here would replace the user's session with a new shell while the UI
    /// still said "reattaching". A missing tmux must fail the attach so the
    /// recovery path reports a missing session and offers the explicit
    /// "Open new shell" action instead.
    static func remoteAttachCommandLine(
        sessionID: Int,
        controlMode: Bool,
        socketPath: String? = nil,
        pathPrefix: String = ""
    ) -> String? {
        // A socket path arrives from the server side; refuse anything that
        // could break out of the single-quoted `sh -c` wrapper rather than
        // trying to escape it cleverly.
        var socketArgument = ""
        if let socketPath {
            guard isSafeSocketPath(socketPath) else { return nil }
            socketArgument = "-S '\(socketPath)' "
        }
        let cc = controlMode ? "-CC " : ""
        // `\$` matters and is easy to lose. This whole string is handed to the
        // remote *login* shell, which strips the single quotes and passes the
        // body to the inner `sh`. An unescaped `"$3"` is then a positional
        // parameter of that inner shell — unset, so tmux would receive
        // `attach-session -t ""` and attach to whatever it considers current.
        // That is the silent target substitution CON-05 forbids, arriving
        // through a quoting bug rather than a policy one. Escaped, the inner
        // shell sees a literal `$3`, which is tmux's session id syntax.
        return "sh -c '\(pathPrefix)exec tmux \(socketArgument)\(cc)attach-session -t \"\\$\(sessionID)\"'"
    }

    /// Attach-only by session **name**, for regular (non-control) tmux mode.
    ///
    /// Regular mode has no control channel, so there is no way to collect the
    /// server/session metadata that proves continuity. What is still possible,
    /// and what §9.2 requires, is refusing to *create*: `attach-session`
    /// without `-A` fails when the session is gone, and the recovery path then
    /// reports a missing session instead of handing back a fresh empty one.
    /// Attachment readiness here is not the pane-by-pane guarantee control
    /// mode gives, and is not reported as one.
    static func remoteAttachByNameCommandLine(
        sessionName: String,
        socketPath: String? = nil,
        pathPrefix: String = ""
    ) -> String? {
        guard isSafeSessionName(sessionName) else { return nil }

        var socketArgument = ""
        if let socketPath {
            guard isSafeSocketPath(socketPath) else { return nil }
            socketArgument = "-S '\(socketPath)' "
        }
        return "sh -c '\(pathPrefix)exec tmux \(socketArgument)attach-session -t '\\''\(sessionName)'\\'''"
    }

    /// A session name is safe to embed when it survives the nested quoting
    /// above without meaning anything to either shell. Anything else is
    /// refused rather than escaped cleverly.
    static func isSafeSessionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A socket path is safe to embed when it is an absolute path made of
    /// characters that carry no meaning to the shell inside single quotes.
    static func isSafeSocketPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count <= 512 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        return path.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Discovery query for the continuity evidence of one session id.
    static func continuityQuery(sessionID: Int) -> String {
        "display-message -p -t \"$\(sessionID)\" \"\(continuityFormat)\""
    }

    /// Discovery query for every session's continuity evidence.
    static func continuityListQuery() -> String {
        "list-sessions -F \"\(continuityFormat)\""
    }

    /// Parse a multi-line `list-sessions` reply in `continuityFormat`.
    @MainActor static func parseContinuityList(_ body: String) -> [TmuxContinuityEvidence] {
        body.split(whereSeparator: \.isNewline).compactMap { parseContinuity(String($0)) }
    }
}
