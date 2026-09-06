//
//  KeySequencePendingIndicator.swift
//  shell
//
//  "Waiting for the second key" HUD for multi-key chord bindings. Without
//  it a half-entered chord looks exactly like a dead keyboard.
//
//  Its own view on purpose. KeySequenceTracker is an ObservableObject whose
//  objectWillChange fires on every prefix key; observing it from
//  MainView.body would re-evaluate the whole window on each chord — the
//  invalidation pattern this project has traced to its FrontBoard-timeout
//  crash family. Scoped here, only this label redraws.
//

import SwiftUI

@MainActor
struct KeySequencePendingIndicator: View {
    @ObservedObject private var tracker = KeySequenceTracker.shared

    var body: some View {
        // nil unless a prefix is armed; the tracker's own 1s timeout, its
        // cross-view reset and resetIfOwnedBy() all clear it, so there is no
        // dismissal to write here.
        if let pending = tracker.pendingDisplayString {
            Text(pending)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
                .accessibilityLabel(Text(
                    "Waiting for the next key in a shortcut",
                    comment: "Accessibility label for the pending key-chord indicator"
                ))
        }
    }
}
