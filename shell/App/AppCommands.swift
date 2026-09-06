//
//  AppCommands.swift
//  shell
//
//  SwiftUI Commands for menu bar integration on macOS Catalyst and iPadOS 26+
//  These provide menu visibility while UIKeyCommands handle actual input priority
//
//  All commands use UIApplication.shared.sendAction() to route through the responder
//  chain, ensuring actions are handled by the focused terminal in the key window.
//

import SwiftUI
import UIKit
import Combine

// MARK: - Keyboard Shortcut State

/// Observable object that provides current keyboard shortcuts for menu display
/// This is separate from KeybindManager to avoid the iPadOS 26 issue with
/// @ObservedObject in CommandGroup(replacing:)
@MainActor
final class MenuShortcutState: ObservableObject {
    static let shared = MenuShortcutState()

    @Published var shortcuts: [KeybindAction: KeyboardShortcut] = [:]

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Build initial shortcuts
        rebuildShortcuts()

        // Listen for keybind changes
        KeybindManager.shared.keybindsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.rebuildShortcuts()
            }
            .store(in: &cancellables)
    }

    private func rebuildShortcuts() {
        var newShortcuts: [KeybindAction: KeyboardShortcut] = [:]

        for binding in KeybindManager.shared.activeBindings {
            // Multi-key sequences (e.g. ctrl+a > t) cannot be represented as
            // menu shortcuts; publishing just the leader chord would fire the
            // action on a bare ctrl+a, hijacking the sequence's first key.
            // KeybindCommandGenerator applies the same exclusion; sequences
            // are handled exclusively by KeySequenceTracker.
            guard !binding.sequence.isSequence,
                  let firstTrigger = binding.sequence.first,
                  let keyEquivalent = firstTrigger.swiftUIKeyEquivalent else {
                continue
            }

            #if targetEnvironment(macCatalyst)
            // The fixed "Send Escape" menu item is the sole owner of ⌘. on
            // Catalyst (the reserved chord only arrives via the menu rail);
            // its handler dispatches a cmd+period binding itself. Publishing
            // the shortcut here too would create a duplicate key equivalent.
            if firstTrigger == .commandPeriod { continue }
            #endif

            let modifiers = firstTrigger.swiftUIEventModifiers
            newShortcuts[binding.action] = KeyboardShortcut(keyEquivalent, modifiers: modifiers)
        }

        shortcuts = newShortcuts
    }
}

// MARK: - Main Commands Structure

struct AppCommands: Commands {
    @ObservedObject var shortcutState = MenuShortcutState.shared

    var body: some Commands {
        // These are the only menu rail: the UIMenuBuilder path is gone.
        #if targetEnvironment(macCatalyst)
        MacApplicationCommands()
        #endif
        FileCommands(shortcutState: shortcutState)
        EditCommands(shortcutState: shortcutState)
        AppViewCommands(shortcutState: shortcutState)
        TerminalCommands(shortcutState: shortcutState)
        ShellCommands(shortcutState: shortcutState)
        WindowCommands(shortcutState: shortcutState)
    }
}

// MARK: - File Commands

struct FileCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        // Shell is not document-based, and macOS's default Save As/Duplicate
        // item owns Cmd+Shift+S. Removing it lets tmux Sessions display and own
        // the user-configurable default shortcut in the Tabs menu.
        CommandGroup(replacing: .saveItem) {
            EmptyView()
        }

        // Replace system "New" items with our custom file commands
        CommandGroup(replacing: .newItem) {
            Button("New Local Shell") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuCreateLocalShell(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .new_local_shell, shortcuts: shortcutState.shortcuts))

            Button("New Tab") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuNewTab(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .new_tab, shortcuts: shortcutState.shortcuts))

            Button("New Window") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuNewWindow(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .new_window, shortcuts: shortcutState.shortcuts))

            Button("Duplicate SSH Tab") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuDuplicateTabWithSSH(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .duplicate_ssh_tab, shortcuts: shortcutState.shortcuts))

            Divider()
            OpenRecentProfilesMenu()
        }
    }
}

