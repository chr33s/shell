//
//  SSHConnectionView.swift
//  shell
//
//  The launch / connection screen (spec section 13):
//
//      +--------------------------+
//      | New Local Terminal       |
//      |                          |
//      | SSH                      |
//      | ------------------------ |
//      | production               |
//      | home-server              |
//      | dev-vm                   |
//      |                          |
//      | + Add SSH Host           |
//      +--------------------------+
//
//  Selecting a profile immediately opens a terminal tab.
//

import SwiftUI

/// Which list the connection screen opens on. The fork has a single list, so
/// these only distinguish "open the profile list" from "open the editor".
enum ConnectionSidebarTab: Hashable {
    case lastUsed
    case profiles
    case newHost
}

struct SSHConnectionView: View {
    /// Pre-filled configuration (reconnect / deep link). When set, the editor
    /// opens on this config instead of the profile list.
    var initialConfig: SSHConfig?

    var connectionError: String?

    /// Connect with an ad-hoc configuration (or `nil` for a local terminal).
    var onConnect: (SSHConfig?, SplitOption) -> Void

    /// Connect using a saved profile.
    var onProfileConnect: ((SSHProfile, SplitOption) -> Void)?

    /// When the terminal list is empty there is nothing behind this screen, so
    /// it must not be dismissable.
    var preventDismissal: Bool = false

    /// Sidebar close callback. When set, "Cancel" becomes "Done" and calls this
    /// instead of `dismiss()`.
    var onClose: (() -> Void)?

    /// Which list to show on appear.
    var initialTab: ConnectionSidebarTab?

    @Environment(\.dismiss) private var dismiss
    @State private var profileManager = ConnectionProfileManager.shared
    @State private var editorProfile: SSHProfile?
    @State private var editorConfig: SSHConfig?
    @State private var showEditor = false
    @State private var splitOption: SplitOption = .newTab

    init(
        initialConfig: SSHConfig? = nil,
        connectionError: String? = nil,
        onConnect: @escaping (SSHConfig?, SplitOption) -> Void,
        onProfileConnect: ((SSHProfile, SplitOption) -> Void)? = nil,
        preventDismissal: Bool = false,
        onClose: (() -> Void)? = nil,
        initialTab: ConnectionSidebarTab? = nil
    ) {
        self.initialConfig = initialConfig
        self.connectionError = connectionError
        self.onConnect = onConnect
        self.onProfileConnect = onProfileConnect
        self.preventDismissal = preventDismissal
        self.onClose = onClose
        self.initialTab = initialTab
    }

    /// Where a new session lands.
    enum SplitOption: String, CaseIterable {
        case newTab = "New Tab"
        case splitRight = "Split Right"
        case splitDown = "Split Down"

        var displayName: String {
            switch self {
            case .newTab: return String(localized: "New Tab")
            case .splitRight: return String(localized: "Split Right")
            case .splitDown: return String(localized: "Split Down")
            }
        }

        var systemImage: String {
            switch self {
            case .newTab: return "plus.rectangle.on.rectangle"
            case .splitRight: return "rectangle.split.2x1"
            case .splitDown: return "rectangle.split.1x2"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onConnect(nil, splitOption)
                        close()
                    } label: {
                        Label("New Local Terminal", systemImage: "terminal")
                    }
                    .themedRow()
                }

                Section {
                    if profileManager.profiles.isEmpty {
                        Text("No saved hosts yet.")
                            .foregroundStyle(.secondary)
                            .themedRow()
                    } else {
                        ForEach(profileManager.profiles) { profile in
                            profileRow(profile)
                        }
                    }

                    Button {
                        editorProfile = nil
                        editorConfig = nil
                        showEditor = true
                    } label: {
                        Label("Add SSH Host", systemImage: "plus")
                    }
                    .themedRow()
                } header: {
                    Text("SSH")
                }

                Section {
                    Picker("Open In", selection: $splitOption) {
                        ForEach(SplitOption.allCases, id: \.self) { option in
                            Label(option.displayName, systemImage: option.systemImage).tag(option)
                        }
                    }
                    .themedRow()
                }
            }
            .themedList()
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !preventDismissal {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(onClose == nil ? "Cancel" : "Done") { close() }
                    }
                }
            }
            .sheet(isPresented: $showEditor) {
                ProfileEditorSheet(
                    profile: editorProfile,
                    initialConfig: editorConfig,
                    connectionError: connectionError,
                    onConnect: { config in
                        showEditor = false
                        onConnect(config, splitOption)
                        close()
                    }
                )
            }
            .onAppear(perform: applyInitialState)
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: SSHProfile) -> some View {
        Button {
            connect(profile)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(profile.displayString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .themedRow()
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                try? profileManager.deleteProfile(id: profile.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                editorProfile = profile
                editorConfig = nil
                showEditor = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.accentColor)
        }
    }

    private func connect(_ profile: SSHProfile) {
        // Record usage only on the branch this view actually dispatches itself.
        // `onProfileConnect` handlers (MainView.connectToProfile) already call
        // `recordUsage`, and it is not idempotent (`useCount += 1`), so calling
        // it here too double-counted every profile launched from this list and
        // skewed `ProfileSortOrder` / `getSuggestions` against profiles launched
        // from other paths. Do not hoist this call back out of the `else`.
        if let onProfileConnect {
            onProfileConnect(profile, splitOption)
        } else {
            profileManager.recordUsage(id: profile.id)
            onConnect(profile.sshConfig, splitOption)
        }
        close()
    }

    private func applyInitialState() {
        if let initialConfig {
            editorProfile = nil
            editorConfig = initialConfig
            showEditor = true
            return
        }
        if initialTab == .newHost {
            editorProfile = nil
            editorConfig = nil
            showEditor = true
        }
    }

    /// Dismiss the view — uses `onClose` for the sidebar, `dismiss()` for a sheet.
    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
