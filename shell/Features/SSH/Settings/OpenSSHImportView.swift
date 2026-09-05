//
//  OpenSSHImportView.swift
//  shell
//
//  Settings entry for importing ~/.ssh/config (and the keys it references)
//  as ConnectionProfiles. UX mirrors GhosttyConfigImportView: discovery
//  section -> preview sheet -> folder picker -> summary sheet.
//

import SwiftUI
import UniformTypeIdentifiers
import os.log

struct OpenSSHImportView: View {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "OpenSSHImport")

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var showFolderPicker = false
    @State private var pickerError: String?
    @State private var planError: String?

    @State private var pendingPlan: OpenSSHImportPlan?
    @State private var summary: OpenSSHImportSummary?

    @State private var autoDetected: [URL] = []

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Import from OpenSSH")
                        .font(.headline)
                    Text("Read a .ssh folder (the one with your config and id_* files) and turn each Host entry into a connection profile. Private keys referenced by IdentityFile are imported into the keychain if they aren't already there. Passwords are never read from disk.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }

            if !autoDetected.isEmpty {
                Section {
                    ForEach(autoDetected, id: \.self) { url in
                        Button {
                            handleDirectoryURL(url, requiresSecurityScope: false)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill.badge.gearshape")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayLabel(for: url))
                                        .font(.body)
                                    Text(displayPath(for: url))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .themedRow()
                    }
                } header: {
                    Text("Found")
                } footer: {
                    autoDetectedFooter
                }
            }

            Section {
                Button {
                    showFolderPicker = true
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("Select .ssh folder…")
                    }
                }
                .themedRow()
            } footer: {
                Text(manualPickFooter)
            }

            #if !targetEnvironment(macCatalyst)
            if autoDetected.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No .ssh folder in shell", systemImage: "info.circle")
                            .font(.subheadline)
                        Text("Open the Files app, go to the shell folder, create a folder called \".ssh\" inside it, then copy your config and id_* files into it. Come back here to import.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }
            }
            #endif
        }
        .themedList()
        .navigationTitle("Import from OpenSSH")
        .onAppear { refreshAutoDetected() }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            onCompletion: handleFolderSelection
        )
        .sheet(item: $pendingPlan) { plan in
            NavigationStack {
                OpenSSHImportPreviewSheet(
                    plan: plan,
                    onCancel: { pendingPlan = nil },
                    onApply: { folderPath, keyOverrides in
                        var applied = plan
                        applied.keys = applied.keys.map { keyPlan in
                            var copy = keyPlan
                            if let override = keyOverrides[keyPlan.id] {
                                copy.includeOnImport = override.include
                                copy.passphrase = override.passphrase
                            }
                            return copy
                        }
                        let result = OpenSSHImporter.apply(plan: applied, folderPath: folderPath)
                        pendingPlan = nil
                        summary = result
                    }
                )
            }
            .themedSubSheet(sheetThemeColors)
        }
        .sheet(item: $summary) { result in
            NavigationStack {
                OpenSSHImportSummarySheet(summary: result, onDismiss: { summary = nil })
            }
            .themedSubSheet(sheetThemeColors)
        }
        .alert("Import Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) {
                pickerError = nil
                planError = nil
            }
        } message: {
            Text(pickerError ?? planError ?? "")
        }
    }

    // MARK: - Bindings

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { pickerError != nil || planError != nil },
            set: { if !$0 { pickerError = nil; planError = nil } }
        )
    }

    // MARK: - Footer copy

    private var autoDetectedFooter: some View {
        #if targetEnvironment(macCatalyst)
        Text("Detected .ssh folders on this Mac.")
        #else
        Text("Detected .ssh folder inside the shell folder.")
        #endif
    }

    private var manualPickFooter: String {
        #if STANDALONE
        return "Pick any folder that contains an ssh config file. On macOS this is usually ~/.ssh."
        #elseif APPSTORE
        return "Pick the .ssh folder you want to import. You'll be prompted to grant access."
        #else
        return "Pick the .ssh folder you want to import. On iPad, the folder lives inside the shell folder in Files."
        #endif
    }

    // MARK: - Auto-detect

    private func refreshAutoDetected() {
        var urls: [URL] = []
        for url in candidateAutoDetectURLs() {
            if isUsableSSHDirectory(url) {
                urls.append(url)
            }
        }
        autoDetected = urls
    }

    /// Candidate paths the importer auto-detects on each platform.
    private func candidateAutoDetectURLs() -> [URL] {
        var urls: [URL] = []
        #if STANDALONE
        let homeSSH = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)
        urls.append(homeSSH)
        #endif
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(documents.appendingPathComponent(".ssh", isDirectory: true))
        }
        return urls
    }

    private func isUsableSSHDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // Require a config file inside; without one the import has nothing to do.
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("config").path)
    }

    // MARK: - Display helpers

    private func displayLabel(for url: URL) -> String {
        #if STANDALONE
        if url.path.hasPrefix(NSHomeDirectory()) { return "~/.ssh" }
        #endif
        // On iOS the Files-app label for the Documents directory is "shell".
        if url.path.contains("/Documents/.ssh") { return "shell/.ssh" }
        return url.lastPathComponent
    }

    private func displayPath(for url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    // MARK: - File picker handling

    private func handleFolderSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            handleDirectoryURL(url, requiresSecurityScope: true)
        case .failure(let error):
            pickerError = error.localizedDescription
        }
    }

    /// Build a plan from a chosen directory. When `requiresSecurityScope` is
    /// true (file-picker path on sandboxed builds), wrap reads with the
    /// security-scoped resource lifecycle.
    private func handleDirectoryURL(_ url: URL, requiresSecurityScope: Bool) {
        let started = requiresSecurityScope ? url.startAccessingSecurityScopedResource() : true
        defer {
            if requiresSecurityScope && started {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let plan = try OpenSSHImporter.preview(sshDirectory: url)
            pendingPlan = plan
        } catch {
            planError = error.localizedDescription
        }
    }
}

