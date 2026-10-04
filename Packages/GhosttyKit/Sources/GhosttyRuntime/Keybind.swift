import Foundation

/// Modifier bits as in `ghostty_input_mods_e` (sides folded together).
struct Mods: OptionSet, Hashable, Sendable {
    let rawValue: UInt32

    static let shift = Mods(rawValue: 1 << 0)
    static let ctrl = Mods(rawValue: 1 << 1)
    static let alt = Mods(rawValue: 1 << 2)
    static let superKey = Mods(rawValue: 1 << 3)
    static let caps = Mods(rawValue: 1 << 4)
    static let altRight = Mods(rawValue: 1 << 8)

    /// The four modifiers bindings and encoders care about.
    var binding: Mods {
        intersection([.shift, .ctrl, .alt, .superKey])
    }
}

/// A key as named in Ghostty config triggers.
enum NamedKey: String, Sendable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case digit0 = "0", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4"
    case digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"
    case minus, equal, bracketLeft = "bracket_left", bracketRight = "bracket_right", backslash
    case semicolon, quote, comma, period, slash, backquote, intlBackslash = "intl_backslash"
    case enter, tab, space, backspace, escape, delete, insert
    case home, end, pageUp = "page_up", pageDown = "page_down"
    case arrowUp = "arrow_up", arrowDown = "arrow_down", arrowLeft = "arrow_left", arrowRight = "arrow_right"
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19
    case shiftLeft = "shift_left", shiftRight = "shift_right", controlLeft = "control_left"
    case controlRight = "control_right", altLeft = "alt_left", altRight = "alt_right"
    case metaLeft = "meta_left", metaRight = "meta_right"

    init?(configName: String) {
        let aliases: [String: NamedKey] = [
            "up": .arrowUp, "down": .arrowDown, "left": .arrowLeft, "right": .arrowRight,
            "esc": .escape, "return": .enter, "pageup": .pageUp, "pagedown": .pageDown,
            "apostrophe": .quote, "grave_accent": .backquote, "left_bracket": .bracketLeft,
            "right_bracket": .bracketRight, "digit_0": .digit0, "digit_1": .digit1, "digit_2": .digit2,
            "digit_3": .digit3, "digit_4": .digit4, "digit_5": .digit5, "digit_6": .digit6,
            "digit_7": .digit7, "digit_8": .digit8, "digit_9": .digit9, "zero": .digit0,
            "-": .minus, "=": .equal, "[": .bracketLeft, "]": .bracketRight, "\\": .backslash,
            ";": .semicolon, "'": .quote, ",": .comma, ".": .period, "/": .slash, "`": .backquote
        ]
        if let key = aliases[configName] ?? NamedKey(rawValue: configName) {
            self = key
        } else {
            return nil
        }
    }

    /// macOS virtual keycode (`kVK_*`) → key, the code Shell passes in
    /// `ghostty_input_key_s.keycode`.
    static func from(keycode: UInt32) -> NamedKey? {
        keycodes[keycode]
    }

    private static let keycodes: [UInt32: NamedKey] = [
        0x00: .a, 0x01: .s, 0x02: .d, 0x03: .f, 0x04: .h, 0x05: .g, 0x06: .z, 0x07: .x,
        0x08: .c, 0x09: .v, 0x0A: .intlBackslash, 0x0B: .b, 0x0C: .q, 0x0D: .w, 0x0E: .e, 0x0F: .r,
        0x10: .y, 0x11: .t, 0x12: .digit1, 0x13: .digit2, 0x14: .digit3, 0x15: .digit4, 0x16: .digit6,
        0x17: .digit5, 0x18: .equal, 0x19: .digit9, 0x1A: .digit7, 0x1B: .minus, 0x1C: .digit8,
        0x1D: .digit0, 0x1E: .bracketRight, 0x1F: .o, 0x20: .u, 0x21: .bracketLeft, 0x22: .i,
        0x23: .p, 0x24: .enter, 0x25: .l, 0x26: .j, 0x27: .quote, 0x28: .k, 0x29: .semicolon,
        0x2A: .backslash, 0x2B: .comma, 0x2C: .slash, 0x2D: .n, 0x2E: .m, 0x2F: .period,
        0x30: .tab, 0x31: .space, 0x32: .backquote, 0x33: .backspace, 0x35: .escape,
        0x36: .metaRight, 0x37: .metaLeft, 0x38: .shiftLeft, 0x3A: .altLeft, 0x3B: .controlLeft,
        0x3C: .shiftRight, 0x3D: .altRight, 0x3E: .controlRight,
        0x7A: .f1, 0x78: .f2, 0x63: .f3, 0x76: .f4, 0x60: .f5, 0x61: .f6, 0x62: .f7, 0x64: .f8,
        0x65: .f9, 0x6D: .f10, 0x67: .f11, 0x6F: .f12, 0x69: .f13, 0x6B: .f14, 0x71: .f15,
        0x6A: .f16, 0x40: .f17, 0x4F: .f18, 0x50: .f19,
        0x7E: .arrowUp, 0x7D: .arrowDown, 0x7B: .arrowLeft, 0x7C: .arrowRight,
        0x73: .home, 0x77: .end, 0x74: .pageUp, 0x79: .pageDown, 0x75: .delete, 0x72: .insert,
        0x4C: .enter
    ]

    var isModifier: Bool {
        switch self {
        case .shiftLeft, .shiftRight, .controlLeft, .controlRight, .altLeft, .altRight, .metaLeft, .metaRight: true
        default: false
        }
    }
}

