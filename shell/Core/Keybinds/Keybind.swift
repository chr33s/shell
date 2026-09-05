//
//  Keybind.swift
//  shell
//
//  Complete keybinding: sequence -> action mapping
//

import Foundation

/// A complete keybinding mapping a key sequence to an action
struct Keybind: Codable, Identifiable, Hashable, Sendable {
    /// Unique identifier for this keybind
    let id: UUID

    /// The key sequence that triggers this action
    let sequence: KeySequence

    /// The action to perform
    let action: KeybindAction

    /// Optional parameter for the action (e.g., "1" for "increase_font_size:1")
    let actionParameter: String?

    /// Whether this is a user override (vs default)
    let isUserOverride: Bool

    /// Source of this keybind for debugging
    let source: KeybindSource

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        sequence: KeySequence,
        action: KeybindAction,
        actionParameter: String? = nil,
        isUserOverride: Bool = false,
        source: KeybindSource = .default
    ) {
        self.id = id
        self.sequence = sequence
        self.action = action
        self.actionParameter = actionParameter
        self.isUserOverride = isUserOverride
        self.source = source
    }

    /// Convenience initializer for single-key bindings
    init(
        key: KeyCode,
        modifiers: KeybindModifiers = [],
        action: KeybindAction,
        actionParameter: String? = nil,
        isUserOverride: Bool = false,
        source: KeybindSource = .default
    ) {
        self.id = UUID()
        self.sequence = KeySequence(key: key, modifiers: modifiers)
        self.action = action
        self.actionParameter = actionParameter
        self.isUserOverride = isUserOverride
        self.source = source
    }

    /// Convenience initializer for trigger-based bindings
    init(
        trigger: KeyTrigger,
        action: KeybindAction,
        actionParameter: String? = nil,
        isUserOverride: Bool = false,
        source: KeybindSource = .default
    ) {
        self.id = UUID()
        self.sequence = KeySequence(trigger: trigger)
        self.action = action
        self.actionParameter = actionParameter
        self.isUserOverride = isUserOverride
        self.source = source
    }

    // MARK: - Ghostty Config Format

    /// Parse from ghostty config format: "cmd+t=new_local_shell" or "cmd+p=increase_font_size:2"
    init?(ghosttyLine: String, source: KeybindSource = .externalConfig) {
        // Parse: keybind = trigger=action or keybind = trigger=action:param
        let line = ghosttyLine.trimmingCharacters(in: .whitespaces)

        // Remove "keybind = " prefix if present
        var content = line
        if content.lowercased().hasPrefix("keybind") {
            content = String(content.dropFirst("keybind".count))
                .trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("=") {
                content = String(content.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // Split trigger=action
        guard let equalsIndex = content.firstIndex(of: "=") else {
            return nil
        }

        let triggerStr = String(content[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
        let fullActionStr = String(content[content.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)

        // Parse action and optional parameter (e.g., "increase_font_size:1" -> action="increase_font_size", param="1")
        let actionStr: String
        let parameter: String?
        if let colonIndex = fullActionStr.firstIndex(of: ":") {
            actionStr = String(fullActionStr[..<colonIndex])
            parameter = String(fullActionStr[fullActionStr.index(after: colonIndex)...])
        } else {
            actionStr = fullActionStr
            parameter = nil
        }

        guard let sequence = KeySequence(ghosttyFormat: triggerStr),
              let action = KeybindAction(rawValue: actionStr) else {
            return nil
        }

        self.id = UUID()
        self.sequence = sequence
        self.action = action
        self.actionParameter = parameter
        self.isUserOverride = (source == .userOverride)
        self.source = source
    }

    /// Convert to ghostty config format
    var ghosttyFormat: String {
        if let param = actionParameter {
            return "keybind = \(sequence.ghosttyFormat)=\(action.rawValue):\(param)"
        }
        return "keybind = \(sequence.ghosttyFormat)=\(action.rawValue)"
    }

    // MARK: - Escape Sequence Decoding

    /// Decode escape sequences in text action parameters (Ghostty config format).
    /// Handles: \x## (hex bytes), \e/\E (ESC), \n \r \t \a \b (C escapes), \\ (literal backslash)
    static func decodeEscapeSequence(_ text: String) -> Data {
        var result = Data()
        var chars = text[...].makeIterator()

        while let ch = chars.next() {
            if ch == "\\" {
                guard let next = chars.next() else {
                    result.append(contentsOf: "\\".utf8)
                    break
                }
                switch next {
                case "x":
                    // Hex byte: \x## (exactly 2 hex digits)
                    let h1 = chars.next()
                    let h2 = chars.next()
                    if let h1, let h2,
                       let byte = UInt8(String([h1, h2]), radix: 16) {
                        result.append(byte)
                    }
                case "e", "E":
                    result.append(0x1B)
                case "n":
                    result.append(0x0A)
                case "r":
                    result.append(0x0D)
                case "t":
                    result.append(0x09)
                case "a":
                    result.append(0x07)
                case "b":
                    result.append(0x08)
                case "\\":
                    result.append(contentsOf: "\\".utf8)
                default:
                    // Unknown escape — pass through literally
                    result.append(contentsOf: "\\".utf8)
                    result.append(contentsOf: String(next).utf8)
                }
            } else {
                result.append(contentsOf: String(ch).utf8)
            }
        }

        return result
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Keybind, rhs: Keybind) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Keybind Source

/// Source of a keybind for tracking and debugging
enum KeybindSource: String, Codable, Sendable {
    /// Built-in default keybind
    case `default` = "default"
    /// User override via Settings UI
    case userOverride = "user_override"
    /// From external ghostty config file
    case externalConfig = "external_config"
}

// MARK: - Keybind Set Operations

extension Array where Element == Keybind {
    /// Find keybind by action
    func binding(for action: KeybindAction) -> Keybind? {
        first { $0.action == action }
    }

    /// Find keybind by sequence
    func binding(for sequence: KeySequence) -> Keybind? {
        first { $0.sequence == sequence }
    }

    /// Find keybind by first trigger (for sequence lookup)
    func bindings(startingWith trigger: KeyTrigger) -> [Keybind] {
        filter { $0.sequence.matchesPrefix(trigger) }
    }

    /// Group bindings by category
    func grouped() -> [KeybindCategory: [Keybind]] {
        Dictionary(grouping: self) { $0.action.category }
    }

    /// Sort by action display name
    func sortedByName() -> [Keybind] {
        sorted { $0.action.displayName < $1.action.displayName }
    }

    /// Filter to show only customizable actions
    func customizable() -> [Keybind] {
        filter { KeybindAction.customizableActions.contains($0.action) }
    }
}
