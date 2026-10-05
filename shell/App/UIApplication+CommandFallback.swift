//
//  UIApplication+CommandFallback.swift
//  shell
//
//  Fallback command routing when TerminalView is not in the responder chain
//  (e.g., when all tabs are closed on iPad or Mac Catalyst)
//

import UIKit

extension UIApplication {

    /// Menu tracking on iPadOS 27 can leave the nil-target responder walk
    /// without a handler, even for selectors implemented by UIApplication.
    /// Keep first responders (including HUDs) first, then target the app
    /// explicitly. Never retry an action that the responder chain consumed.
    @discardableResult
    func sendMenuAction(_ action: Selector, from sender: Any? = nil) -> Bool {
        if sendAction(action, to: nil, from: sender, for: nil) { return true }
        guard responds(to: action) else { return false }
        return sendAction(action, to: self, from: sender, for: nil)
    }

    @MainActor
    private func swiftty_postNotification(_ name: Notification.Name, userInfo: [String: Any] = [:]) {
        var info = userInfo
        if let sceneID = swiftty_activeWindowSceneSessionID() {
            info[SwifttyCommandRouting.windowSceneSessionIDKey] = sceneID
        }
        NotificationCenter.default.post(name: name, object: nil, userInfo: info.isEmpty ? nil : info)
    }

