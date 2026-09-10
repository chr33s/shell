#if targetEnvironment(macCatalyst)
import Foundation

@MainActor
final class CatalystKeyboardLayout {
    static let shared = CatalystKeyboardLayout()
    var isAvailable: Bool { MacSupport.bridge != nil }
    /// `command` selects the layout's Command-specific mapping so shortcuts
    /// resolve to the logical key on non-US layouts.
    func translateKey(cgKeyCode: UInt16, shift: Bool, command: Bool = false) -> String? {
        MacSupport.bridge?.translateKey(cgKeyCode, shift: shift, command: command)
    }
}
#endif
