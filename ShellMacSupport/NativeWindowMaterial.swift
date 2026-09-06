import AppKit

/// Owns the AppKit side of the window background material: the liquid-glass
/// backdrop and the NSVisualEffectView blur used by sandboxed builds.
///
/// Glass lives in a borderless child window ordered directly behind the terminal
/// window rather than in-window: Catalyst's hosted UIKit tree is treated as
/// foreground by an in-window glass pass, so it would refract the terminal
/// instead of the desktop. The terminal keeps drawing its theme background at the
/// configured opacity, so the window's own alpha and shadow are unchanged.
final class NativeWindowMaterial {
    private static let blurViewIdentifier = NSUserInterfaceItemIdentifier("dev.chr33s.shell.backgroundBlur")

    private final class Backdrop {
        let window: NSWindow
        let glassView: NSGlassEffectView
        var observers: [NSObjectProtocol] = []
        init(window: NSWindow, glassView: NSGlassEffectView) {
            self.window = window
            self.glassView = glassView
        }
    }

    private var backdrops: [ObjectIdentifier: Backdrop] = [:]

    func isBackdrop(_ window: NSObject) -> Bool {
        backdrops.values.contains { $0.window === window }
    }

    // MARK: - Liquid glass

    func applyGlass(to object: NSObject, clear: Bool) {
        guard let window = object as? NSWindow else { return }
        // A child ordered in before the parent is on screen would show alone;
        // the caller re-asserts the material once the window becomes visible.
        guard window.isVisible else { return }
        // A backdrop ordered in under an opaque parent is born fully occluded and
        // its glass never starts rendering. Drop any existing one and wait for the
        // pass that clears `isOpaque`, so the glass is always built on screen.
        guard !window.isOpaque else {
            removeGlass(from: window)
            return
        }

        let key = ObjectIdentifier(window)
        let backdrop: Backdrop
        if let existing = backdrops[key] {
            backdrop = existing
        } else {
            let frame = window.frame
            let child = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            child.isOpaque = false
            child.hasShadow = false
            child.ignoresMouseEvents = true
            child.isReleasedWhenClosed = false
            child.backgroundColor = .clear
            // Dark-appearance "regular" glass is a dark smoky material that hides
            // the desktop; light appearance renders bright frosted glass that
            // passes the desktop through the way the CGS blur does.
            child.appearance = NSAppearance(named: .aqua)

            let glassView = NSGlassEffectView(frame: NSRect(origin: .zero, size: frame.size))
            glassView.autoresizingMask = [.width, .height]
            child.contentView = glassView
            window.addChildWindow(child, ordered: .below)

            backdrop = Backdrop(window: child, glassView: glassView)
            let center = NotificationCenter.default
            for name: NSNotification.Name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                                              NSWindow.didEnterFullScreenNotification,
                                              NSWindow.didExitFullScreenNotification] {
                backdrop.observers.append(center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] notification in
                    guard let parent = notification.object as? NSWindow else { return }
                    MainActor.assumeIsolated { self?.syncBackdrop(to: parent) }
                })
            }
            backdrop.observers.append(center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] notification in
                guard let parent = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.removeGlass(from: parent) }
            })
            backdrops[key] = backdrop
        }

        backdrop.glassView.style = clear ? .clear : .regular
        syncBackdrop(to: window)
    }

    func removeGlass(from object: NSObject) {
        guard let backdrop = backdrops.removeValue(forKey: ObjectIdentifier(object)) else { return }
        backdrop.observers.forEach { NotificationCenter.default.removeObserver($0) }
        (object as? NSWindow)?.removeChildWindow(backdrop.window)
        backdrop.window.orderOut(nil)
        // `isReleasedWhenClosed` is false, so this only takes the window out of
        // NSApp.windows — without it every teardown leaks a hidden window that the
        // material sweep then rescans forever.
        backdrop.window.close()
    }

    /// Match the backdrop's frame and corner radius to its parent.
    private func syncBackdrop(to window: NSWindow) {
        guard let backdrop = backdrops[ObjectIdentifier(window)] else { return }
        backdrop.window.setFrame(window.frame, display: true)
        // Rounded corners are the parent's; full screen has none. Same private
        // `_cornerRadius` read ghostty uses for its own glass shape.
        var radius: CGFloat = 0
        if !window.styleMask.contains(.fullScreen),
           window.responds(to: NSSelectorFromString("_cornerRadius")),
           let parentRadius = window.value(forKey: "_cornerRadius") as? CGFloat {
            radius = parentRadius
        }
        backdrop.glassView.cornerRadius = radius
    }

    // MARK: - NSVisualEffectView blur

    func setVisualEffectBlur(_ enabled: Bool, for object: NSObject) {
        guard let content = (object as? NSWindow)?.contentView else { return }
        let existing = content.subviews.first { $0.identifier == Self.blurViewIdentifier }
        guard enabled else {
            existing?.removeFromSuperview()
            return
        }
        if let existing {
            // Re-insert so later subviews cannot end up beneath the blur.
            existing.removeFromSuperview()
            content.addSubview(existing, positioned: .below, relativeTo: nil)
            return
        }
        let blurView = NSVisualEffectView(frame: content.bounds)
        // .hudWindow reads well behind terminal text; .behindWindow blurs the
        // desktop rather than the app's own content; .active keeps the effect on
        // while the window is inactive.
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.identifier = Self.blurViewIdentifier
        blurView.autoresizingMask = [.width, .height]
        content.addSubview(blurView, positioned: .below, relativeTo: nil)
    }
}
