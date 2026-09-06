//
//  TmuxTabMenu.swift
//  shell
//
//  Shared tmux-admin section for tab context menus, used by both the top
//  tab bar (TabBar) and the vertical tab sidebar (VerticalTabSidebar) so
//  the two surfaces expose the same tmux features. Surface-specific items
//  (Connection Info, Transfer, Move Left/Right, theme override, Close)
//  stay in each surface's own menu builder; only the tmux items and their
//  rename/detach dialogs live here.
//
//  Context-menu content cannot usefully own @State (the menu is rebuilt
//  on every presentation), so dialog state lives in a coordinator object
//  held as @State by the HOST view. Menu items mutate the coordinator;
//  the dialogs modifier — applied outside the menu, on the host's body —
//  observes it and presents the alerts/confirmation dialog.
//

import SwiftUI

// MARK: - Dialog Coordinator

/// Dialog state for the shared tmux menu items: which tab is being
/// renamed/detached and the in-flight text-field contents. One instance
/// per host view (TabBar, VerticalTabSidebar), stored as `@State`.
@MainActor @Observable
final class TmuxTabDialogCoordinator {
    var renameWindowTab: TabModel?
    var renameWindowText = ""
    var renameSessionGatewayTab: TabModel?
    var renameSessionText = ""
    var detachConfirmGatewayTab: TabModel?

    /// Message from a tmux command that failed under a user gesture; nil when
    /// no failure alert is up. The menu's actions are fire-and-forget Tasks
    /// with no visible success state, so without this a rejected rename or a
    /// timeout is indistinguishable from the app ignoring the tap. Mirrors
    /// the dashboard's inline `errorMessage` (TmuxSessionDashboardView).
    var commandFailure: String?

    /// Surface a failed tmux command. `TmuxCommandError` is a `LocalizedError`
    /// whose description is already user-facing (tmux's own text for
    /// `.serverError`, e.g. "duplicate session: x").
    func report(_ error: Error) {
        commandFailure = error.localizedDescription
    }

    func requestRenameWindow(_ tab: TabModel) {
        renameWindowText = tab.title
        renameWindowTab = tab
    }

    func requestRenameSession(_ tab: TabModel, controller: TmuxController?) {
        renameSessionText = controller?.currentSessionName ?? ""
        renameSessionGatewayTab = tab
    }

    func requestDetach(_ tab: TabModel) {
        detachConfirmGatewayTab = tab
    }
}

// MARK: - Shared tmux Menu Items

/// The non-destructive tmux admin section of a tab context menu. Renders
/// nothing for plain (non-tmux) tabs; window tabs get rename / move-to-
/// session / new-tab / sessions / hide; gateway tabs get new-tab /
/// sessions / rename-session. The destructive Detach item is separate
/// (`TmuxGatewayDetachMenuItem`) so hosts can place it in their own
/// destructive section.
struct TmuxTabMenuItems: View {
    let tab: TabModel
    /// Resolved by the host (MainView's `tmuxControllerForTab` closure).
    let controller: TmuxController?
    let dialogs: TmuxTabDialogCoordinator
    let onNewTmuxWindow: (TabModel) -> Void
    /// Routing differs per surface: the top bar opens MainView's dashboard
    /// sheet; the sidebar presents its own local sheet (it lives in an
    /// embedded hosting controller).
    let onShowTmuxSessions: (TabModel) -> Void

    /// Window-tab tmux actions need a live window id and must not run
    /// while a reconcile may replace the tab. (id=tmux-hidden-windows)
    private var windowActionsAvailable: Bool {
        tab.isTmuxWindow && tab.tmuxWindowId != nil && !tab.awaitingTmuxReconcile
    }

