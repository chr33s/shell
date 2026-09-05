//
//  TerminalSearchOverlay.swift
//  shell
//
//  Floating search overlay for scrollback search
//

import SwiftUI

/// The search bar pill (text field + nav/close buttons). Positioning and dragging
/// are handled by `DraggableHUDContainer`, which hosts this in a UIKit view and
/// moves it with a native pan — a SwiftUI `DragGesture` here stutters and fights
/// the embedded `TextField`/buttons for touches.
struct TerminalSearchOverlay: View {
    @ObservedObject var searchState: Ghostty.SearchState
    let onSearch: (String) -> Void
    let onNavigate: (String) -> Void
    let onClose: () -> Void

    @FocusState private var isSearchFieldFocused: Bool

    // Debouncing for search input
    @State private var searchDebounceTask: Task<Void, Never>? = nil

    private var isPhone: Bool {
        #if os(visionOS)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    private var innerPadding: CGFloat { isPhone ? 8 : 10 }
    private var hStackSpacing: CGFloat { isPhone ? 6 : 8 }
    private var textFieldWidth: CGFloat { isPhone ? 140 : 180 }
    private var resultCounterPadding: CGFloat { isPhone ? 45 : 55 }

    var body: some View {
        HStack(spacing: hStackSpacing) {
            // Search text field
            TextField("Search", text: $searchState.needle)
                .textFieldStyle(.plain)
                .frame(width: textFieldWidth)
                .padding(.leading, innerPadding)
                .padding(.trailing, resultCounterPadding)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.1))
                .cornerRadius(8)
                .focused($isSearchFieldFocused)
                .overlay(alignment: .trailing) {
                    resultCounter
                }
                .onSubmit {
                    onNavigate("next")
                }
                .submitLabel(.search)

            // Navigation buttons
            Button(action: { onNavigate("next") }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.primary)

            Button(action: { onNavigate("previous") }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.primary)

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(innerPadding)
        .searchOverlayBackground()
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: searchState.needle) { _, newValue in
            scheduleSearch(for: newValue)
        }
        // Escape + the customizable Find shortcut are handled by the hosting
        // DraggableHUDContainer (host UIKeyCommand + findInTerminal menu forwarding),
        // so dismissal honors KeybindManager instead of a hardcoded key here.
    }

    @ViewBuilder
    private var resultCounter: some View {
        Group {
            if let selected = searchState.selected {
                let total = searchState.total.map(String.init) ?? "?"
                Text("\(selected + 1)/\(total)")
            } else if let total = searchState.total {
                Text("-/\(total)")
            } else {
                EmptyView()
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .monospacedDigit()
        .padding(.trailing, innerPadding)
    }

    private func scheduleSearch(for needle: String) {
        searchDebounceTask?.cancel()
        let delayMillis = needle.count < 3 ? 300 : 50
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delayMillis) * 1_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                onSearch(needle)
            }
        }
    }
}

private extension View {
    /// Liquid-glass pill background matching `brightnessHUDBackground()`, at the
    /// search overlay's 12pt radius. `glassEffect` supplies its own elevation, so
    /// the manual shadow is only kept in the pre-26 fallback.
    @ViewBuilder
    func searchOverlayBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        #if os(visionOS)
        self.background(.regularMaterial, in: shape)
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        }
        #endif
    }
}
