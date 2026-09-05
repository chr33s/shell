//
//  SettingsPresentation.swift
//  shell
//
//  The whole Settings surface: four sections (Terminal, SSH, tmux, Sync)
//  and the sheet that presents them. Spec section 12 — no other settings
//  pages.
//

import SwiftUI

/// The four top-level settings sections.
enum SettingsSection: String, Hashable, Identifiable, CaseIterable {
    case terminal
    case ssh
    case tmux
    case sync

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .terminal: "Terminal"
        case .ssh: "SSH"
        case .tmux: "tmux"
        case .sync: "Sync"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .ssh: "network"
        case .tmux: "square.split.2x2"
        case .sync: "icloud"
        }
    }
}

/// A deep link into a specific settings screen.
enum SettingsDestination: Hashable {
    case sshIdentities
    case sshProfiles
    case knownHosts
}

// MARK: - Root

struct SettingsView: View {
    var initialDestination: SettingsDestination?
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    @State private var hasNavigatedToInitialDestination = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(SettingsSection.allCases) { section in
                        NavigationLink(value: section) {
                            Label(section.title, systemImage: section.systemImage)
                        }
                        .themedRow()
                    }
                }
            }
            .themedList()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        if let onClose { onClose() } else { dismiss() }
                    }
                }
            }
            .navigationDestination(for: SettingsSection.self) { section in
                switch section {
                case .terminal: SettingsTerminalSection()
                case .ssh: SettingsSSHSection()
                case .tmux: SettingsTmuxSection()
                case .sync: SettingsSyncSection()
                }
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .sshIdentities: SSHKeyManagementView()
                case .sshProfiles: SSHProfilesSettingsView()
                case .knownHosts: KnownHostsView()
                }
            }
            .onAppear(perform: navigateToInitialDestination)
        }
    }

    private func navigateToInitialDestination() {
        guard let initialDestination, !hasNavigatedToInitialDestination else { return }
        hasNavigatedToInitialDestination = true
        path.append(SettingsSection.ssh)
        path.append(initialDestination)
    }
}

// MARK: - Settings Sheet Modifier

/// Presents Settings as a sheet on every platform. The fork has no separate
/// iPad/Catalyst side panel.
struct SettingsSheetModifier: ViewModifier {
    @Binding var showSettings: Bool
    var settingsDestination: SettingsDestination?
    var onDismiss: (() -> Void)?

    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showSettings, onDismiss: { onDismiss?() }) {
                SettingsView(
                    initialDestination: settingsDestination,
                    onClose: { showSettings = false }
                )
                .themedSheet(themeColors: themeColors, accentColor: accentColor, colorScheme: colorScheme)
            }
    }
}
