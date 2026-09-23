import Foundation
import CoreGraphics

/// Keyboard notifications can describe the system keyboard without its input
/// accessory after reloadInputViews. Include the accessory's actual placement,
/// without adding its height twice when the notification already includes it.
nonisolated enum TerminalKeyboardGeometry {
    static func includingAccessory(keyboard: CGRect, accessory: CGRect?, container: CGRect) -> CGRect {
        guard let accessory,
              !keyboard.isNull, !keyboard.isEmpty,
              !accessory.isNull, !accessory.isEmpty,
              keyboard.width >= container.width - 50,
              accessory.width >= container.width - 50,
              keyboard.intersects(container), accessory.intersects(container),
              // Only the row adjoining/inside the keyboard's top edge belongs
              // to this placement. During show/hide the accessory can still be
              // at its old position while the notification gives the destination.
              accessory.maxY >= keyboard.minY - 2,
              accessory.minY <= keyboard.minY + 2 else { return keyboard }
        return keyboard.union(accessory)
    }
}
