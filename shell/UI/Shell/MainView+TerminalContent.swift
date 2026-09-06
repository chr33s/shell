//
//  MainView+TerminalContent.swift
//  shell
//
//  Terminal content area views for MainView.
//  Extracted to help compiler type-checking and build parallelization.
//

import SwiftUI
import GhosttyKit
import os
import UIKit

// MARK: - Terminal Content Views

extension MainView {

    /// Returns the reconnection overlay if needed for the current focused terminal.
    /// - Note: The `restorationVersion` check forces SwiftUI to re-evaluate when restoration state changes
    ///   (TerminalView is a class, so @State doesn't observe its @Published properties)
    @ViewBuilder
    var reconnectionOverlay: some View {
        // Note: restorationVersion check forces SwiftUI re-evaluation when state changes
        let _ = restorationVersion
        if terminals.indices.contains(selectedTabIndex),
           let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
           focusedTerminal.showsReconnectionOverlay {
            ReconnectionOverlayView(
                state: focusedTerminal.restorationState,
                connectionConfig: focusedTerminal.connectionConfig,
                onReconnect: {
                    if focusedTerminal.isLiveDisconnectionOverlay {
                        focusedTerminal.isLiveDisconnectionOverlay = false
                        focusedTerminal.restorationState = .none
                        NotificationCenter.default.post(name: .terminalRestorationStateChanged, object: focusedTerminal)
                        focusedTerminal.manualReconnect()
                    } else {
                        TerminalRestorationReconnector.retryReconnection(for: focusedTerminal)
                    }
                },
                onEnterPassword: { password in
                    TerminalRestorationReconnector.handlePasswordEntry(for: focusedTerminal, password: password)
                },
                onClose: {
                    NotificationCenter.default.post(
                        name: .closeSplit,
                        object: focusedTerminal,
                        userInfo: ["windowId": windowId]
                    )
                }
            )
        }
    }

