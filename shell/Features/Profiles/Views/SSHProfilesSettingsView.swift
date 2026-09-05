//
//  SSHProfilesSettingsView.swift
//  shell
//
//  Saved SSH profiles list (Settings → SSH → Profiles).
//

import SwiftUI

struct SSHProfilesSettingsView: View {
    @State private var profileManager = ConnectionProfileManager.shared
    @State private var editorProfile: SSHProfile?
    @State private var showEditor = false

    var body: some View {
        List {
            if profileManager.profiles.isEmpty {
                Section {
                    Text("No saved hosts yet.")
                        .foregroundStyle(.secondary)
                        .themedRow()
                }
            } else {
                ForEach(profileManager.profiles) { profile in
                    Button {
                        editorProfile = profile
                        showEditor = true
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
                            _ = try? profileManager.duplicateProfile(id: profile.id)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .tint(.accentColor)
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    editorProfile = nil
                    showEditor = true
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            ProfileEditorSheet(profile: editorProfile)
        }
    }
}
