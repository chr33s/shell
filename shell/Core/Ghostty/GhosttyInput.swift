//
//  GhosttyInput.swift
//  shell
//
//  Input handling for Ghostty on iOS
//

import Foundation
import UIKit
import GhosttyKit

extension Ghostty {
    struct Input {}
}

// MARK: - Ghostty.Input.KeyEvent

extension Ghostty.Input {
    /// Represents a keyboard input event
    struct KeyEvent {
        let action: Action
        /// Native Apple keycode expected by Ghostty's embedded API.
        /// This is not a `ghostty_input_key_e` raw value.
        let nativeKeyCode: UInt32
        let text: String?
        let composing: Bool
        let mods: Mods
        let consumedMods: Mods
        let unshiftedCodepoint: UInt32

        init(
            nativeKeyCode: UInt32,
            action: Action = .press,
            text: String? = nil,
            composing: Bool = false,
            mods: Mods = [],
            consumedMods: Mods = [],
            unshiftedCodepoint: UInt32 = 0
        ) {
            self.nativeKeyCode = nativeKeyCode
            self.action = action
            self.text = text
            self.composing = composing
            self.mods = mods
            self.consumedMods = consumedMods
            self.unshiftedCodepoint = unshiftedCodepoint
        }

        /// Executes a closure with a temporary C representation of this KeyEvent
        @discardableResult
        func withCValue<T>(execute: (ghostty_input_key_s) -> T) -> T {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action.cAction
            keyEvent.keycode = nativeKeyCode
            keyEvent.composing = composing
            keyEvent.mods = mods.cMods
            keyEvent.consumed_mods = consumedMods.cMods
            keyEvent.unshifted_codepoint = unshiftedCodepoint

            if let text = text {
                return text.withCString { textPtr in
                    keyEvent.text = textPtr
                    return execute(keyEvent)
                }
            } else {
                keyEvent.text = nil
                return execute(keyEvent)
            }
        }
    }
}

// MARK: - Ghostty.Input.Action

extension Ghostty.Input {
    enum Action {
        case release
        case press
        case `repeat`

        var cAction: ghostty_input_action_e {
            switch self {
            case .release: return GHOSTTY_ACTION_RELEASE
            case .press: return GHOSTTY_ACTION_PRESS
            case .repeat: return GHOSTTY_ACTION_REPEAT
            }
        }
    }
}

// MARK: - Native Keycodes

extension Ghostty.Input {
    /// Translate UIKit HID usages to the native macOS keycodes used by
    /// Ghostty's Apple-platform keymap. The embedded C API's `keycode` field
    /// takes this native value, not a `ghostty_input_key_e` enum raw value.
    static func nativeKeyCode(for hidUsage: UIKeyboardHIDUsage) -> UInt32? {
        nativeKeyCodes[hidUsage]
    }

    private static let nativeKeyCodes: [UIKeyboardHIDUsage: UInt32] = [
        // Printable keys
        .keyboardA: 0x00, .keyboardS: 0x01, .keyboardD: 0x02, .keyboardF: 0x03,
        .keyboardH: 0x04, .keyboardG: 0x05, .keyboardZ: 0x06, .keyboardX: 0x07,
        .keyboardC: 0x08, .keyboardV: 0x09, .keyboardB: 0x0B, .keyboardQ: 0x0C,
        .keyboardW: 0x0D, .keyboardE: 0x0E, .keyboardR: 0x0F, .keyboardY: 0x10,
        .keyboardT: 0x11, .keyboard1: 0x12, .keyboard2: 0x13, .keyboard3: 0x14,
        .keyboard4: 0x15, .keyboard6: 0x16, .keyboard5: 0x17, .keyboardEqualSign: 0x18,
        .keyboard9: 0x19, .keyboard7: 0x1A, .keyboardHyphen: 0x1B, .keyboard8: 0x1C,
        .keyboard0: 0x1D, .keyboardCloseBracket: 0x1E, .keyboardO: 0x1F,
        .keyboardU: 0x20, .keyboardOpenBracket: 0x21, .keyboardI: 0x22,
        .keyboardP: 0x23, .keyboardL: 0x25, .keyboardJ: 0x26, .keyboardQuote: 0x27,
        .keyboardK: 0x28, .keyboardSemicolon: 0x29,
        // ISO keyboards reuse the ANSI backslash position for the Non-US pound key.
        .keyboardBackslash: 0x2A, .keyboardNonUSPound: 0x2A,
        .keyboardComma: 0x2B, .keyboardSlash: 0x2C, .keyboardN: 0x2D,
        .keyboardM: 0x2E, .keyboardPeriod: 0x2F,
        .keyboardTab: 0x30, .keyboardSpacebar: 0x31,
        .keyboardGraveAccentAndTilde: 0x32,
        .keyboardNonUSBackslash: 0x0A,
        .keyboardDeleteOrBackspace: 0x33,
        .keyboardReturnOrEnter: 0x24,
        .keyboardEscape: 0x35,

        // Modifier keys
        .keyboardLeftGUI: 0x37, .keyboardRightGUI: 0x36,
        .keyboardLeftShift: 0x38, .keyboardRightShift: 0x3C,
        .keyboardLeftAlt: 0x3A, .keyboardRightAlt: 0x3D,
        .keyboardLeftControl: 0x3B, .keyboardRightControl: 0x3E,

        // Function keys
        .keyboardF1: 0x7A, .keyboardF2: 0x78, .keyboardF3: 0x63, .keyboardF4: 0x76,
        .keyboardF5: 0x60, .keyboardF6: 0x61, .keyboardF7: 0x62, .keyboardF8: 0x64,
        .keyboardF9: 0x65, .keyboardF10: 0x6D, .keyboardF11: 0x67, .keyboardF12: 0x6F,
        .keyboardF13: 0x69, .keyboardF14: 0x6B, .keyboardF15: 0x71, .keyboardF16: 0x6A,
        .keyboardF17: 0x40, .keyboardF18: 0x4F, .keyboardF19: 0x50,

        // Navigation keys
        .keyboardUpArrow: 0x7E, .keyboardDownArrow: 0x7D,
        .keyboardLeftArrow: 0x7B, .keyboardRightArrow: 0x7C,
        .keyboardHome: 0x73, .keyboardEnd: 0x77,
        .keyboardPageUp: 0x74, .keyboardPageDown: 0x79,
        .keyboardDeleteForward: 0x75, .keyboardInsert: 0x72,
    ]
}

