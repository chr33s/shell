#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

struct MacApplicationCommands: Commands {
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
        // which cannot express tab groups, tmux window tabs, splits within a tab,
        // or Tab Exposé. These are the affordances that do carry over, backed by
        // the existing in-window tab model.
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
