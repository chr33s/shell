//
//  MainView+TabBar.swift
//  shell
//
//  Tab bar width calculation logic for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import os

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Tab Bar Display Mode

extension MainView {

    /// Display mode for the tab bar, determining layout strategy
    enum TabBarDisplayMode: Equatable {
        case singleTab      // Centered title only
        case equalWidth     // Equal-width tabs filling space
        case scrolling      // Scrollable tabs when overflow occurs
    }

    /// Width reserved for action buttons (plus + settings)
    static let actionButtonsWidth: CGFloat = TabMetrics.tabBarHeight * 2

    static let integratedMaximumTabWidth: CGFloat = 240
    static let catalystWindowDragWidth: CGFloat = 42

    /// Usable width for tab items after fixed leading chrome and trailing
    /// action buttons are reserved. Per-tab display mode decisions live in
    /// `TabBar`, where reading title/badge/health metadata does not invalidate
    /// `MainView.body`.
    func availableTabBarWidth(in geometry: GeometryProxy) -> CGFloat {
        max(0, geometry.size.width - Self.actionButtonsWidth - tabBarLeadingPadding)
    }

    /// Width of the compact tab viewport. Capped tabs leave real flexible
    /// space after the new-tab button instead of stretching across the window.
    func integratedTabTrackWidth(in geometry: GeometryProxy) -> CGFloat {
        let tabCount = tabsModel.navigationTabs.count
        guard tabCount > 0 else { return 0 }

        let scopeWidth = integratedScopeMenuWidth
        let preferred = CGFloat(tabCount) * Self.integratedMaximumTabWidth + scopeWidth
        let capacity = max(
            0,
            geometry.size.width
                - tabBarLeadingPadding
                - Self.actionButtonsWidth
                - integratedMinimumDragWidth
        )
        return min(preferred, capacity)
    }

    private var integratedScopeMenuWidth: CGFloat {
        guard showTabScopeMenu,
              tabsModel.orderProjection.mode != .flat,
              let title = tabsModel.orderProjection.activeScopeTitle else { return 0 }
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        return min(170, max(66, ceil((title as NSString).size(withAttributes: [.font: font]).width) + 46))
        #else
        return min(170, max(66, CGFloat(title.count * 7) + 46))
        #endif
    }

    var integratedMinimumDragWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        return (usesTitlebarTabs || hideWindowTitleBar)
            ? Self.catalystWindowDragWidth
            : 0
        #else
        return 0
        #endif
    }
}

// MARK: - Tab Bar Content and Tab Helpers

extension MainView {

    // MARK: - Tab Keyboard Shortcut Helper

    /// Returns keyboard shortcut string for a tab at the given index
    /// Only returns shortcuts for tabs 1-9 when the setting is enabled
    func keyboardShortcut(for index: Int) -> String? {
        guard showTabShortcutIndicators, index < 9 else { return nil }
        return "⌘\(index + 1)"
    }

    // MARK: - Tab Bar Content

    /// Build tab bar content based on display mode.
    ///
    /// All per-tab Observation reads (`tab.title`, `tab.connectionHealth`,
    /// `tab.connectionHealth`) live inside `TabBar.body`, NOT here, so
    /// network-driven mutations (OSC 0/2 title sequences during reconnect,
    /// keepalive ping health updates, embedded mosh/trzsz session-change
    /// notifications) only invalidate `TabBar.body` and do not propagate
    /// up to MainView. The whole crash family in this project's IPS files
    /// (varying frames; common root: scene-update transactions blow the
    /// 10s/30s FrontBoard budget when MainView re-evaluates) hinges on
    /// this decoupling.
    /// The compact track caps at the space left after fixed controls. A cap,
    /// not a fixed width: outer modifiers inset the row below what the proxy
    /// reports, and a rigid frame pushed the buttons off-window.
    @ViewBuilder
    func tabBarTrack(in geometry: GeometryProxy, theme: ResolvedTabBarTheme) -> some View {
        if usesCompactTabSpacing {
            let preferredWidth = integratedTabTrackWidth(in: geometry)
            GeometryReader { trackGeometry in
                tabBarContent(
                    availableWidth: trackGeometry.size.width,
                    theme: theme
                )
            }
            .frame(maxWidth: preferredWidth, alignment: .leading)
            .frame(height: TabMetrics.tabBarHeight)
        } else {
            tabBarContent(
                availableWidth: availableTabBarWidth(in: geometry),
                theme: theme
            )
        }
    }

