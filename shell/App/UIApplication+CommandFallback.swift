//
//  UIApplication+CommandFallback.swift
//  shell
//
//  Fallback command routing when TerminalView is not in the responder chain
//  (e.g., when all tabs are closed on iPad or Mac Catalyst)
//

import UIKit

extension UIApplication {

    @MainActor
    private func ghostty_postNotification(_ name: Notification.Name, userInfo: [String: Any] = [:]) {
        var info = userInfo
        if let sceneID = ghostty_activeWindowSceneSessionID() {
            info[GhosttyCommandRouting.windowSceneSessionIDKey] = sceneID
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
    func ghostty_activeWindowSceneSessionID() -> String? {
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

    // MARK: - Menu Actions (SwiftUI Commands)

    @objc func menuCreateLocalShell(_ sender: Any?) {
        ghostty_postNotification(.createLocalShell)
    }

    @objc func menuNewTab(_ sender: Any?) {
        ghostty_postNotification(.newTab)
    }

    @objc func menuNewWindow(_ sender: Any?) {
        ghostty_postNotification(.newWindow)
    }

    @objc func menuDuplicateTabWithSSH(_ sender: Any?) {
        ghostty_postNotification(.duplicateTabWithSSH)
    }

    @objc func menuSplitRight(_ sender: Any?) {
        ghostty_postNotification(.createSplit, userInfo: ["direction": "right"])
    }

    @objc func menuSplitDown(_ sender: Any?) {
        ghostty_postNotification(.createSplit, userInfo: ["direction": "down"])
    }

    @objc func menuNavigateSplitLeft(_ sender: Any?) {
        ghostty_postNotification(.navigateSplit, userInfo: ["direction": "left"])
    }

    @objc func menuNavigateSplitRight(_ sender: Any?) {
        ghostty_postNotification(.navigateSplit, userInfo: ["direction": "right"])
    }

    @objc func menuNavigateSplitUp(_ sender: Any?) {
        ghostty_postNotification(.navigateSplit, userInfo: ["direction": "up"])
    }

    @objc func menuNavigateSplitDown(_ sender: Any?) {
        ghostty_postNotification(.navigateSplit, userInfo: ["direction": "down"])
    }

    @objc func menuToggleSplitZoom(_ sender: Any?) {
        ghostty_postNotification(.toggleSplitZoom)
    }

    @objc func menuEqualizeSplits(_ sender: Any?) {
        ghostty_postNotification(.equalizeSplits)
    }

    @objc func menuOpenSettings(_ sender: Any?) {
        ghostty_postNotification(.openSettings)
    }

    @objc func menuBrowseHosts(_ sender: Any?) {
        ghostty_postNotification(.browseHosts)
    }

    @objc func menuBrowseProfiles(_ sender: Any?) {
        ghostty_postNotification(.browseProfiles)
    }

    /// Open one saved SSH profile in the focused window. `sender` carries the
    /// profile's id, since a plain selector cannot: the recent-profile menu
    /// items and the Dock menu all funnel through here.
    @objc func menuOpenRecentProfile(_ sender: Any?) {
        guard let id = sender as? UUID else { return }
        ghostty_postNotification(.openRecentProfile, userInfo: ["profileID": id.uuidString])
    }

    @objc func menuToggleTabBar(_ sender: Any?) {
        ghostty_postNotification(.toggleTabBar)
    }

    @objc func menuMoveTabToNewWindow(_ sender: Any?) {
        ghostty_postNotification(.moveTabToNewWindow)
    }

    @objc func menuMergeAllWindows(_ sender: Any?) {
        ghostty_postNotification(.mergeAllWindows)
    }

    @objc func menuToggleGroupMode(_ sender: Any?) {
        ghostty_postNotification(.toggleGroupMode)
    }

    @objc func menuPreviousGroup(_ sender: Any?) {
        ghostty_postNotification(.previousGroup)
    }

    @objc func menuNextGroup(_ sender: Any?) {
        ghostty_postNotification(.nextGroup)
    }

    @objc func menuToggleTransparency(_ sender: Any?) {
        ghostty_postNotification(.toggleTransparency)
    }

    @objc func menuToggleTitleBar(_ sender: Any?) {
        ghostty_postNotification(.toggleTitleBar)
    }

    @objc func menuPreviousTab(_ sender: Any?) {
        ghostty_postNotification(.previousTab)
    }

    @objc func menuNextTab(_ sender: Any?) {
        ghostty_postNotification(.nextTab)
    }

    @objc func menuShowTmuxSessions(_ sender: Any?) {
        ghostty_postNotification(.showTmuxSessions)
    }

    @objc func menuDetachOtherClients(_ sender: Any?) {
        ghostty_postNotification(.detachOtherClients)
    }

    @objc func menuSelectTab1(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 1])
    }

    @objc func menuSelectTab2(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 2])
    }

    @objc func menuSelectTab3(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 3])
    }

    @objc func menuSelectTab4(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 4])
    }

    @objc func menuSelectTab5(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 5])
    }

    @objc func menuSelectTab6(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 6])
    }

    @objc func menuSelectTab7(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 7])
    }

    @objc func menuSelectTab8(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 8])
    }

    @objc func menuSelectTab9(_ sender: Any?) {
        ghostty_postNotification(.selectTab, userInfo: ["tabIndex": 9])
    }

    // MARK: - Non-Menu Commands

    @objc func increaseFontSize(_ sender: Any?) {
        ghostty_postNotification(.increaseFontSize)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        ghostty_postNotification(.decreaseFontSize)
    }

    @objc func resetFontSizeToDefault(_ sender: Any?) {
        ghostty_postNotification(.resetFontSize)
    }

    @objc func findInTerminal(_ sender: Any?) {
        ghostty_postNotification(.startSearch)
    }
}
