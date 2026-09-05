//
//  TmuxController+Windows.swift
//  shell
//
//  Window administration for tmux control mode: create / rename / kill
//  windows, and move / link / unlink windows between sessions. All ops ride
//  the generic reply layer (sendCommandWithReply); topology changes are never
//  applied locally — the attached session's tabs follow the resulting
//  %window-add / %window-close reconcile, and other sessions' lists refresh
//  via noteSessionsChanged().
//
//  Window ids ("@N") are server-global, so source targets never need a
//  session prefix. Session-scoped targets use the "$N" id form throughout,
//  immune to name escaping.
//

import Foundation

extension TmuxController {
    /// Create a window appended at the end of a session's window list.
    /// `{end}` + `-a` is strict append ("-t $N:+" would resolve relative to
    /// the session's current window and error on an occupied index). Always
    /// `-d`: the app ignores tmux's remote focus anyway, and for THIS
    /// gateway's attached session the armed new-window request makes the
    /// reconcile-built tab open and get selected locally — the same flow as
    /// the gateway "+" button.
    func createWindow(inSession sessionId: Int) async throws {
        if sessionId == currentSessionId { noteNewWindowRequest() }
        _ = try await sendCommandWithReply(
            "new-window -d -a -t \"$\(sessionId):{end}\" -PF \"#{window_id}\"")
        noteSessionsChanged()
    }

    /// Rename a window. The attached session's tab title follows via the
    /// %window-renamed reconcile (set_tab_title); the reply only confirms.
    /// Note tmux disables automatic-rename for the window, as any manual
    /// rename does.
    func renameWindow(id windowId: Int, to name: String) async throws {
        // ROOTSHELL-TMUX (id=tmux-quote-c0)
        guard TmuxControlModeParser.isValidTmuxName(name) else {
            throw TmuxCommandError.invalidName
        }
        _ = try await sendCommandWithReply(
            "rename-window -t @\(windowId) \(TmuxControlModeParser.quote(name))")
        noteSessionsChanged()
    }

    /// Kill a window in any session. Killing the attached session's LAST
    /// window ends the session — the caller is responsible for confirming
    /// and for tolerating `.gatewayEnded` (the detach can outrun the reply),
    /// mirroring killSession.
    func killWindow(id windowId: Int) async throws {
        _ = try await sendCommandWithReply("kill-window -t @\(windowId)")
        noteSessionsChanged()
    }

    /// Move a window to another session, at the destination's first free
    /// index (a session-only "$N:" target picks the next unused index, which
    /// is append semantics without {end} arithmetic). Moving the attached
    /// session's last window ends the session, same caveat as killWindow.
    func moveWindow(id windowId: Int, toSession sessionId: Int) async throws {
        _ = try await sendCommandWithReply(
            "move-window -s @\(windowId) -t \"$\(sessionId):\"")
        noteSessionsChanged()
    }

    /// Link a window into another session (the window then exists in both;
    /// #{window_linked} flips on). A duplicate link surfaces as
    /// `.serverError` ("window already linked...").
    func linkWindow(id windowId: Int, toSession sessionId: Int) async throws {
        _ = try await sendCommandWithReply(
            "link-window -s @\(windowId) -t \"$\(sessionId):\"")
        noteSessionsChanged()
    }

    /// Unlink a window from the session it's reached through. Only offered
    /// when the window is linked into 2+ sessions (isLinked), so it can never
    /// fail with "only linked to one session"; destruction is killWindow's
    /// job (no -k here).
    func unlinkWindow(id windowId: Int) async throws {
        _ = try await sendCommandWithReply("unlink-window -t @\(windowId)")
        noteSessionsChanged()
    }
}
