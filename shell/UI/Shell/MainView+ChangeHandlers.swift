//
//  MainView+ChangeHandlers.swift
//  shell
//
//  Lifecycle and onChange handler pipeline for MainView's body.
//  Extracted from MainView.swift for build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

extension MainView {

    // MARK: - Lifecycle and Change Handler Pipeline

    @ViewBuilder
    func applyLifecycleHandlers<V: View>(_ view: V) -> some View {
        // Note: embedded mosh/trzsz/ghostty session-change notifications used to
        // bump `tabBarVersion` here to force the tab bar to re-render. Combined
        // with `.id(tabBarVersion)` (since removed) that tore down and rebuilt
        // the entire tab subtree on every session-change. Phase 3 introduces
        // per-tab @Observable observation; until then the roam-protocol
        // indicator may lag a frame on these transitions, which is acceptable.
        let base = view
            .onAppear(perform: handleOnAppear)
            .onDisappear(perform: handleOnDisappear)
            // An already-open terminal window should claim document URLs
            // before the WindowGroup scene matcher creates another window.
            // `allowing` MUST stay "*": it is the set of events an existing
            // window may receive at all, and narrowing it makes iPadOS spawn
            // a new empty window for anything outside the set — including
            // plain app-icon activations and ssh/mosh/shell URLs.
            .handlesExternalEvents(
                preferring: ["file://"],
                allowing: ["*"]
            )
            .onOpenURL { url in
                guard url.isFileURL else { return }
                #if targetEnvironment(macCatalyst)
                // A folder (or a file's folder) is a shell tab, not a document.
                // The scene delegate may deliver the same open; deposits dedupe.
                // Whatever the router declines falls through to the file path.
                Ghostty.logger.info("[urlopen] onOpenURL window=\(windowId, privacy: .public)")
                if CatalystAppDelegate.routeAutomationURL(url, source: "mainView.onOpenURL") {
                    return
                }
                #endif
                Ghostty.logger.info("[urlopen] ignoring file URL in window=\(windowId, privacy: .public)")
            }

        applyChangeHandlers(base)
    }

    @ViewBuilder
    private func applyChangeHandlers<V: View>(_ view: V) -> some View {
        let base = view
            // Single deterministic keyboard-ownership gate. Whenever ANY
            // overlay/sheet presence changes, push the new state to every
            // terminal in the window: gate up → terminals refuse first
            // responder (the overlay's field owns the keyboard); gate down →
            // `setOverlayOwnsKeyboard(false)` reconciles first responder back to
            // the focused terminal. Overlay→overlay handoffs (e.g. tab sidebar
            // "+" → connection sidebar, or → settings) keep `isAnySheetPresented`
            // true throughout, so the gate never flaps mid-transition. This
            // replaces the racing per-view +50/250/300/350/450/600ms retries
            // that used to fight the sidebar's search field.
            .onChange(of: isAnySheetPresented) { oldValue, newValue in
                Ghostty.logger.info("onChange(isAnySheetPresented) \(oldValue) -> \(newValue)")
                setOverlayOwnsKeyboardForAllTerminals(newValue)
            }
            .onChange(of: terminals.count) { oldCount, newCount in
                if newCount > 0 {
                    windowClosingAfterTabTransfer = false
                }
                handleTerminalCountChange(oldCount: oldCount, newCount: newCount)
            }
            .onChange(of: selectedTabIndex) { oldValue, newValue in
                handleSelectedTabChange(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: showConnectionSidebar) { oldValue, newValue in
                handleShowConnectionSheetChange(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: showSettings) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: showToolbarSettings) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: connectionInfoToShow != nil) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: tmuxDashboardRequest != nil) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal(includeCatalystDismissalRetry: true)
                }
            }

        applyRemainingHandlers(base)
    }

    @ViewBuilder
    private func applyRemainingHandlers<V: View>(_ view: V) -> some View {
        let chained = view
            .onChange(of: showPasswordPromptSheet) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: showKeyResolutionSheet) { oldValue, newValue in
                if newValue {
                    resignFirstResponderForSheetPresentation()
                } else if oldValue {
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: alerts.showNewHostAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.newHost)
                } else if oldValue {
                    if alerts.presentedKind == .newHost {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: alerts.showKeyChangedAlert) { oldValue, newValue in
                if newValue {
                    alerts.enqueue(.keyChanged)
                } else if oldValue {
                    if alerts.presentedKind == .keyChanged {
                        alerts.completePresented(clearBackingState: false)
                    }
                    restoreFirstResponderAfterSheetDismissal()
                }
            }

        applyTailHandlers(chained)
    }

    // Split from applyRemainingHandlers so the single chain stays inside the
    // type-checker's budget.
    @ViewBuilder
    private func applyTailHandlers<V: View>(_ view: V) -> some View {
        view
            #if !targetEnvironment(macCatalyst)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                transitionLifecycleScenePhase(to: .inactive)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                transitionLifecycleScenePhase(to: .background)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                transitionLifecycleScenePhase(to: .active)
            }
            #else
            // Mac Catalyst intentionally does not synthesize MainView lifecycle
            // transitions from AppKit focus changes. Losing app focus is not an
            // iOS-style background transition: terminals should keep running,
            // renderers should not be paused, SSH reminders should not fire, and
            // heavy scrollback/window persistence should not run on every Cmd-Tab.
            // Catalyst activation-only work remains in CatalystAppDelegate.
            #endif
            .onChange(of: windowIsKeyWindow) { _, newValue in
                updateWindowFocusState()
                if newValue {
                    refreshSelectionAfterExternalTabMutation(allowFocus: true)
                }
            }
            .onChange(of: isAnySheetPresented) { _, sheetPresented in
                #if !targetEnvironment(macCatalyst)
                setSelectionUIOccludedByPresentation(sheetPresented)
                #endif
                if !sheetPresented {
                    resyncSelectionHandlesAfterTransientOcclusion()
                }
            }
            .modifier(NotificationHandlersModifier(
                tabBarHidden: $tabBarHidden,
                restorationVersion: $restorationVersion,
                windowId: windowId,
                tabsModel: tabsModel,
                shouldHandleNotification: shouldHandleNotification
            ))
#if targetEnvironment(macCatalyst)
            .onChange(of: tabsInTitlebarEnabled) { _, _ in
                handleTabsInTitlebarEnabledChange()
            }
            .onChange(of: topTabStyle) { _, _ in
                handleTabsInTitlebarEnabledChange()
            }
            .onChange(of: hideWindowTitleBar) { _, _ in
                // Same layout consequence as moving tabs in/out of the
                // titlebar: surfaces must resize into/out of the top strip.
                handleTabsInTitlebarEnabledChange()
            }
#else
            .onChange(of: tabBarHidden) { _, isHidden in
                // If the tab bar was just hidden while no terminals exist,
                // show the connection sheet so the user isn't stranded.
                if isHidden && terminals.isEmpty && !showConnectionSidebar {
                    showConnectionSidebar = true
                }
            }
#endif
    }
}
