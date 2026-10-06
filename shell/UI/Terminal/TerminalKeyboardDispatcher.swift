//
//  TerminalKeyboardDispatcher.swift
//  shell
//
//  Typed adapter from Shell keyboard presses to the terminal's existing input
//  and action paths. Owns no transport: bytes still leave through the
//  terminal's send paths and the session's recovery input gate.
//

import Foundation

/// A semantic keyboard action. Labels are never wire data.
enum TerminalKeyboardAction: Equatable, Sendable {
    case character(ShellKeyboardCharacter)
    case named(ShellKeyboardNamedKey)
    case paste
}

/// Identity of the terminal and connection an interaction began on.
/// Captured at touch-down and re-validated at every dispatch and repeat.
struct TerminalKeyboardTargetIdentity: Equatable {
    let terminal: ObjectIdentifier
    /// The session object; a reconnect replaces it.
    let session: ObjectIdentifier?
    /// The rendering surface (tmux panes have no session).
    let surface: UInt?
}

enum TerminalKeyboardDispatchResult: Equatable {
    /// Bytes or a claimed shortcut went to the original target.
    case delivered
    /// An unclaimed Command chord: consumed, nothing written.
    case unassignedShortcut
    /// Delivered, but the connection is not accepting more input (offline or
    /// backpressure). Repeats must stop.
    case rejected
    /// The original target is gone or no longer eligible. Nothing was sent.
    case targetUnavailable
}

/// The terminal side of the dispatcher. `Swiftty.TerminalView` conforms;
/// tests substitute a recorder.
@MainActor
protocol TerminalKeyboardDispatchTarget: AnyObject {
    /// nil while the terminal cannot take keyboard input (not focused, no
    /// window, scene inactive).
    var keyboardTargetIdentity: TerminalKeyboardTargetIdentity? { get }
    /// False while the connection is not live or its input budget is full.
    var keyboardTargetIsAcceptingInput: Bool { get }
    /// Existing local binding and sequence dispatch. True when claimed.
    func keyboardDispatchBinding(_ trigger: KeyTrigger) -> Bool
    /// Existing printable-key path (compose routing, local Ctrl+C, encoder).
    func keyboardSendPrintable(_ key: String, modifiers: KeyModifiers)
    /// Existing named-key paths (Return, Escape, Tab, Backspace, encoder).
    func keyboardSendNamedKey(_ key: ShellKeyboardNamedKey, modifiers: KeyModifiers)
    func keyboardPaste()
    func keyboardReportUnassignedShortcut()
}

@MainActor
final class TerminalKeyboardDispatcher {
    weak var target: TerminalKeyboardDispatchTarget?
    let modifiers: SoftwareModifierModel

    init(target: TerminalKeyboardDispatchTarget?, modifiers: SoftwareModifierModel) {
        self.target = target
        self.modifiers = modifiers
    }

    /// Snapshot the destination when an interaction begins.
    func beginInteraction() -> TerminalKeyboardTargetIdentity? {
        target?.keyboardTargetIdentity
    }

    /// Whether a repeat for an interaction may keep firing.
    func canContinue(_ identity: TerminalKeyboardTargetIdentity?) -> Bool {
        guard let target, let identity else { return false }
        return target.keyboardTargetIdentity == identity && target.keyboardTargetIsAcceptingInput
    }

    @discardableResult
    func perform(_ action: TerminalKeyboardAction, on identity: TerminalKeyboardTargetIdentity?) -> TerminalKeyboardDispatchResult {
        guard let target, let identity else { return .targetUnavailable }
        guard target.keyboardTargetIdentity == identity else {
            // The pane, tab, or connection this touch began on is gone. Never
            // re-resolve a fresh target, and drop latched modifiers with it.
            modifiers.clearAll()
            return .targetUnavailable
        }

        let active = modifiers.active
        let outcome: TerminalKeyboardDispatchResult
        switch action {
        case .paste:
            target.keyboardPaste()
            outcome = .delivered
        case .character(let character):
            outcome = dispatchCharacter(character, modifiers: active, target: target)
        case .named(let key):
            outcome = dispatchNamedKey(key, modifiers: active, target: target)
        }

        // One-shots are consumed per emitted key, claimed shortcut, or paste,
        // so a pending modifier can never apply to a later, unrelated key.
        // Locked modifiers are the user's explicit state and survive.
        modifiers.consumeOneShots()
        guard outcome == .delivered else { return outcome }
        // Rejected input is never queued here; the caller stops repeating.
        return target.keyboardTargetIsAcceptingInput ? .delivered : .rejected
    }

    // MARK: - Printable

    private func dispatchCharacter(
        _ character: ShellKeyboardCharacter,
        modifiers active: KeyModifiers,
        target: TerminalKeyboardDispatchTarget
    ) -> TerminalKeyboardDispatchResult {
        let chord = active.intersection([.control, .alt, .command])
        // A literal symbol ignores the user's Shift for both text and identity:
        // Shift + `[` is still `[`, never Shift+[ (`{`).
        let userShift = !character.isLiteral && active.contains(.shift)
        if let keyCode = character.keyCode {
            var triggerModifiers = Self.keybindModifiers(chord)
            if character.impliesShift || userShift { triggerModifiers.insert(.shift) }
            if target.keyboardDispatchBinding(KeyTrigger(key: keyCode, modifiers: triggerModifiers)) {
                return .delivered
            }
        }
        if active.contains(.command) {
            target.keyboardReportUnassignedShortcut()
            return .unassignedShortcut
        }
        if chord.isEmpty {
            // Plain or Shift-only: insert exactly the resolved character once.
            target.keyboardSendPrintable(String(character.text), modifiers: [])
        } else {
            // Ctrl/Alt chords encode the US base key so every keyboard
            // protocol sees a key identity, never the symbol's label.
            var encoded = chord
            if character.impliesShift || userShift { encoded.insert(.shift) }
            target.keyboardSendPrintable(String(character.baseKey), modifiers: encoded)
        }
        return .delivered
    }

    // MARK: - Named keys

    private func dispatchNamedKey(
        _ key: ShellKeyboardNamedKey,
        modifiers active: KeyModifiers,
        target: TerminalKeyboardDispatchTarget
    ) -> TerminalKeyboardDispatchResult {
        var keyModifiers = active
        if key.impliesShift { keyModifiers.insert(.shift) }
        if target.keyboardDispatchBinding(KeyTrigger(key: key.keyCode, modifiers: Self.keybindModifiers(keyModifiers))) {
            return .delivered
        }
        if keyModifiers.contains(.command) {
            target.keyboardReportUnassignedShortcut()
            return .unassignedShortcut
        }
        target.keyboardSendNamedKey(key == .backtab ? .tab : key, modifiers: keyModifiers)
        return .delivered
    }

    static func keybindModifiers(_ modifiers: KeyModifiers) -> KeybindModifiers {
        var result: KeybindModifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.alt) { result.insert(.option) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }
}
