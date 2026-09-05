//
//  TmuxController+Sessions.swift
//  shell
//
//  Session dashboard support for tmux control mode: an async command/reply
//  layer over ghostty_surface_tmux_command_with_reply, plus the session
//  operations (list / switch / create / rename / kill / detach) the dashboard drives.
//
//  One control client shows ONE session at a time (tmux gates %output on the
//  client's attached session), so "switching" re-attaches this gateway's
//  client (`attach-session -t`); the core viewer rebuilds and the reconcile
//  replaces every window tab in one batch. Showing two sessions at once
//  requires a second gateway tab (its own `tmux -CC` client).
//

import Foundation

extension Notification.Name {
    /// Posted (object: the gateway's owner terminal UUID) when the tmux server's
    /// session list may have changed (%sessions-changed, other-client churn,
    /// or a local create/rename/kill). The dashboard refreshes on it.
    static let tmuxSessionsDidChange = Notification.Name("tmuxSessionsDidChange")
    /// Posted (object: the gateway's owner terminal UUID) when this gateway's
    /// attached session identity changed (attach / switch / rename).
    static let tmuxAttachedSessionDidChange = Notification.Name("tmuxAttachedSessionDidChange")
    /// Posted (object: the gateway's owner terminal UUID) when this gateway's
    /// control-mode client has ended and the gateway is back at its shell.
    static let tmuxControlModeDidEnd = Notification.Name("tmuxControlModeDidEnd")
}

extension TmuxController {
    // MARK: - Reply layer

