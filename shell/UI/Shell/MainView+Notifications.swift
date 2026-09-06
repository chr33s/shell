//
//  MainView+Notifications.swift
//  shell
//
//  Notification observers for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import GhosttyKit
import os
import UIKit

// MARK: - Observer Token Bag

/// Holds the opaque tokens returned by NotificationCenter's block-based
/// `addObserver(forName:object:queue:using:)` API so they can be removed on
/// view teardown. Previous code dropped those tokens and called
/// `NotificationCenter.default.removeObserver(self)` from `handleOnDisappear`,
/// which only matches the legacy selector-based API path — block-based
/// observers leaked. iPhone backgrounding evicts the scene UI aggressively;
/// each `onAppear`/`onDisappear` cycle stacked another full set of 32
/// observers without removing the previous set, so notifications fired N
/// times against captured-but-disconnected `MainView` state. Symptom: after
/// a few background bounces, taps and other commands appeared to do nothing
/// (they were running on torn-down `@State` storage).
final class MainViewObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func track(_ token: NSObjectProtocol) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let toRemove = tokens
        tokens.removeAll()
        lock.unlock()
        let center = NotificationCenter.default
        for token in toRemove {
            center.removeObserver(token)
        }
    }

    deinit {
        // Safety net: NotificationCenter retains the closure (and thus any
        // captured state) until the token is removed. Always remove on dealloc
        // even if `removeAll()` was already called (idempotent).
        lock.lock()
        let toRemove = tokens
        tokens.removeAll()
        lock.unlock()
        let center = NotificationCenter.default
        for token in toRemove {
            center.removeObserver(token)
        }
    }

    /// Convenience wrapper around `NotificationCenter.default.addObserver(forName:...)`
    /// that records the returned token for later removal. The bag always
    /// removes from `.default` on cleanup, so we don't accept an alternate
    /// center — that would silently leak.
    func observe(
        _ name: Notification.Name,
        queue: OperationQueue? = .main,
        using block: @escaping @Sendable (Notification) -> Void
    ) {
        track(NotificationCenter.default.addObserver(forName: name, object: nil, queue: queue, using: block))
    }

    func observeOnMainActor(
        _ name: Notification.Name,
        using block: @escaping @MainActor @Sendable (Notification) -> Void
    ) {
        observe(name, queue: .main) { notification in
            MainActor.assumeIsolated {
                block(notification)
            }
        }
    }
}

// MARK: - Notification Observers

extension MainView {
    /// Open Settings. The companion close is just `showSettings = false`; both
    /// drive the binding-based `SidePanelOverlay` directly, so there is no gate
    /// and no deferred flip — the toggle is instant, like the tab sidebar.
    func requestSettingsPresentation(destination: SettingsDestination? = nil) {
        #if targetEnvironment(macCatalyst)
        // Settings is its own window on the Mac, not an in-window overlay.
        MacSettingsWindow.show(destination: destination)
        #else
        if showConnectionSidebar {
            showConnectionSidebar = false
        }

        guard !showSettings else { return }
        if let destination {
            settingsDestination = destination
        }

        showSettings = true
        #endif
    }

    func setupNotificationObservers() {
        // Idempotent: SwiftUI does not guarantee `onAppear` fires only once
        // per live view identity (e.g., back-to-back transitions can re-fire
        // it without an intervening `onDisappear`). Drain the bag before
        // re-registering so a second call doesn't double up handlers.
        observerBag.removeAll()

        #if !targetEnvironment(macCatalyst)
        observerBag.observeOnMainActor(UIScene.didDisconnectNotification) { [self] notification in
            self.handleSceneDisconnectNotification(notification)
        }
        #endif

        observerBag.observeOnMainActor(.createSplit) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            guard let direction = notification.userInfo?["direction"] as? String else { return }
            let splitDirection: SplitTree<SplitPaneView>.NewDirection
            switch direction {
            case "left": splitDirection = .left
            case "right": splitDirection = .right
            case "up": splitDirection = .up
            case "down": splitDirection = .down
            default: return
            }
            self.createSplit(direction: splitDirection)
        }