    var body: some View {
        if tab.isTmuxWindow {
            if windowActionsAvailable {
                Button {
                    dialogs.requestRenameWindow(tab)
                } label: {
                    Label("Rename Tab", systemImage: "pencil")
                }
                moveToSessionMenu
            }
            Button {
                onNewTmuxWindow(tab)
            } label: {
                Label("New tmux Tab", systemImage: "plus.rectangle.on.rectangle")
            }
            Button {
                onShowTmuxSessions(tab)
            } label: {
                Label("tmux Sessions", systemImage: "rectangle.split.3x1")
            }
            if windowActionsAvailable {
                Button {
                    if let windowId = tab.tmuxWindowId {
                        controller?.hideWindow(windowId: windowId)
                    }
                } label: {
                    Label("Hide Tab", systemImage: "eye.slash")
                }
            }
        } else if tab.isTmuxGateway, let controller, controller.isActive {
            Button {
                onNewTmuxWindow(tab)
            } label: {
                Label("New tmux Tab", systemImage: "plus.rectangle.on.rectangle")
            }
            Button {
                onShowTmuxSessions(tab)
            } label: {
                Label("tmux Sessions", systemImage: "rectangle.split.3x1")
            }
            Button {
                dialogs.requestRenameSession(tab, controller: controller)
            } label: {
                Label("Rename Session", systemImage: "pencil")
            }
            // Evict other clients (e.g. a small-screen device left attached,
            // clamping the shared window). Shown unconditionally on the gateway:
            // the prior `otherAttachedClientCount > 0` gate read cachedSessions,
            // which the top tab bar only warms on appear/tab-count change — so
            // the option flickered in/out versus the sidebar (which re-warms on
            // every open). `detach-client -a` is safe with no other clients
            // attached (tmux skips the issuing control client), so always
            // offering it is both deterministic and harmless, and matches the
            // keyboard shortcut. (id=tmux-detach-other-clients)
            Button {
                Task { @MainActor in
                    do {
                        try await controller.detachOtherClients()
                    } catch TmuxCommandError.gatewayEnded {
                        // Control mode already ended; its teardown is the feedback.
                    } catch {
                        dialogs.report(error)
                    }
                }
            } label: {
                Label("Detach Other Clients", systemImage: "person.2.slash")
            }
            // Hide/show the gateway tab itself: the strip and tab navigation
            // skip it while hidden; the sidebar keeps its dimmed group header
            // as the recovery affordance. Hide is gated on ≥1 visible window
            // tab (canHideGatewayTab). In the top bar only Hide is reachable —
            // a hidden gateway is filtered out of the strip.
            // (id=tmux-hidden-gateway)
            if tab.isHiddenTmuxWindow {
                Button {
                    controller.showGatewayTab(andSelect: true)
                } label: {
                    Label("Show Gateway Tab", systemImage: "eye")
                }
            } else if controller.canHideGatewayTab {
                Button {
                    controller.hideGatewayTab()
                } label: {
                    Label("Hide Gateway Tab", systemImage: "eye.slash")
                }
            }
        }
    }

