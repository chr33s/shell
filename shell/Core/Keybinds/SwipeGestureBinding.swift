//
//  SwipeGestureBinding.swift
//  shell
//
//  Models the binding attached to a horizontal terminal swipe: one of the
//  built-in presets (next/previous tab, tmux/zellij window switching).
//
//  The bindings are fixed — see SwipeGestureManager. The `sequence` and
//  `customKeyRef` cases, the Codable conformance that persisted them and the
//  `swipeGestureBindings` setting they were stored under are gone: no build
//  ever shipped a way to produce them.
//

import Foundation

enum SwipeDirection: String, Codable, CaseIterable, Hashable, Sendable {
    case left
    case right
}

enum SwipeGestureBinding: Hashable, Sendable {
    case preset(SwipeGesturePreset)

    /// True when this binding will not perform any action when triggered, so
    /// the recognizer can be disabled instead of silently eating the gesture.
    var isDisabled: Bool {
        self == .preset(.none)
    }

    /// The app-level tab navigation preset, when this binding switches
    /// shell tabs instead of sending bytes to the terminal.
    var appTabPreset: SwipeGesturePreset? {
        guard case .preset(let preset) = self, preset.isAppTabNavigation else {
            return nil
        }
        return preset
    }

    var isAppTabNavigation: Bool {
        appTabPreset != nil
    }
}

/// Built-in swipe presets. App-action presets (next/previous tab) post a
/// notification; multiplexer presets expand into a [SequenceStep] for the
/// shared sender to write to the terminal.
enum SwipeGesturePreset: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    case nextTab
    case previousTab
    case tmuxNextWindow
    case tmuxPreviousWindow
    case tmuxNextSession
    case tmuxPreviousSession
    case zellijNextTab
    case zellijPreviousTab

    var id: String { rawValue }

    var isAppTabNavigation: Bool {
        self == .nextTab || self == .previousTab
    }

    /// For app-action presets, the notification name to post. Nil for terminal sequences.
    var notificationName: Notification.Name? {
        switch self {
        case .nextTab: return .nextTab
        case .previousTab: return .previousTab
        default: return nil
        }
    }

    /// For sequence presets, the built-in fallback steps to send to the terminal.
    /// Terminal-specific discovery may override these at send time.
    var fallbackSequence: [SequenceStep]? {
        switch self {
        case .tmuxNextWindow:
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("b"))),
                .text("n"),
            ]
        case .tmuxPreviousWindow:
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("b"))),
                .text("p"),
            ]
        case .tmuxNextSession:
            // Ctrl+B then ')' switches to the next attached session via switch-client
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("b"))),
                .text(")"),
            ]
        case .tmuxPreviousSession:
            // Ctrl+B then '(' switches to the previous session
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("b"))),
                .text("("),
            ]
        case .zellijNextTab:
            // Enter Tab mode (Ctrl+T), move right, then Esc to return to Normal mode
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("t"))),
                .text("l"),
                .keyCombo(SequenceStep.KeyCombo(modifiers: [], key: .special(.escape))),
            ]
        case .zellijPreviousTab:
            return [
                .keyCombo(SequenceStep.KeyCombo(modifiers: [.ctrl], key: .letter("t"))),
                .text("h"),
                .keyCombo(SequenceStep.KeyCombo(modifiers: [], key: .special(.escape))),
            ]
        default:
            return nil
        }
    }

    /// The key sequence this preset sends. The fork does not probe the remote
    /// multiplexer for its configured bindings, so the built-in default is
    /// always used.
    var resolvedSequence: [SequenceStep]? {
        fallbackSequence
    }
}
