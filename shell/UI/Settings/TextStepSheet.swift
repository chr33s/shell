//
//  TextStepSheet.swift
//  shell
//
//  Reusable sheet for entering a literal text step in a key sequence.
//  Used by both CustomKeyEditorView and SwipeGesturesSettingsView.
//

import SwiftUI

struct TextStepSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    let confirmLabel: String
    let onConfirm: (String) -> Void

    @State private var text: String

    init(
        initialText: String? = nil,
        confirmLabel: String = "Add",
        onConfirm: @escaping (String) -> Void
    ) {
        self.confirmLabel = confirmLabel
        self.onConfirm = onConfirm
        _text = State(initialValue: initialText ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Text to send", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .themedRow()
                } header: {
                    Text("Text to Send")
                } footer: {
                    Text("The text will be sent as terminal input.")
                }
            }
            .themedList()
            .navigationTitle(confirmLabel == "Done" ? "Edit Text" : "Add Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) {
                        onConfirm(text)
                        dismiss()
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