        observerBag.observeOnMainActor(.navigateSplit) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            guard let direction = notification.userInfo?["direction"] as? String else { return }
            let focusDirection: SplitTree<SplitPaneView>.FocusDirection
            switch direction {
            case "left": focusDirection = .spatial(.left)
            case "right": focusDirection = .spatial(.right)
            case "up": focusDirection = .spatial(.up)
            case "down": focusDirection = .spatial(.down)
            default: return
            }
            self.navigateSplit(direction: focusDirection)
        }

        observerBag.observeOnMainActor(.closeSplit) { [self] notification in
            Ghostty.logger.info("closeSplit notification received by window \(self.windowId)")
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else {
                Ghostty.logger.info("closeSplit: notification doesn't belong to this window")
                return
            }

            // Route by the posted pane when present so async session-end
            // events close the dying tab, not whichever tab the user has since
            // switched to. nil object → fall back to the focused split.
            let target = notification.object as? SplitPaneView
            self.closeSplit(targeting: target)
        }

        observerBag.observeOnMainActor(.toggleSplitZoom) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            self.toggleSplitZoom()
        }

        observerBag.observeOnMainActor(.equalizeSplits) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            self.equalizeSplits()
        }

        observerBag.observeOnMainActor(.focusSplit) { [self] notification in
            guard let paneView = notification.object as? SplitPaneView else { return }
            guard terminals.indices.contains(selectedTabIndex) else { return }

            // Update focused pane if it belongs to current tab
            if terminals[selectedTabIndex].splitTree.contains(paneView) {
                setFocusedPane(paneView, inTab: selectedTabIndex)
            }
        }

        // Tab management observers
        observerBag.observeOnMainActor(.newTab) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }

            self.addNewTab()
        }

        observerBag.observeOnMainActor(.newWindow) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }

            Ghostty.logger.info("newWindow: opening new window from window \(self.windowId)")
            #if targetEnvironment(macCatalyst)
            // Use requestSceneSessionActivation to ensure our scene delegate is used
            // This allows us to set the initial window size properly
            UIApplication.shared.requestSceneSessionActivation(
                nil,
                userActivity: nil,
                options: nil,
                errorHandler: { error in
                    Ghostty.logger.error("Failed to create new window: \(error.localizedDescription)")
                }
            )
            #else
            self.openWindow(id: "main-terminal")
            #endif
        }

        observerBag.observeOnMainActor(.previousTab) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            self.previousTab()
        }

        observerBag.observeOnMainActor(.nextTab) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            self.nextTab()
        }

        observerBag.observeOnMainActor(.previousGroup) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            self.previousGroup()
        }

        observerBag.observeOnMainActor(.nextGroup) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            self.nextGroup()
        }

        observerBag.observe(.appTabSwipeBegan, queue: nil) { [self] notification in
            MainActor.assumeIsolated {
                guard self.shouldHandleNotification(notification) else {
                    if let accept = notification.userInfo?["accept"] as? (Bool) -> Void {
                        accept(false)
                    }
                    return
                }
                self.handleAppTabSwipeBegan(notification)
            }
        }

        observerBag.observe(.appTabSwipeChanged, queue: nil) { [self] notification in
            MainActor.assumeIsolated {
                guard self.shouldHandleNotification(notification) else { return }
                self.handleAppTabSwipeChanged(notification)
            }
        }

        observerBag.observe(.appTabSwipeEnded, queue: nil) { [self] notification in
            MainActor.assumeIsolated {
                guard self.shouldHandleNotification(notification) else { return }
                self.handleAppTabSwipeEnded(notification)
            }
        }

        observerBag.observeOnMainActor(.selectTab) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            guard let tabIndex = notification.userInfo?["tabIndex"] as? Int else { return }
            self.selectTab(at: tabIndex)
        }

        observerBag.observeOnMainActor(.showTmuxSessions) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.showTmuxSessionsForSelectedTab()
        }

        observerBag.observeOnMainActor(.detachOtherClients) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.detachOtherClientsForSelectedTab()
        }

        observerBag.observeOnMainActor(.increaseFontSize) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            guard terminals.indices.contains(selectedTabIndex),
                  let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
                  focusedTerminal.surface != nil
            else { return }
            Ghostty.logger.info("Increasing font size for focused terminal")
            if focusedTerminal.applyTmuxWindowFontSize(delta: 1) { return }
            focusedTerminal.changeLocalFontSize(delta: 1)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                focusedTerminal.updatePTYSize()
            }
        }

        observerBag.observeOnMainActor(.decreaseFontSize) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            guard terminals.indices.contains(selectedTabIndex),
                  let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
                  focusedTerminal.surface != nil
            else { return }
            Ghostty.logger.info("Decreasing font size for focused terminal")
            if focusedTerminal.applyTmuxWindowFontSize(delta: -1) { return }
            focusedTerminal.changeLocalFontSize(delta: -1)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                focusedTerminal.updatePTYSize()
            }
        }

        observerBag.observeOnMainActor(.resetFontSize) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            guard terminals.indices.contains(selectedTabIndex),
                  let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
                  focusedTerminal.surface != nil
            else { return }
            Ghostty.logger.info("Resetting font size for focused terminal")
            if focusedTerminal.resetTmuxWindowFontSize() { return }
            focusedTerminal.resetLocalFontSize()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                focusedTerminal.updatePTYSize()
            }
        }

        observerBag.observeOnMainActor(.startSearch) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            guard terminals.indices.contains(selectedTabIndex),
                  let focusedTerminal = terminals[selectedTabIndex].focusedTerminal
            else { return }
            focusedTerminal.performActionAsync("start_search")
        }

        observerBag.observeOnMainActor(.openSettings) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            // Immediate toggle (open AND close), mirroring the tab sidebar's
            // CMD-shift-\: the binding-driven SidePanelOverlay animates either
            // way, so flip it directly.
            if self.showSettings {
                self.showSettings = false
            } else {
                self.requestSettingsPresentation()
            }
        }

        observerBag.observeOnMainActor(.duplicateTabWithSSH) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            self.duplicateCurrentTabWithSSH()
        }

        observerBag.observeOnMainActor(.createLocalShell) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            // Default: new local-shell tab. In a tmux -CC context the configured
            // New Tab Action may open a tmux window or prompt. (id=tmux-new-tab-action)
            self.handleNewTabCommand()
        }

        observerBag.observeOnMainActor(.sshURLReceived) { [self] notification in
            guard let payload = notification.userInfo?[SSHURLPayload.key] as? SSHURLPayload else { return }
            // Catalyst addresses the open to one window; without this every open
            // window would connect to the same host. An untargeted post (iOS,
            // single window) is still handled here.
            if let target = notification.userInfo?[GhosttyCommandRouting.windowSceneSessionIDKey] as? String,
               target != self.windowSceneSessionID { return }
            if self.showSettings { self.showSettings = false }
            self.handleSSHURL(payload.components)
        }

        observerBag.observeOnMainActor(.browseHosts) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            if self.showSettings { self.showSettings = false }
            self.connectionSidebarInitialTab = .newHost
            self.showConnectionSidebar = true
        }

        observerBag.observeOnMainActor(.browseProfiles) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            if self.showSettings { self.showSettings = false }
            self.connectionSidebarInitialTab = .profiles
            self.showConnectionSidebar = true
        }

        observerBag.observeOnMainActor(.moveTabToNewWindow) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            guard let tab = self.tabsModel.selectedTab else { return }
            self.moveTabToNewWindow(tab)
        }

        observerBag.observeOnMainActor(.mergeAllWindows) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.mergeAllWindows()
        }

        observerBag.observeOnMainActor(.openRecentProfile) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            guard let rawID = notification.userInfo?["profileID"] as? String,
                  let id = UUID(uuidString: rawID),
                  let profile = ConnectionProfileManager.shared.profile(for: id) else { return }
            self.connectToProfile(profile, splitOption: .newTab)
        }

        observerBag.observeOnMainActor(.ghosttySearchStateChanged) { [self] notification in
            // Handle both UIKeyCommand (with terminal) and SwiftUI Commands (nil object)
            guard self.shouldHandleNotification(notification) else { return }
            // Increment version to force SwiftUI re-render
            self.searchStateVersion += 1
        }

        observerBag.observeOnMainActor(.ghosttyComposeStateChanged) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.composeStateVersion += 1
        }

        observerBag.observeOnMainActor(.bellTriggered) { [self] notification in
            guard let terminalView = notification.object as? Ghostty.TerminalView else { return }

            // Find which tab contains this terminal and trigger wiggle
            for tab in self.terminals {
                if tab.splitTree.contains(terminalView) {
                    self.triggerWiggle(forTabId: tab.id)
                    break
                }
            }
        }

        observerBag.observeOnMainActor(.showToolbarSettings) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            self.showToolbarSettings = true
        }

        // SSH connection-health settings, applied to already-running sessions.
        // `SettingsStore.emit` posts `.settingsDidChange` once per batch for
        // every origin (a local write from Settings, an iCloud merge, the text
        // config overlay), and the batch carries only the key names — so the
        // handlers re-read the current values from the store rather than
        // trusting a payload. Both rows in Settings are window-agnostic, so
        // this deliberately skips `shouldHandleNotification`: every open window
        // must retune its own sessions.
        observerBag.observeOnMainActor(.settingsDidChange) { [self] notification in
            guard let changed = notification.userInfo?[SettingsChange.userInfoKeys] as? [String] else { return }
            if changed.contains(Settings.Connections.healthMonitoring.name) {
                self.applySSHHealthMonitoringSetting()
            }
            if changed.contains(Settings.Connections.healthProbeInterval.name) {
                self.applySSHHealthProbeIntervalSetting()
            }
        }

        // Handle embedded session connection config changes (shell-launched SSH/Mosh/Trzsz)
        // This triggers a session count recount so LocationDiaryManager sees the new session
        observerBag.observeOnMainActor(.terminalConnectionConfigChanged) { [self] notification in
            guard self.shouldHandleNotification(notification) else { return }
            if let terminalView = notification.object as? Ghostty.TerminalView,
               let tabID = self.tabID(for: terminalView) {
                self.tabsModel.markGroupingInputsChanged(for: tabID)
            }
            self.notifySessionCountChanged()

        }
    }

    // MARK: - SSH Health Monitoring Live Apply

    /// Start or stop the probe loop on every live `CitadelSSHSession` in this
    /// window so the toggle takes effect without reconnecting.
    /// `startHealthMonitoringIfEnabled()` re-checks the setting itself and
    /// no-ops when a monitor already exists, so this is safe to run repeatedly.
    private func applySSHHealthMonitoringSetting() {
        let enabled = SettingsStore.shared.value(Settings.Connections.healthMonitoring)
        for tab in self.terminals {
            for terminalView in tab.splitTree.terminalLeaves {
                guard let citadelSession = terminalView.session as? CitadelSSHSession else { continue }
                if enabled {
                    citadelSession.startHealthMonitoringIfEnabled()
                } else {
                    citadelSession.stopHealthMonitoring()
                    // Clear the tab's mirrored health so the indicator doesn't
                    // freeze on the last RTT. Written through the `TabModel`
                    // reference rather than `terminals[i]`, which would round-trip
                    // the whole array through the shim's setter, and
                    // equality-guarded because an unconditional write to an
                    // @Observable property invalidates every view reading it.
                    if tab.connectionHealth != nil {
                        tab.connectionHealth = nil
                    }
                }
            }
        }
    }

    /// Re-time the probe loop on every live `CitadelSSHSession` in this window.
    /// `ConnectionHealthMonitor.updateInterval` ignores a no-op change, so an
    /// unrelated write in the same batch costs nothing.
    private func applySSHHealthProbeIntervalSetting() {
        let interval = TimeInterval(SettingsStore.shared.value(Settings.Connections.healthProbeInterval))
        for tab in self.terminals {
            for terminalView in tab.splitTree.terminalLeaves {
                guard let citadelSession = terminalView.session as? CitadelSSHSession else { continue }
                citadelSession.updateHealthProbeInterval(interval)
            }
        }
    }

    #if !targetEnvironment(macCatalyst)
    private func handleSceneDisconnectNotification(_ notification: Notification) {
        let disconnectedID = (notification.object as? UIScene)?.session.persistentIdentifier
        if let windowSceneSessionID {
            guard disconnectedID == windowSceneSessionID else { return }
        } else {
            // UIKit may report the disconnect before or after removing the
            // scene from connectedScenes; <= 1 covers both single-window
            // timings while avoiding cross-window cleanup.
            let connectedSceneCount = UIApplication.shared.connectedScenes.count
            guard connectedSceneCount <= 1 else { return }
        }

        performWindowCleanup(reason: "sceneDisconnect")
    }
    #endif
}