    @ViewBuilder
    private var moveToSessionMenu: some View {
        if let controller, controller.isActive {
            let otherSessions = controller.cachedSessions
                .filter { $0.id != controller.currentSessionId }
            if !otherSessions.isEmpty {
                Menu {
                    ForEach(otherSessions) { destination in
                        Button(destination.name) {
                            guard let windowId = tab.tmuxWindowId else { return }
                            Task { @MainActor in
                                do {
                                    try await controller.moveWindow(id: windowId, toSession: destination.id)
                                } catch TmuxCommandError.gatewayEnded {
                                    // Control mode already ended; its teardown is the feedback.
                                } catch {
                                    dialogs.report(error)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Move to Session", systemImage: "arrow.turn.up.right")
                }
            }
        }
    }
}

/// Destructive "Detach" item for a tmux gateway tab. Separate from
/// `TmuxTabMenuItems` so each surface can place it in its destructive
/// section (next to Close), keeping menu ordering idiomatic per surface.
struct TmuxGatewayDetachMenuItem: View {
    let tab: TabModel
    let controller: TmuxController?
    let dialogs: TmuxTabDialogCoordinator

    var body: some View {
        if tab.isTmuxGateway, let controller, controller.isActive {
            Button(role: .destructive) {
                dialogs.requestDetach(tab)
            } label: {
                Label("Detach", systemImage: "eject")
            }
        }
    }
}

// MARK: - Dialogs Modifier

/// Hosts the rename-window / rename-session alerts and the detach
/// confirmation dialog driven by a `TmuxTabDialogCoordinator`. Applied to
/// the host view's body (NOT inside the context menu) via
/// `.tmuxTabDialogs(coordinator:controller:)`. Presentation anchors hang
/// off a zero-sized hidden background, the same pattern the sidebar used
/// for its local dialogs.
private struct TmuxTabDialogsModifier: ViewModifier {
    @Bindable var dialogs: TmuxTabDialogCoordinator
    let controller: (TabModel) -> TmuxController?

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                renameWindowDialog
                renameSessionDialog
                detachGatewayDialog
                commandFailureAlert
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private var renameWindowDialog: some View {
        Color.clear.alert("Rename Tab", isPresented: Binding(
            get: { dialogs.renameWindowTab != nil },
            set: { if !$0 { dialogs.renameWindowTab = nil } }
        )) {
            TextField("Tab name", text: $dialogs.renameWindowText)
                .autocorrectionDisabled()
                #if !os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("Rename") {
                guard let tab = dialogs.renameWindowTab,
                      let windowId = tab.tmuxWindowId,
                      let controller = controller(tab) else { return }
                let name = dialogs.renameWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { @MainActor in
                    do {
                        try await controller.renameWindow(id: windowId, to: name)
                    } catch TmuxCommandError.gatewayEnded {
                        // Control mode already ended; its teardown is the feedback.
                    } catch {
                        dialogs.report(error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var renameSessionDialog: some View {
        Color.clear.alert("Rename Session", isPresented: Binding(
            get: { dialogs.renameSessionGatewayTab != nil },
            set: { if !$0 { dialogs.renameSessionGatewayTab = nil } }
        )) {
            TextField("Session name", text: $dialogs.renameSessionText)
                .autocorrectionDisabled()
                #if !os(visionOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("Rename") {
                guard let tab = dialogs.renameSessionGatewayTab,
                      let controller = controller(tab),
                      let sessionId = controller.currentSessionId else { return }
                let name = dialogs.renameSessionText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { @MainActor in
                    do {
                        try await controller.renameSession(id: sessionId, to: name)
                    } catch TmuxCommandError.gatewayEnded {
                        // Control mode already ended; its teardown is the feedback.
                    } catch {
                        dialogs.report(error)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var detachGatewayDialog: some View {
        Color.clear.confirmationDialog(
            "Detach Gateway?",
            isPresented: Binding(
                get: { dialogs.detachConfirmGatewayTab != nil },
                set: { if !$0 { dialogs.detachConfirmGatewayTab = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Detach Gateway", role: .destructive) {
                guard let tab = dialogs.detachConfirmGatewayTab,
                      let controller = controller(tab) else { return }
                controller.detachGatewayClient()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leaves tmux control mode for this tab. The tmux session keeps running on the server.")
        }
    }

    /// Failure surface for the menu's tmux commands. The message is tmux's own
    /// text (or the app-side timeout / invalid-name description), so it is
    /// shown verbatim — `Text(String)` deliberately picks the non-localizing
    /// StringProtocol overload here.
    private var commandFailureAlert: some View {
        Color.clear.alert("tmux Command Failed", isPresented: Binding(
            get: { dialogs.commandFailure != nil },
            set: { if !$0 { dialogs.commandFailure = nil } }
        )) {
            Button("OK", role: .cancel) { dialogs.commandFailure = nil }
        } message: {
            Text(dialogs.commandFailure ?? "")
        }
    }
}

extension View {
    /// Attach the shared tmux rename/detach dialogs driven by `coordinator`.
    func tmuxTabDialogs(
        coordinator: TmuxTabDialogCoordinator,
        controller: @escaping (TabModel) -> TmuxController?
    ) -> some View {
        modifier(TmuxTabDialogsModifier(dialogs: coordinator, controller: controller))
    }
}