/// File > Open Recent, listing saved SSH profiles most-recently-used first.
///
/// macOS's own Open Recent is document-based and shell is not a document app,
/// so this is the equivalent for the thing users actually reopen. It is a View
/// rather than bare `Commands` content so `@Observable` tracking rebuilds the
/// menu as profiles are used. There is deliberately no "Clear Menu" item: the
/// order comes from each profile's stored usage stats, which the user manages
/// in Settings, and clearing them here would silently discard that data.
struct OpenRecentProfilesMenu: View {
    private static let maxItems = 10

    @State private var profileManager = ConnectionProfileManager.shared

    private var recents: [SSHProfile] {
        profileManager.profiles
            .compactMap { profile in profile.lastUsedAt.map { (profile, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.maxItems)
            .map(\.0)
    }

    var body: some View {
        Menu("Open Recent") {
            ForEach(recents) { profile in
                Button(profile.name) {
                    UIApplication.shared.menuOpenRecentProfile(profile.id)
                }
            }
        }
        .disabled(recents.isEmpty)
    }
}

// MARK: - Dynamic Shortcut Modifier

/// View modifier that applies a keyboard shortcut from the current binding state
struct DynamicShortcut: ViewModifier {
    let action: KeybindAction
    let shortcuts: [KeybindAction: KeyboardShortcut]

    func body(content: Content) -> some View {
        if let shortcut = shortcuts[action] {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}

// Note: Close (Cmd-W) is handled by:
// 1. System-provided Close menu item
// 2. UIKeyCommand in TerminalViewKeyboard.swift with wantsPriorityOverSystemBehavior
// 3. pressesBegan fallback for keys that bypass UIKeyCommand

// MARK: - Menu Toggle State

/// Invalidation signal for menu-bar checkmarks whose truth `@Observable`
/// cannot see: which window is key (`WindowFocusRegistry` is a plain registry)
/// and the two flags that live on `Ghostty.TerminalView`, a UIView. Everything
/// else the toggles read (`SettingBox`, `TabsModel`, `TabModel`,
/// `TransparencyManager`) is already `@Observable` and needs no wiring here.
///
/// `noteWindowFocusChanged()` / `notePaneStateChanged()` are the intended hooks
/// for the sites that own those truths — `WindowFocusRegistry.update/remove`
/// and the `didSet` of `TerminalView.isMouseCaptured` / `showComposeOverlay`.
/// Until those call in, this class self-wires from the same notifications those
/// sites react to, so the checkmarks are correct on their own. The hooks are
/// purely additive: a duplicate window bump is dropped (the resolved model is
/// unchanged) and a duplicate pane bump costs one extra, identical rebuild.
///
/// It never stores a `TabsModel` and holds the tracked pane weakly, so the menu
/// bar can never keep a closed window or pane alive.
@MainActor
@Observable
final class MenuFocusState {
    static let shared = MenuFocusState()

    private(set) var windowRevision = 0
    private(set) var paneRevision = 0

    @ObservationIgnored private let observers = MainViewObserverBag()
    @ObservationIgnored private var windowRefreshScheduled = false
    @ObservationIgnored private var paneTrackingRefreshScheduled = false
    /// Last window the menu resolved to. Weak, and compared by identity only —
    /// bumping `windowRevision` only when this actually changes keeps a stream
    /// of key/main notifications from becoming a stream of menu rebuilds.
    @ObservationIgnored private weak var lastResolvedTabs: TabsModel?
    /// The pane whose `isMouseCaptured` is currently sunk.
    @ObservationIgnored private weak var trackedTerminal: Ghostty.TerminalView?
    @ObservationIgnored private var mouseCaptureSink: AnyCancellable?

    private init() {
        // Which window is key. These are exactly the notifications
        // `MainViewWindowSceneReporter` turns into `WindowFocusRegistry`
        // writes, so watching them keeps the checkmarks in step with the
        // registry `activeTabs()` reads.
        observeWindowFocus([
            UIWindow.didBecomeKeyNotification,
            UIWindow.didResignKeyNotification,
            UIScene.didActivateNotification,
            UIScene.willDeactivateNotification,
            UIScene.didDisconnectNotification,
        ])
        #if targetEnvironment(macCatalyst)
        // Catalyst raises AppKit's key/main changes as well, and the reporter
        // already listens to these same string-named notifications.
        observeWindowFocus([
            Notification.Name("NSWindowDidBecomeKeyNotification"),
            Notification.Name("NSWindowDidResignKeyNotification"),
            Notification.Name("NSWindowDidBecomeMainNotification"),
            Notification.Name("NSWindowDidResignMainNotification"),
        ])
        #endif

        // Compose posts this from every one of its write sites, so it stands in
        // for the `showComposeOverlay` didSet.
        observers.observeOnMainActor(.ghosttyComposeStateChanged) { [weak self] _ in
            self?.notePaneStateChanged()
        }

        // Moving focus between panes and tabs changes which pane the
        // pane-scoped items describe. The read itself is already covered by
        // `@Observable` (`TabsModel.selectedTabID`, `TabModel.focusedPane`);
        // this only re-points the mouse-capture sink, and never bumps on its
        // own. These fire as the change is requested, so re-arm a turn later.
        for name in [
            Notification.Name.focusSplit,
            .navigateSplit,
            .createSplit,
            .closeSplit,
            .selectTab,
            .nextTab,
            .previousTab,
        ] {
            observers.observeOnMainActor(name) { [weak self] _ in
                self?.schedulePaneTrackingRefresh()
            }
        }
    }

    private func observeWindowFocus(_ names: [Notification.Name]) {
        for name in names {
            observers.observeOnMainActor(name) { [weak self] _ in
                self?.noteWindowFocusChanged()
            }
        }
    }

    /// The key window changed. Safe to call redundantly: it re-resolves and
    /// only invalidates the menu when the resolved window actually differs.
    func noteWindowFocusChanged() {
        refreshWindowFocus()
        scheduleWindowFocusRefresh()
    }

    /// A flag on the focused pane changed (compose, mouse capture).
    func notePaneStateChanged() {
        paneRevision &+= 1
        refreshPaneTracking()
    }

    /// The `TabsModel` a menu command will actually land in. Mirrors
    /// `UIApplication.ghostty_activeWindowSceneSessionID()` (which stamps the
    /// command) and `MainView.shouldHandleNotification` (which accepts it), so
    /// the checkmark can never disagree with where the command goes.
    static func activeTabs() -> TabsModel? {
        if let sceneID = UIApplication.shared.ghostty_activeWindowSceneSessionID(),
           let windowId = TerminalWindowRegistry.windowId(forSceneSessionId: sceneID),
           let model = TerminalWindowRegistry.tabsModel(for: windowId) {
            return model
        }
        return soleTerminalWindowTabs()
    }

    /// The single terminal window's model, when it is the only one. Mirrors
    /// `shouldHandleNotification`'s single-window acceptance rule — including
    /// its exclusion of the Settings scene, which is a `UIWindowScene` too.
    private static func soleTerminalWindowTabs() -> TabsModel? {
        #if targetEnvironment(macCatalyst)
        let scenes = UIApplication.shared.connectedScenes
            .filter { CatalystSceneDelegate.isTerminalScene($0) }
            .compactMap { $0 as? UIWindowScene }
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        #endif
        guard scenes.count == 1,
              let windowId = TerminalWindowRegistry.windowId(
                  forSceneSessionId: scenes[0].session.persistentIdentifier
              ) else {
            return nil
        }
        return TerminalWindowRegistry.tabsModel(for: windowId)
    }

    private func refreshWindowFocus() {
        let resolved = Self.activeTabs()
        defer { refreshPaneTracking() }
        guard resolved !== lastResolvedTabs else { return }
        lastResolvedTabs = resolved
        windowRevision &+= 1
    }

    /// `MainViewWindowSceneReporter` writes `WindowFocusRegistry` from a
    /// `Task { @MainActor }`, and a window registers itself with
    /// `TerminalWindowRegistry` from `onAppear`; neither is ordered against
    /// this observer. Re-resolving on the next two main-queue turns guarantees
    /// at least one read lands after the registry settled. Each re-resolve is a
    /// dictionary lookup that invalidates nothing unless the answer changed.
    private func scheduleWindowFocusRefresh() {
        guard !windowRefreshScheduled else { return }
        windowRefreshScheduled = true
        onNextMainQueueTurn { [weak self] in
            guard let self else { return }
            self.refreshWindowFocus()
            self.onNextMainQueueTurn { [weak self] in
                guard let self else { return }
                self.windowRefreshScheduled = false
                self.refreshWindowFocus()
            }
        }
    }

    private func schedulePaneTrackingRefresh() {
        guard !paneTrackingRefreshScheduled else { return }
        paneTrackingRefreshScheduled = true
        onNextMainQueueTurn { [weak self] in
            guard let self else { return }
            self.paneTrackingRefreshScheduled = false
            self.refreshPaneTracking()
        }
    }

    /// Points the `isMouseCaptured` sink at the currently focused pane.
    ///
    /// `isMouseCaptured` is ghostty's own truth and is written without any
    /// notification — `updateMouseCaptureState()` flips it when the program
    /// enables mouse reporting. It is `@Published`, so a sink is the one way to
    /// see that from here. Re-arming is identity-guarded, so the sink calling
    /// back into `notePaneStateChanged()` cannot recurse.
    private func refreshPaneTracking() {
        let terminal = Self.activeTabs()?.selectedTab?.focusedTerminal
        guard terminal !== trackedTerminal else { return }
        trackedTerminal = terminal
        mouseCaptureSink = terminal?.$isMouseCaptured
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.notePaneStateChanged() }
            }
    }

    private func onNextMainQueueTurn(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }
}

// MARK: - Menu Toggle Item

/// One checkable menu-bar item.
///
/// It is a `View` rather than bare `Commands` content for the same reason
/// `OpenRecentProfilesMenu` is: only a view body that reads its own truth gets
/// `@Observable` tracking, so a parent `Commands` struct computing `isOn` and
/// passing it down would never invalidate.
///
/// This adds state reflection only. Every item dispatches through the same
/// `sendAction(_:to:from:for:)` call its `Button` made, so what the item *does*
/// — and which responder handles it — is unchanged.
struct MenuToggleItem: View {
    enum Kind {
        case topTabBar
        case groupMode
        case transparency
        case titleBar
        case fullScreen
        case splitZoom
        case compose
        case mouseCapture
    }

    let kind: Kind
    let shortcuts: [KeybindAction: KeyboardShortcut]

    @State private var focus = MenuFocusState.shared
    @State private var transparency = TransparencyManager.shared

    @Setting(Settings.Tabs.barHidden) private var tabBarHidden
    @Setting(Settings.Window.hideTitleBar) private var hideWindowTitleBar
    @Setting(Settings.Window.fullScreenMode) private var fullScreenMode

    var body: some View {
        // Both truths are read here, in this view's own body, so `@Observable`
        // registers the dependency against THIS item. A binding getter runs
        // outside the body's tracking scope and would never invalidate it.
        let checked = isOn
        let enabled = isEnabled
        Toggle(title, isOn: Binding(get: { checked }, set: { _ in dispatch() }))
            .disabled(!enabled)
            .modifier(DynamicShortcut(action: keybind, shortcuts: shortcuts))
    }

    /// The window the command will land in, re-resolved whenever the key window
    /// changes. Deliberately not cached: every downstream read re-registers
    /// with `@Observable` against the new model, and nothing retains the old.
    private var tabs: TabsModel? {
        _ = focus.windowRevision
        return MenuFocusState.activeTabs()
    }

    private var terminal: Ghostty.TerminalView? {
        _ = focus.paneRevision
        return tabs?.selectedTab?.focusedTerminal
    }

    /// The item is named for the thing it checks, not the verb it performs — a
    /// checked "Toggle Compose" would be wrong on macOS. The two settings that
    /// store the *hidden* state are therefore inverted here.
    private var isOn: Bool {
        switch kind {
        case .topTabBar: return !tabBarHidden
        case .groupMode: return tabs?.isGroupedModeEnabled == true
        case .transparency: return !transparency.isTransparencyDisabled
        case .titleBar: return !hideWindowTitleBar
        case .fullScreen: return fullScreenMode
        case .splitZoom: return tabs?.selectedTab?.splitTree.zoomed != nil
        case .compose: return terminal?.showComposeOverlay == true
        case .mouseCapture: return terminal?.isMouseCaptured == true
        }
    }

    /// Window-scoped items act on the key window, not on a focused pane, so
    /// they stay live with no terminal focused; they grey out only when no
    /// window would accept the command. Pane-scoped items need a focused pane.
    /// Unchecked-and-disabled is the macOS idiom for "unknown" — mixed state
    /// would be wrong here, since every one of these resolves to exactly one
    /// truth and no item fans out over a selection.
    private var isEnabled: Bool {
        switch kind {
        case .topTabBar, .groupMode, .transparency, .titleBar, .fullScreen:
            return tabs != nil
        case .splitZoom, .compose, .mouseCapture:
            return terminal != nil
        }
    }

    private var title: String {
        switch kind {
        case .topTabBar:
            return String(localized: "Top Tab Bar", comment: "Checkable View menu item")
        case .groupMode:
            return String(localized: "Group Mode", comment: "Checkable View menu item")
        case .transparency:
            return String(localized: "Transparency", comment: "Checkable View menu item")
        case .titleBar:
            return String(localized: "Title Bar", comment: "Checkable View menu item")
        case .fullScreen:
            return String(localized: "Full Screen", comment: "Checkable View menu item")
        case .splitZoom:
            return String(localized: "Split Zoom", comment: "Checkable Terminal menu item")
        case .compose:
            return String(localized: "Compose", comment: "Checkable Terminal menu item")
        case .mouseCapture:
            return String(localized: "Mouse Capture", comment: "Checkable Terminal menu item")
        }
    }

    private var keybind: KeybindAction {
        switch kind {
        case .topTabBar: return .toggle_tab_bar
        case .groupMode: return .toggle_group_mode
        case .transparency: return .toggle_transparency
        case .titleBar: return .toggle_titlebar
        case .fullScreen: return .toggle_full_screen
        case .splitZoom: return .toggle_split_zoom
        case .compose: return .toggle_compose
        case .mouseCapture: return .toggle_mouse_capture
        }
    }

    private func dispatch() {
        switch kind {
        case .topTabBar:
            send(#selector(Ghostty.TerminalView.menuToggleTabBar(_:)))
        case .groupMode:
            send(#selector(Ghostty.TerminalView.menuToggleGroupMode(_:)))
        case .transparency:
            send(#selector(Ghostty.TerminalView.menuToggleTransparency(_:)))
        case .titleBar:
            send(#selector(Ghostty.TerminalView.menuToggleTitleBar(_:)))
        case .fullScreen:
            send(#selector(Ghostty.TerminalView.menuToggleFullScreen(_:)))
        case .splitZoom:
            send(#selector(Ghostty.TerminalView.menuToggleSplitZoom(_:)))
        case .compose:
            send(#selector(Ghostty.TerminalView.menuToggleCompose(_:)))
        case .mouseCapture:
            send(#selector(Ghostty.TerminalView.menuToggleMouseCapture(_:)))
        }
    }

    private func send(_ selector: Selector) {
        UIApplication.shared.sendAction(selector, to: nil, from: nil, for: nil)
    }
}

// MARK: - Edit Commands

struct EditCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        // System provides Copy/Paste/Select All via .pasteboard - don't duplicate them
        // Add Clear Screen and Find after system pasteboard items
        CommandGroup(after: .pasteboard) {
            Button("Clear Screen") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuClearScreen(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .clear_screen, shortcuts: shortcutState.shortcuts))

            Divider()

            Button("Find") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.findInTerminal(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .start_search, shortcuts: shortcutState.shortcuts))
        }
    }
}

// MARK: - View Commands (injected into system View menu)

struct AppViewCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        // Inject view/appearance items into the system View menu after toolbar items
        CommandGroup(after: .toolbar) {
            // Font size section
            Button("Increase Font Size") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.increaseFontSize(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .increase_font_size, shortcuts: shortcutState.shortcuts))

            Button("Decrease Font Size") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.decreaseFontSize(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .decrease_font_size, shortcuts: shortcutState.shortcuts))

            Button("Reset Font Size") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.resetFontSizeToDefault(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .reset_font_size, shortcuts: shortcutState.shortcuts))

            Divider()

            // View toggles
            MenuToggleItem(kind: .topTabBar, shortcuts: shortcutState.shortcuts)

            MenuToggleItem(kind: .groupMode, shortcuts: shortcutState.shortcuts)

            Button("Switch Keyboard Language") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuCycleInputSource(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .cycle_input_source, shortcuts: shortcutState.shortcuts))

            #if targetEnvironment(macCatalyst)
            MenuToggleItem(kind: .transparency, shortcuts: shortcutState.shortcuts)

            MenuToggleItem(kind: .titleBar, shortcuts: shortcutState.shortcuts)
            #endif

            #if !targetEnvironment(macCatalyst)
            // iPad only — macOS system provides "Enter Full Screen" in View menu
            MenuToggleItem(kind: .fullScreen, shortcuts: shortcutState.shortcuts)
            #endif
        }
    }
}