    @ViewBuilder
    private func tabBarContent(
        availableWidth: CGFloat,
        theme: ResolvedTabBarTheme
    ) -> some View {
        TabBar(
            theme: theme,
            availableWidth: availableWidth,
            style: topTabStyle,
            usesCompactSpacing: usesCompactTabSpacing,
            selectedStyleRawValue: topTabStyleRawValueBinding,
            tabsModel: tabsModel,
            selectedTabIndex: Binding(
                get: { selectedTabIndex },
                set: { newIndex in
                    selectedTabIndex = newIndex
                }
            ),
            windowId: windowId,
            usesTitlebarTabs: topTabBarAttachedToWindow,
            sshHealthMonitoringEnabled: sshHealthMonitoringEnabled,
            tabNamespace: tabNamespace,
            canAcceptWindowTransferDrop: tabTransferDropOverlayVisible,
            suppressSelectionAnimation: tabIndicator.suppressNextSelectionAnimation,
            wigglingTabIds: $wigglingTabIds,
            tabFrames: $tabFrames,
            onCloseTab: { index in closeTab(at: index) },
            onMoveTab: { from, to in moveTab(from: from, to: to) },
            onSelectTab: { index in
                guard index != selectedTabIndex else { return }
                if tabBarAnimationsDisabled || UIAccessibility.isReduceMotionEnabled {
                    selectedTabIndex = index
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedTabIndex = index
                    }
                }
            },
            keyboardShortcut: { index in keyboardShortcut(for: index) },
            onTabHover: { id, isHovered in
                tabHover.handleHover(tabId: id, isHovered: isHovered)
            },
            // Per-tab / per-window theme overrides were removed: there was no
            // setter anywhere in the app, so no tab could ever carry one and
            // the "Clear Theme Override" item could never appear. Reporting
            // `false` keeps that item hidden; the two parameters themselves
            // are vestigial and should come out of `TabBar` with the menu item
            // and the badge slot.
            tabHasThemeOverride: { _ in false },
            onClearThemeOverride: { _ in },
            onShowConnectionInfo: { tab in showConnectionInfo(for: tab) },
            onMoveTabToNewWindow: { tab in moveTabToNewWindow(tab) },
            onMoveTabsToNewWindow: { ids in moveTabsToNewWindow(ids) },
            onNewTmuxWindow: { tab in requestTmuxNewWindow(for: tab) },
            onShowTmuxSessions: { tab in showTmuxSessions(for: tab) },
            tmuxController: { tab in tmuxControllerForTab(tab) }
        )
    }

    // MARK: - Shared tab context-menu helpers (top bar + vertical sidebar)

    func showConnectionInfo(for tab: TabModel) {
        connectionInfoToShow = tab.connectionInfo
    }

    func moveTabToNewWindow(_ tab: TabModel) {
        guard TabTransferCoordinator.shared.canTransfer(tab) else { return }
        moveTabsToNewWindow([tab.id])
    }

    /// Stage a group / gateway (one or more tabs) and open a fresh window that
    /// claims them on appear. Generalizes `moveTabToNewWindow`.
    func moveTabsToNewWindow(_ tabIDs: [UUID]) {
        guard TabTransferCoordinator.canOfferWindowTransfers, !tabIDs.isEmpty else { return }
        TabTransferCoordinator.shared.prepareMoveTabsToNewWindow(tabIDs, from: windowId)
        #if targetEnvironment(macCatalyst)
        UIApplication.shared.requestSceneSessionActivation(
            nil,
            userActivity: nil,
            options: nil,
            errorHandler: { error in
                TabTransferCoordinator.shared.cancelPendingMoveTabsToNewWindow(tabIDs, from: windowId)
                Ghostty.logger.error("Failed to create transfer window: \(error.localizedDescription)")
            }
        )
        #else
        openWindow(id: "main-terminal")
        #endif
    }

    /// Window menu "Merge All Windows": pull every other window's tabs into this
    /// one, in the order the transfer targets are listed. Each source window
    /// empties and closes itself through the existing tab-transfer path, so this
    /// is the same operation as dragging every tab across by hand.
    func mergeAllWindows() {
        guard TabTransferCoordinator.canOfferWindowTransfers else { return }
        for target in TerminalWindowRegistry.targets(excluding: windowId) {
            guard let sourceModel = TerminalWindowRegistry.tabsModel(for: target.id) else { continue }
            let tabIDs = sourceModel.tabs.map(\.id)
            guard !tabIDs.isEmpty else { continue }
            TabTransferCoordinator.shared.moveTabs(
                tabIDs,
                from: target.id,
                to: windowId,
                isDestinationWindowFocused: isWindowFocused
            )
        }
    }

    /// Create a new tmux window for either tab kind: gateway tabs route
    /// through the gateway surface, window tabs through their focused pane.
    func requestTmuxNewWindow(for tab: TabModel) {
        if tab.isTmuxGateway {
            tab.splitTree.terminalLeaves.first(where: { $0.tmuxController != nil })?
                .requestTmuxNewWindowFromGateway()
        } else {
            tab.focusedTerminal?.requestTmuxNewWindow()
        }
    }

    func showTmuxSessions(for tab: TabModel) {
        if let controller = tmuxControllerForTab(tab) {
            tmuxDashboardRequest = TmuxDashboardRequest(controller: controller)
        }
    }

}
