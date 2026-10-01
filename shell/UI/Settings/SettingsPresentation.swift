//
//  SettingsPresentation.swift
//  shell
//
//  The whole Settings surface: Terminal, SSH, tmux, Sync, and the optional
//  Control companion. docs/specs/shell.md §11 is four sections; docs/specs/control-protocol.md adds
//  Control as the one allowed extra.
//

import SwiftUI

/// The top-level settings sections.
enum SettingsSection: String, Hashable, Identifiable, CaseIterable {
    case terminal
    case ssh
    case tmux
    case sync
    case control

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .terminal: "Terminal"
        case .ssh: "SSH"
        case .tmux: "tmux"
        case .sync: "Sync"
        case .control: "Control"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .ssh: "network"
        case .tmux: "square.split.2x2"
        case .sync: "icloud"
        case .control: "applewatch"
        }
    }
}

/// A deep link into a specific settings screen.
enum SettingsDestination: String, Hashable {
    case sshIdentities
    case sshProfiles
    case knownHosts

    /// The section whose navigation stack the destination is pushed onto.
    var section: SettingsSection { .ssh }
}

// MARK: - Content

/// The screen for a section or deep link, shared by the sheet's drill-down
/// stack and the Catalyst window's split view.
extension SettingsSection {
    @ViewBuilder var content: some View {
        switch self {
        case .terminal: SettingsTerminalSection()
        case .ssh: SettingsSSHSection()
        case .tmux: SettingsTmuxSection()
        case .sync: SettingsSyncSection()
        case .control: SettingsControlSection()
        }
    }
}

extension SettingsDestination {
    @ViewBuilder var content: some View {
        switch self {
        case .sshIdentities: SSHKeyManagementView()
        case .sshProfiles: SSHProfilesSettingsView()
        case .knownHosts: KnownHostsView()
        }
    }
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
            .navigationDestination(for: SettingsSection.self) { $0.content }
            .navigationDestination(for: SettingsDestination.self) { $0.content }
            .onAppear(perform: navigateToInitialDestination)
        }
    }

    private func navigateToInitialDestination() {
        guard let initialDestination, !hasNavigatedToInitialDestination else { return }
        hasNavigatedToInitialDestination = true
        path.append(initialDestination.section)
        path.append(initialDestination)
    }
}

// MARK: - Settings Sheet Modifier

/// Presents Settings as a sheet on iPhone, iPad, and visionOS. Mac Catalyst
/// opens `MacSettingsSplitViewController` in its own window instead.
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
