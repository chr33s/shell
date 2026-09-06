//
//  TabHoverController.swift
//  shell
//
//  Debounced tab-hover state for MainView's health tooltip, extracted from
//  MainView @State into an owned @Observable controller. One instance per
//  window (owned via @State), so multi-window hover state stays independent.
//

import SwiftUI

/// Debounces tab-bar hover events so the health popover doesn't flicker:
/// shows after a 300ms delay, hides after 150ms, and switches between tabs
/// instantly while a popover is already up.
@MainActor @Observable final class TabHoverController {
    /// The tab whose health popover is currently shown (nil = none).
    private(set) var hoveredTabId: UUID?
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// Handle tab hover with debouncing to prevent flicker
    /// Shows popover after 300ms delay, hides after 150ms delay
    func handleHover(tabId: UUID, isHovered: Bool) {
        if isHovered {
            // Cancel any pending hide
            hideTask?.cancel()
            hideTask = nil

            // If already showing this tab, nothing to do
            if hoveredTabId == tabId {
                // Also cancel any pending show task since we're already showing
                showTask?.cancel()
                showTask = nil
                return
            }

            // Cancel previous show task if switching tabs
            showTask?.cancel()

            // If already showing a different tab, switch immediately (no delay)
            // This makes tab-to-tab transitions feel snappy
            if hoveredTabId != nil {
                hoveredTabId = tabId
                return
            }

            // Debounce initial show (300ms)
            showTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                self?.hoveredTabId = tabId
            }
        } else {
            // Cancel any pending show
            showTask?.cancel()
            showTask = nil

            // Only start hide timer if we're showing something
            guard hoveredTabId != nil else { return }

            // Debounce hide (150ms)
            hideTask?.cancel()
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                self?.hoveredTabId = nil
            }
        }
    }

    /// Clear the popover immediately, skipping the 150ms hide debounce.
    ///
    /// Called when the system dismisses the popover itself (a tap outside it, a
    /// scene change) rather than the pointer leaving the tab. Routing that
    /// through `handleHover(isHovered: false)` would leave `hoveredTabId` set
    /// for another 150ms, and the presentation binding would re-present the
    /// popover the user just dismissed.
    func dismiss() {
        showTask?.cancel()
        showTask = nil
        hideTask?.cancel()
        hideTask = nil
        hoveredTabId = nil
    }

    deinit {
        showTask?.cancel()
        hideTask?.cancel()
    }
}
