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
