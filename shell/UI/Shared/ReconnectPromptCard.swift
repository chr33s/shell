//
//  ReconnectPromptCard.swift
//  shell
//
//  Reusable card chrome + password-entry section shared by the terminal
//  reconnection overlay (and future pane types that restore sessions).
//

import SwiftUI

/// Full-bleed dimmed backdrop with a top-anchored glass card: icon slot,
/// title, subtitle, and a caller-supplied content slot underneath.
struct ReconnectPromptCard<Icon: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            // Semi-transparent background
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                icon()

                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.gray)

                content()
            }
            .padding(24)
            .overlayCardBackground()
            .padding(.horizontal, 20)
            .padding(.top, 60)
        }
    }
}

/// Password prompt section for the card's content slot: explanatory
/// prompt, focused secure field, optional "Save Password" toggle, and a
/// Connect button. Owns the typed password locally and hands it (plus the
/// toggle value, always true when the toggle is hidden) to `onSubmit`.
struct ReconnectPasswordSection: View {
    let prompt: String
    var showsSaveToggle: Bool = false
    let onSubmit: (String, Bool) -> Void

    @State private var password: String = ""
    @State private var savePassword = true
    @FocusState private var passwordFieldFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text(prompt)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .focused($passwordFieldFocused)
                .onSubmit(submit)

            if showsSaveToggle {
                Toggle("Save Password", isOn: $savePassword)
                    .frame(maxWidth: 280)
            }

            Button(action: submit) {
                Label("Connect", systemImage: "arrow.right.circle.fill")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty)
        }
        .onAppear {
            passwordFieldFocused = true
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onSubmit(password, savePassword)
    }
}
