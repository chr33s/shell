#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import os

/// The Services submenu.
///
/// UIKit builds the Catalyst main menu out of these commands and puts no Services
/// item in it, and AppKit fills only a menu it has been handed through
/// `NSApp.servicesMenu`, so the item is inserted on the AppKit side by the macOS
/// support bundle. Nothing here has to track UIKit's menu rebuilds: the bundle
/// re-attaches the item whenever the menu bar is entered.
@MainActor
enum MacServicesMenu {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "MacServicesMenu")
    private static var requested = false

    /// Installs the Services item once, one runloop turn after the command tree is
    /// first built. The main menu is UIKit's, made from that tree, so it does not
    /// exist yet while these commands are being constructed; a turn later it does.
    /// A first attempt that still finds no main menu is not fatal — the bundle has
    /// armed its own re-attach and the item appears at the latest when the user
    /// first enters the menu bar.
    static func installWhenMenuExists() {
        guard !requested else { return }
        requested = true
        DispatchQueue.main.async { install() }
    }

    private static func install() {
        guard let bridge = MacSupport.bridge else { return }
        let title = String(localized: "Services", comment: "Application menu item")
        if !bridge.installServicesMenu(title: title) {
            logger.notice("Services menu deferred: the main menu does not exist yet")
        }
    }
}

struct MacApplicationCommands: Commands {
    // The commands are the only handle this app has on menu-bar construction, so
    // the one-shot Services install is kicked off from here rather than from a
    // launch callback that runs before the menu exists.
    @MainActor init() { MacServicesMenu.installWhenMenuExists() }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Shell") { MacSupport.bridge?.showAbout() }
        }
        CommandGroup(replacing: .textFormatting) {}
        CommandGroup(after: .newItem) {
            Button("Close Tab") {
                if !UIApplication.shared.sendAction(#selector(Ghostty.TerminalView.closeSplit(_:)),
                                                     to: nil, from: nil, for: nil) {
                    MacSupport.bridge?.closeKeyWindow()
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { MacSupport.bridge?.closeKeyWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        // The Window menu carries what native NSWindow tabs would have provided.
        // The tab bar itself stays custom: AppKit tabs are one window per tab,
        // which cannot express tab groups, tmux window tabs, or splits within a
        // tab. These are the affordances that do carry over, backed by the
        // existing in-window tab model.
        CommandGroup(after: .windowArrangement) {
            Button("Previous Tab") { UIApplication.shared.menuPreviousTab(nil) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { UIApplication.shared.menuNextTab(nil) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            // The system-standard tab chords, which every other Mac tabbed app
            // answers. They are fixed rather than rebindable: the configurable
            // Previous/Next Tab actions are in the Tabs menu.
            Button("Show Previous Tab") { UIApplication.shared.menuPreviousTab(nil) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Show Next Tab") { UIApplication.shared.menuNextTab(nil) }
                .keyboardShortcut(.tab, modifiers: .control)

            Divider()

            Button("Move Tab to New Window") { UIApplication.shared.menuMoveTabToNewWindow(nil) }
            Button("Merge All Windows") { UIApplication.shared.menuMergeAllWindows(nil) }
        }
    }
}
#endif
