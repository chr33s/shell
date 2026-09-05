//
//  DraggableTabBar.swift
//  shell
//
//  Catalyst window-drag regions used by the integrated top tab bar.
//

import SwiftUI

#if targetEnvironment(macCatalyst)
import AppKit
import UIKit

extension View {
    /// Placeholder modifier - drag blocking is now handled by WindowAccessor
    func blockWindowDrag(when enabled: Bool) -> some View {
        self  // Pass through unchanged - AppKit DragBlockerView handles this
    }
}

/// A UIKit-hosted region that starts AppKit's native window drag using the
/// current mouse-down event. Hosting a real UIView is important: a clear
/// SwiftUI shape does not reliably win hit testing over a UIViewRepresentable
/// terminal beneath it on Catalyst.
struct CatalystWindowDragRegion: UIViewRepresentable {
    var tabStyleSelection: Binding<String>?

    init(tabStyleSelection: Binding<String>? = nil) {
        self.tabStyleSelection = tabStyleSelection
    }

    func makeCoordinator() -> TabStyleContextMenuCoordinator {
        TabStyleContextMenuCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = CatalystWindowDragView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.accessibilityElementsHidden = true
        if let tabStyleSelection {
            context.coordinator.update(
                selectedStyleRawValue: tabStyleSelection,
                primaryAction: nil
            )
            context.coordinator.install(on: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let tabStyleSelection {
            context.coordinator.update(
                selectedStyleRawValue: tabStyleSelection,
                primaryAction: nil
            )
        }
    }
}

private final class CatalystWindowDragView: UIView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let sceneID = window?.windowScene?.session.persistentIdentifier,
              let bridge = MacSupport.bridge,
              let nsWindow = MacSupport.window(for: sceneID) else {
            super.touchesBegan(touches, with: event)
            return
        }
        WindowDragObserver.shared.dragStripTouchBegan()
        let handled = bridge.beginWindowDrag(nsWindow)
        WindowDragObserver.shared.dragStripTouchEnded()
        if !handled { super.touchesBegan(touches, with: event) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        WindowDragObserver.shared.dragStripTouchEnded()
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        WindowDragObserver.shared.dragStripTouchEnded()
        super.touchesCancelled(touches, with: event)
    }
}

#endif
