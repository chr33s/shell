//
//  MainView.swift
//  shell
//
//  Main view for the terminal app: stored properties + `body` only.
//
//  Everything else lives in topic-named companion files, all
//  `extension MainView` unless noted:
//    MainViewBody             - body subview builders
//    MainViewPresentation     - applyScene/Sheet/OverlayChange modifier pipeline
//    MainViewAlerts           - unified alert UI (queue lives in MainAlertController)
//    MainViewChangeHandlers   - applyLifecycle/Change/RemainingHandlers
//    MainViewEventHandlers    - onAppear/onDisappear/tab-change/window-focus handlers
//    MainViewConnectionSheet  - connection sheet content + connect dispatch
//    MainViewDeepLinks        - ssh:// URL handling
//    MainViewTabBar           - tab bar content and context-menu helpers
//    MainViewSheetTheme       - SheetThemeColors env key + theme resolution
//    MainViewSupportViews     - standalone helper views/modifiers (not extensions)
//    MainViewWindowSceneReporter - window scene/frame reporting (not extensions)
//    MainViewTabDrag          - TabDragState + TabDragModifier (not extensions)
//  plus the pre-existing: MainViewFocus, MainViewLifecycle, MainViewModifiers,
//  MainViewNotifications, MainViewPersistence, MainViewSplits,
//  MainViewSSHValidation, MainViewTabBarStyling, MainViewTabManagement,
//  MainViewTerminalContent, MainViewTypes.
//
//  Stored properties must stay in this file (Swift disallows stored
//  properties in extensions). Most are deliberately `internal`, not
//  `private` — the companion extensions live in other files and `private`
//  would hide the properties from them.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

struct MainView: View {
    
    // MARK: - Properties
    
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow
    @SceneStorage("windowId") var sceneWindowId: String = UUID().uuidString
    var windowId: String { sceneWindowId }
    @State var isWindowFocused: Bool = false
    @State var windowIsKeyWindow: Bool = false
    /// The default shell a fresh window opened before any request reached it.
    /// A URL open landing right after (SwiftUI spawns the scene first, then
    /// delivers onOpenURL) replaces it instead of trailing it.
    @State var placeholderShell: (tabID: UUID, createdAt: Date)?
    /// True while saved tabs are being restored; a URL open that lands
    /// meanwhile waits so it follows the restored tabs instead of preceding them.
    @State var restorationInFlight = false
    @State var lifecycleScenePhase: ScenePhase = {
        switch UIApplication.shared.applicationState {
        case .active:
            return .active
        case .inactive:
            return .inactive
        case .background:
            return .background
        @unknown default:
            return .inactive
        }
    }()
    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    @State var shortRemoteSessionBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State var shortRemoteSessionBackgroundTaskIDBox: ShortRemoteSessionBackgroundTaskIDBox?
    #endif

    /// Per-window tab state. Replaces the previous `@State var terminals:
    /// [TerminalTab] = []` design where any per-tab mutation invalidated all
    /// of `MainView`'s body. `TabsModel` is `@Observable`; SwiftUI tracks
    /// reads at property granularity, so a title change on one tab no longer
    /// invalidates sibling tabs or the surrounding chrome.
    @State var tabsModel = TabsModel()

    /// Source-compat shim. Most call sites use `terminals[i].xxx` (which works
    /// in-place because `TabModel` is a class) or array-mutating helpers like
    /// `terminals.append(_:)`. The set-path replaces the underlying tabs array,
    /// which is fine because `TabModel` instances are reference-typed and
    /// retained.
    var terminals: [TerminalTab] {
        get { tabsModel.tabs }
        nonmutating set { tabsModel.tabs = newValue }
    }

    /// Source-compat shim around `tabsModel.selectedTabID`. The `Int` index is
    /// what the existing `MainView` plumbing expects; the canonical truth lives
    /// as a UUID on the model so reorders don't desync the selection.
    var selectedTabIndex: Int {
        get {
            tabsModel.selectedTabIndex ?? 0
        }
        nonmutating set {
            guard newValue >= 0, newValue < tabsModel.tabs.count else {
                tabsModel.selectedTabID = tabsModel.tabs.first?.id
                return
            }
            tabsModel.selectedTabID = tabsModel.tabs[newValue].id
        }
    }

