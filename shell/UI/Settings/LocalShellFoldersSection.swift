//
//  LocalShellFoldersSection.swift
//  shell
//
//  Settings rows for the folders the sandboxed local shell may enter.
//

#if targetEnvironment(macCatalyst)
import SwiftUI

/// Lists the interpreter shell's home and the folders the user has granted it,
/// with Add and Remove. Shown only when the interpreter is the backend, i.e. the
/// sandboxed Catalyst build; the native shell sees the whole disk already.
struct LocalShellFoldersSection: View {
    @Binding var showsFolderPicker: Bool
    @Binding var errorMessage: String?
    @State private var folders = LocalShellFolders.shared

    var body: some View {
        Section {
            LabeledContent("Home") {
                Text(Self.abbreviated(LocalShellBackend.homeDirectory))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .themedRow()

            ForEach(folders.paths, id: \.self) { path in
                HStack {
                    Label {
                        Text(Self.abbreviated(path))
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        folders.remove(path)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(String(localized: "Remove \(path)", comment: "Local shell folders: remove a granted folder")))
                }
                .themedRow()
            }

            Button {
                showsFolderPicker = true
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            .themedRow()

            if folders.staleCount > 0 {
                Button("Forget Missing Folders") {
                    folders.forgetStale()
                }
                .themedRow()
            }
        } header: {
            // Plain header: grants are bookmarks for this Mac, never a synced setting.
            Text("Folders")
        } footer: {
            Text("The local shell runs inside the app's sandbox. It starts in its home and can enter the folders listed here; add one to work on it from the shell.")
        }
    }

    /// `~` for the account home, so container paths stay readable in one line.
    private static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        // Under the sandbox NSHomeDirectory() is the container; the account home is
        // its ancestor. Use the shortest prefix that applies.
        let userHome = (home as NSString).standardizingPath.components(separatedBy: "/Library/Containers/").first ?? home
        if path.hasPrefix(userHome + "/") { return "~" + path.dropFirst(userHome.count) }
        return path
    }
}
#endif
