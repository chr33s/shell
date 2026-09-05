//
//  MainView+Presentation.swift
//  shell
//
//  Scene/sheet modifier pipeline and sheet-presentation predicates for MainView.
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

    // MARK: - Sheet Presentation Predicates

    /// Whether the pending "Ask Each Time" tab is already hidden — used to omit
    /// the Hide Tab dialog button (hiding it is a no-op). (id=tmux-tab-close-action)
    private var pendingTmuxCloseTabIsHidden: Bool {
        guard let id = pendingTmuxCloseTabID,
              let tab = terminals.first(where: { $0.id == id }) else { return false }
        return tab.isHiddenTmuxWindow
    }

    /// Returns true if any sheet or overlay is currently presented
    /// Used to prevent focus restoration from showing keyboard over sheets
    var isAnySheetPresented: Bool {
        showSettings ||
            showToolbarSettings ||
            showConnectionSidebar ||
            showPasswordPromptSheet ||
            showKeyboardInteractivePrompt ||
            showKeyResolutionSheet ||
            connectionInfoToShow != nil ||
            tmuxDashboardRequest != nil
    }

    // MARK: - View Modifiers

    @ViewBuilder
    func applySceneModifiers<V: View>(_ view: V) -> some View {
#if targetEnvironment(macCatalyst)
        // hideWindowTitleBar also forces the top safe area ignored: with the
        // titlebar merely hidden (not removed) the OS may still report a top
        // inset, which would push content down and expose the window backdrop.
        view
            .modifier(TitlebarTabsModifier(isEnabled: usesTitlebarTabs || hideWindowTitleBar, fullScreenEnabled: false))
            .background(windowId == "visor" ? nil : CurrentWindowTitleAccessor(tabsModel: tabsModel))
#elseif !os(visionOS)
        view
            .modifier(TitlebarTabsModifier(isEnabled: usesTitlebarTabs, fullScreenEnabled: fullScreenModeEnabled))
            .background(windowId == "visor" ? nil : CurrentWindowTitleAccessor(tabsModel: tabsModel))
#else
        view
            .modifier(TitlebarTabsModifier(isEnabled: usesTitlebarTabs, fullScreenEnabled: false))
            .ornament(
                visibility: showKeyboardToolbar ? .visible : .hidden,
                attachmentAnchor: .scene(.bottom),
                contentAlignment: .center
            ) {
                KeyboardToolbarOrnament(
                    focusedTerminal: terminals.indices.contains(selectedTabIndex)
                        ? terminals[selectedTabIndex].focusedTerminal : nil,
                    isVisible: $showKeyboardToolbar
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleKeyboardToolbar)) { _ in
                showKeyboardToolbar.toggle()
            }
#endif
    }

    @ViewBuilder
    func applySheetModifiers<V: View>(_ view: V, sheetTheme: ResolvedSheetTheme) -> some View {
        view
            .modifier(SettingsSheetModifier(
                showSettings: $showSettings,
                settingsDestination: settingsDestination,
                onDismiss: { settingsDestination = nil },
                themeColors: sheetTheme.themeColors,
                accentColor: sheetTheme.accentColor,
                colorScheme: sheetTheme.colorScheme
            ))
            .sheet(isPresented: $showToolbarSettings) {
                NavigationStack {
                    KeyboardToolbarSettingsView()
                }
                .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            .sheet(item: $connectionInfoToShow) { info in
                ConnectionInfoSheet(info: info)
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            // "Ask Each Time" tmux tab-close action sheet. (id=tmux-tab-close-action)
            .confirmationDialog(
                "Close tmux Tab",
                isPresented: Binding(
                    get: { pendingTmuxCloseTabID != nil },
                    set: { if !$0 { pendingTmuxCloseTabID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Close tmux Window") { runPendingTmuxClose(.closeWindow) }
                    .keyboardShortcut(.defaultAction)
                Button("Detach Session") { runPendingTmuxClose(.detachSession) }
                Button("Detach Session & Close Gateway") { runPendingTmuxClose(.detachSessionAndCloseGateway) }
                // Omit Hide Tab for an already-hidden tab: hiding is a no-op there,
                // and performTmuxClose(.hideTab) would fall back to kill-window —
                // turning an explicitly non-destructive choice destructive.
                // (id=tmux-tab-close-action)
                if !pendingTmuxCloseTabIsHidden {
                    Button("Hide Tab") { runPendingTmuxClose(.hideTab) }
                }
                Button("Cancel", role: .cancel) { pendingTmuxCloseTabID = nil }
                    .keyboardShortcut(.cancelAction)
            } message: {
                Text("Choose what to do with this tmux control-mode tab.")
            }
            // "Ask Each Time" tmux new-tab (⌘T) action sheet. (id=tmux-new-tab-action)
            .confirmationDialog(
                "New Tab",
                isPresented: Binding(
                    get: { pendingTmuxNewTabTabID != nil },
                    set: { if !$0 { pendingTmuxNewTabTabID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Local Shell") { runPendingTmuxNewTab(local: true) }
                    .keyboardShortcut(.defaultAction)
                Button("New tmux Tab") { runPendingTmuxNewTab(local: false) }
                Button("Cancel", role: .cancel) { pendingTmuxNewTabTabID = nil }
                    .keyboardShortcut(.cancelAction)
            } message: {
                Text("Open a new local shell tab, or a new tmux window in the current session.")
            }
            .sheet(item: $tmuxDashboardRequest) { request in
                TmuxSessionDashboardView(controller: request.controller)
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            .sheet(isPresented: $showConnectionSidebar) {
                connectionSheetContent
                    .environmentObject(ghosttyApp)
                    .interactiveDismissDisabled(terminals.isEmpty)
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            .sheet(isPresented: $showPasswordPromptSheet) {
                if let profile = passwordPromptProfile {
                    PasswordPromptSheet(
                        host: profile.sshConfig.host,
                        port: profile.sshConfig.port,
                        username: profile.sshConfig.username,
                        onSubmit: { password, shouldSave in
                            handlePasswordSubmit(profile: profile, password: password, shouldSave: shouldSave)
                        },
                        onCancel: {
                            showPasswordPromptSheet = false
                            passwordPromptProfile = nil
                        }
                    )
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
                }
            }
            .sheet(isPresented: $showKeyboardInteractivePrompt) {
                if let entry = keyboardInteractiveQueue.first {
                    KeyboardInteractivePromptView(
                        challenge: entry.challenge,
                        sessionLabel: entry.sessionLabel,
                        onSubmit: { responses in
                            respondToKeyboardInteractive(responses)
                        },
                        onCancel: {
                            respondToKeyboardInteractive(nil)
                        }
                    )
                    // Force an explicit Submit/Cancel: a swipe-dismiss must still
                    // resume the continuation, so treat interactive dismissal as
                    // cancel via the same handler.
                    .interactiveDismissDisabled()
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
                    .id(entry.id)
                }
            }
            .sheet(isPresented: $showKeyResolutionSheet) {
                if let config = keyResolutionConfig {
                    KeyResolutionSheet(
                        unresolvedKeys: keyResolutionUnresolvedKeys,
                        config: config,
                        profileID: keyResolutionProfileID,
                        connectionIdentity: keyResolutionConnectionIdentity,
                        onResolved: { resolvedConfig in
                            showKeyResolutionSheet = false
                            connectWithConfig(resolvedConfig, splitOption: keyResolutionSplitOption, sourceProfileID: keyResolutionProfileID)
                        },
                        onCancel: {
                            showKeyResolutionSheet = false
                        }
                    )
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
                }
            }
    }

    @ViewBuilder
    func applyOverlayChangeHandlers<V: View>(_ view: V) -> some View {
        view
    }

}