    @State var showSettings = false
    @State var showToolbarSettings = false
    @State var settingsDestination: SettingsDestination?
    @State var showConnectionSidebar = false
    @State var connectionSidebarInitialTab: ConnectionSidebarTab = .lastUsed
    @State var showPasswordPromptSheet = false
    @State var passwordPromptProfile: ConnectionProfile?
    @State var passwordPromptSplitOption: SSHConnectionView.SplitOption = .newTab
    @State var showKeyResolutionSheet = false
    @State var keyResolutionUnresolvedKeys: [UnresolvedKeyInfo] = []
    @State var keyResolutionConfig: SSHConfig?
    @State var keyResolutionProfileID: UUID?
    @State var keyResolutionConnectionIdentity: String?
    @State var keyResolutionSplitOption: SSHConnectionView.SplitOption = .newTab
    /// "Ask Each Time" tmux tab-close: the tab whose ⌘W/✕ is awaiting the
    /// user's choice in the close action sheet. (id=tmux-tab-close-action)
    @State var pendingTmuxCloseTabID: UUID?
    /// "Ask Each Time" tmux new-tab (⌘T): the tmux tab whose new-tab choice is
    /// awaiting the user (local shell vs new tmux window). (id=tmux-new-tab-action)
    @State var pendingTmuxNewTabTabID: UUID?
    @State var reconnectingTabIndex: Int?
    @State var reconnectConfig: SSHConfig?
    /// Source-compat shim around `tabsModel.draggingTabID`.
    var draggingTab: TerminalTab? {
        get {
            guard let id = tabsModel.draggingTabID else { return nil }
            return tabsModel.tabs.first(where: { $0.id == id })
        }
        nonmutating set {
            tabsModel.draggingTabID = newValue?.id
        }
    }
    @State var tabHover = TabHoverController()
    @State var wigglingTabIds: Set<UUID> = []
    @State var tabFrames: [UUID: CGRect] = [:]

    // Namespace for glass effect tab transitions (iOS 26+)
    @Namespace var tabNamespace
    
    // Theme observation for tab bar styling
    @State var connectionInfoToShow: ConnectionInfo?
    @State var tmuxDashboardRequest: TmuxDashboardRequest?
    @Setting(Settings.Tabs.showScopeMenu) var showTabScopeMenu

    var themeManager = ThemeManager.shared
    var transparencyManager = TransparencyManager.shared
    var keyboardGeometry = KeyboardGeometryMonitor.shared
    var themeOverrideManager = ThemeOverrideManager.shared
    var themeUIOverridesManager = ThemeUIOverridesManager.shared
#if targetEnvironment(macCatalyst)
    var titlebarLayoutManager = TitlebarLayoutManager.shared
#endif

    // Theme-Aware UI toggle. Read by the sheet-theme helpers in
    // MainViewSheetTheme.swift; `private` would hide it from extensions
    // in other files.
    @Setting(Settings.Theme.themedUI) var themedUIEnabled

    // SSH settings
    @Setting(Settings.Connections.healthMonitoring) var sshHealthMonitoringEnabled
#if targetEnvironment(macCatalyst)
    @Setting(Settings.Window.tabsInTitlebar) var tabsInTitlebarEnabled
    @Setting(Settings.Window.hideTitleBar) var hideWindowTitleBar
#endif

    // Tab bar visibility
    @Setting(Settings.Tabs.barHidden) var tabBarHidden
    @Setting(Settings.Tabs.showShortcutIndicators) var showTabShortcutIndicators
    @Setting(Settings.Tabs.barAnimationsDisabled) var tabBarAnimationsDisabled
    @Setting(Settings.Tabs.topTabStyle) var topTabStyle
    @Setting(Settings.Tabs.compactPillSpacing) var compactPillTabSpacing

    /// Raw-value bridge for the shared tab components that still take `Binding<String>`.
    var topTabStyleRawValueBinding: Binding<String> {
        Binding(
            get: { topTabStyle.rawValue },
            set: { topTabStyle = TopTabStyle.resolve($0) }
        )
    }
    var usesCompactTabSpacing: Bool {
        topTabStyle.usesEqualWidthTabs || compactPillTabSpacing
    }

#if !targetEnvironment(macCatalyst) && !os(visionOS)
    @Setting(Settings.Window.fullScreenMode) var fullScreenModeEnabled
#endif

#if os(visionOS)
    @State var showKeyboardToolbar: Bool = true
#endif