    /// The scene an untargeted command is stamped for: the registry's key
    /// scene when it still exists, then the key window's scene, then any
    /// foreground one. Not private — the menu bar's checkable items resolve
    /// their state through the same call (see `MenuFocusState.activeTabs()`),
    /// so a checkmark cannot describe a different window than the one the
    /// command lands in.
    @MainActor
    func swiftty_activeWindowSceneSessionID() -> String? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        if let activeSceneId = WindowFocusRegistry.shared.activeSceneSessionId() {
            if scenes.contains(where: { $0.session.persistentIdentifier == activeSceneId }) {
                return activeSceneId
            } else {
                WindowFocusRegistry.shared.remove(sceneSessionId: activeSceneId)
            }
        }
        if let keyScene = scenes.first(where: { scene in
            scene.windows.contains { $0.isKeyWindow }
        }) {
            return keyScene.session.persistentIdentifier
        }
        return scenes.first { scene in
            scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
        }?.session.persistentIdentifier
    }

    @objc func menuToggleFullScreen(_ sender: Any?) {
        swiftty_postNotification(.toggleFullScreen)
    }

    // These actions need the selected pane even when it isn't first responder.
    // MainView resolves it inside the scene targeted by swiftty_postNotification.
    private func swiftty_postPaneCommand(_ command: SwifttyCommandRouting.PaneCommand) {
        swiftty_postNotification(SwifttyCommandRouting.paneCommandNotification,
                                 userInfo: [SwifttyCommandRouting.paneCommandKey: command])
    }

    @objc func menuClearScreen(_ sender: Any?) {
        swiftty_postPaneCommand(.clearScreen)
    }

    @objc func menuScrollPageUp(_ sender: Any?) {
        swiftty_postPaneCommand(.scrollPageUp)
    }

    @objc func menuScrollPageDown(_ sender: Any?) {
        swiftty_postPaneCommand(.scrollPageDown)
    }

    @objc func menuScrollToTop(_ sender: Any?) {
        swiftty_postPaneCommand(.scrollToTop)
    }

    @objc func menuScrollToBottom(_ sender: Any?) {
        swiftty_postPaneCommand(.scrollToBottom)
    }

    @objc func menuPreviousPrompt(_ sender: Any?) {
        swiftty_postPaneCommand(.previousPrompt)
    }

    @objc func menuNextPrompt(_ sender: Any?) {
        swiftty_postPaneCommand(.nextPrompt)
    }

    @objc func menuToggleCompose(_ sender: Any?) {
        swiftty_postPaneCommand(.toggleCompose)
    }

    @objc func menuToggleMouseCapture(_ sender: Any?) {
        swiftty_postPaneCommand(.toggleMouseCapture)
    }

    @objc func menuCycleInputSource(_ sender: Any?) {
        swiftty_postPaneCommand(.cycleInputSource)
    }

    // MARK: - Menu Actions (SwiftUI Commands)

    @objc func menuCreateLocalShell(_ sender: Any?) {
        swiftty_postNotification(.createLocalShell)
    }

    @objc func menuNewTab(_ sender: Any?) {
        swiftty_postNotification(.newTab)
    }

    @objc func menuNewWindow(_ sender: Any?) {
        swiftty_postNotification(.newWindow)
    }

    @objc func menuDuplicateTabWithSSH(_ sender: Any?) {
        swiftty_postNotification(.duplicateTabWithSSH)
    }

    @objc func menuSplitRight(_ sender: Any?) {
        swiftty_postNotification(.createSplit, userInfo: ["direction": "right"])
    }

    @objc func menuSplitDown(_ sender: Any?) {
        swiftty_postNotification(.createSplit, userInfo: ["direction": "down"])
    }

    @objc func menuNavigateSplitLeft(_ sender: Any?) {
        swiftty_postNotification(.navigateSplit, userInfo: ["direction": "left"])
    }

    @objc func menuNavigateSplitRight(_ sender: Any?) {
        swiftty_postNotification(.navigateSplit, userInfo: ["direction": "right"])
    }

    @objc func menuNavigateSplitUp(_ sender: Any?) {
        swiftty_postNotification(.navigateSplit, userInfo: ["direction": "up"])
    }

    @objc func menuNavigateSplitDown(_ sender: Any?) {
        swiftty_postNotification(.navigateSplit, userInfo: ["direction": "down"])
    }

    @objc func menuToggleSplitZoom(_ sender: Any?) {
        swiftty_postNotification(.toggleSplitZoom)
    }

    @objc func menuEqualizeSplits(_ sender: Any?) {
        swiftty_postNotification(.equalizeSplits)
    }

    @objc func menuOpenSettings(_ sender: Any?) {
        swiftty_postNotification(.openSettings)
    }

    @objc func menuBrowseHosts(_ sender: Any?) {
        swiftty_postNotification(.browseHosts)
    }

    @objc func menuBrowseProfiles(_ sender: Any?) {
        swiftty_postNotification(.browseProfiles)
    }

    /// Open one saved SSH profile in the focused window. `sender` carries the
    /// profile's id, since a plain selector cannot: the recent-profile menu
    /// items and the Dock menu all funnel through here.
    @objc func menuOpenRecentProfile(_ sender: Any?) {
        guard let id = sender as? UUID else { return }
        swiftty_postNotification(.openRecentProfile, userInfo: ["profileID": id.uuidString])
    }

    @objc func menuToggleTabBar(_ sender: Any?) {
        swiftty_postNotification(.toggleTabBar)
    }

    @objc func menuMoveTabToNewWindow(_ sender: Any?) {
        swiftty_postNotification(.moveTabToNewWindow)
    }

    @objc func menuMergeAllWindows(_ sender: Any?) {
        swiftty_postNotification(.mergeAllWindows)
    }

    @objc func menuToggleGroupMode(_ sender: Any?) {
        swiftty_postNotification(.toggleGroupMode)
    }

    @objc func menuPreviousGroup(_ sender: Any?) {
        swiftty_postNotification(.previousGroup)
    }

    @objc func menuNextGroup(_ sender: Any?) {
        swiftty_postNotification(.nextGroup)
    }

    @objc func menuToggleTransparency(_ sender: Any?) {
        swiftty_postNotification(.toggleTransparency)
    }

    @objc func menuPreviousTab(_ sender: Any?) {
        swiftty_postNotification(.previousTab)
    }

    @objc func menuNextTab(_ sender: Any?) {
        swiftty_postNotification(.nextTab)
    }

    @objc func menuShowTmuxSessions(_ sender: Any?) {
        swiftty_postNotification(.showTmuxSessions)
    }

    @objc func menuDetachOtherClients(_ sender: Any?) {
        swiftty_postNotification(.detachOtherClients)
    }

    @objc func menuSelectTab1(_ sender: Any?) {
        swiftty_postNotification(.selectTab, userInfo: ["tabIndex": 1])
    }

    @objc func menuSelectTab2(_ sender: Any?) {
        swiftty_postNotification(.selectTab, userInfo: ["tabIndex": 2])
    }

    @objc func menuSelectTab3(_ sender: Any?) {
        swiftty_postNotification(.selectTab, userInfo: ["tabIndex": 3])
    }

    @objc func menuSelectTab4(_ sender: Any?) {
        swiftty_postNotification(.selectTab, userInfo: ["tabIndex": 4])
    }

    @objc func menuSelectTab5(_ sender: Any?) {
        swiftty_postNotification(.selectTab, userInfo: ["tabIndex": 5])
    }

    @objc func menuSelectTab6(_ sender: Any?) {
        swiftty_postNotification(.selectTab, userInfo: ["tabIndex": 6])
    }

    @objc func menuSelectTab7(_ sender: Any?) {
        swiftty_postNotification(.selectTab, userInfo: ["tabIndex": 7])
    }

    @objc func menuSelectTab8(_ sender: Any?) {
        swiftty_postNotification(.selectTab, userInfo: ["tabIndex": 8])
    }

    @objc func menuSelectTab9(_ sender: Any?) {
        swiftty_postNotification(.selectTab, userInfo: ["tabIndex": 9])
    }

    // MARK: - Non-Menu Commands

    @objc func increaseFontSize(_ sender: Any?) {
        swiftty_postNotification(.increaseFontSize)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        swiftty_postNotification(.decreaseFontSize)
    }

    @objc func resetFontSizeToDefault(_ sender: Any?) {
        swiftty_postNotification(.resetFontSize)
    }

    @objc func findInTerminal(_ sender: Any?) {
        swiftty_postNotification(.startSearch)
    }
}
