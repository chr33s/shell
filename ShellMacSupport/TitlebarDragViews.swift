import AppKit

final class TitlebarDragHandle: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { noteHover() }
    override func mouseMoved(with event: NSEvent) { noteHover() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    private func noteHover() {
        NSCursor.openHand.set()
        NotificationCenter.default.post(name: Notification.Name("ShellMacDragStripHover"), object: window)
    }
    override func mouseDown(with event: NSEvent) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        NotificationCenter.default.post(name: Notification.Name("ShellMacDragStripBegan"), object: window)
        window.performDrag(with: event)
        NotificationCenter.default.post(name: Notification.Name("ShellMacDragStripEnded"), object: window)
    }
}

final class TitlebarDragBlocker: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let event = NSApp.currentEvent,
           [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type) { return nil }
        if let content = window?.contentView, let parent = superview {
            let contentPoint = content.superview?.convert(point, from: parent) ?? point
            if let target = content.hitTest(contentPoint), target !== content { return nil }
        }
        return hit
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
}