    // Tab indicator overlay (shown when switching tabs with tab bar hidden)
    // and its one-shot suppression flags (see TabIndicatorController).
    @State var tabIndicator = TabIndicatorController()
    @State var appTabSwipeState: AppTabSwipeState?

    // Unified main-alert queue: host-key validation, SSH/GPG agent
    // approvals, helper-missing, and AI-agent alerts all route through this
    // per-window controller (see MainAlertController).
    @State var alerts = MainAlertController()

    // Keyboard-interactive (RFC 4256) challenges — queue of pending server prompt
    // rounds, presented one at a time via a sheet (needs free-form text entry).
    @State var keyboardInteractiveQueue: [PendingKeyboardInteractiveChallenge] = []
    @State var showKeyboardInteractivePrompt = false
    
    
    // Search state change trigger - incremented to force re-render when search opens/closes
    @State var searchStateVersion: Int = 0
    @State var composeStateVersion: Int = 0
    // Restoration state change trigger - incremented to force re-render when restoration state changes
    // (TerminalView is a class, so @State doesn't observe its @Published properties)
    @State var restorationVersion: Int = 0
    @State var windowSceneSessionID: String?
    @State var windowSafeAreaInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
#if targetEnvironment(macCatalyst)
    // Per-window geometry restore is stashed in onAppear and applied exactly once
    // the windowId→scene link is published by WindowSceneReporter — an event,
    // not a 2s poll. `pendingRestoreFrame` is nil for a brand-new window.
    // Non-private: stash/apply live in the MainViewPersistence.swift extension
    // (a different file), so `private` would hide them there.
    @State var pendingRestoreFrame: CGRect?
    @State var isFirstRestoredWindow: Bool = false
    @State var geometryRestorePending: Bool = false
    @State var geometryRestoreApplied: Bool = false
    // This window's last observed system frame, captured CONTINUOUSLY during the
    // session by WindowSceneReporter (on layout/resize/focus) — NOT just at save
    // time. The save-time `windowScene(forWindowId:)` lookup returns nil on
    // macOS 27 (scenes torn down before terminate / registry unset), so
    // serializeWindowState reads this instead, giving each window its own frame.
    @State var lastKnownWindowFrame: CGRect?
#endif
    
    /// Holds tokens from NotificationCenter's block-based addObserver API so
    /// they can be removed on `handleOnDisappear`. See MainViewObserverBag
    /// doc for the leak this fixes.
    @State var observerBag = MainViewObserverBag()
    @State var didCleanUpWindow = false
    @State var windowClosingAfterTabTransfer = false
    @State var tabTransferDropOverlayVisible = false
    