    /// Queries the canonical server identity used by push routes. Every -CC
    /// client on every shell device receives the same value for the same
    /// tmux server lifetime. A restart changes pid/start-time, preventing a
    /// stale notification from matching a reused pane ID.
    func refreshPushRouteServerIdentity() {
        guard pushRouteServerIdentity == nil,
              pushRouteServerIdentityTask == nil,
              !didEnd, !isDetaching, !ownerSurfaceFreed else { return }
        pushRouteServerIdentityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pushRouteServerIdentityTask = nil }
            guard self.pushRouteServerIdentity == nil else { return }
            for attempt in 1...3 {
                guard !Task.isCancelled,
                      !self.didEnd, !self.isDetaching, !self.ownerSurfaceFreed else { return }
                if let body = try? await self.sendCommandWithReply(
                    "display-message -p \"#{host}:#{socket_path},#{pid},#{start_time}\"",
                    timeout: .seconds(4)
                ) {
                    let identity = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !identity.isEmpty {
                        self.pushRouteServerIdentity = identity
                        NotificationCenter.default.post(name: .tmuxPaneBindingsChanged, object: nil)
                        return
                    }
                }
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    /// Send a tmux command through the gateway's FIFO command channel and
    /// await its response body. Throws `TmuxCommandError.serverError` when
    /// tmux answers `%error`, `.gatewayEnded` when the query was dropped by a
    /// viewer reset/teardown before tmux answered, and `.timeout` as the
    /// final backstop.
    func sendCommandWithReply(
        _ cmd: String,
        timeout: Duration = .seconds(8)
    ) async throws -> String {
        // ownerSurfaceFreed: the gateway view freed ownerSurface (tab/scene
        // teardown) without ever setting didEnd, so sendRawCommandWithReply's
        // ghostty_surface_tmux_command_with_reply would be a use-after-free.
        // A surviving dashboard/task is the path that reaches here post-free.
        // ROOTSHELL-TMUX (id=tmux-gateway-surface-freed)
        guard !didEnd, !isDetaching, !ownerSurfaceFreed else { throw TmuxCommandError.gatewayEnded }
        let tag = nextReplyTag
        // Skip 0 on wraparound so a tag is always nonzero.
        nextReplyTag = nextReplyTag == UInt32.max ? 1 : nextReplyTag + 1


        let reply: TmuxCommandReply = try await withCheckedThrowingContinuation { continuation in
            pendingReplies[tag] = continuation
            replyTimeouts[tag] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, !Task.isCancelled else { return }
                if let pending = self.pendingReplies.removeValue(forKey: tag) {
                    self.replyTimeouts.removeValue(forKey: tag)
                    pending.resume(throwing: TmuxCommandError.timeout)
                }
            }
            sendRawCommandWithReply(cmd, tag: tag)
        }

        if reply.isError {
            // An empty error body means the query was dropped before tmux
            // answered (viewer reset / teardown / no viewer), not a tmux error.
            if reply.body.isEmpty { throw TmuxCommandError.gatewayEnded }
            throw TmuxCommandError.serverError(
                reply.body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return reply.body
    }

    private func sendRawCommandWithReply(_ cmd: String, tag: UInt32) {
        var data = Data(cmd.utf8)
        if data.last != UInt8(ascii: "\n") { data.append(UInt8(ascii: "\n")) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_surface_tmux_command_with_reply(
                gatewaySurfaceForCommands,
                base.assumingMemoryBound(to: CChar.self),
                UInt(data.count),
                tag)
        }
    }

    /// Deliver a GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE to its waiting request.
    /// Unknown tags (timed-out requests answering late) are dropped.
    func handleCommandReply(_ reply: TmuxCommandReply) {
        replyTimeouts.removeValue(forKey: reply.tag)?.cancel()
        guard let continuation = pendingReplies.removeValue(forKey: reply.tag) else {
            return
        }
        continuation.resume(returning: reply)
    }

    /// Fail every pending request. Called when control mode ends (the core
    /// also errors pending queries back on its reset paths; this covers the
    /// Swift-side teardown ordering).
    func failAllPendingReplies(_ error: TmuxCommandError) {
        let pending = pendingReplies
        pendingReplies.removeAll()
        for task in replyTimeouts.values { task.cancel() }
        replyTimeouts.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Attached-session identity

    /// GHOSTTY_ACTION_TMUX_SESSION_CHANGED: the session this gateway is
    /// attached to (startup, switch, or rename). Persists the name for
    /// reconnect-by-name and nudges the dashboard.
    func updateCurrentSession(id: Int, name: String) {
        let changed = currentSessionId != id || currentSessionName != name
        let sessionIdentityChanged = currentSessionId != id
        currentSessionId = id
        currentSessionName = name
        if let connectionKey {
            TmuxGatewaySessionStore.setLastSessionName(name, forConnection: connectionKey)
        }
        // The hidden-window set is per-session: reload on attach/switch (a
        // mere rename keeps the set). Mirror applies synchronously; the
        // `show @hidden` reply converges. (id=tmux-hidden-windows)
        if sessionIdentityChanged {
            reloadHiddenWindows(forSessionId: id)
        }
        if changed {
            // Mirror onto the gateway tab so the sidebar's gateway header
            // re-renders; TmuxController is not observable. `ownedGatewayTab`
            // (not `resolvedGatewayTab`) so this can never land on ANOTHER
            // gateway's tab before ours is marked — markGatewayTab seeds it
            // in that case.
            ownedGatewayTab()?.tmuxSessionName = name
            NotificationCenter.default.post(
                name: .tmuxAttachedSessionDidChange,
                object: ownerTerminalUUIDForNotifications)
        }
    }

    /// GHOSTTY_ACTION_TMUX_SESSIONS_CHANGED: server session list churn.
    func noteSessionsChanged() {
        NotificationCenter.default.post(
            name: .tmuxSessionsDidChange,
            object: ownerTerminalUUIDForNotifications)
    }

    // MARK: - Session operations

    func listSessions() async throws -> [TmuxControlSession] {
        let body = try await sendCommandWithReply(
            "list-sessions -F \"\(TmuxControlModeParser.listSessionsFormat)\"")
        let sessions = TmuxControlModeParser.parseSessions(body)
        cachedSessions = sessions
        return sessions
    }

    /// Fire-and-forget cache warm-up so context-menu session pickers (built
    /// by synchronous ViewBuilders) have a fresh `cachedSessions` to read.
    func refreshSessionsCache() {
        Task { @MainActor [weak self] in
            _ = try? await self?.listSessions()
        }
    }

    func listWindows(sessionId: Int) async throws -> [TmuxControlWindow] {
        let body = try await sendCommandWithReply(
            "list-windows -t \"$\(sessionId)\" -F \"\(TmuxControlModeParser.listWindowsFormat)\"")
        return TmuxControlModeParser.parseWindows(body)
    }

    /// Capture the active pane of a tmux window for dashboard previews. This
    /// matches the connect-time discovery preview path (`capture-pane -p -e`):
    /// tmux emits ANSI styling, the Swift preview surface renders it read-only.
    func captureWindowPreview(windowId: Int) async throws -> String? {
        let body = try await sendCommandWithReply(
            "capture-pane -t \"@\(windowId)\" -p -e",
            timeout: .seconds(4)
        )
        let trimmed = body.replacingOccurrences(
            of: "\\s+$",
            with: "",
            options: .regularExpression
        )
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Working directory of every pane on this gateway's server, keyed by
    /// pane id (`TmuxPaneBinding.paneId`).
    ///
    /// One round trip answers for ALL panes, so a gateway hosting a dozen
    /// agents costs exactly the same as one hosting a single agent. tmux
    /// derives `pane_current_path` from the process itself, so this needs no
    /// shell integration on the remote host — it is the only directory source
    /// that works on a stock box. (id=agent-project)
    func paneWorkingDirectories() async throws -> [Int: String] {
        let body = try await sendCommandWithReply(
            "list-panes -a -F \"#{pane_id} #{pane_current_path}\"",
            timeout: .seconds(4)
        )

        return TmuxPanePathParser.parse(body)
    }

    /// Title and foreground command for every pane visible to this tmux
    /// server. One query refreshes all projected pane labels.
    func paneDisplayIdentities() async throws -> [Int: TmuxPaneDisplayIdentity] {
        let body = try await sendCommandWithReply(
            "list-panes -a -F \"#{pane_id}\t#{pane_title}\t#{pane_current_command}\"",
            timeout: .seconds(4)
        )
        return TmuxPaneDisplayIdentityParser.parse(body)
    }

    /// Re-attach this gateway's control client to another session. The switch
    /// itself is driven by the core: tmux answers, then sends
    /// %session-changed, the viewer rebuilds, and the reconcile replaces all
    /// window tabs in one batch (old windows pruned, new ones ensured).
    func switchToSession(id: Int, selectingWindowId windowId: Int? = nil) async throws {
        if id == currentSessionId {
            if let windowId {
                _ = selectWindowTab(windowId: windowId)
            }
            return
        }
        noteSessionSwitchRequest(selectingWindowId: windowId)
        do {
            _ = try await sendCommandWithReply("attach-session -t \"$\(id)\"")
        } catch TmuxCommandError.gatewayEnded {
            // The switch's own viewer rebuild can drop the reply before tmux
            // answers (notification-first ordering). That IS the success path;
            // the SESSION_CHANGED action carries the real outcome.
        }
    }

    /// Create a session (detached) and optionally switch to it. Uses `-PF` so
    /// the new session's id comes back in the reply (one round trip);
    /// duplicate names surface as `.serverError` ("duplicate session: x").
    func createSession(named name: String, andSwitch: Bool = true) async throws {
        // A pasted multi-line name would otherwise smuggle a second tmux
        // command past quote(). ROOTSHELL-TMUX (id=tmux-quote-c0)
        guard TmuxControlModeParser.isValidTmuxName(name) else {
            throw TmuxCommandError.invalidName
        }
        let body = try await sendCommandWithReply(
            "new-session -d -s \(TmuxControlModeParser.quote(name)) -PF \"#{session_id}\"")
        noteSessionsChanged()
        guard andSwitch, let id = TmuxControlModeParser.parseSessionId(body) else { return }
        try await switchToSession(id: id)
    }

    func renameSession(id: Int, to name: String) async throws {
        // ROOTSHELL-TMUX (id=tmux-quote-c0)
        guard TmuxControlModeParser.isValidTmuxName(name) else {
            throw TmuxCommandError.invalidName
        }
        _ = try await sendCommandWithReply(
            "rename-session -t \"$\(id)\" \(TmuxControlModeParser.quote(name))")
        noteSessionsChanged()
        if id == currentSessionId {
            updateCurrentSession(id: id, name: name)
        }
    }

    /// Kill a session. Killing the CURRENTLY attached session while other
    /// sessions exist pre-switches to `fallback` first, so the gateway hops
    /// instead of dropping to a dead shell. Killing the last session is the
    /// caller's explicit choice (confirmed in the dashboard UI): tmux exits,
    /// %exit tears control mode down, and the gateway returns to its shell.
    func killSession(id: Int, fallback: Int? = nil) async throws {
        if id == currentSessionId, let fallback, fallback != id {
            try await switchToSession(id: fallback)
        }
        do {
            _ = try await sendCommandWithReply("kill-session -t \"$\(id)\"")
        } catch TmuxCommandError.gatewayEnded {
            // Killing the attached session detaches this client before the
            // reply block can arrive. Expected; %exit drives the teardown.
        }
        noteSessionsChanged()
    }

    /// Gracefully detach this dashboard's gateway control client. This is the
    /// same FIFO-safe path used by ESC on the gateway: tmux keeps the session
    /// alive, control mode exits, and the gateway tab returns to its shell.
    func detachGatewayClient() {
        requestGracefulDetach(source: "dashboard")
    }

    /// Detach every OTHER client attached to the tmux server, keeping THIS
    /// gateway attached. `detach-client -a` skips the command's own control
    /// client (tmux `cmd-detach-client.c` skips `cloop == c`), so we stay
    /// connected and there is no teardown — unlike `requestGracefulDetach`.
    /// Useful when a small-screen client was left attached and is clamping
    /// the shared window size down for everyone (tmux resize.c semantics).
    func detachOtherClients() async throws {
        _ = try await sendCommandWithReply("detach-client -a")
    }

    /// Count of clients OTHER than us currently attached anywhere on the
    /// server, derived from cached `list-sessions` data. Exactly one attached
    /// client is always this gateway, so subtract it. Used to gate the
    /// "Detach Other Clients" UI. Reads `cachedSessions`, warmed by
    /// `refreshSessionsCache()` (same source the move-to-session picker uses).
    var otherAttachedClientCount: Int {
        max(0, cachedSessions.reduce(0) { $0 + $1.attachedClients } - 1)
    }
}
