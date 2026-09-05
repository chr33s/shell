import SwiftUI
import UIKit

/// Modal for answering a keyboard-interactive (RFC 4256) SSH challenge: the
/// server supplies a name/instruction and one or more prompts (each marked echo
/// or no-echo), commonly used for OTP/2FA or PAM password flows. Mirrors
/// ``PasswordPromptSheet`` styling.
struct KeyboardInteractivePromptView: View {
    let challenge: KeyboardInteractiveChallenge
    let sessionLabel: String
    let onSubmit: ([String]) -> Void
    let onCancel: () -> Void
    /// Factory for the session's live auth-banner state stream, shown
    /// display-only above the prompts. The sheet covers the pane's
    /// auth-banner card on iPhone, so OTP-style banner instructions (and
    /// their URLs) must appear here too.

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var responses: [String]
    @FocusState private var focusedIndex: Int?

    init(
        challenge: KeyboardInteractiveChallenge,
        sessionLabel: String,
        onSubmit: @escaping ([String]) -> Void,
        onCancel: @escaping () -> Void,
    ) {
        self.challenge = challenge
        self.sessionLabel = sessionLabel
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _responses = State(initialValue: Array(repeating: "", count: challenge.prompts.count))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading) {
                            Text(sessionLabel)
                                .font(.headline)
                            if !challenge.name.isEmpty {
                                Text(challenge.name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .themedRow()
                } header: {
                    Text("Connection")
                } footer: {
                    if !challenge.instruction.isEmpty {
                        Text(challenge.instruction)
                    }
                }

                if challenge.prompts.isEmpty {
                    Section {
                        Text("No input required. Tap Continue to proceed.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .themedRow()
                    }
                } else {
                    Section {
                        ForEach(challenge.prompts.indices, id: \.self) { index in
                            promptField(index: index)
                        }
                    } header: {
                        Text(challenge.prompts.count > 1 ? "Server Prompts" : "Server Prompt")
                    }
                }
            }
            .themedList()
            .navigationTitle("Authentication")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(challenge.prompts.isEmpty ? "Continue" : "Submit") {
                        onSubmit(responses)
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                guard !challenge.prompts.isEmpty else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedIndex = 0
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    /// Index of the first password-like (no-echo) prompt, if any. The hidden
    /// username AutoFill anchor is attached to this field so the OS password
    /// manager can match the saved credential. Nil for OTP-only challenges,
    /// which have no saved-password credential to match.
    private var usernameAnchorIndex: Int? {
        guard !challenge.username.isEmpty else { return nil }
        return challenge.prompts.firstIndex {
            !$0.echo && KeyboardInteractiveSecretKind.classify($0.prompt) == .password
        }
    }

    /// Zero-size, invisible username field. Attached as a `.background` (not a
    /// list row) so it stays in the hierarchy for AutoFill association without
    /// adding any visible row or layout space to the form.
    @ViewBuilder
    private var usernameAnchor: some View {
        TextField("", text: .constant(challenge.username))
            .textContentType(.username)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func promptField(index: Int) -> some View {
        let prompt = challenge.prompts[index]
        let label = prompt.prompt.isEmpty ? "Response" : prompt.prompt
        Group {
            if prompt.echo {
                TextField(label, text: $responses[index])
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                // Hidden field. Pick the AutoFill content type from the prompt
                // text: `.password` surfaces the OS password-manager key,
                // `.oneTimeCode` surfaces the 2FA/OTP suggestion strip.
                SecureField(label, text: $responses[index])
                    .textContentType(KeyboardInteractiveSecretKind.classify(prompt.prompt) == .password
                                     ? .password : .oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .background { if index == usernameAnchorIndex { usernameAnchor } }
            }
        }
        .focused($focusedIndex, equals: index)
        .submitLabel(index == challenge.prompts.count - 1 ? .go : .next)
        .onSubmit {
            if index < challenge.prompts.count - 1 {
                focusedIndex = index + 1
            } else {
                onSubmit(responses)
            }
        }
        .themedRow()
    }
}