// MARK: - Preview sheet

private struct OpenSSHImportPreviewSheet: View {
    let plan: OpenSSHImportPlan
    let onCancel: () -> Void
    let onApply: (_ folderPath: String, _ keyOverrides: [UUID: KeyOverride]) -> Void

    @Environment(\.sheetThemeColors) private var sheetThemeColors

    struct KeyOverride {
        var include: Bool
        var passphrase: String
    }

    /// Local mirror of editable key state so toggles and passphrase entry don't
    /// require mutating the plan struct in place.
    @State private var keyState: [UUID: KeyOverride] = [:]
    @State private var folderPath: String = ""

    var body: some View {
        List {
            // Summary header
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headerTitle).font(.headline)
                    Text(headerDetail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }

            // Profiles
            if !plan.profiles.isEmpty {
                Section {
                    ForEach(plan.profiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundColor(.accentColor)
                                Text(profile.name)
                                    .font(.body)
                                if profile.aliases.count > 1 {
                                    Text("+\(profile.aliases.count - 1) alias")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .cornerRadius(4)
                                }
                                Spacer()
                            }
                            Text(profile.connectionLine)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let jump = profile.jumpHostDisplay {
                                Text("via \(jump)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .themedRow()
                    }
                } header: {
                    Text("Profiles to Create (\(plan.profiles.count))")
                }
            }

            // Keys
            if !plan.keys.isEmpty {
                Section {
                    ForEach(plan.keys) { key in
                        keyRow(for: key)
                            .themedRow()
                    }
                } header: {
                    Text("Keys (\(plan.keys.count))")
                } footer: {
                    Text("Toggle off any key you don't want imported. Already-imported keys are matched by fingerprint.")
                }
            }

            // Skipped
            if !plan.skipped.isEmpty {
                Section {
                    ForEach(plan.skipped) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.subheadline)
                            Text(item.reason)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                } header: {
                    Text("Skipped (\(plan.skipped.count))")
                }
            }

            // Warnings
            if !plan.warnings.isEmpty {
                Section {
                    ForEach(plan.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .themedRow()
                    }
                } header: {
                    Text("Notes")
                }
            }
        }
        .themedList()
        .navigationTitle("Review Import")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { seedKeyState() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Import") {
                    onApply(folderPath, keyState)
                }
                .disabled(!plan.hasAnythingToApply)
            }
        }
    }

    // MARK: - Key row UI

    @ViewBuilder
    private func keyRow(for key: OpenSSHKeyPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: key.status))
                    .foregroundColor(iconColor(for: key.status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.filename).font(.body)
                    Text(statusText(for: key))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if isToggleable(key.status) {
                    Toggle("", isOn: includeBinding(for: key))
                        .labelsHidden()
                }
            }

            if shouldShowPassphraseField(key) {
                SecureField("Passphrase", text: passphraseBinding(for: key))
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                Text("Used once to decrypt the key during import; never stored.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func iconName(for status: OpenSSHKeyPlan.Status) -> String {
        switch status {
        case .readyForImport(_, true): return "lock.fill"
        case .readyForImport(_, false): return "key.fill"
        case .alreadyImported: return "checkmark.seal.fill"
        case .fileMissing: return "questionmark.folder"
        case .parseFailed: return "exclamationmark.triangle.fill"
        }
    }

    private func iconColor(for status: OpenSSHKeyPlan.Status) -> Color {
        switch status {
        case .readyForImport(_, true): return .appHighlight
        case .readyForImport(_, false): return .accentColor
        case .alreadyImported: return .appSuccess
        case .fileMissing: return .secondary
        case .parseFailed: return .appDanger
        }
    }

    private func statusText(for key: OpenSSHKeyPlan) -> String {
        switch key.status {
        case .readyForImport(_, true):
            return "Encrypted, passphrase needed"
        case .readyForImport(let fp, false):
            return String(localized: "Ready to import (SHA256:\(fp.prefix(12))…)", comment: "OpenSSH import validation status")
        case .alreadyImported(_, let name, _):
            return String(localized: "Already in keychain as '\(name)'", comment: "OpenSSH import validation status")
        case .fileMissing:
            return String(localized: "File not found at \(key.path)", comment: "OpenSSH import validation status")
        case .parseFailed(let msg):
            return String(localized: "Could not parse: \(msg)", comment: "OpenSSH import validation status")
        }
    }

    private func isToggleable(_ status: OpenSSHKeyPlan.Status) -> Bool {
        if case .readyForImport = status { return true }
        return false
    }

    private func shouldShowPassphraseField(_ key: OpenSSHKeyPlan) -> Bool {
        guard let override = keyState[key.id], override.include else { return false }
        if case .readyForImport(_, true) = key.status { return true }
        return false
    }

    private func seedKeyState() {
        guard keyState.isEmpty else { return }
        var seed: [UUID: KeyOverride] = [:]
        for key in plan.keys {
            seed[key.id] = KeyOverride(include: key.includeOnImport, passphrase: key.passphrase)
        }
        keyState = seed
    }

    private func includeBinding(for key: OpenSSHKeyPlan) -> Binding<Bool> {
        Binding(
            get: { keyState[key.id]?.include ?? key.includeOnImport },
            set: { newValue in
                var current = keyState[key.id] ?? KeyOverride(include: key.includeOnImport, passphrase: key.passphrase)
                current.include = newValue
                keyState[key.id] = current
            }
        )
    }

    private func passphraseBinding(for key: OpenSSHKeyPlan) -> Binding<String> {
        Binding(
            get: { keyState[key.id]?.passphrase ?? key.passphrase },
            set: { newValue in
                var current = keyState[key.id] ?? KeyOverride(include: key.includeOnImport, passphrase: key.passphrase)
                current.passphrase = newValue
                keyState[key.id] = current
            }
        )
    }

    // MARK: - Header

    private var headerTitle: String {
        plan.sshDirectory.path.contains("/Documents/.ssh")
            ? "shell/.ssh"
            : plan.sshDirectory.path
    }

    private var headerDetail: String {
        let profilesPart = "\(plan.profiles.count) profile(s)"
        let keysPart = "\(plan.keys.count) key file(s)"
        let skippedPart = plan.skipped.isEmpty ? "" : ", \(plan.skipped.count) skipped"
        return "\(profilesPart), \(keysPart)\(skippedPart)"
    }
}

