//
//  KeyComboPickerSheet.swift
//  shell
//
//  Reusable sheet for picking a key combination (modifiers + key).
//  Used by CustomKeyEditorView (toolbar custom keys). A second consumer,
//  SwipeGesturesSettingsView, no longer exists in the tree.
//

import SwiftUI

struct KeyComboPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    let confirmLabel: String
    let onConfirm: (SequenceStep.KeyCombo) -> Void

    @State private var selectedModifiers: Set<SequenceStep.KeyModifier>
    @State private var selectedKey: SequenceStep.ComboKey?
    @State private var activeTab: KeyTab

    init(
        initialCombo: SequenceStep.KeyCombo? = nil,
        confirmLabel: String = "Add",
        onConfirm: @escaping (SequenceStep.KeyCombo) -> Void
    ) {
        self.confirmLabel = confirmLabel
        self.onConfirm = onConfirm
        _selectedModifiers = State(initialValue: initialCombo?.modifiers ?? [])
        _selectedKey = State(initialValue: initialCombo?.key)

        // Pick the right tab based on the initial key
        if let key = initialCombo?.key {
            switch key {
            case .letter: _activeTab = State(initialValue: .letters)
            case .digit: _activeTab = State(initialValue: .numbers)
            case .symbol: _activeTab = State(initialValue: .symbols)
            case .special: _activeTab = State(initialValue: .special)
            }
        } else {
            _activeTab = State(initialValue: .letters)
        }
    }

    enum KeyTab: String, CaseIterable {
        case letters = "Letters"
        case numbers = "Numbers"
        // Without this tab `ComboKey.symbol` had no producer at all: the grid
        // rendered "0123456789" only, so Ctrl+[ or Cmd+- could not be bound even
        // though `KeyCombo.terminalData()` has always encoded symbols correctly.
        case symbols = "Symbols"
        case special = "Special"

        var displayName: String {
            switch self {
            case .letters: return String(localized: "Letters", comment: "Key tab: letter keys")
            case .numbers: return String(localized: "Numbers", comment: "Key tab: number keys")
            case .symbols: return String(localized: "Symbols", comment: "Key tab: symbol keys")
            case .special: return String(localized: "Special", comment: "Key tab: special keys")
            }
        }
    }

    private var canConfirm: Bool {
        selectedKey != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Modifier buttons
                VStack(alignment: .leading) {
                    Text("MODIFIERS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    HStack(spacing: 12) {
                        ForEach(SequenceStep.KeyModifier.allCases, id: \.self) { mod in
                            Button {
                                if selectedModifiers.contains(mod) {
                                    selectedModifiers.remove(mod)
                                } else {
                                    selectedModifiers.insert(mod)
                                }
                            } label: {
                                VStack(spacing: 2) {
                                    Text(mod.displayGlyph)
                                        .font(.title2)
                                    Text(mod.displayName)
                                        .font(.caption2)
                                }
                                .frame(width: 64, height: 56)
                                .background(
                                    selectedModifiers.contains(mod)
                                        ? Color.accentColor.opacity(0.2)
                                        : sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(selectedModifiers.contains(mod) ? Color.accentColor : .clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }

                // Key picker
                VStack(alignment: .leading) {
                    Text("KEY")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    Picker("Key Type", selection: $activeTab) {
                        ForEach(KeyTab.allCases, id: \.self) { tab in
                            Text(tab.displayName).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    ScrollView {
                        switch activeTab {
                        case .letters:
                            letterGrid
                        case .numbers:
                            numberGrid
                        case .symbols:
                            symbolGrid
                        case .special:
                            specialGrid
                        }
                    }
                    .frame(maxHeight: 200)
                }

                // Preview
                previewView

                Spacer()
            }
            .padding(.top)
            .background((sheetThemeColors?.background ?? Color(uiColor: .systemBackground)).ignoresSafeArea())
            .navigationTitle("Key Combination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) {
                        if let key = selectedKey {
                            onConfirm(SequenceStep.KeyCombo(modifiers: selectedModifiers, key: key))
                            dismiss()
                        }
                    }
                    .disabled(!canConfirm)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var letterGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 6) {
            ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), id: \.self) { char in
                keyButton(
                    label: String(char),
                    key: .letter(Character(char.lowercased()))
                )
            }
        }
        .padding(.horizontal)
    }

    private var numberGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 6) {
            ForEach(Array("0123456789"), id: \.self) { char in
                keyButton(
                    label: String(char),
                    key: .digit(char)
                )
            }
        }
        .padding(.horizontal)
    }

    /// Punctuation reachable from a US keyboard, unshifted forms first then
    /// shifted. Both forms are listed as separate keys because
    /// `KeyCombo.terminalData()` sends the picked character verbatim and ignores
    /// Shift for symbols — `-` and `_` are two keys here, not one key plus a
    /// modifier. Every entry is ASCII, which is what `characterData` encodes.
    private static let symbolCharacters: [Character] = Array("`-=[]\\;',./~_+{}|:\"<>?!@#$%^&*()")

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 6) {
            ForEach(Self.symbolCharacters, id: \.self) { char in
                keyButton(
                    label: String(char),
                    key: .symbol(char)
                )
            }
        }
        .padding(.horizontal)
    }

    private var specialGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(SequenceStep.SpecialKey.allCases, id: \.self) { special in
                keyButton(
                    label: special.displayGlyph,
                    key: .special(special)
                )
            }
        }
        .padding(.horizontal)
    }

    private func keyButton(label: String, key: SequenceStep.ComboKey) -> some View {
        let isSelected = selectedKey == key
        return Button {
            selectedKey = key
        } label: {
            Text(label)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    isSelected
                        ? Color.accentColor.opacity(0.2)
                        : sheetThemeColors?.rowBackground ?? Color(uiColor: .tertiarySystemGroupedBackground)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }

    private var previewView: some View {
        VStack(alignment: .leading) {
            Text("PREVIEW")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            HStack {
                Spacer()
                if let key = selectedKey {
                    let combo = SequenceStep.KeyCombo(modifiers: selectedModifiers, key: key)
                    Text(combo.displayText)
                        .font(.system(.title2, design: .monospaced))
                } else {
                    Text("Select a key")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(height: 44)
            .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }
}