// MARK: - Terminal Commands

struct TerminalCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        CommandMenu("Terminal") {
            // Split creation
            Button("Split Right") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSplitRight(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .split_right, shortcuts: shortcutState.shortcuts))

            Button("Split Down") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSplitDown(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .split_down, shortcuts: shortcutState.shortcuts))

            Divider()

            // Focus Split submenu
            Menu("Focus Split") {
                Button("Left") {
                    UIApplication.shared.sendAction(
                        #selector(Ghostty.TerminalView.menuNavigateSplitLeft(_:)),
                        to: nil, from: nil, for: nil
                    )
                }
                .modifier(DynamicShortcut(action: .navigate_split_left, shortcuts: shortcutState.shortcuts))

                Button("Right") {
                    UIApplication.shared.sendAction(
                        #selector(Ghostty.TerminalView.menuNavigateSplitRight(_:)),
                        to: nil, from: nil, for: nil
                    )
                }
                .modifier(DynamicShortcut(action: .navigate_split_right, shortcuts: shortcutState.shortcuts))

                Button("Up") {
                    UIApplication.shared.sendAction(
                        #selector(Ghostty.TerminalView.menuNavigateSplitUp(_:)),
                        to: nil, from: nil, for: nil
                    )
                }
                .modifier(DynamicShortcut(action: .navigate_split_up, shortcuts: shortcutState.shortcuts))

                Button("Down") {
                    UIApplication.shared.sendAction(
                        #selector(Ghostty.TerminalView.menuNavigateSplitDown(_:)),
                        to: nil, from: nil, for: nil
                    )
                }
                .modifier(DynamicShortcut(action: .navigate_split_down, shortcuts: shortcutState.shortcuts))
            }

            Divider()

            // Split management
            MenuToggleItem(kind: .splitZoom, shortcuts: shortcutState.shortcuts)

            Button("Equalize Splits") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuEqualizeSplits(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .equalize_splits, shortcuts: shortcutState.shortcuts))

            Divider()

            // Scroll commands
            Button("Scroll Page Up") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuScrollPageUp(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .scroll_page_up, shortcuts: shortcutState.shortcuts))

            Button("Scroll Page Down") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuScrollPageDown(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .scroll_page_down, shortcuts: shortcutState.shortcuts))

            Button("Scroll to Top") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuScrollToTop(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .scroll_to_top, shortcuts: shortcutState.shortcuts))

            Button("Scroll to Bottom") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuScrollToBottom(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .scroll_to_bottom, shortcuts: shortcutState.shortcuts))

            Divider()

            MenuToggleItem(kind: .compose, shortcuts: shortcutState.shortcuts)

            MenuToggleItem(kind: .mouseCapture, shortcuts: shortcutState.shortcuts)

            #if targetEnvironment(macCatalyst)
            Divider()

            // Cmd+Period never reaches responder UIKeyCommands or press events
            // on Catalyst — a menu key equivalent (like Xcode's ⌘. Stop item)
            // is the one rail that receives AND consumes the reserved chord.
            // Fixed shortcut: MenuShortcutState excludes cmd+period so this
            // item stays its sole owner; the handler dispatches a cmd+period
            // keybind first and falls back to sending Escape.
            Button("Send Escape") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSystemCancel(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .keyboardShortcut(".", modifiers: .command)
            #endif
        }
    }
}