// MARK: - Window Filtering and Title Observation

extension MainView {

    // MARK: - Window Filtering Helper
    
    /// Check if a TerminalView belongs to this window
    private func belongsToThisWindow(_ pane: SplitPaneView?) -> Bool {
        guard let pane = pane else { return false }

        // Check if the pane exists in any of this window's tabs
        for terminal in terminals {
            if terminal.splitTree.contains(where: { $0 === pane }) {
                return true
            }
        }
        return false
    }
    
    /// Check if notification should be handled by this window
    /// Notifications may include a terminal object or a window scene identifier
    func shouldHandleNotification(_ notification: Notification) -> Bool {
        guard let pane = notification.object as? SplitPaneView else {
            // No terminal view in notification - check for scene ID targeting
            if let targetSceneID = notification.userInfo?[GhosttyCommandRouting.windowSceneSessionIDKey] as? String,
               let windowSceneSessionID,
               targetSceneID == windowSceneSessionID {
                return true
            }

            // On iPad/iPhone (single-window), accept notifications without explicit targeting
            // This handles the case when all tabs are closed and menu/keyboard shortcuts are used
            #if targetEnvironment(macCatalyst)
            // Count only scenes that host a MainView: the Settings window is a
            // UIWindowScene too, and counting it would make the sole terminal
            // window start refusing untargeted commands as soon as it opens.
            let connectedScenes = UIApplication.shared.connectedScenes
                .filter { CatalystSceneDelegate.isTerminalScene($0) }
            #else
            let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            #endif
            if connectedScenes.count <= 1 {
                return true
            }

            return false
        }
        return belongsToThisWindow(pane)
    }
    
    // MARK: - Title Observation
    //
    // Title and connection-health observation moved into `TabModel.startObserving()`
    // (see `Views/TabsModel.swift`). Each tab subscribes to its own focused
    // `Ghostty.TerminalView`'s `$title` and `$connectionHealth` and writes the
    // resolved values into its own `@Observable` properties — invalidation is
    // scoped per-tab instead of triggering a full `MainView` body recompute.
    //
    // The thin wrapper below keeps the existing call sites in
    // `MainViewTabManagement` and `MainViewPersistence` working: it just
    // forwards to the corresponding `TabModel.startObserving(...)` call.

    /// Set up title observation for the focused terminal in a tab.
    /// Forwards to `TabModel.startObserving()` so the per-tab subscription is
    /// owned by the tab model itself.
    func setupTitleObservation(at tabIndex: Int, preserveExistingTitle: Bool = false) {
        guard tabIndex < terminals.count else { return }
        terminals[tabIndex].startObserving(preserveExistingTitle: preserveExistingTitle)
    }
}