/// One key of a trigger: a named physical key or a character.
enum TriggerKey: Hashable, Sendable {
    case physical(NamedKey)
    case unicode(UInt32)
}

struct Trigger: Hashable, Sendable {
    var mods: Mods
    var key: TriggerKey

    /// Parses `super+shift+c`.
    init?(_ text: String) {
        var parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "super++" spells the plus key.
        if text.hasSuffix("++") {
            parts.removeLast(2)
            parts.append("plus")
        }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var mods: Mods = []
        for part in parts {
            switch part {
            case "shift": mods.insert(.shift)
            case "ctrl", "control": mods.insert(.ctrl)
            case "alt", "opt", "option": mods.insert(.alt)
            case "super", "cmd", "command": mods.insert(.superKey)
            default: return nil
            }
        }
        self.mods = mods
        var name = last
        if name.hasPrefix("physical:") {
            name.removeFirst("physical:".count)
        }
        let symbols: [String: String] = ["plus": "+", "greater_than": ">", "less_than": "<"]
        if let key = NamedKey(configName: name) {
            self.key = .physical(key)
        } else if let symbol = symbols[name] ?? (name.unicodeScalars.count == 1 ? name : nil),
                  let scalar = symbol.unicodeScalars.first {
            self.key = .unicode(scalar.value)
        } else {
            return nil
        }
    }

    init(mods: Mods, key: TriggerKey) {
        self.mods = mods
        self.key = key
    }

    /// Whether a key press matches. Character triggers compare against the
    /// unshifted codepoint, and against the shifted text when Shift is part of
    /// the trigger (`super+shift+g` and `super+G` alike).
    func matches(key: NamedKey?, unshifted: UInt32, text: String?, mods pressed: Mods) -> Bool {
        let pressed = pressed.binding
        switch self.key {
        case let .physical(k):
            return k == key && pressed == mods
        case let .unicode(cp):
            if pressed == mods, unshifted != 0, Self.lower(unshifted) == Self.lower(cp) {
                return true
            }
            // A shifted symbol (e.g. "+" on shift+equal) bound without shift.
            if pressed == mods.union(.shift), let scalar = text?.unicodeScalars.first, scalar.value == cp {
                return true
            }
            return false
        }
    }

    private static func lower(_ cp: UInt32) -> UInt32 {
        (0x41 ... 0x5A).contains(cp) ? cp + 0x20 : cp
    }
}

/// `keybind = trigger[>trigger...]=action[:param]`.
struct Keybind: Sendable {
    var sequence: [Trigger]
    var action: String
    var flags: Set<String> = []

    var trigger: [Trigger] {
        sequence
    }

    init?(_ value: String) {
        var spec = value
        var flags: Set<String> = []
        for prefix in ["global:", "all:", "unconsumed:", "performable:"] {
            while spec.hasPrefix(prefix) {
                flags.insert(String(prefix.dropLast()))
                spec.removeFirst(prefix.count)
            }
        }
        // The action starts after the first "=" that is not the key itself
        // (e.g. `super+==increase_font_size:1`).
        guard let split = Self.actionSeparator(in: spec) else { return nil }
        let triggerText = String(spec[..<split])
        let action = String(spec[spec.index(after: split)...])
        var sequence: [Trigger] = []
        for part in triggerText.split(separator: ">") {
            guard let t = Trigger(String(part)) else { return nil }
            sequence.append(t)
        }
        guard !sequence.isEmpty, !action.isEmpty else { return nil }
        self.sequence = sequence
        self.action = action
        self.flags = flags
    }

    init(_ trigger: String, _ action: String) {
        sequence = [Trigger(trigger)!]
        self.action = action
    }

    private static func actionSeparator(in s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "=" {
                let previous = i > s.startIndex ? s[s.index(before: i)] : "+"
                // "=" directly after a "+" or at the start is the equal key.
                if previous != "+" {
                    return i
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Ghostty's macOS defaults that make sense for a touch/iPad terminal.
    static let defaults: [Keybind] = [
        Keybind("super+c", "copy_to_clipboard"),
        Keybind("super+v", "paste_from_clipboard"),
        Keybind("super+k", "clear_screen"),
        Keybind("super+a", "select_all"),
        Keybind("super+equal", "increase_font_size:1"),
        Keybind("super+plus", "increase_font_size:1"),
        Keybind("super+minus", "decrease_font_size:1"),
        Keybind("super+0", "reset_font_size"),
        Keybind("super+home", "scroll_to_top"),
        Keybind("super+end", "scroll_to_bottom"),
        Keybind("super+page_up", "scroll_page_up"),
        Keybind("super+page_down", "scroll_page_down"),
        Keybind("shift+page_up", "scroll_page_up"),
        Keybind("shift+page_down", "scroll_page_down"),
        Keybind("super+f", "start_search"),
        Keybind("super+g", "navigate_search:next"),
        Keybind("super+shift+g", "navigate_search:previous")
    ]
}
