import AppKit

@objc(ShellMacSupport)
final class ShellMacSupport: NSObject, MacBridge {
    required override init() { super.init() }

    private let terminalEvents = NativeTerminalEvents()
    private let material = NativeWindowMaterial()
    private let dockMenu = NativeDockMenu()
    private var shells: [Int32: NativeShellProcess] = [:]
    func createShell(executable: String, arguments: [String], environment: [String: String],
                     directory: String, rows: UInt16, columns: UInt16) throws -> any MacShellProcess {
        let process = try NativeShellProcess(executable: executable, arguments: arguments,
            environment: environment, directory: directory, rows: rows, columns: columns)
        shells[process.processID] = process
        process.observeExit { [weak self] pid in self?.shells.removeValue(forKey: pid) }
        return process
    }
    func installTerminalEvents(
        scroll: @escaping (NSObject, CGPoint, Double, Double, Bool, Int) -> Bool,
        hover: @escaping (NSObject?, CGPoint) -> Void,
        menu: @escaping (NSObject, CGPoint) -> [any MacMenuEntry]?) {
        terminalEvents.install(scroll: scroll, hover: hover, menu: menu)
        for window in NSApp.windows { terminalEvents.track(window) }
    }
    func installDockMenu(_ provider: @escaping () -> [any MacMenuEntry]) -> Bool {
        dockMenu.install(provider: provider)
    }
    func showAbout() { NSApp.orderFrontStandardAboutPanel(nil) }
    func closeKeyWindow() { NSApp.keyWindow?.performClose(nil) }
    func stopShells() {
        for process in shells.values { process.terminate(signal: SIGHUP) }
    }

    var windows: [NSObject] { NSApp.windows }
    func isKeyWindow(_ window: NSObject) -> Bool { (window as? NSWindow)?.isKeyWindow ?? false }
    func isVisible(_ window: NSObject) -> Bool { (window as? NSWindow)?.isVisible ?? false }
    func isOpaque(_ window: NSObject) -> Bool { (window as? NSWindow)?.isOpaque ?? true }
    func frame(of window: NSObject) -> CGRect { (window as? NSWindow)?.frame ?? .zero }
    func setTitle(_ title: String, for window: NSObject) { (window as? NSWindow)?.title = title }
    func toggleFullScreen(_ window: NSObject) { (window as? NSWindow)?.toggleFullScreen(nil) }
    func setAlpha(_ alpha: CGFloat, for window: NSObject) { (window as? NSWindow)?.alphaValue = alpha }

    func activate(_ window: NSObject) {
        NSApp.unhide(nil)
        guard let window = window as? NSWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func beginWindowDrag(_ window: NSObject) -> Bool {
        guard let window = window as? NSWindow, !window.styleMask.contains(.fullScreen),
              let event = NSApp.currentEvent, event.window === window,
              event.type == .leftMouseDown else { return false }
        window.performDrag(with: event)
        return true
    }

    func configureBackground(_ transparent: Bool, for window: NSObject) {
        guard let window = window as? NSWindow else { return }
        window.acceptsMouseMovedEvents = true
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? NSColor(white: 1, alpha: 0.001) : .windowBackgroundColor
    }

    func refresh(_ window: NSObject) {
        guard let window = window as? NSWindow else { return }
        window.invalidateShadow()
        window.display()
    }

    func isMaterialBackdrop(_ window: NSObject) -> Bool { material.isBackdrop(window) }
    func applyGlassBackdrop(_ window: NSObject, clear: Bool) { material.applyGlass(to: window, clear: clear) }
    func removeGlassBackdrop(_ window: NSObject) { material.removeGlass(from: window) }
    func setVisualEffectBlur(_ enabled: Bool, for window: NSObject) {
        material.setVisualEffectBlur(enabled, for: window)
    }

    func setApplicationAppearance(_ mode: Int) {
        switch mode {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func titlebarLeadingInset(_ window: NSObject) -> CGFloat {
        guard let window = window as? NSWindow else { return 0 }
        let maxX = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil).maxX }.max() ?? 0
        return maxX > 0 ? maxX + 8 : 0
    }

    func configureTitlebar(_ object: NSObject, hidden: Bool, separatorHidden: Bool,
                          tabsInTitlebar: Bool, tabBarHidden: Bool, tabCount: Int) {
        guard let window = object as? NSWindow else { return }
        terminalEvents.track(window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = separatorHidden ? .none : .automatic
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = hidden
        }
        guard let content = window.contentView, let frame = content.superview else { return }
        removeDragViews(from: frame)
        // Track only chrome hidden by us so restoring does not reveal AppKit-hidden views.
        for view in frame.subviews where view !== content {
            if hidden, !view.isHidden {
                view.isHidden = true
                hiddenChrome.add(view)
            } else if !hidden, hiddenChrome.contains(view) {
                view.isHidden = false
                hiddenChrome.remove(view)
            }
        }
        guard (tabsInTitlebar && !tabBarHidden) || hidden else { return }
        let titlebar = frame.subviews.first { String(describing: type(of: $0)).contains("Titlebar") }
        let band = titlebar?.frame ?? NSRect(x: 0, y: frame.bounds.maxY - 28,
                                              width: frame.bounds.width, height: 28)
        if tabCount > 1, !hidden, let titlebar {
            let blocker = TitlebarDragBlocker(frame: NSRect(x: 100, y: 0,
                width: max(0, band.width - 100), height: max(0, band.height - 12)))
            blocker.autoresizingMask = [.width]
            titlebar.addSubview(blocker, positioned: .above, relativeTo: nil)
        }
        let leading: CGFloat = hidden ? 0 : 100
        let handle = TitlebarDragHandle(frame: NSRect(x: band.minX + leading, y: band.maxY - 12,
            width: max(0, band.width - leading), height: 12))
        handle.autoresizingMask = [.width, .minYMargin]
        frame.addSubview(handle, positioned: .above, relativeTo: nil)
    }

    private let hiddenChrome = NSHashTable<NSView>.weakObjects()

    private func removeDragViews(from view: NSView) {
        for child in view.subviews {
            if child is TitlebarDragHandle || child is TitlebarDragBlocker {
                child.removeFromSuperview()
            } else {
                removeDragViews(from: child)
            }
        }
    }
}
