//
//  TmuxController+HiddenWindows.swift
//  shell
//
//  Hide a tmux window without killing it. Hidden state is UI-level: the
//  window stays alive on the server and the reconcile keeps updating its tab
//  (title, layout, panes at opacity 0 — the cost of an unselected tab); the
//  tab strip, sidebar, and tab navigation just skip it. The set persists in
//  the session's `@hidden` user option (see TmuxHiddenWindowsCodec for the
//  cross-client wire format) and is reloaded on every attach/session switch.
//
//  Note tmux emits NO notification when a user option changes, so a second
//  control-mode client of the same session sees a hidden-set change only at
//  its next attach. (id=tmux-hidden-windows)
//

import Foundation

extension TmuxController {
    func isWindowHidden(_ windowId: Int) -> Bool {
        hiddenWindowIds.contains(windowId)
    }

    /// Hide a projected window: flag its tab, move selection to the nearest
    /// visible neighbor if it was the selected one, and persist. The window
    /// keeps running on the server. Returns true when it actually hid the
    /// window; false on a no-op (controller inactive/ended, no such window, or
    /// already hidden) so callers can choose a real fallback rather than treat
    /// a silent no-op as a completed action. (id=tmux-tab-close-action)
    @discardableResult
    func hideWindow(windowId: Int) -> Bool {
        guard isActive, !didEnd,
              let tab = windowTab(forWindowId: windowId),
              !hiddenWindowIds.contains(windowId) else { return false }
        hiddenWindowIds.insert(windowId)
        tab.isHiddenTmuxWindow = true
        moveSelectionOffTab(tab.id)
        // Hiding the last visible window while the gateway tab is hidden too:
        // moveSelectionOffTab only recovers when this tab was the SELECTED
        // one (its selectGatewayTab fallback auto-unhides); enforce the
        // invariant for the unselected case. (id=tmux-hidden-gateway)
        enforceGatewayVisibleWhenGroupHidden()
        persistHiddenWindowsToServer()
        saveHiddenMirror()
        return true
    }

    /// Restore a hidden window: clear the flag, re-arm its size pushes (they
    /// were suppressed while hidden and other clients may have resized the
    /// server window meanwhile), optionally select it, and persist.
    func showWindow(windowId: Int, andSelect: Bool = true) {
        guard hiddenWindowIds.remove(windowId) != nil else { return }
        windowTab(forWindowId: windowId)?.isHiddenTmuxWindow = false
        reArmWindowSize(windowId: windowId)
        resyncPaneSizes(windowId: windowId)
        if andSelect {
            selectWindowTab(windowId: windowId)
        }
        persistHiddenWindowsToServer()
        saveHiddenMirror()
    }

    /// Load the attached session's hidden set: the local mirror applies
    /// synchronously (no flash for locally-known hidden windows while the
    /// authoritative reply is in flight), then `show ... @hidden` converges.
    /// Called when the attached session's identity changes (attach/switch).
    func reloadHiddenWindows(forSessionId sessionId: Int) {
        if let connectionKey {
            let mirrored = TmuxHiddenWindowsStore.load(
                connectionKey: connectionKey, sessionId: sessionId)
            applyHiddenSet(mirrored)
        } else if !hiddenWindowIds.isEmpty {
            // No mirror identity (local gateway): clear the previous
            // session's set until the server answers.
            applyHiddenSet([])
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let body: String
            do {
                body = try await self.sendCommandWithReply(
                    "show -v -q -t \"$\(sessionId)\" @hidden")
            } catch {
                // Timeout / gateway ended: keep the mirror-seeded set.
                return
            }
            // The session may have switched again while the query was in
            // flight; a stale reply must not clobber the new session's set.
            guard self.currentSessionId == sessionId else { return }
            self.applyHiddenSet(TmuxHiddenWindowsCodec.decode(body))
            self.saveHiddenMirror()
        }
    }

