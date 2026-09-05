//
//  TmuxSessionDashboardView.swift
//  shell
//
//  Session list for a tmux -CC gateway: lists every session on the server
//  (name, window count, attached marker), switches the gateway's attached
//  session, and creates / renames / kills sessions. One control client
//  displays one session at a time (tmux gates %output on the attached
//  session), so switching re-attaches this gateway; to SHOW two sessions at
//  once, open a second gateway tab to the same host.
//
//  Deliberately plain: spec.md §5 removes session previews, thumbnails,
//  hidden-window synchronization, and advanced window administration menus.
//  What remains is the session switching surface §5 requires.
//

import SwiftUI

/// Sheet payload: which gateway's controller the dashboard drives.
struct TmuxDashboardRequest: Identifiable {
    let id = UUID()
    let controller: TmuxController
}

struct TmuxSessionDashboardView: View {
    let controller: TmuxController
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [TmuxControlSession] = []
    @State private var windowsBySession: [Int: [TmuxControlWindow]] = [:]
    @State private var expandedSessionIds: Set<Int> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingWindowSelectionId: Int?

    // Create / rename alert state
    @State private var showingCreateAlert = false
    @State private var newSessionName = ""
    @State private var renameTarget: TmuxControlSession?
    @State private var renameText = ""
    // Confirmations
    @State private var killTarget: TmuxControlSession?
    @State private var switchTarget: TmuxControlSession?
    @State private var switchTargetWindow: TmuxControlWindow?
    @State private var showingDetachConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.appHighlight)
                            .themedRow()
                    }
                }
                Section("Gateway") {
                    gatewayRow
                        .themedRow()
                }
                Section {
                    ForEach(sessions) { session in
                        sessionRow(session)
                    }
                } footer: {
                    Text("Switching re-attaches this tmux tab's client. To view two sessions at once, open a second connection to this host.")
                }
            }
            .themedList()
            .navigationTitle("tmux Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newSessionName = ""
                        showingCreateAlert = true
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                    .disabled(controller.didEnd)
                }
            }
            .overlay {
                if isLoading && sessions.isEmpty {
                    ProgressView()
                }
            }
        }
        .overlay {
            Button("") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
        .background {
            dialogPresenter
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .presentationDetents([.medium, .large], selection: .constant(.large))
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .tmuxSessionsDidChange)) { note in
            guard isOurGateway(note) else { return }
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tmuxAttachedSessionDidChange)) { note in
            guard isOurGateway(note) else { return }
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tmuxControlModeDidEnd)) { note in
            guard isOurGateway(note) else { return }
            dismiss()
        }
    }

    private var dialogPresenter: some View {
        ZStack {
            createSessionDialog
            renameSessionDialog
            killSessionDialog
            switchSessionDialog
            detachGatewayDialog
        }
    }

    private var createSessionDialog: some View {
        Color.clear.alert("New Session", isPresented: $showingCreateAlert) {
            TextField("Session name", text: $newSessionName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Create & Switch") {
                let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await run { try await controller.createSession(named: name, andSwitch: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a new tmux session on this server and switches this tab's client to it.")
        }
    }

    private var renameSessionDialog: some View {
        Color.clear.alert("Rename Session", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Session name", text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Rename") {
                guard let target = renameTarget else { return }
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await run { try await controller.renameSession(id: target.id, to: name) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var killSessionDialog: some View {
        Color.clear.confirmationDialog(
            killConfirmationTitle,
            isPresented: Binding(
                get: { killTarget != nil },
                set: { if !$0 { killTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Kill Session", role: .destructive) {
                guard let target = killTarget else { return }
                let fallback = sessions.first(where: { $0.id != target.id })?.id
                Task { await run { try await controller.killSession(id: target.id, fallback: fallback) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(killConfirmationMessage)
        }
    }

    private var switchSessionDialog: some View {
        Color.clear.confirmationDialog(
            "Switch Session",
            isPresented: Binding(
                get: { switchTarget != nil },
                set: {
                    if !$0 {
                        switchTarget = nil
                        switchTargetWindow = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Switch", role: .destructive) {
                guard let target = switchTarget else { return }
                if let window = switchTargetWindow {
                    pendingWindowSelectionId = window.id
                    Task { await selectWindowAndDismiss(window, in: target) }
                } else {
                    Task { await switchAndDismiss(to: target.id) }
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This session is attached elsewhere. All attached clients mirror the same windows.")
        }
    }

    private var detachGatewayDialog: some View {
        Color.clear.confirmationDialog(
            "Detach Gateway?",
            isPresented: $showingDetachConfirmation,
            titleVisibility: .visible
        ) {
            Button("Detach Gateway", role: .destructive) {
                controller.detachGatewayClient()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leaves tmux control mode for this tab. The tmux session keeps running on the server.")
        }
    }

    private var killConfirmationTitle: String {
        guard let target = killTarget else { return "Kill Session" }
        return "Kill \"\(target.name)\"?"
    }

    private var killConfirmationMessage: String {
        guard let target = killTarget else { return "" }
        if target.id == controller.currentSessionId {
            return "This is the attached session. Killing it switches this tab to another session, or ends control mode when none remain."
        }
        return "Every program running in that session is terminated."
    }

    // MARK: - Rows

    private var gatewayRow: some View {
        HStack(spacing: 10) {
            Button {
                if controller.selectGatewayTab() {
                    dismiss()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: controller.gatewaySourceSystemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)

                    Text(controller.gatewaySourceDisplayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.didEnd)
            .accessibilityLabel("Gateway \(controller.gatewaySourceDisplayName)")

            Button {
                showingDetachConfirmation = true
            } label: {
                Image(systemName: "eject")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(controller.didEnd)
            .accessibilityLabel("Detach Gateway")

            // Evict every OTHER client (e.g. a small-screen device left
            // attached, clamping the shared window). Shown only while other
            // clients are attached, using the freshly-refreshed session list.
            // (id=tmux-detach-other-clients)
            if otherAttachedClientCount > 0 {
                Button {
                    Task { await run { try await controller.detachOtherClients() } }
                } label: {
                    Image(systemName: "person.2.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(controller.didEnd)
                .accessibilityLabel("Detach ^[\(otherAttachedClientCount) other client](inflect: true)")
            }
        }
    }

    /// Clients other than us attached anywhere on the server, from the
    /// freshly-loaded `sessions` list (one attached client is always us).
    private var otherAttachedClientCount: Int {
        max(0, sessions.reduce(0) { $0 + $1.attachedClients } - 1)
    }

    @ViewBuilder
    private func sessionRow(_ session: TmuxControlSession) -> some View {
        let isCurrent = session.id == controller.currentSessionId
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Tapping a session SWITCHES to it (the primary action). The
                // current session's row expands its window list instead. Both
                // buttons need an explicit non-default style: with a single
                // default Button, List makes the WHOLE row one tap target and
                // the second button never fires.
                Button {
                    if isCurrent {
                        toggleExpanded(session)
                    } else {
                        requestSwitch(to: session)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(session.name)
                                .fontWeight(isCurrent ? .semibold : .regular)
                            if isCurrent {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.appSuccess)
                                    .imageScale(.small)
                            }
                        }
                        HStack(spacing: 8) {
                            Text("\(session.windowCount) window\(session.windowCount == 1 ? "" : "s")")
                            if isCurrent {
                                Text("current")
                            } else if session.isAttachedSomewhere {
                                Text("attached")
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    toggleExpanded(session)
                } label: {
                    Image(systemName: expandedSessionIds.contains(session.id) ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }

            if expandedSessionIds.contains(session.id) {
                windowList(for: session)
            }
        }
        .contextMenu {
            if !isCurrent {
                Button {
                    requestSwitch(to: session)
                } label: {
                    Label("Switch to Session", systemImage: "arrow.right.circle")
                }
            }
            Button {
                renameTarget = session
                renameText = session.name
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                killTarget = session
            } label: {
                Label("Kill Session", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func windowList(for session: TmuxControlSession) -> some View {
        if let windows = windowsBySession[session.id] {
            VStack(alignment: .leading, spacing: 2) {
                if windows.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.tertiary)
                        Text("No windows")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } else {
                    ForEach(windows) { window in
                        windowRow(window, in: session)
                    }
                }
                newWindowRow(for: session)
            }
            .padding(.leading, 12)
            .padding(.vertical, 6)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading windows")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.vertical, 6)
            .padding(.leading, 12)
        }
    }

    private func windowRow(_ window: TmuxControlWindow, in session: TmuxControlSession) -> some View {
        Button {
            selectWindow(window, in: session)
        } label: {
            HStack(spacing: 9) {
                Text("\(window.index)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.fill.tertiary, in: Capsule())

                Text(window.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if window.isActive, session.id == controller.currentSessionId {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.appSuccess)
                }

                Spacer(minLength: 8)

                if pendingWindowSelectionId == window.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .disabled(pendingWindowSelectionId != nil)
    }

    private func newWindowRow(for session: TmuxControlSession) -> some View {
        Button {
            Task { await run { try await controller.createWindow(inSession: session.id) } }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 22)
                Text("New Window")
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(controller.didEnd)
    }

    // MARK: - Actions

    private func isOurGateway(_ note: Notification) -> Bool {
        (note.object as? UUID) == controller.ownerTerminalUUIDForNotifications
    }

    private func toggleExpanded(_ session: TmuxControlSession) {
        if expandedSessionIds.contains(session.id) {
            expandedSessionIds.remove(session.id)
            return
        }
        expandedSessionIds.insert(session.id)
        guard windowsBySession[session.id] == nil else { return }
        Task { @MainActor in
            do {
                windowsBySession[session.id] = try await controller.listWindows(sessionId: session.id)
            } catch {
                windowsBySession[session.id] = []
            }
        }
    }

    private func requestSwitch(to session: TmuxControlSession) {
        // A session that's already attached (another device, or another
        // gateway tab of ours) mirrors its windows to every client. Warn,
        // don't block — that's normal tmux multi-client behavior.
        if session.isAttachedSomewhere {
            switchTarget = session
            switchTargetWindow = nil
        } else {
            Task { await switchAndDismiss(to: session.id) }
        }
    }

    private func selectWindow(_ window: TmuxControlWindow, in session: TmuxControlSession) {
        guard pendingWindowSelectionId == nil, !controller.didEnd else { return }
        if session.id != controller.currentSessionId, session.isAttachedSomewhere {
            switchTarget = session
            switchTargetWindow = window
            return
        }
        pendingWindowSelectionId = window.id
        Task { @MainActor in
            await selectWindowAndDismiss(window, in: session)
        }
    }

    private func selectWindowAndDismiss(_ window: TmuxControlWindow, in session: TmuxControlSession) async {
        defer {
            if pendingWindowSelectionId == window.id {
                pendingWindowSelectionId = nil
            }
        }

        do {
            errorMessage = nil
            if session.id == controller.currentSessionId {
                if controller.selectWindowTab(windowId: window.id) {
                    dismiss()
                } else {
                    errorMessage = "That tmux window is not available yet."
                    await refresh()
                }
            } else {
                try await controller.switchToSession(id: session.id, selectingWindowId: window.id)
                dismiss()
            }
        } catch TmuxCommandError.gatewayEnded {
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func switchAndDismiss(to sessionId: Int) async {
        await run { try await controller.switchToSession(id: sessionId) }
        if errorMessage == nil { dismiss() }
    }

    private func refresh() async {
        // ownerSurfaceFreed: the gateway view freed its surface out from under a
        // dashboard that outlived a tab/scene teardown; dismiss instead of
        // querying through the dangling surface. ROOTSHELL-TMUX
        // (id=tmux-gateway-surface-freed)
        guard !controller.didEnd, !controller.ownerSurfaceFreed else {
            dismiss()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await controller.listSessions()
            errorMessage = nil
            // Refresh any expanded sessions' window lists too (cheap, and the
            // refresh was likely triggered by topology churn).
            for id in expandedSessionIds {
                guard sessions.contains(where: { $0.id == id }) else {
                    expandedSessionIds.remove(id)
                    windowsBySession.removeValue(forKey: id)
                    continue
                }
                windowsBySession[id] = (try? await controller.listWindows(sessionId: id)) ?? []
            }
        } catch TmuxCommandError.gatewayEnded {
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Run a session operation, surfacing failures inline and refreshing after.
    private func run(_ operation: () async throws -> Void) async {
        do {
            errorMessage = nil
            try await operation()
            await refresh()
        } catch TmuxCommandError.gatewayEnded {
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