// MARK: - Ghostty.Input.Mods

extension Ghostty.Input {
    struct Mods: OptionSet {
        let rawValue: UInt32

        static let none = Mods([])
        static let shift = Mods(rawValue: GHOSTTY_MODS_SHIFT.rawValue)
        static let ctrl = Mods(rawValue: GHOSTTY_MODS_CTRL.rawValue)
        static let alt = Mods(rawValue: GHOSTTY_MODS_ALT.rawValue)
        static let cmd = Mods(rawValue: GHOSTTY_MODS_SUPER.rawValue)
        static let caps = Mods(rawValue: GHOSTTY_MODS_CAPS.rawValue)
        static let shiftRight = Mods(rawValue: GHOSTTY_MODS_SHIFT_RIGHT.rawValue)
        static let ctrlRight = Mods(rawValue: GHOSTTY_MODS_CTRL_RIGHT.rawValue)
        static let altRight = Mods(rawValue: GHOSTTY_MODS_ALT_RIGHT.rawValue)
        static let cmdRight = Mods(rawValue: GHOSTTY_MODS_SUPER_RIGHT.rawValue)

        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        init(cMods: ghostty_input_mods_e) {
            self.rawValue = cMods.rawValue
        }

        var cMods: ghostty_input_mods_e {
            ghostty_input_mods_e(rawValue)
        }
    }

    /// Scroll event modifiers (precision and momentum)
    /// This is a packed bitmask matching the Zig `ScrollMods` packed struct.
    struct ScrollMods {
        let rawValue: Int32

        static let none = ScrollMods(precision: false, momentum: .none)

        init(precision: Bool = false, momentum: Momentum = .none) {
            var value: Int32 = 0
            if precision {
                value |= 0b0000_0001
            }
            value |= Int32(momentum.rawValue) << 1
            self.rawValue = value
        }

        init(rawValue: Int32) {
            self.rawValue = rawValue
        }

        var cMods: ghostty_input_scroll_mods_t {
            rawValue
        }
    }

    /// Momentum phase for scroll events (inertial scrolling)
    enum Momentum: UInt8 {
        case none = 0
        case began = 1
        case stationary = 2
        case changed = 3
        case ended = 4
        case cancelled = 5
        case mayBegin = 6
    }
}

// MARK: - Ghostty.Input.MouseButtonEvent

extension Ghostty.Input {
    struct MouseButtonEvent {
        let action: MouseState
        let button: MouseButton
        let mods: Mods

        init(action: MouseState, button: MouseButton, mods: Mods = []) {
            self.action = action
            self.button = button
            self.mods = mods
        }
    }

    enum MouseState {
        case release
        case press

        var cMouseState: ghostty_input_mouse_state_e {
            switch self {
            case .release: return GHOSTTY_MOUSE_RELEASE
            case .press: return GHOSTTY_MOUSE_PRESS
            }
        }
    }

    enum MouseButton {
        case unknown
        case left
        case right
        case middle

        var cMouseButton: ghostty_input_mouse_button_e {
            switch self {
            case .unknown: return GHOSTTY_MOUSE_UNKNOWN
            case .left: return GHOSTTY_MOUSE_LEFT
            case .right: return GHOSTTY_MOUSE_RIGHT
            case .middle: return GHOSTTY_MOUSE_MIDDLE
            }
        }
    }
}

// MARK: - Ghostty.Input.MousePosEvent

extension Ghostty.Input {
    struct MousePosEvent {
        let x: Double
        let y: Double
        let mods: Mods

        init(x: Double, y: Double, mods: Mods = []) {
            self.x = x
            self.y = y
            self.mods = mods
        }
    }
}

// MARK: - Ghostty.Input.MouseScrollEvent

extension Ghostty.Input {
    struct MouseScrollEvent {
        let deltaX: Double
        let deltaY: Double
        let mods: ScrollMods

        init(deltaX: Double, deltaY: Double, mods: ScrollMods = .none) {
            self.deltaX = deltaX
            self.deltaY = deltaY
            self.mods = mods
        }
    }
}