    /// Returns the search overlay for the focused terminal, when search is open.
    @ViewBuilder
    func searchOverlay(searchStateVersion: Int) -> some View {
        // Read searchStateVersion to trigger re-render when search state changes
        let _ = searchStateVersion
        if terminals.indices.contains(selectedTabIndex),
           let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
           let searchState = focusedTerminal.searchState {
            // Hosted in a UIKit container so a native pan can drag it smoothly;
            // a SwiftUI DragGesture fights the bar's TextField/buttons for touches.
            // Dismissal honors the customizable start_search binding by answering the
            // app's Find menu action (findInTerminal) while the bar is focused; Escape
            // dismisses via a host UIKeyCommand.
            DraggableHUDContainer(
                dismissShortcuts: [.escape],
                forwardsFindToggle: true,
                onDismiss: { focusedTerminal.closeSearch() }
            ) {
                TerminalSearchOverlay(
                    searchState: searchState,
                    onSearch: { focusedTerminal.performSearch($0) },
                    onNavigate: { focusedTerminal.navigateSearch(direction: $0) },
                    onClose: { focusedTerminal.closeSearch() }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Find the tab ID that owns a given terminal view, or nil if not in any tab.
    func tabID(for terminalView: Ghostty.TerminalView) -> UUID? {
        for tab in terminals {
            if tab.splitTree.contains(where: { $0 === terminalView }) {
                return tab.id
            }
        }
        return nil
    }

    func showTmuxSessionsForSelectedTab() {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        let tab = terminals[selectedTabIndex]
        guard tab.isTmuxWindow || tab.isTmuxGateway else { return }
        guard let controller = tmuxControllerForTab(tab) else { return }
        tmuxDashboardRequest = TmuxDashboardRequest(controller: controller)
    }

    /// Evict every OTHER tmux client (`detach-client -a`) for the selected
    /// tab's gateway, keeping this client attached. Works from ANY tmux CC tab:
    /// `tmuxControllerForTab` resolves a window tab through its pane binding to
    /// the owning gateway's controller. No `otherAttachedClientCount` gate —
    /// that count reads `cachedSessions`, only warmed when a tab menu opens, so
    /// it's cold on a bare keyboard shortcut. `detach-client -a` is safe
    /// regardless: tmux skips the issuing control client, so it no-ops when no
    /// other clients are attached.
    func detachOtherClientsForSelectedTab() {
        guard terminals.indices.contains(selectedTabIndex) else { return }
        let tab = terminals[selectedTabIndex]
        guard tab.isTmuxWindow || tab.isTmuxGateway,
              let controller = tmuxControllerForTab(tab) else { return }
        Task { @MainActor in
            do {
                try await controller.detachOtherClients()
            } catch TmuxCommandError.gatewayEnded {
                // Control mode already ended; its teardown is the feedback.
            } catch {
                // Same surface the tab menus give this command
                // (TmuxTabMenu's commandFailureAlert): the shortcut has no
                // visible success state either, so a rejected or timed-out
                // detach would otherwise be indistinguishable from the app
                // ignoring the keystroke.
                NotificationCenter.default.post(
                    name: .tmuxShortcutCommandFailed,
                    object: nil,
                    userInfo: [
                        "windowId": windowId,
                        "message": error.localizedDescription
                    ]
                )
            }
        }
    }

    /// Resolve the tmux controller backing a tab: the gateway tab holds the
    /// controller on its gateway view; a tmux window tab reaches it through
    /// any pane's binding (parent surface keys the per-gateway registry —
    /// correct even with multiple gateways open).
    func tmuxControllerForTab(_ tab: TabModel) -> TmuxController? {
        if let controller = tab.splitTree.terminalLeaves.first(where: { $0.tmuxController != nil })?.tmuxController {
            return controller
        }
        for view in tab.splitTree.terminalLeaves {
            if let binding = view.tmuxPaneBinding {
                return TmuxController.controller(forOwnerSurface: binding.parentSurface)
            }
        }
        return nil
    }

    /// Returns the compose overlay if the focused terminal has compose active.
    @ViewBuilder
    func composeOverlay(composeStateVersion: Int) -> some View {
        let _ = composeStateVersion
        if terminals.indices.contains(selectedTabIndex),
           let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
           focusedTerminal.showComposeOverlay {
            TerminalComposeOverlay(
                initialText: focusedTerminal.composeText,
                onSend: { text in
                    focusedTerminal.sendComposedText(text)
                    // Explicitly clear persisted text so future opens start empty.
                    // Don't rely on onChange firing before onClose removes the overlay.
                    focusedTerminal.composeText = ""
                },
                onClose: {
                    // Restore first responder to terminal BEFORE removing overlay
                    // so the keyboard transitions smoothly without bounce
                    focusedTerminal.becomeFirstResponder()
                    focusedTerminal.showComposeOverlay = false
                    NotificationCenter.default.post(name: .ghosttyComposeStateChanged, object: focusedTerminal)
                },
                onTextChanged: { newText in
                    focusedTerminal.composeText = newText
                },
                keyboardAccessory: focusedTerminal.shouldShowKeyboardToolbar ? focusedTerminal.keyboardAccessory : nil,
                onTextViewCreated: { textView in
                    focusedTerminal.activeComposeTextView = textView
                }
            )
        }
    }

    /// The terminal overlays ZStack (search, reconnection, compose).
    @ViewBuilder
    func terminalOverlays() -> some View {
        Group {
            // Search overlay for focused terminal
            searchOverlay(searchStateVersion: searchStateVersion)

            // Reconnection overlay for restored sessions
            reconnectionOverlay

            // tmux -CC window placeholder restored from disk, awaiting reconcile
            tmuxReconnectingOverlay

            // Compose text overlay
            composeOverlay(composeStateVersion: composeStateVersion)

            // Failure alert for tmux commands run from a keyboard shortcut
            // (the tab menus carry their own coordinator).
            TmuxShortcutFailureAlert(windowId: windowId)

            #if os(visionOS)
            // Floating button to toggle keyboard toolbar ornament
            visionOSKeyboardToggle
            #endif
        }
        .tint(sheetAccentColor)
        .optionalColorSchemeEnvironment(sheetColorSchemeForSheets)
    }

    #if os(visionOS)
    @ViewBuilder
    private var visionOSKeyboardToggle: some View {
        if !showKeyboardToolbar {
            Button {
                NotificationCenter.default.post(name: .toggleKeyboardToolbar, object: nil)
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding([.trailing, .bottom], 16)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: showKeyboardToolbar)
        }
    }
    #endif

    /// Overlay shown when the selected tab is a restored tmux -CC window
    /// PLACEHOLDER still awaiting its reconcile (the gateway is reattaching the
    /// live `tmux -CC` over tssh). Disappears automatically when the controller
    /// adopts the placeholder (`awaitingTmuxReconcile` -> false, fills it with
    /// live panes) or the resume watchdog removes the tab.
    @ViewBuilder
    var tmuxReconnectingOverlay: some View {
        if terminals.indices.contains(selectedTabIndex),
           terminals[selectedTabIndex].awaitingTmuxReconcile {
            let tab = terminals[selectedTabIndex]
            if tab.splitTree.isEmpty {
                tmuxReconnectRecoveryPanel(for: tab)
            } else {
                tmuxReconnectStatusPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Purely informational — never swallow touches. Without this
                    // the overlay blocks gestures over the terminal area while a
                    // restored tmux -CC window reconnects.
                    .allowsHitTesting(false)
            }
        }
    }

    private var tmuxReconnectStatusPill: some View {
        tmuxReconnectStatusRow
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 400)
            .bannerBackground()
    }

    private var tmuxReconnectStatusRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Reconnecting tmux…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tmuxReconnectRecoveryPanel(for tab: TabModel) -> some View {
        let gatewayTab = tmuxReconnectGatewayTab(for: tab)
        return ZStack {
            Color.clear
                .allowsHitTesting(false)
            VStack(spacing: 12) {
                tmuxReconnectStatusRow
                    .frame(maxWidth: 360, maxHeight: nil)

                tmuxReconnectActionButtons(for: tab, gatewayAvailable: gatewayTab != nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .bannerBackground()
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tmuxReconnectActionButtons(for tab: TabModel, gatewayAvailable: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tmuxReconnectGatewayButton(for: tab, available: gatewayAvailable)
                tmuxReconnectCancelButton(for: tab)
            }

            VStack(spacing: 8) {
                tmuxReconnectGatewayButton(for: tab, available: gatewayAvailable)
                    .frame(maxWidth: .infinity)
                tmuxReconnectCancelButton(for: tab)
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .controlSize(.small)
    }

    @ViewBuilder
    private func tmuxReconnectGatewayButton(for tab: TabModel, available: Bool) -> some View {
        if available {
            Button {
                selectTmuxReconnectGateway(for: tab)
            } label: {
                Label("Gateway", systemImage: "terminal")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.bordered)
        }
    }

    private func tmuxReconnectCancelButton(for tab: TabModel) -> some View {
        Button(role: .destructive) {
            cancelTmuxReconnectRecovery(for: tab)
        } label: {
            Label("Cancel Recovery", systemImage: "xmark.circle")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(.bordered)
    }

    private func tmuxReconnectGatewayTab(for tab: TabModel) -> TabModel? {
        guard let owner = tab.owningGatewayTerminalUUID else { return nil }
        return TmuxWindowRegistry.gatewayTab(ownerTerminalUUID: owner)?.tab
    }

    private func selectTmuxReconnectGateway(for tab: TabModel) {
        guard let owner = tab.owningGatewayTerminalUUID else { return }
        if let gatewayTab = terminals.first(where: { candidate in
            candidate.splitTree.contains { $0.uuid == owner }
        }) {
            gatewayTab.isHiddenTmuxWindow = false
            gatewayTab.pendingHiddenTmuxGatewayRestore = false
            selectTab(id: gatewayTab.id)
        } else if let located = TmuxWindowRegistry.gatewayTab(ownerTerminalUUID: owner) {
            _ = TmuxWindowRegistry.selectGateway(ownerTerminalUUID: owner, allowFocus: true)
            activateWindowIfPossible(windowId: located.windowId)
        }
    }

    private func activateWindowIfPossible(windowId: String) {
        guard windowId != self.windowId,
              let sceneSessionId = TerminalWindowRegistry.sceneSessionId(for: windowId),
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.session.persistentIdentifier == sceneSessionId })
        else { return }
        UIApplication.shared.requestSceneSessionActivation(
            scene.session,
            userActivity: nil,
            options: nil,
            errorHandler: { error in
                Ghostty.logger.error("Failed to activate gateway window: \(error.localizedDescription)")
            }
        )
    }

    private func cancelTmuxReconnectRecovery(for tab: TabModel) {
        guard let owner = tab.owningGatewayTerminalUUID else {
            if let index = tabsModel.index(of: tab.id) {
                terminals.remove(at: index)
                tabsModel.repairSelectionIfNeeded()
            }
            return
        }

        if let gateway = TmuxWindowRegistry.gatewayView(ownerTerminalUUID: owner) {
            gateway.cancelTmuxRestoreRecovery()
            return
        }

        TmuxWindowRegistry.removeAwaitingPlaceholders(ownerTerminalUUID: owner)
    }

    /// A gesture-only fallback for restored tmux window placeholders. Normal
    /// terminal swipes live on `TerminalView`, but an awaiting-reconcile
    /// placeholder has an empty split tree, so there is no terminal view under
    /// the reconnect pill to receive a screen swipe.
    @ViewBuilder
    var tmuxReconnectingSwipeFallback: some View {
        if terminals.indices.contains(selectedTabIndex) {
            let tab = terminals[selectedTabIndex]
            if tab.awaitingTmuxReconcile && tab.splitTree.isEmpty {
                TmuxReconnectSwipeFallbackView(
                    leftAction: reconnectPlaceholderSwipeAction(for: .left),
                    rightAction: reconnectPlaceholderSwipeAction(for: .right)
                )
                .allowsHitTesting(true)
            }
        }
    }

    private func reconnectPlaceholderSwipeAction(for direction: SwipeDirection) -> TmuxReconnectSwipeFallbackView.Action {
        switch SwipeGestureManager.shared.binding(for: direction) {
        case .preset(.nextTab):
            return .tabNavigation(nextTab)
        case .preset(.previousTab):
            return .tabNavigation(previousTab)
        default:
            // Sequence/custom-key/multiplexer bindings need a live terminal
            // surface to receive bytes. Leave them disabled on empty placeholders
            // instead of silently consuming the swipe.
            return .disabled
        }
    }



    /// Theme-colored fill shown while no tab content is displayable: a tab
    /// swap is mid-reveal with nothing to hold on screen (first tab at
    /// launch, the displayed tab was just closed, reveal timeout). Prevents
    /// the translucent window background from ever showing raw desktop on
    /// macOS. Deliberately NOT shown while a previous tab is still visible:
    /// the terminal's own background is already drawn at this opacity, and
    /// stacking a second fill behind it would darken the window.
    @ViewBuilder
    var tabRevealBackdropFill: some View {
        let displayedTab = tabsModel.displayedTabID.flatMap { id in
            terminals.first(where: { $0.id == id })
        }
        let hasDisplayedContent = displayedTab.map { !$0.splitTree.isEmpty } ?? false
        if !hasDisplayedContent,
           let themeColors = effectiveThemeColors,
           let bgColor = Color(hex: themeColors.background) {
            bgColor
                .opacity(transparencyManager.backgroundOpacity)
                .ignoresSafeArea()
        }
    }

    #if !os(visionOS) && !targetEnvironment(macCatalyst)
    /// This window's live `UIWindowScene`, resolved through the
    /// windowId -> sceneSessionId link `TerminalWindowRegistry` publishes.
    /// Returns nil before the scene reporter has established that link, or once
    /// the scene has gone away.
    ///
    /// The Catalyst build carries its own copy in `MainView+Persistence.swift`
    /// (inside that file's `targetEnvironment(macCatalyst)` fence); the two
    /// fences are mutually exclusive, so exactly one definition is compiled for
    /// any given platform.
    static func windowScene(forWindowId windowId: String) -> UIWindowScene? {
        guard let sessionId = TerminalWindowRegistry.sceneSessionId(for: windowId) else { return nil }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.persistentIdentifier == sessionId }
    }
    #endif

    /// Calculates bottom padding for a terminal based on effects and keyboard.
    /// Also reports whether that padding puts the terminal's bottom edge
    /// directly against a resting toolbar row, i.e. whether
    /// `terminalTopGridAlignmentPadding` may close the grid's whole-row
    /// remainder against it.
    /// - Parameters:
    ///   - geometry: The geometry proxy for the terminal view
    ///   - keyboardFrame: The current keyboard frame (passed explicitly to ensure SwiftUI dependency tracking)
    ///   - keyboardHeight: The current keyboard height (passed explicitly to ensure SwiftUI dependency tracking)
    ///   - reservedBottomToolbarHeight: Actual toolbar/accessory height reserved by the selected focused terminal.
    ///   - containerBottomSafeAreaExpansion: Height the container safe-area escape actually gained
    ///     this layout pass, measured by the reader pair in `terminalTabsView`.
    func terminalBottomPadding(
        geometry: GeometryProxy,
        keyboardFrame: CGRect,
        keyboardHeight: CGFloat,
        reservedBottomToolbarHeight: CGFloat,
        containerBottomSafeAreaExpansion: CGFloat
    ) -> (padding: CGFloat, gridAlignsToToolbar: Bool) {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let isDocked = keyboardGeometry.isKeyboardDocked
        let containerFrame = geometry.frame(in: .global)
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        // `UIScreen.main` is deprecated and need not be the display this window
        // is on. Resolve this window's own scene through the windowId -> scene
        // link; before that link is up (or once the scene has gone away) fall
        // back to the container the terminal is drawn in.
        let windowScreenBounds = Self.windowScene(forWindowId: windowId)?.screen.bounds
        let visibleKeyboardFrameHeight: CGFloat = {
            guard !keyboardFrame.isNull, !keyboardFrame.isEmpty else { return 0 }
            let bounds = isPhone ? containerFrame : (windowScreenBounds ?? containerFrame)
            // Narrow bottom HUDs (the pencil's minimized-keyboard pill, the
            // floating mini keyboard) are not keyboard coverage.
            guard keyboardFrame.width >= bounds.width - 50 else { return 0 }
            let intersection = bounds.intersection(keyboardFrame)
            guard !intersection.isNull, !intersection.isEmpty else { return 0 }
            return intersection.height
        }()
        // Every "is a system keyboard docked" signal below is a height
        // threshold over the whole keyboard region — and that region is the
        // input accessory itself when no keyboard is up. A tall accessory then
        // reads as a keyboard: two stacked drawer rows alone reach 132pt, past
        // the 120pt line and KeyboardGeometryMonitor's 100pt dock test. Discount the
        // region the accessory accounts for first, testing the largest
        // coverage signal: `visibleKeyboardFrameHeight` is gated on a
        // near-screen-wide frame, so an iPad Split View window reports 0 while
        // `keyboardHeight` still carries a real docked keyboard.
        let keyboardRegionHeight = max(
            visibleKeyboardFrameHeight,
            max(keyboardHeight, keyboardFrame.isNull || keyboardFrame.isEmpty ? 0 : keyboardFrame.height)
        )
        // Tolerance is the bottom safe area: UIKit may contribute part of the
        // home-indicator strip below the accessory itself. A real docked
        // keyboard is hundreds of points tall and stays clear of this window.
        let accessoryOwnsWholeKeyboardRegion = reservedBottomToolbarHeight > 0
            && keyboardRegionHeight <= reservedBottomToolbarHeight + windowSafeAreaInsets.bottom + 2
        let hasSoftwareKeyboard = !accessoryOwnsWholeKeyboardRegion && (
            KeyboardTracker.shared.isSoftwareKeyboardVisible ||
            keyboardHeight > 0 ||
            visibleKeyboardFrameHeight >= 120
        )
        let dockedKeyboardCoverage = isPhone
            ? visibleKeyboardFrameHeight
            : max(keyboardHeight, visibleKeyboardFrameHeight, keyboardFrame.height)
        let hasDockedKeyboard = isDocked && hasSoftwareKeyboard && dockedKeyboardCoverage > 0
        let reservesBottomToolbar = reservedBottomToolbarHeight > 0

        // Calculate the raw keyboard coverage (for ocean calculation)
        let rawKeyboardCoverage: CGFloat
        if hasDockedKeyboard {
            rawKeyboardCoverage = dockedKeyboardCoverage
        } else if reservesBottomToolbar {
            rawKeyboardCoverage = reservedBottomToolbarHeight
        } else {
            rawKeyboardCoverage = 0
        }

        // The safe-area escape pushes the terminal's bottom edge below the
        // keyboard top by whatever it expanded; give that back as padding while
        // a docked keyboard occupies the bottom, so terminal bottom == keyboard
        // top by construction. Measured in this same pass, not modelled: the
        // previous version gated the reported inset on a "preserved keyboard is
        // physically hidden" flag, and on iOS 27 the flag and the safe-area
        // change stopped landing together, wobbling the terminal both ways.
        // A toolbar-only / accessory input view subsumes the inset the same
        // way (expansion is 0 while it is up), so a reserved toolbar gets the
        // same compensation when an overlay or app switch hides it.
        let preservedKeyboardSafeAreaCompensation: CGFloat =
            (hasDockedKeyboard || reservesBottomToolbar) ? containerBottomSafeAreaExpansion : 0

        // Calculate adjusted offset for terminal positioning (reduced to avoid excess gap)
        let keyboardOffset: CGFloat
        if hasDockedKeyboard {
            if isPhone {
                // The keyboard frame is in screen coordinates while the
                // terminal container can move when fullscreen hides/shows the
                // status bar. On iPhone, use the exact overlap with the
                // current container so the terminal ends at the keyboard top.
                keyboardOffset = dockedKeyboardCoverage + preservedKeyboardSafeAreaCompensation
            } else {
                // Docked software keyboard: subtract visual padding already provided by toolbar
                let bottomClearance: CGFloat = max(20, windowSafeAreaInsets.bottom)
                keyboardOffset = max(0, dockedKeyboardCoverage - bottomClearance) + preservedKeyboardSafeAreaCompensation
            }
        } else if reservesBottomToolbar {
            if isPhone {
                // The terminal container already ends at the top of the
                // bottom safe-area strip, and the toolbar stands on the
                // screen's bottom edge (primary input view in toolbar-only
                // mode, flush accessory next to a hardware keyboard), so
                // reserve exactly the part of the accessory that rises above
                // the strip.
                keyboardOffset = max(
                    0,
                    reservedBottomToolbarHeight - windowSafeAreaInsets.bottom
                ) + preservedKeyboardSafeAreaCompensation
            } else {
                // The iPad container already keeps the terminal above the
                // bottom safe-area strip. Reserve only the toolbar height that
                // extends above that strip, or toolbar-only mode leaves the
                // Home-indicator clearance as a visible gap above the row.
                keyboardOffset = max(
                    0,
                    reservedBottomToolbarHeight - windowSafeAreaInsets.bottom
                ) + preservedKeyboardSafeAreaCompensation
            }
        } else {
            keyboardOffset = 0
        }

        #else
        let keyboardOffset = keyboardGeometry.keyboardOverlapHeight(in: geometry.frame(in: .global), keyboardFrame: keyboardFrame)
        let rawKeyboardCoverage = keyboardOffset
        #endif

        var padding: CGFloat = 0

        #if os(visionOS)
        padding += geometry.safeAreaInsets.bottom
        #endif
        if keyboardOffset > 0 {
            padding += keyboardOffset
        }

        #if os(visionOS)
        // Add clearance for the keyboard toolbar ornament when visible
        if showKeyboardToolbar {
            padding += KeyboardSizes.iPad.toolbar.height
        }
        #endif

        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // Only a resting toolbar row gives the grid a stable bottom edge to
        // align against. A docked keyboard's coverage moves through its
        // present/dismiss (and interactive-drag) frames, so re-quantizing the
        // grid against it would make the content's top edge saw-tooth.
        let gridAlignsToToolbar = isPhone
            && reservesBottomToolbar
            && !hasDockedKeyboard
        #else
        let gridAlignsToToolbar = false
        #endif

        return (padding, gridAlignsToToolbar)
    }

    /// Top padding that moves the terminal grid's whole-row remainder from the
    /// bottom edge to the top, so the last row ends flush against a resting
    /// toolbar row instead of a font-dependent gap (up to one row) above it.
    ///
    /// Bottom padding alone cannot close that gap: rows are laid out from the
    /// content box's top, so the last row's bottom only moves in whole-row
    /// steps — lowering the box slides rows *under* the toolbar (clipping
    /// their glyphs), never closer to its top edge.
    ///
    /// Returns 0 whenever exact alignment is not possible: a split tree (pane
    /// heights derive from divider ratios, not this container), a pane without
    /// a live grid, or a non-terminal pane.
    /// - Parameters:
    ///   - containerHeight: Height of the safe-area-escaped container the tab
    ///     view fills (the `expanded` reader in `terminalTabsView`), which the
    ///     paddings subtract from.
    ///   - bottomPadding: The bottom padding computed by
    ///     `terminalBottomPadding` for this same pass.
    ///   - tab: The tab whose grid is being aligned.
    func terminalTopGridAlignmentPadding(
        containerHeight: CGFloat,
        bottomPadding: CGFloat,
        tab: TerminalTab
    ) -> CGFloat {
        guard let node = tab.splitTree.zoomed ?? tab.splitTree.root,
              case .leaf(let pane) = node,
              let terminal = pane as? Ghostty.TerminalView,
              let size = terminal.surfaceSize,
              size.cell_height_px > 0
        else { return 0 }
        // The pane's render scale, matching what `cell_height_px` was measured
        // at (same rule as the tmux sizing math).
        let scale = terminal.contentScaleFactor > 0
            ? terminal.contentScaleFactor
            : terminal.traitCollection.displayScale
        guard scale > 0 else { return 0 }
        let cellHeightPx = CGFloat(size.cell_height_px)
        // The grid is pinned top-left inside the surface, inset by the window
        // padding on each edge (balance stays disabled, see
        // PaddingManager.configPadding). Mirror the core's padding math
        // exactly, in framebuffer pixels: it scales the config value by the
        // surface DPI, and font.face.default_dpi is 96 on iOS (72 is macOS
        // only), so each side gets floor(config × scale × 96 / 72) pixels.
        let configPaddingY = CGFloat(PaddingManager.shared.effectivePaddingY)
        let paddingPx = (configPaddingY * scale * 96 / 72).rounded(.down)
        let gridHeightPx = (containerHeight - bottomPadding) * scale - paddingPx * 2
        guard cellHeightPx > 0, gridHeightPx > cellHeightPx else { return 0 }
        let remainderPx = gridHeightPx.truncatingRemainder(dividingBy: cellHeightPx)
        // Keep one pixel of the remainder: a grid height that is an EXACT
        // whole-row multiple sits on the core's integer-floor boundary, and
        // rounding must never cost a row. One spare pixel is invisible.
        return max(0, remainderPx - 1) / scale
    }

    /// The terminal tabs ForEach view.
    @ViewBuilder
    func terminalTabsView(geometry: GeometryProxy, width: CGFloat) -> some View {
        // Read keyboard state directly to ensure SwiftUI tracks these dependencies
        let keyboardFrame = keyboardGeometry.keyboardFrame
        let keyboardHeight = keyboardGeometry.keyboardHeight
        let _ = keyboardGeometry.keyboardStateVersion // Force re-render on keyboard state changes
        let _ = keyboardGeometry.gridMetricsVersion // Re-render on cell-size changes (grid-alignment padding)
        let _ = checkUniquePaneOwnership()
        // `inner` sits outside the container safe-area escape and `expanded`
        // inside it, so their height difference is the expansion UIKit granted
        // this pass. The escape lets the drawable extend into the home-indicator
        // strip; the grid stays above it via ghostty_surface_set_bottom_inset.
        // visionOS/macCatalyst add the bottom inset in terminalBottomPadding
        // instead, so they keep the single-reader path.
        GeometryReader { inner in
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            GeometryReader { expanded in
                terminalTabsStack(
                    geometry: geometry,
                    width: width,
                    containerHeight: expanded.size.height,
                    keyboardFrame: keyboardFrame,
                    keyboardHeight: keyboardHeight,
                    containerBottomSafeAreaExpansion: max(0, expanded.size.height - inner.size.height)
                )
            }
            .ignoresSafeArea(.container, edges: .bottom)
            // Keep in sync with the per-tab `.transaction` in terminalTabsStack.
            // The escape used to sit under that modifier, which is what kept the
            // strip-driven resize off any ambient sheet animation.
            .transaction {
                if appTabSwipeState?.isSettling != true {
                    $0.animation = nil
                }
            }
            #else
            terminalTabsStack(
                geometry: geometry,
                width: width,
                containerHeight: inner.size.height,
                keyboardFrame: keyboardFrame,
                keyboardHeight: keyboardHeight,
                containerBottomSafeAreaExpansion: 0
            )
            #endif
        }
    }

    /// The tabs ZStack. Contains the per-tab `.zIndex` (set by
    /// `appTabSwipeVisualMetrics` to order tabs during an app-tab swipe)
    /// inside its OWN stacking context. A bare `ForEach` would flatten into
    /// the parent `terminalContentZStack`, so the displayed tab's zIndex (1)
    /// would compete with — and paint OVER — the zIndex-0 overlays and effect
    /// layer in that ZStack (search, compose, reconnection…), hiding them
    /// and swallowing touch/keyboard input.
    /// Wrapping in a ZStack scopes those zIndex values to the tabs alone and
    /// restores plain source-order layering against the overlays.
    @ViewBuilder
    private func terminalTabsStack(
        geometry: GeometryProxy,
        width: CGFloat,
        containerHeight: CGFloat,
        keyboardFrame: CGRect,
        keyboardHeight: CGFloat,
        containerBottomSafeAreaExpansion: CGFloat
    ) -> some View {
        ZStack {
            ForEach(Array(terminals.enumerated()), id: \.element.id) { index, tab in
                if !tab.splitTree.isEmpty {
                    let visualMetrics = appTabSwipeVisualMetrics(for: tab.id, width: width)
                    let liveBottomToolbarHeight = tab.focusedPane?.reservedKeyboardToolbarHeightAtBottom ?? 0
                    // During an app-tab swipe both visible tabs must use the
                    // same reservation. The target is not first responder yet,
                    // so its live value is otherwise 0 and its viewport appears
                    // taller beside the toolbar-shortened source tab.
                    let reservedBottomToolbarHeight: CGFloat = appTabSwipeState?
                        .reservedBottomToolbarHeight(for: tab.id)
                        ?? ((index == selectedTabIndex || tab.id == tabsModel.displayedTabID)
                            ? liveBottomToolbarHeight
                            : 0)
                    let bottomPadding = terminalBottomPadding(
                        geometry: geometry,
                        keyboardFrame: keyboardFrame,
                        keyboardHeight: keyboardHeight,
                        reservedBottomToolbarHeight: reservedBottomToolbarHeight,
                        containerBottomSafeAreaExpansion: containerBottomSafeAreaExpansion
                    )
                    let topPadding = bottomPadding.gridAlignsToToolbar
                        ? terminalTopGridAlignmentPadding(
                            containerHeight: containerHeight,
                            bottomPadding: bottomPadding.padding,
                            tab: tab
                        )
                        : 0
                    TerminalSplitTreeView(
                        tree: tab.splitTree,
                        onResize: { node, ratio in
                            handleSplitResize(tabIndex: index, node: node, ratio: ratio)
                        },
                        isActive: index == selectedTabIndex,
                        focusedPane: tab.focusedPane,
                        routesFocusedProgressToIntegratedEdge: topTabStyle == .integrated
                            && !tabBarHidden
                    )
                    // NOTE: the tmux control-mode client size is NOT driven from here.
                    // A tmux pane is a real ghostty surface, so its grid is recomputed
                    // in the core (cell/font/inset-aware) on every resize/keyboard/font
                    // change exactly like a normal surface, and the tmux backend relays
                    // it; the viewer turns a single-pane window's resize into
                    // `refresh-client -C`. Driving it from SwiftUI geometry here would
                    // re-derive the grid in the wrong place and add a round trip.
                    //
                    // The id is scoped by tab. `structuralIdentity` alone compares
                    // leaves by pane OBJECT identity, so two tabs holding the same
                    // pane (a tmux move-pane before the source tab's layout heals)
                    // gave sibling ForEach children an equal explicit id and SwiftUI
                    // trapped in DisplayList.ViewUpdater.ViewCache with "repeated
                    // view". Combining the stable tab UUID keeps the rebuild-on-
                    // structure-change behavior the tmux reconcile depends on.
                    .id(TabSplitTreeIdentity(tabID: tab.id, tree: tab.splitTree.structuralIdentity))
                    // Visibility keys off the lagging displayedTabID (not the
                    // selection) so a freshly opened tab stays hidden, and the
                    // previous tab stays on screen, until its renderer has
                    // presented a first frame. Hit testing and isActive stay on
                    // the selection: input must reach the new tab immediately.
                    //
                    // During an app-tab swipe, visual state deliberately diverges
                    // from selected/displayed state: source and target are both
                    // visible so they can slide beside each other, but input stays
                    // on the current selected/source tab until release commits.
                    .opacity(visualMetrics.opacity)
                    .offset(x: visualMetrics.offsetX)
                    .zIndex(visualMetrics.zIndex)
                    .allowsHitTesting(index == selectedTabIndex && (appTabSwipeState == nil || tab.id == appTabSwipeState?.sourceTabID))
                    .padding(.top, topPadding)
                    .padding(.bottom, bottomPadding.padding)
                    // The safe-area escape moved up to the reader in
                    // terminalTabsView that measures the expansion it grants.
                    .transaction {
                        if appTabSwipeState?.isSettling != true {
                            $0.animation = nil
                        }
                    }
                }
            }
        }
        // App-tab swipe views deliberately travel beyond their own bounds.
        // Clip at the expanded terminal viewport (which already includes the
        // bottom safe-area escape) so they cannot smear beneath the sidebar.
        .clipped()
    }

    private func appTabSwipeVisualMetrics(for tabID: UUID, width: CGFloat) -> (opacity: Double, offsetX: CGFloat, zIndex: Double) {
        guard let state = appTabSwipeState else {
            return (tabID == tabsModel.displayedTabID ? 1 : 0, 0, tabID == tabsModel.displayedTabID ? 1 : 0)
        }

        let effectiveWidth = max(max(width, state.width), 1)
        let translation: CGFloat = switch state.direction {
        case .left:
            min(0, max(-effectiveWidth, state.translationX))
        case .right:
            max(0, min(effectiveWidth, state.translationX))
        }
        let targetEntryOffset = state.direction == .left ? effectiveWidth : -effectiveWidth

        if tabID == state.sourceTabID {
            return (1, translation, 2)
        }
        if tabID == state.targetTabID {
            return (1, translation + targetEntryOffset, 1)
        }
        return (0, 0, 0)
    }

    /// A pane may be a leaf of exactly one tab's split tree. Two tabs sharing a
    /// pane makes two SplitTreeHostingViews fight over the same UIView every
    /// layout pass, and used to crash SwiftUI outright ("repeated view"). Logs
    /// rather than traps so a device build keeps running and names the offenders.
    /// Debug-only; compiles to a no-op in release.
    private func checkUniquePaneOwnership() {
        #if DEBUG
        var owners: [ObjectIdentifier: UUID] = [:]
        for tab in terminals {
            let tabID = tab.id
            for pane in tab.splitTree.terminalLeaves {
                let key = ObjectIdentifier(pane)
                guard let other = owners[key] else {
                    owners[key] = tabID
                    continue
                }
                if other != tabID {
                    let paneUUID = pane.uuid
                    Ghostty.logger.fault(
                        "pane \(paneUUID) is in two tabs' split trees: \(other) and \(tabID)")
                }
            }
        }
        #endif
    }

    /// The main terminal content ZStack (terminals + overlays).
    @ViewBuilder
    func terminalContentZStack(
        geometry: GeometryProxy,
        width: CGFloat
    ) -> some View {
        ZStack {
            tabRevealBackdropFill
            terminalTabsView(geometry: geometry, width: width)
            tmuxReconnectingSwipeFallback
            terminalOverlays()
            if tabTransferDropOverlayVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [TabTransferCoordinator.dragUTType],
                        delegate: WindowTabTransferDropDelegate(
                            windowId: windowId,
                            insertionIndex: {
                                tabsModel.selectedTabID
                                    .flatMap { tabsModel.index(of: $0) }
                                    .map { $0 + 1 }
                            },
                            groupOverride: {
                                tabsModel.isGroupedModeEnabled ? tabsModel.activeGroupID : nil
                            },
                            isWindowFocused: {
                                isWindowFocused
                            }
                        )
                    )
            }
        }
        .frame(width: width)
        // Disable SwiftUI's automatic keyboard avoidance - we handle it manually via terminalBottomPadding
        // which correctly distinguishes docked vs undocked keyboards
        .ignoresSafeArea(.keyboard)
    }

    /// The complete terminal content.
    @ViewBuilder
    func terminalAndSidebarContent(geometry: GeometryProxy) -> some View {
        terminalContentZStack(
            geometry: geometry,
            width: geometry.size.width
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Notification.Name {
    /// A tmux command invoked by keyboard shortcut failed. Carries
    /// `"windowId"` (the originating window, so only that window alerts) and
    /// `"message"` (the error's already user-facing description — tmux's own
    /// `%error` text, or the app-side timeout / invalid-name description).
    /// Consumed by `TmuxShortcutFailureAlert`.
    static let tmuxShortcutCommandFailed = Notification.Name("dev.chr33s.shell.tmuxShortcutCommandFailed")
}

/// Failure alert for the tmux commands reachable by keyboard shortcut.
///
/// The tab menus report the same failures through `TmuxTabDialogCoordinator`,
/// but that coordinator is `@State` on the menu's host view (TabBar), so a
/// MainView method has no way to reach it — and a MainView extension cannot
/// add stored state of its own. So the message lives in this tiny view, which
/// picks it up from the window-scoped `.tmuxShortcutCommandFailed` post.
/// Title, buttons and verbatim message match `TmuxTabMenu`'s
/// `commandFailureAlert` so the two paths look identical to the user;
/// `Text(String)` deliberately picks the non-localizing StringProtocol
/// overload, since the message is the server's own text.
private struct TmuxShortcutFailureAlert: View {
    let windowId: String
    @State private var message: String?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .alert("tmux Command Failed", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .tmuxShortcutCommandFailed)) { notification in
                guard notification.userInfo?["windowId"] as? String == windowId,
                      let text = notification.userInfo?["message"] as? String,
                      !text.isEmpty
                else { return }
                message = text
            }
    }
}

/// Explicit SwiftUI identity for a tab's split-tree subtree: the tab's stable
/// UUID plus the tree's structure. See the `.id(...)` call in `terminalTabsView`.
private struct TabSplitTreeIdentity: Hashable {
    let tabID: UUID
    let tree: SplitTree<SplitPaneView>.StructuralIdentity
}

private struct TmuxReconnectSwipeFallbackView: UIViewRepresentable {
    enum Action {
        case disabled
        case tabNavigation(@MainActor () -> Void)

        var isEnabled: Bool {
            if case .tabNavigation = self { return true }
            return false
        }
    }

    let leftAction: Action
    let rightAction: Action

    func makeCoordinator() -> Coordinator {
        Coordinator(leftAction: leftAction, rightAction: rightAction)
    }

    func makeUIView(context: Context) -> SwipeFallbackUIView {
        let view = SwipeFallbackUIView()
        view.configure(coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: SwipeFallbackUIView, context: Context) {
        context.coordinator.leftAction = leftAction
        context.coordinator.rightAction = rightAction
        uiView.leftSwipe.isEnabled = leftAction.isEnabled
        uiView.rightSwipe.isEnabled = rightAction.isEnabled
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var leftAction: Action
        var rightAction: Action

        init(leftAction: Action, rightAction: Action) {
            self.leftAction = leftAction
            self.rightAction = rightAction
        }

        @objc
        func handleLeftSwipe(_ gesture: UISwipeGestureRecognizer) {
            perform(leftAction)
        }

        @objc
        func handleRightSwipe(_ gesture: UISwipeGestureRecognizer) {
            perform(rightAction)
        }

        private func perform(_ action: Action) {
            guard case .tabNavigation(let handler) = action else { return }
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            handler()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard touch.type == .direct else { return false }
            guard let view = gestureRecognizer.view else { return false }

            // Preserve the window-level tab-sidebar edge pan. A left-edge
            // rightward swipe should open the drawer, not switch to the previous
            // tab. This mirrors TabSidebarEdgeSwipe's activation band.
            if let fallbackView = view as? SwipeFallbackUIView,
               gestureRecognizer === fallbackView.rightSwipe,
               touch.location(in: view).x <= 32 {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class SwipeFallbackUIView: UIView {
        let leftSwipe = UISwipeGestureRecognizer()
        let rightSwipe = UISwipeGestureRecognizer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = true

            leftSwipe.direction = .left
            leftSwipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            leftSwipe.cancelsTouchesInView = false
            addGestureRecognizer(leftSwipe)

            rightSwipe.direction = .right
            rightSwipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            rightSwipe.cancelsTouchesInView = false
            addGestureRecognizer(rightSwipe)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(coordinator: Coordinator) {
            leftSwipe.removeTarget(nil, action: nil)
            rightSwipe.removeTarget(nil, action: nil)

            leftSwipe.addTarget(coordinator, action: #selector(Coordinator.handleLeftSwipe(_:)))
            rightSwipe.addTarget(coordinator, action: #selector(Coordinator.handleRightSwipe(_:)))
            leftSwipe.delegate = coordinator
            rightSwipe.delegate = coordinator
        }
    }
}
