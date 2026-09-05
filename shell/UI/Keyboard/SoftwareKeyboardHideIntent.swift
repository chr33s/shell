import UIKit

/// User intent to keep the software keyboard hidden, scoped to a window so
/// tab switches and overlay round trips inside that window re-apply it
/// instead of re-showing the keyboard. Session-only.
enum SoftwareKeyboardHideIntent: Equatable {
    case none
    /// Hidden via the toolbar chevron. `pinned` (long press) survives terminal
    /// taps; only the chevron restores it.
    case hidden(pinned: Bool)

    var isHidden: Bool { self != .none }
    var isPinned: Bool { self == .hidden(pinned: true) }
}

@MainActor
final class SoftwareKeyboardHideIntentStore {
    static let shared = SoftwareKeyboardHideIntentStore()

    private final class Box {
        var intent: SoftwareKeyboardHideIntent
        init(_ intent: SoftwareKeyboardHideIntent) { self.intent = intent }
    }

    private let intents = NSMapTable<UIWindow, Box>.weakToStrongObjects()

    func intent(for window: UIWindow?) -> SoftwareKeyboardHideIntent {
        guard let window else { return .none }
        return intents.object(forKey: window)?.intent ?? .none
    }

    func set(_ intent: SoftwareKeyboardHideIntent, for window: UIWindow?) {
        guard let window else { return }
        if intent == .none {
            intents.removeObject(forKey: window)
        } else {
            intents.setObject(Box(intent), forKey: window)
        }
    }
}
