//
//  TerminalView+SwipeGestures.swift
//  shell
//
//  Single source of truth for resolving and dispatching a horizontal swipe
//  on the terminal. The iOS direct-touch handlers in TerminalViewGestures.swift
//  and the Mac Catalyst trackpad pan handler in TerminalViewScroll.swift both
//  funnel through `performSwipeBinding(_:)`, so the fixed bindings in
//  SwipeGestureManager apply identically across platforms.
//

import Foundation
import UIKit

extension Ghostty.TerminalView {
    /// Resolve the binding for the given direction and execute it.
    /// App-action presets post a notification (preserving the legacy tab-switch
    /// behavior); multiplexer presets write their key sequence to the terminal
    /// via the shared `sendSequenceSteps` helper.
    func performSwipeBinding(_ direction: SwipeDirection) {
        switch SwipeGestureManager.shared.binding(for: direction) {
        case .preset(let preset):
            performPreset(preset)
        }
    }

    private func performPreset(_ preset: SwipeGesturePreset) {
        if preset == .none { return }
        // App-action presets post a notification; sequence presets write to the terminal.
        if let name = preset.notificationName {
            triggerHapticFeedback()
            NotificationCenter.default.post(name: name, object: self)
            return
        }
        if let steps = preset.resolvedSequence, !steps.isEmpty {
            triggerHapticFeedback()
            sendSequenceSteps(steps)
        }
    }
}