// MARK: - Shell Commands

struct ShellCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        CommandMenu("Shell") {
            Button("Browse Hosts") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuBrowseHosts(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .browse_hosts, shortcuts: shortcutState.shortcuts))

            Button("Browse Profiles") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuBrowseProfiles(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .browse_profiles, shortcuts: shortcutState.shortcuts))
        }

        // Handle system Settings menu item (Cmd+,)
        // The system provides "Settings..." automatically, we just need to handle the action
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                #if targetEnvironment(macCatalyst)
                MacSettingsWindow.show()
                #else
                UIApplication.shared.menuOpenSettings(nil)
                #endif
            }
            .modifier(DynamicShortcut(action: .open_settings, shortcuts: shortcutState.shortcuts))
        }
    }
}

// MARK: - Window Commands

struct WindowCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        // Use "Tabs" menu to avoid conflict with system Window menu
        CommandMenu("Tabs") {
            Button("Previous Tab") {
                UIApplication.shared.menuPreviousTab(nil)
            }
            .modifier(DynamicShortcut(action: .previous_tab, shortcuts: shortcutState.shortcuts))

            Button("Next Tab") {
                UIApplication.shared.menuNextTab(nil)
            }
            .modifier(DynamicShortcut(action: .next_tab, shortcuts: shortcutState.shortcuts))

            // ⌘⌥[ / ⌘⌥]: the menu owns these, which is what shows the glyph; a
            // customized binding still gets a prioritized UIKeyCommand
            // (KeybindAction.needsSystemPriority).
            Button("Previous Group") {
                UIApplication.shared.menuPreviousGroup(nil)
            }
            .modifier(DynamicShortcut(action: .previous_group, shortcuts: shortcutState.shortcuts))

            Button("Next Group") {
                UIApplication.shared.menuNextGroup(nil)
            }
            .modifier(DynamicShortcut(action: .next_group, shortcuts: shortcutState.shortcuts))

            Button("tmux Sessions") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuShowTmuxSessions(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .show_tmux_sessions, shortcuts: shortcutState.shortcuts))

            Button("Detach Other Clients") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuDetachOtherClients(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .detach_other_clients, shortcuts: shortcutState.shortcuts))

            Divider()

            // Tab selection (1-9) - individual buttons for sendAction compatibility
            Button("Tab 1") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab1(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_1, shortcuts: shortcutState.shortcuts))

            Button("Tab 2") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab2(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_2, shortcuts: shortcutState.shortcuts))

            Button("Tab 3") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab3(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_3, shortcuts: shortcutState.shortcuts))

            Button("Tab 4") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab4(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_4, shortcuts: shortcutState.shortcuts))

            Button("Tab 5") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab5(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_5, shortcuts: shortcutState.shortcuts))

            Button("Tab 6") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab6(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_6, shortcuts: shortcutState.shortcuts))

            Button("Tab 7") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab7(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_7, shortcuts: shortcutState.shortcuts))

            Button("Tab 8") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab8(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_8, shortcuts: shortcutState.shortcuts))

            Button("Tab 9") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab9(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_9, shortcuts: shortcutState.shortcuts))
        }
    }
}
