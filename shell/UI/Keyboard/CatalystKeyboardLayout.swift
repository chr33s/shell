#if targetEnvironment(macCatalyst)
import Foundation

@MainActor
final class CatalystKeyboardLayout {
    static let shared = CatalystKeyboardLayout()
    var isAvailable: Bool { MacSupport.bridge != nil }
    func translateKey(cgKeyCode: UInt16, shift: Bool) -> String? {
        MacSupport.bridge?.translateKey(cgKeyCode, shift: shift)
    }
}
#endif
