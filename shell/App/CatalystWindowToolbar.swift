//
//  CatalystWindowToolbar.swift
//  shell
//
//  The native toolbar in each terminal window's title bar on Mac Catalyst.
//  New Tab and Settings are real NSToolbar items, so they take Liquid Glass,
//  overflow, and pointer behavior from AppKit. The tab strip itself stays a
//  SwiftUI view inside `MainView`, drawn through the transparent title bar in
//  the same row: Catalyst cannot host that strip's twenty-odd closures bound
//  to `MainView` state inside a toolbar item without re-plumbing them, so the
//  strip is instead inset to end where the native items begin
//  (`TitlebarLayoutManager.trailingInset`).
//

#if targetEnvironment(macCatalyst)
import UIKit

@MainActor
final class CatalystWindowToolbar: NSObject, NSToolbarDelegate {
    static let toolbarIdentifier = NSToolbar.Identifier("dev.chr33s.shell.terminalToolbar")
    static let newTabItem = NSToolbarItem.Identifier("dev.chr33s.shell.toolbar.newTab")
    static let settingsItem = NSToolbarItem.Identifier("dev.chr33s.shell.toolbar.settings")

    private weak var windowScene: UIWindowScene?
    /// Routes item actions to this window's `MainView` through the same
    /// scene-session targeting the menu bar commands use.
    private let sceneSessionID: String

    init(windowScene: UIWindowScene) {
        self.windowScene = windowScene
        self.sceneSessionID = windowScene.session.persistentIdentifier
        super.init()
    }

    /// Installs the toolbar into the scene's title bar. The unified style puts
    /// the items inline with the (hidden) title, which is the row the SwiftUI
    /// tab strip occupies.
    func install() {
        guard let titlebar = windowScene?.titlebar else { return }
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        titlebar.toolbar = toolbar
        titlebar.toolbarStyle = .unified
        titlebar.titleVisibility = .hidden
        titlebar.separatorStyle = .none
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.newTabItem, Self.settingsItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.newTabItem:
            // A pull-down, the way Terminal.app's New Tab item lists profiles:
            // local shell, saved SSH hosts, then the full Connect sheet.
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = UIImage(systemName: "plus")
            item.label = String(localized: "New Tab", comment: "Toolbar item")
            item.toolTip = String(localized: "New Tab", comment: "Toolbar item")
            item.showsIndicator = false
            item.itemMenu = UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.newTabMenuElements() ?? [])
                }
            ])
            return item

        case Self.settingsItem:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = UIImage(systemName: "gearshape")
            item.label = String(localized: "Settings", comment: "Toolbar item")
            item.toolTip = String(localized: "Settings", comment: "Toolbar item")
            item.isBordered = true
            item.target = self
            item.action = #selector(openSettings(_:))
            return item

        default:
            return nil
        }
    }

    // MARK: - Actions

    private func newTabMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = []

        elements.append(UIAction(
            title: String(localized: "New Local Terminal", comment: "Toolbar New Tab menu"),
            image: UIImage(systemName: "terminal")
        ) { [weak self] _ in
            // Honours the tmux New Tab Action the way ⌘T does.
            self?.post(.createLocalShell)
        })

        let profiles = ConnectionProfileManager.shared.profiles
        if !profiles.isEmpty {
            let hosts = profiles.map { profile in
                UIAction(
                    title: profile.name,
                    subtitle: profile.displayString,
                    image: UIImage(systemName: "network")
                ) { [weak self] _ in
                    self?.post(.openRecentProfile, userInfo: ["profileID": profile.id.uuidString])
                }
            }
            elements.append(UIMenu(
                title: String(localized: "SSH", comment: "Toolbar New Tab menu section"),
                options: .displayInline,
                children: hosts
            ))
        }

        elements.append(UIMenu(options: .displayInline, children: [
            UIAction(
                title: String(localized: "Connect…", comment: "Toolbar New Tab menu"),
                image: UIImage(systemName: "plus.circle")
            ) { [weak self] _ in
                self?.post(.newTab)
            }
        ]))

        return elements
    }

    @objc private func openSettings(_ sender: Any?) {
        MacSettingsWindow.show()
    }

    private func post(_ name: Notification.Name, userInfo extra: [String: Any] = [:]) {
        var userInfo: [AnyHashable: Any] = [GhosttyCommandRouting.windowSceneSessionIDKey: sceneSessionID]
        for (key, value) in extra {
            userInfo[key] = value
        }
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }
}
#endif
