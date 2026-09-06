import AppKit

/// Standalone ABI smoke test: loads the separately built bundle through the same
/// Objective-C protocol as Catalyst, then checks isolation between two windows.
@main
struct MacSupportSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        precondition(CommandLine.arguments.count == 2, "Pass the built ShellMacSupport.bundle path")
        let bundle = Bundle(path: CommandLine.arguments[1])!
        try bundle.loadAndReturnError()
        let type = bundle.principalClass as! any MacBridge.Type
        let bridge = type.init()
        let first = NSWindow(contentRect: NSRect(x: 10, y: 20, width: 640, height: 480),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 800, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        bridge.setTitle("First terminal", for: first)
        bridge.setTitle("Second terminal", for: second)
        precondition(first.title == "First terminal" && second.title == "Second terminal")
        precondition(bridge.frame(of: first) == first.frame)
        precondition(bridge.frame(of: second) == second.frame)
        bridge.configureBackground(true, for: first)
        bridge.configureBackground(false, for: second)
        precondition(!bridge.isOpaque(first) && bridge.isOpaque(second))
        bridge.configureTitlebar(first, hidden: true, separatorHidden: true,
                                 tabsInTitlebar: true, tabBarHidden: false, tabCount: 2)
        precondition(first.standardWindowButton(.closeButton)?.isHidden == true)
        precondition(first.styleMask.contains(.fullSizeContentView))
        bridge.configureTitlebar(first, hidden: false, separatorHidden: false,
                                 tabsInTitlebar: false, tabBarHidden: true, tabCount: 1)
        precondition(first.standardWindowButton(.closeButton)?.isHidden == false)
        precondition(first.titlebarSeparatorStyle == .automatic)
        precondition(!bridge.beginWindowDrag(first), "Dragging without a mouse-down event must be rejected")
        precondition(bridge.frame(of: NSObject()) == .zero)

        // Window material: the visual-effect blur is add/remove idempotent and
        // scoped to one window, and no plain window is ever a glass backdrop.
        precondition(!bridge.isMaterialBackdrop(first) && !bridge.isMaterialBackdrop(second))
        let blurCount: (NSWindow) -> Int = { window in
            window.contentView?.subviews.filter { $0 is NSVisualEffectView }.count ?? 0
        }
        bridge.setVisualEffectBlur(true, for: first)
        bridge.setVisualEffectBlur(true, for: first)
        precondition(blurCount(first) == 1, "Repeated blur installs must not stack views")
        precondition(blurCount(second) == 0, "Blur must not leak into another window")
        bridge.setVisualEffectBlur(false, for: first)
        precondition(blurCount(first) == 0)
        bridge.setVisualEffectBlur(false, for: first)
        precondition(blurCount(first) == 0, "Removing an absent blur must be a no-op")

        // Glass is only built for a visible, non-opaque window; a hidden one is
        // left for a later pass rather than given a backdrop that cannot render.
        bridge.applyGlassBackdrop(first, clear: false)
        precondition(first.childWindows?.isEmpty ?? true, "Hidden window must not get a backdrop")
        bridge.removeGlassBackdrop(first)

        bridge.setAlpha(0, for: first)
        precondition(first.alphaValue == 0)
        bridge.setAlpha(1, for: first)

        bridge.setApplicationAppearance(2)
        precondition(NSApp.appearance?.name == .darkAqua)
        bridge.setApplicationAppearance(1)
        precondition(NSApp.appearance?.name == .aqua)
        bridge.setApplicationAppearance(0)
        precondition(NSApp.appearance == nil)

        // No NSApplication delegate in this harness, so the Dock menu has nothing
        // to attach to — it must report that rather than crash.
        precondition(!bridge.installDockMenu({ [] }), "Dock menu needs an application delegate")

        // Services: declined while there is no main menu, then inserted above the
        // Hide group, wired to NSApp.servicesMenu, and idempotent across the
        // rebuilds UIKit performs on the Catalyst main menu. The harness has no
        // menu of its own, so the application menu is synthesized to pin both the
        // placement rule and the second install being a no-op.
        precondition(!bridge.installServicesMenu(title: "Services"), "No main menu means no Services item")
        let appMenu = NSMenu(title: "shell")
        appMenu.addItem(withTitle: "About shell", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide shell", action: NSSelectorFromString("hide:"), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit shell", action: NSSelectorFromString("terminate:"), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
        defer { NSApp.mainMenu = nil; NSApp.servicesMenu = nil }
        precondition(bridge.installServicesMenu(title: "Services"))
        guard let services = NSApp.servicesMenu,
              let servicesIndex = appMenu.items.firstIndex(where: { $0.submenu === services }),
              let hideIndex = appMenu.items.firstIndex(where: { $0.action == NSSelectorFromString("hide:") })
        else { preconditionFailure("Services item was not installed") }
        precondition(servicesIndex < hideIndex, "Services belongs above the Hide group")
        let installedItems = appMenu.numberOfItems
        precondition(bridge.installServicesMenu(title: "Services"))
        precondition(appMenu.numberOfItems == installedItems, "A second install must not duplicate the item")
        precondition(NSApp.servicesMenu === services, "The submenu AppKit fills must survive a reinstall")

        try checkShellSpawn(bridge)
        checkInputSources(bridge)
        print("Mac support ABI and window isolation smoke test passed")
    }

    /// The native PTY: a real fork/exec through PTYSpawn.c, its output read back
    /// off the duplicated master, and a failed exec reported as a thrown error
    /// rather than a live process writing to a dead descriptor.
    @MainActor private static func checkShellSpawn(_ bridge: any MacBridge) throws {
        let process = try bridge.createShell(
            executable: "/bin/sh", arguments: ["-c", "printf 'pty-ok'"],
            environment: ["PATH": "/usr/bin:/bin"], directory: "/", rows: 24, columns: 80)
        precondition(process.processID > 0, "Spawn must report the child's pid")
        let master = process.duplicateMaster()
        precondition(master >= 0, "The master descriptor must be duplicable")
        defer { close(master); process.terminate(signal: SIGKILL) }

        // The slave stays open until the child exits, so read until the shell's
        // output has arrived rather than until EOF.
        var output = ""
        var buffer = [UInt8](repeating: 0, count: 256)
        while !output.contains("pty-ok") {
            let count = read(master, &buffer, buffer.count)
            guard count > 0 else { break }
            output += String(decoding: buffer[0..<count], as: UTF8.self)
        }
        precondition(output.contains("pty-ok"), "Expected the child's PTY output, got \(output.debugDescription)")

        var execFailed = false
        do {
            _ = try bridge.createShell(
                executable: "/nonexistent/shell", arguments: [], environment: [:],
                directory: "/", rows: 24, columns: 80)
        } catch { execFailed = true }
        precondition(execFailed, "A failed exec must surface as a thrown error, not a live process")
    }

    /// Text Input Services returns NULL rather than an empty list when it is
    /// unavailable, so every entry point has to answer without unwrapping it.
    @MainActor private static func checkInputSources(_ bridge: any MacBridge) {
        for source in bridge.inputSources() {
            precondition(source["id"] != nil && source["name"] != nil, "Every source needs an id and a name")
        }
        _ = bridge.currentInputSourceID()
        _ = bridge.currentInputSourceLanguages()
        _ = bridge.translateKey(0, shift: false)
        precondition(!bridge.selectInputSource("dev.chr33s.shell.no-such-input-source"),
                     "An unknown input source must be declined, not selected")
    }
}