    var body: some View {
        // Bump the body-evaluation counter at the very top so even early-exit
        // paths are counted. Snapshot+reset on each BG/FG transition prints the
        // count as a `bodyEvals=N` key on those lifecycle checkpoints, letting
        // us verify post-refactor that sustained network instability does not
        // re-evaluate the body. Pre-refactor the count grew with per-tab
        // title/health/roam-protocol mutations; post-refactor it should only
        // grow on structural events (tab add/remove, manual selection, sheet
        // visibility, keyboard frame).
        let content = GeometryReader { geometry in
            #if !os(visionOS)
            let _ = keyboardGeometry.keyboardStateVersion
            let defersBottomSystemGesture = !isAnySheetPresented
                && terminals.indices.contains(selectedTabIndex)
                && terminals[selectedTabIndex].focusedPane?
                    .defersBottomSystemGestureForKeyboardToolbar == true
            #endif

            // Resolve all tab bar styling once for this body evaluation rather
            // than letting each computed property (`tabBarBackgroundColor`,
            // `tabTextColor`, etc.) independently re-resolve the override
            // theme and re-extract UIColor RGB components. See
            // `ResolvedTabBarTheme` doc for details.
            let resolvedTheme = resolvedTabBarTheme()
            ZStack {
                // Full-bleed backgrounds
                fullBleedBackground(geometry: geometry, theme: resolvedTheme)

                VStack(spacing: 0) {
                    // Top toolbar spacer when tab bar is hidden (Catalyst only)
                    catalystTabBarSpacer(geometry: geometry)

                    if !tabBarHidden {
                        HStack(spacing: 0) {
                            tabBarLeadingSpacer(geometry: geometry, theme: resolvedTheme)

                            // Tab bar - switches between display modes
                            //
                            // The previous design carried a `tabBarVersion`
                            // counter that was bumped from drop completions
                            // and notification observers, with `.id(tabBarVersion)`
                            // forcing a structural rebuild of the entire tab
                            // bar subtree on every increment. With per-tab
                            // observation via `TabModel`, the tab bar
                            // re-evaluates only on the property reads it
                            // actually performs, so no manual refresh signal
                            // is needed.
                            tabBarTrack(in: geometry, theme: resolvedTheme)
                                .layoutPriority(0)
                                // Toggling grouped mode changes `navigationTabs`,
                                // which can flip the tab-bar display mode (e.g.
                                // equalWidth→singleTab when two tabs live in
                                // different groups). Animating that structural
                                // swap makes the selected tab's glass capsule
                                // morph for ~1s, during which the roam "R" badge
                                // composites against the unsettled glass and looks
                                // washed out. Snap the layout for grouped-mode
                                // toggles so the badge is correct immediately;
                                // ordinary tab add/remove + resize still animate
                                // (this innermost transaction only fires when
                                // `isGroupedModeEnabled` itself changes).
                                .transaction(value: tabsModel.isGroupedModeEnabled) { $0.animation = nil }
                                .animation(.easeInOut(duration: 0.25), value: terminals.count)
#if targetEnvironment(macCatalyst)
                                .blockWindowDrag(when: usesTitlebarTabs)
#endif

                            if usesCompactTabSpacing {
                                tabBarAddButton(theme: resolvedTheme)
                                integratedTabBarDragRegion()
                                    .layoutPriority(-1)
                                tabBarSettingsButton(theme: resolvedTheme)
                            } else {
                                TabStyleContextMenuRegion(
                                    selectedStyleRawValue: topTabStyleRawValueBinding
                                )
                                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                                .layoutPriority(-1)
                                tabBarActionButtons(theme: resolvedTheme)
                            }
                        }
                        .frame(height: TabMetrics.tabBarHeight)
                        .frame(maxWidth: .infinity)
                        .background {
                            ZStack {
                                tabBarChromeBackground(resolvedTheme)

                                // Background layer on purpose: the active tab
                                // occludes the run beneath it, so the line
                                // reads as rising around that tab.
                                if topTabStyle.usesStripLayout {
                                    IntegratedTabEdgeRuleView(
                                        palette: resolvedTheme.integratedEdgePalette
                                    )
                                }
                            }
                            // Visual chrome must not own an interaction behind
                            // every foreground tab, button, and empty-space menu.
                            .allowsHitTesting(false)
                        }
                        .overlayPreferenceValue(IntegratedActiveTabBoundsPreferenceKey.self) { bounds in
                            integratedOSCProgressEdge(activeTabBounds: bounds)
                        }
                        .modifier(ContainerCornerModifier())
#if targetEnvironment(macCatalyst)
                        .catalystCursorRegion()
#endif
                        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                            // Tab frame preferences are only used by Catalyst
                            // titlebar dragging. Guard and defer the write so
                            // selection animations don't feed layout-pass
                            // preferences back into MainView every frame.
                            DispatchQueue.main.async {
                                if tabFrames != frames {
                                    tabFrames = frames
                                }
                            }
                        }
                    }
                    
                    // Terminal view
                    if ghosttyApp.readiness == .ready, !terminals.isEmpty {
                        terminalAndSidebarContent(geometry: geometry)
                    } else if ghosttyApp.readiness == .ready, terminals.isEmpty, !windowClosingAfterTabTransfer {
                        // Empty state - shown when all tabs are closed
                        EmptyStateResponder(
                            onNewTab: addNewTab,
                            onNewLocalShell: createLocalShellTab
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if ghosttyApp.readiness == .ready, terminals.isEmpty {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if ghosttyApp.readiness == .loading {
                        loadingView
                    } else if ghosttyApp.readiness == .error {
                        errorView
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(WindowSceneReporter(onUpdate: { scene, safeAreaInsets, isKeyWindow in
                    let newID = scene?.session.persistentIdentifier
                    let newInsets = EdgeInsets(
                        top: safeAreaInsets.top,
                        leading: safeAreaInsets.left,
                        bottom: safeAreaInsets.bottom,
                        trailing: safeAreaInsets.right
                    )
                    // Dispatch to avoid modifying state during view update
                    DispatchQueue.main.async {
                        if windowSceneSessionID != newID {
                            windowSceneSessionID = newID
                            TerminalWindowRegistry.updateSceneSessionId(newID, for: windowId)
                            #if targetEnvironment(macCatalyst)
                            // The scene link is now resolvable — this is the
                            // precise event the geometry restore was waiting for.
                            // Apply once (no-ops if nothing is pending or already
                            // applied, or if onAppear hasn't stashed yet — in
                            // which case onAppear's own call will apply it).
                            if newID != nil {
                                tryApplyPendingGeometry()
                            }
                            #endif
                        }
                        if windowSafeAreaInsets.top != newInsets.top ||
                            windowSafeAreaInsets.leading != newInsets.leading ||
                            windowSafeAreaInsets.bottom != newInsets.bottom ||
                            windowSafeAreaInsets.trailing != newInsets.trailing {
                            windowSafeAreaInsets = newInsets
                        }
                        if windowIsKeyWindow != isKeyWindow {
                            windowIsKeyWindow = isKeyWindow
                        }
                    }
                }, onFrameUpdate: { frame in
                    // Continuously track this window's own frame so save doesn't
                    // depend on the terminate-time scene lookup (nil on macOS 27).
                    #if targetEnvironment(macCatalyst)
                    DispatchQueue.main.async {
                        if lastKnownWindowFrame != frame {
                            lastKnownWindowFrame = frame
                        }
                    }
                    #endif
                }))
                #if !os(visionOS)
                // Defer Home while an iPhone/iPad toolbar sits at the screen
                // edge without a docked software keyboard.
                .defersSystemGestures(
                    on: ((UIDevice.current.userInterfaceIdiom == .phone
                          || UIDevice.current.userInterfaceIdiom == .pad)
                         && defersBottomSystemGesture) ? Edge.Set.bottom : []
                )
                #endif

            } // ZStack
#if targetEnvironment(macCatalyst)
            .overlay(alignment: .top) {
                catalystDragStripShield()
            }
#endif
            .overlay {
                // Tab indicator overlay - shown when switching tabs with tab bar hidden.
                // Pass the TabModel (class reference, structural under Observation),
                // not the title — keeps the title read inside the overlay's body
                // so per-tab title mutations don't invalidate MainView.body.
                if tabIndicator.isShowing && tabBarHidden && terminals.indices.contains(selectedTabIndex) {
                    // Position/count/shortcut reflect navigable tabs; hidden
                    // tmux windows are skipped, and grouped mode scopes this
                    // to the active group.
                    let visiblePosition = tabsModel.navigationIndex(of: terminals[selectedTabIndex].id)
                        ?? selectedTabIndex
                    TabIndicatorOverlay(
                        tab: terminals[selectedTabIndex],
                        allTabs: terminals,
                        currentIndex: visiblePosition,
                        totalCount: tabsModel.navigationTabs.count,
                        keyboardShortcut: keyboardShortcut(for: visiblePosition),
                        tmuxBadgePalette: TmuxTabBadgePalette(theme: resolvedTheme)
                    )
                    .transition(.opacity)
                }
            }
        } // GeometryReader
        // The terminal manages keyboard clearance explicitly. Keep the root
        // layout stable when iOS hides/restores the keyboard around app
        // activation so foregrounding does not bounce the terminal.
        .ignoresSafeArea(.keyboard)

        let sceneContent = applySceneModifiers(content)
        // Resolve sheet styling once for this body evaluation. Without this,
        // each .themedSheet / sheet-aware modifier inside `applySheetModifiers`
        // independently re-reads sheet theme + accent + color-scheme — 8+
        // attachments × 3 properties = 30+ effectiveThemeColors walks per
        // body. Combined with network-driven body invalidations
        // (TabsModel.tabs, KeyboardGeometryMonitor.keyboardStateVersion,
        // ThemeOverrideManager.tabOverrides), that workload is what
        // FrontBoard's 10s foreground / 30s background scene-update budget
        // catches in the 52 0x8BADF00D crash IPS files (varying frames; same
        // root cause: MainView.body is too expensive).
        let sheetTheme = resolvedSheetTheme()
        let sheetContent = applySheetModifiers(sceneContent, sheetTheme: sheetTheme)
        let overlayContent = applyOverlayChangeHandlers(sheetContent)
        let alertContent = applyAlertModifiers(overlayContent)
        return applyLifecycleHandlers(alertContent)
    }

}

#Preview {
    MainView()
        .environmentObject(Ghostty.App())
}
