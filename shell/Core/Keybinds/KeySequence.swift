//
//  KeySequence.swift
//  shell
//
//  Multi-key sequence support for tmux/screen-style keybindings
//

import Foundation

/// Represents a keyboard shortcut that may be a single key or a sequence of keys
/// Examples: "cmd+t" (single), "ctrl+a>n" (sequence)
struct KeySequence: Codable, Hashable, Sendable {
    /// The triggers in this sequence (1 for simple shortcuts, 2+ for sequences)
    let triggers: [KeyTrigger]

    /// Whether this is a multi-key sequence
    var isSequence: Bool {
        triggers.count > 1
    }

    /// The first trigger (leader key for sequences)
    var first: KeyTrigger? {
        triggers.first
    }

    // MARK: - Initialization

    /// Create a single-key sequence
    init(trigger: KeyTrigger) {
        self.triggers = [trigger]
    }

    /// Create a multi-key sequence
    init(triggers: [KeyTrigger]) {
        precondition(!triggers.isEmpty, "KeySequence must have at least one trigger")
        self.triggers = triggers
    }

    /// Create from key and modifiers (convenience for single-key)
    init(key: KeyCode, modifiers: KeybindModifiers = []) {
        self.triggers = [KeyTrigger(key: key, modifiers: modifiers)]
    }

    /// Parse from ghostty config format: "cmd+t" or "ctrl+a>n"
    init?(ghosttyFormat: String) {
        // Split by > for sequences
        let sequenceParts = ghosttyFormat.components(separatedBy: ">")
        var parsedTriggers: [KeyTrigger] = []

        for part in sequenceParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            guard let trigger = KeyTrigger(ghosttyFormat: trimmed) else {
                return nil
            }
            parsedTriggers.append(trigger)
        }

        guard !parsedTriggers.isEmpty else { return nil }
        self.triggers = parsedTriggers
    }

    // MARK: - Conversion

    /// Convert to ghostty config format
    var ghosttyFormat: String {
        triggers.map { $0.ghosttyFormat }.joined(separator: ">")
    }

    /// Mac-style symbol format: "⌘T" or "⌃A → N"
    var symbolDescription: String {
        triggers.map { $0.symbolDescription }.joined(separator: " → ")
    }

    // MARK: - Matching

    /// Check if a trigger matches the start of this sequence
    func matchesPrefix(_ trigger: KeyTrigger) -> Bool {
        guard let first = triggers.first else { return false }
        return first == trigger
    }

    /// Check if this sequence starts with another sequence (for conflict detection)
    func hasPrefix(_ other: KeySequence) -> Bool {
        guard other.triggers.count <= triggers.count else { return false }
        return zip(other.triggers, triggers).allSatisfy { $0 == $1 }
    }

    /// Check if this sequence conflicts with another
    /// Two sequences conflict if one is a prefix of the other
    func conflictsWith(_ other: KeySequence) -> Bool {
        hasPrefix(other) || other.hasPrefix(self)
    }
}
