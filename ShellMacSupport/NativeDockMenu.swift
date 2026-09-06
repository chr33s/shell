import AppKit
import ObjectiveC

/// Turns the bridge's menu model into a real `NSMenu`, retaining the entries for
/// as long as the menu lives so their actions survive AppKit's tracking loop.
final class NativeMenuBuilder: NSObject {
    func menu(from entries: [any MacMenuEntry]) -> NSMenu {
        let result = NSMenu()
        result.autoenablesItems = false
        for entry in entries {
            if entry.isSeparator { result.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: #selector(invoke(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry
            item.isEnabled = entry.enabled
            item.state = NSControl.StateValue(rawValue: entry.state)
            if !entry.children.isEmpty { item.submenu = menu(from: entry.children) }
            result.addItem(item)
        }
        return result
    }

    @objc private func invoke(_ item: NSMenuItem) {
        (item.representedObject as? any MacMenuEntry)?.invoke()
    }
}

/// The Dock tile's menu.
///
/// AppKit reads it from `applicationDockMenu(_:)` on the application delegate,
/// and under Catalyst that delegate belongs to UIKit's shim, which does not
/// implement the method. Rather than replace or proxy the delegate — both of
/// which change an object UIKit hands to its own internals — this adds the one
/// missing method to the shim's class. Nothing existing is swizzled or
/// overridden: if a future UIKit implements `applicationDockMenu(_:)` itself,
/// `class_addMethod` declines and its version keeps winning.
final class NativeDockMenu: NSObject {
    private static var provider: (() -> [any MacMenuEntry])?
    private static let builder = NativeMenuBuilder()

    func install(provider: @escaping () -> [any MacMenuEntry]) -> Bool {
        // Swapping the provider is enough once the method is in place.
        Self.provider = provider
        guard let delegate = NSApp.delegate, let cls: AnyClass = object_getClass(delegate) else { return false }
        let selector = #selector(NSApplicationDelegate.applicationDockMenu(_:))
        if delegate.responds(to: selector) { return true }
        let block: @convention(block) (AnyObject, NSApplication) -> NSMenu? = { _, _ in
            guard let entries = NativeDockMenu.provider?(), !entries.isEmpty else { return nil }
            return NativeDockMenu.builder.menu(from: entries)
        }
        return class_addMethod(cls, selector, imp_implementationWithBlock(block), "@@:@")
    }
}

/// The standard Services submenu.
///
/// UIKit builds `NSApp.mainMenu` under Catalyst and puts no Services item in it,
/// and AppKit only populates a menu it has been handed through
/// `NSApp.servicesMenu`. UIKit also regenerates the main menu whenever the menu
/// system is invalidated — which SwiftUI does every time the command tree
/// republishes — dropping anything inserted before. So the install is idempotent
/// and re-applied from `NSMenu.didBeginTrackingNotification` on the main menu,
/// which AppKit posts when the user enters the menu bar, before any submenu is
/// shown.
///
/// It lives beside the Dock menu rather than in its own file because the bundle's
/// sources are listed one by one in the project; it shares nothing with
/// `NativeMenuBuilder`, which builds menus this app owns outright.
final class NativeServicesMenu: NSObject {
    private var title = ""
    private var observer: NSObjectProtocol?
    /// The submenu handed to AppKit, so a rebuild re-attaches the menu AppKit has
    /// already filled instead of a fresh empty one.
    private weak var installed: NSMenu?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func install(title: String) -> Bool {
        self.title = title
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let menu = note.object as? NSMenu, menu === NSApp.mainMenu else { return }
                self.attach()
            }
        }
        return attach()
    }

    @discardableResult private func attach() -> Bool {
        // AppKit guarantees item 0 of the main menu is the application menu.
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return false }
        let submenu = NSApp.servicesMenu ?? installed ?? NSMenu(title: title)
        installed = submenu
        guard !appMenu.items.contains(where: { $0.submenu === submenu }) else {
            if NSApp.servicesMenu !== submenu { NSApp.servicesMenu = submenu }
            return true
        }
        // Detach from the menu UIKit has just discarded: AppKit refuses a submenu
        // that still belongs to another item.
        if let holder = submenu.supermenu?.items.first(where: { $0.submenu === submenu }) {
            holder.submenu = nil
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        var index = insertionIndex(in: appMenu)
        if index > 0, !appMenu.items[index - 1].isSeparatorItem {
            appMenu.insertItem(.separator(), at: index)
            index += 1
        }
        appMenu.insertItem(item, at: index)
        if index + 1 < appMenu.numberOfItems, !appMenu.items[index + 1].isSeparatorItem {
            appMenu.insertItem(.separator(), at: index + 1)
        }
        NSApp.servicesMenu = submenu  // Assigned last: AppKit fills the menu asynchronously.
        return true
    }

    /// Standard placement: after the Settings group, immediately above Hide.
    /// Matched on action and key equivalent, never on title — the application
    /// menu's titles are system-localized.
    private func insertionIndex(in menu: NSMenu) -> Int {
        let hide = NSSelectorFromString("hide:")
        let terminate = NSSelectorFromString("terminate:")
        if let index = menu.items.firstIndex(where: {
            $0.action == hide || ($0.keyEquivalent == "h" && $0.keyEquivalentModifierMask == .command)
        }) { return index }
        if let index = menu.items.firstIndex(where: {
            $0.action == terminate || ($0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == .command)
        }) { return index }
        return menu.numberOfItems
    }
}