    /// Replace the in-memory hidden set and re-derive every projected tab's
    /// flag. Selection is repaired if it pointed at a now-hidden tab.
    private func applyHiddenSet(_ ids: Set<Int>) {
        hiddenWindowIds = ids
        applyHiddenFlagsToWindowTabs()
        // Another client's @hidden may converge to "all windows hidden" while
        // this client's gateway tab is hidden. (id=tmux-hidden-gateway)
        enforceGatewayVisibleWhenGroupHidden()
        ensureSelectionVisible()
    }

    /// Persist the hidden set as the session's `@hidden` option. Fire and
    /// forget: the write is idempotent latest-wins, and a lost write heals on
    /// the next mutation. Also called by the prune path when another client
    /// kills a hidden window (internal, not private, for that).
    func persistHiddenWindowsToServer() {
        // ownerSurfaceFreed guards the gatewaySurfaceForCommands deref below
        // against the post-teardown UAF that doesn't set didEnd. ROOTSHELL-TMUX
        // (id=tmux-gateway-surface-freed)
        guard !didEnd, !isDetaching, !ownerSurfaceFreed, let sessionId = currentSessionId else { return }
        let value = TmuxHiddenWindowsCodec.encode(hiddenWindowIds)
        let cmd = "set -t \"$\(sessionId)\" @hidden \"\(value)\"\n"
        let data = Data(cmd.utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ghostty_surface_tmux_command(
                gatewaySurfaceForCommands,
                base.assumingMemoryBound(to: CChar.self),
                UInt(data.count))
        }
    }

    /// Mirror the current set locally for instant apply on the next attach.
    /// Also called by the prune path (internal, not private).
    func saveHiddenMirror() {
        guard let connectionKey, let sessionId = currentSessionId else { return }
        TmuxHiddenWindowsStore.save(
            hiddenWindowIds, connectionKey: connectionKey, sessionId: sessionId)
    }

    // MARK: - Gateway tab (id=tmux-hidden-gateway)
    //
    // The gateway tab can be hidden too, riding the same per-tab flag (so all
    // strip/sidebar/navigation filtering applies unchanged) — but its hidden
    // state is CLIENT-LOCAL: every control-mode client has its own gateway
    // tab, so nothing is written to the server's `@hidden` option (whose
    // window-id wire format must stay interoperable) or the UserDefaults
    // mirror. Persistence rides the window-state JSON instead (see
    // MainViewPersistence and TabModel.pendingHiddenTmuxGatewayRestore).
    // Invariant: a hidden gateway always has ≥1 VISIBLE window tab in its
    // group, so the group can never become fully unreachable.

    /// Whether "Hide Gateway Tab" should be offered right now.
    var canHideGatewayTab: Bool {
        isActive && !didEnd && hasVisibleWindowTabs
            && resolvedGatewayTab()?.isHiddenTmuxWindow == false
    }

    /// Hide this controller's gateway tab: flag it, move selection to the
    /// nearest visible neighbor if it was the selected one. UI-level and
    /// client-local; the control client keeps running.
    func hideGatewayTab() {
        guard isActive, !didEnd,
              let tab = resolvedGatewayTab(),
              !tab.isHiddenTmuxWindow,
              hasVisibleWindowTabs else { return }
        tab.isHiddenTmuxWindow = true
        moveSelectionOffTab(tab.id)
    }

    /// Restore a hidden gateway tab, optionally selecting it.
    func showGatewayTab(andSelect: Bool = true) {
        guard let tab = resolvedGatewayTab(), tab.isHiddenTmuxWindow else { return }
        tab.isHiddenTmuxWindow = false
        if andSelect { selectTab(tab.id) }
    }

    /// Heal the hidden-gateway invariant after a path that may have hidden or
    /// killed the group's last visible window (hideWindow on an unselected
    /// tab, another client's @hidden converging, a prune). Un-hides WITHOUT
    /// selecting — the caller's selection logic stays in charge.
    func enforceGatewayVisibleWhenGroupHidden() {
        guard let tab = resolvedGatewayTab(), tab.isHiddenTmuxWindow,
              !hasVisibleWindowTabs else { return }
        tab.isHiddenTmuxWindow = false
    }
}
