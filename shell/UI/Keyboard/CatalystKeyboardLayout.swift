#if targetEnvironment(macCatalyst)
import Foundation

@MainActor
final class CatalystKeyboardLayout {
    static let shared = CatalystKeyboardLayout()
    var isAvailable: Bool { MacSupport.bridge != nil }
    /// `command` selects the layout's Command-specific mapping so shortcuts
    /// resolve to the logical key on non-US layouts. `option` composes the
    /// layout's Option character and `capsLock` applies the Caps Lock state.
    func translateKey(cgKeyCode: UInt16, shift: Bool, command: Bool = false,
                      option: Bool = false, capsLock: Bool = false) -> String? {
        MacSupport.bridge?.translateKey(cgKeyCode, shift: shift, command: command,
                                        option: option, capsLock: capsLock)
    }
}
#endif
