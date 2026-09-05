import AppKit

/// One monitor per app. Returning nil consumes only events claimed by a visible terminal.
final class NativeTerminalEvents: NSObject {
    private var monitor: Any?
    private var scroll: ((NSObject, CGPoint, Double, Double, Bool, Int) -> Bool)?
    private var hover: ((NSObject?, CGPoint) -> Void)?
    private var menu: ((NSObject, CGPoint) -> [any MacMenuEntry]?)?
    private let trackedViews = NSHashTable<NSView>.weakObjects()
    private let builder = NativeMenuBuilder()

    func install(scroll: @escaping (NSObject, CGPoint, Double, Double, Bool, Int) -> Bool,
                 hover: @escaping (NSObject?, CGPoint) -> Void,
                 menu: @escaping (NSObject, CGPoint) -> [any MacMenuEntry]?) {
        self.scroll = scroll
        self.hover = hover
        self.menu = menu
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .rightMouseDown]) { [weak self] event in
            guard let self, let window = event.window, let point = self.normalizedPoint(event) else { return event }
            if event.type == .scrollWheel {
                let phase = self.momentum(event.momentumPhase)
                return self.scroll?(window, point, event.scrollingDeltaX, event.scrollingDeltaY,
                                    event.hasPreciseScrollingDeltas, phase) == true ? nil : event
            }
            guard let content = window.contentView,
                  let entries = self.menu?(window, point), !entries.isEmpty else { return event }
            NSMenu.popUpContextMenu(self.builder.menu(from: entries), with: event, for: content)
            return nil
        }
    }

    func track(_ window: NSWindow) {
        guard let view = window.contentView, !trackedViews.contains(view) else { return }
        trackedViews.add(view)
        view.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
            owner: self, userInfo: nil))
    }
    @objc func mouseMoved(with event: NSEvent) {
        guard let window = event.window, let point = normalizedPoint(event) else { return }
        hover?(window, point)
    }
    @objc func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    @objc func mouseExited(with event: NSEvent) { hover?(nil, .zero) }

    private func normalizedPoint(_ event: NSEvent) -> CGPoint? {
        guard let view = event.window?.contentView, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let point = view.convert(event.locationInWindow, from: nil)
        return CGPoint(x: (point.x - view.bounds.minX) / view.bounds.width,
                       y: view.isFlipped ? (point.y - view.bounds.minY) / view.bounds.height :
                        (view.bounds.maxY - point.y) / view.bounds.height)
    }
    private func momentum(_ phase: NSEvent.Phase) -> Int {
        if phase.contains(.began) { return 1 }
        if phase.contains(.stationary) { return 2 }
        if phase.contains(.changed) { return 3 }
        if phase.contains(.ended) { return 4 }
        if phase.contains(.cancelled) { return 5 }
        if phase.contains(.mayBegin) { return 6 }
        return 0
    }
}
