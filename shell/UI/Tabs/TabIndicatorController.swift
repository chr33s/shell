//
//  TabIndicatorController.swift
//  shell
//
//  Tab-indicator overlay state (shown briefly on tab switch while the tab
//  bar is hidden) plus the one-shot selection-animation suppression flag,
//  extracted from MainView @State into an owned @Observable controller. One
//  instance per window (owned via @State).
//

import SwiftUI

@MainActor @Observable final class TabIndicatorController {
    /// Whether the indicator overlay is currently visible.
    private(set) var isShowing = false

    /// One-shot: skip the tab bar's selection animation for the next
    /// selection change (set around app-tab swipes so the bar doesn't
    /// double-animate after the slide settles).
    var suppressNextSelectionAnimation = false

    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// Show the tab indicator overlay briefly when switching tabs with tab bar hidden
    func showBriefly() {
        // Cancel any existing dismiss task
        hideTask?.cancel()

        // Show the indicator
        withAnimation(.easeOut(duration: 0.15)) {
            isShowing = true
        }

        // Schedule auto-hide after delay
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) {
                self?.isShowing = false
            }
        }
    }

    /// Hide the indicator instantly (no animation) — used when an app-tab
    /// swipe begins so the overlay doesn't linger over the slide.
    func hideImmediately() {
        hideTask?.cancel()
        isShowing = false
    }

    deinit {
        hideTask?.cancel()
    }
}