private extension OpenSSHProfilePlan {
    var connectionLine: String {
        let portSuffix = port == 22 ? "" : ":\(port)"
        return "\(user)@\(hostName)\(portSuffix)"
    }
}

// MARK: - Summary sheet

private struct OpenSSHImportSummarySheet: View {
    let summary: OpenSSHImportSummary
    let onDismiss: () -> Void

    var body: some View {
        List {
            Section {
                Label {
                    Text("Created \(summary.profilesCreated) profile(s)")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.appSuccess)
                }
                .themedRow()

                if summary.keysImported > 0 {
                    Label {
                        Text("Imported \(summary.keysImported) new key(s)")
                    } icon: {
                        Image(systemName: "key.fill")
                            .foregroundColor(.accentColor)
                    }
                    .themedRow()
                }

                if summary.keysSkippedAlreadyPresent > 0 {
                    Label {
                        Text("\(summary.keysSkippedAlreadyPresent) key(s) already in keychain")
                    } icon: {
                        Image(systemName: "checkmark.seal")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }

                if summary.skippedCount > 0 {
                    Label {
                        Text("Skipped \(summary.skippedCount) host(s) (wildcards or duplicates)")
                    } icon: {
                        Image(systemName: "minus.circle")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }

                if !summary.folderPath.isEmpty {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Folder")
                                .font(.subheadline)
                            Text(summary.folderPath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } icon: {
                        Image(systemName: "folder.fill")
                    }
                    .themedRow()
                }
            }

            if !summary.keysFailedToImport.isEmpty {
                Section {
                    ForEach(Array(summary.keysFailedToImport.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.filename).font(.subheadline)
                            Text(item.reason).font(.caption).foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                } header: {
                    Text("Keys That Did Not Import")
                }
            }

            if !summary.profilesFailedToCreate.isEmpty {
                Section {
                    ForEach(Array(summary.profilesFailedToCreate.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.subheadline)
                            Text(item.reason).font(.caption).foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                } header: {
                    Text("Profiles That Did Not Save")
                }
            }

            if !summary.warnings.isEmpty {
                Section {
                    ForEach(summary.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "info.circle")
                            .font(.caption)
                            .themedRow()
                    }
                } header: {
                    Text("Notes")
                }
            }
        }
        .themedList()
        .navigationTitle("Import Complete")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDismiss)
            }
        }
    }
}
