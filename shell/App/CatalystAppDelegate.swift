//
//  CatalystAppDelegate.swift
//  shell
//
//  Mac Catalyst app delegate for intercepting system keyboard shortcuts
//

import UIKit
import os
import ObjectiveC
import UniformTypeIdentifiers

#if targetEnvironment(macCatalyst)

private let logger = Logger(subsystem: "dev.chr33s.shell", category: "CatalystAppDelegate")

@MainActor
private final class CatalystContinuityPasteboardBridge {
    static let shared = CatalystContinuityPasteboardBridge()
    private weak var target: Ghostty.TerminalView?
    private var menuIsActive = false
    private var serviceMayBePending = false

    func arm(for target: Ghostty.TerminalView) {
        self.target = target
        menuIsActive = true
        serviceMayBePending = false
    }

    func noteResigned(_ target: Ghostty.TerminalView) {
        guard self.target === target, menuIsActive else { return }
        // Choosing Insert from iPhone/iPad resigns the UIKit terminal while
        // AppKit keeps the context interaction alive awaiting the result.
        serviceMayBePending = true
    }

    func menuDidEnd(for target: Ghostty.TerminalView) {
        guard self.target === target else { return }
        menuIsActive = false
        // A normal cancellation leaves the terminal as first responder and
        // clears immediately. A selected Service needs the target until AppKit
        // performs its later valid-requestor lookup.
        if !serviceMayBePending || !target.isLogicallyFocused {
            disarm(for: target)
        }
    }

    func disarm(for target: Ghostty.TerminalView) {
        guard self.target === target else { return }
        self.target = nil
        menuIsActive = false
        serviceMayBePending = false
    }

    func makeReceiver(sendType: String?, returnType: String?) -> AnyObject? {
        guard sendType == nil,
              let target,
              target.window != nil,
              let returnType else { return nil }
        guard Self.isAttachmentType(returnType) else { return nil }
        return CatalystContinuityPasteboardReceiver(target: target)
    }

    private static func isAttachmentType(_ type: String) -> Bool {
        guard let contentType = UTType(type) else { return false }
        return contentType.conforms(to: .image) || contentType.conforms(to: .pdf)
    }
}

/// One requestor per native Services query. The menu bridge can be disarmed as
/// soon as its menu closes without invalidating the requestor AppKit already
/// retained for a selected Continuity action.
@MainActor
private final class CatalystContinuityPasteboardReceiver: NSObject {
    private weak var target: Ghostty.TerminalView?
    private var hasDelivered = false

    init(target: Ghostty.TerminalView) {
        self.target = target
        super.init()
    }

    @objc(readSelectionFromPasteboard:)
    private func readSelection(from pasteboard: NSObject) -> Bool {
        guard !hasDelivered, let target, target.window != nil else { return false }
        hasDelivered = true
        defer {
            CatalystContinuityPasteboardBridge.shared.disarm(for: target)
            self.target = nil
        }
        guard let types = pasteboard.value(forKey: "types") as? [String] else {
            logger.error("Continuity service returned a pasteboard without types")
            return false
        }

        logger.info("Continuity service pasteboard types: \(types.joined(separator: "|"), privacy: .public)")

        // A document scan can expose both PDF and an image preview. Keep the
        // PDF so all pages survive; otherwise normalize the first readable
        // native image representation to PNG for the UIKit provider.
        if let pdfType = types.first(where: { type in
            UTType(type)?.conforms(to: .pdf) == true
        }), let data = Self.data(from: pasteboard, type: pdfType), !data.isEmpty {
            target.paste(itemProviders: [Self.provider(data: data, type: UTType.pdf.identifier)])
            return true
        }

        for type in types where Self.isImageType(type) {
            guard let data = Self.data(from: pasteboard, type: type),
                  let image = UIImage(data: data),
                  let pngData = image.pngData(),
                  !pngData.isEmpty else { continue }
            target.paste(itemProviders: [Self.provider(data: pngData, type: UTType.png.identifier)])
            return true
        }

        logger.error("Continuity service supplied no readable image or PDF data")
        return false
    }

    private static func isImageType(_ type: String) -> Bool {
        UTType(type)?.conforms(to: .image) == true
    }

    private static func data(from pasteboard: NSObject, type: String) -> Data? {
        let selector = NSSelectorFromString("dataForType:")
        return pasteboard.perform(selector, with: type)?.takeUnretainedValue() as? Data
    }

    private static func provider(data: Data, type: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

// MARK: - UIApplication Menu Actions Extension
// These methods are on UIApplication to ensure they're always in the responder chain.
// On older macOS with SwiftUI's @UIApplicationDelegateAdaptor, the AppDelegate may not
// be properly reachable in the responder chain for menu validation.

extension UIApplication {

    // MARK: File Menu Actions
    // All actions use sendAction to route through responder chain to the focused terminal

    @objc func ghostty_newLocalShell(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuCreateLocalShell(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_newTab(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNewTab(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_newWindow(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNewWindow(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_duplicateSshTab(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuDuplicateTabWithSSH(_:)), to: nil, from: sender, for: nil)
    }

    // MARK: Edit Menu Actions

    @objc func ghostty_clearScreen(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuClearScreen(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_find(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.findInTerminal(_:)), to: nil, from: sender, for: nil)
    }

    // MARK: Terminal Menu Actions

    /// Reserved Cmd+Period chord, delivered via the menu rail. The nil-target
    /// walk starts at the first responder, so a recording ShortcutCaptureUIView
    /// wins over the focused terminal's handler.
    @objc func ghostty_systemCancel(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuSystemCancel(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_increaseFontSize(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.increaseFontSize(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_decreaseFontSize(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.decreaseFontSize(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_resetFontSize(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.resetFontSizeToDefault(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_splitRight(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuSplitRight(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_splitDown(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuSplitDown(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_focusSplitLeft(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNavigateSplitLeft(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_focusSplitRight(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNavigateSplitRight(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_focusSplitUp(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNavigateSplitUp(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_focusSplitDown(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuNavigateSplitDown(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleSplitZoom(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleSplitZoom(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_equalizeSplits(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuEqualizeSplits(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleTabBar(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleTabBar(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleGroupMode(_ sender: Any?) {
        if !sendAction(#selector(Ghostty.TerminalView.menuToggleGroupMode(_:)), to: nil, from: sender, for: nil) {
            menuToggleGroupMode(sender)
        }
    }

    @objc func ghostty_toggleTabSwitcher(_ sender: Any?) {
        menuToggleTabSwitcher(VNCReservedKeyboardShortcut.toggleTabSwitcher.notificationSender)
    }

    @objc func ghostty_toggleTabExpose(_ sender: Any?) {
        if !sendAction(#selector(Ghostty.TerminalView.menuToggleTabExpose(_:)), to: nil, from: sender, for: nil) {
            menuToggleTabExpose(sender)
        }
    }

    @objc func ghostty_previousGroup(_ sender: Any?) {
        menuPreviousGroup(sender)
    }

    @objc func ghostty_nextGroup(_ sender: Any?) {
        menuNextGroup(sender)
    }

    @objc func ghostty_toggleTransparency(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleTransparency(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleTitleBar(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleTitleBar(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleAutoRedact(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleAutoRedact(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleBackgroundEffect(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleBackgroundEffect(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_scrollPageUp(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuScrollPageUp(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_scrollPageDown(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuScrollPageDown(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_scrollToTop(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuScrollToTop(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_scrollToBottom(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuScrollToBottom(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleThemePicker(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleThemePicker(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleClipboardManager(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleClipboardManager(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleCompose(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleCompose(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleMouseCapture(_ sender: Any?) {
        if !sendAction(NSSelectorFromString("toggleVNCKeyboardCapture:"), to: nil, from: sender, for: nil) {
            sendAction(#selector(Ghostty.TerminalView.menuToggleMouseCapture(_:)), to: nil, from: sender, for: nil)
        }
    }

    @objc func ghostty_toggleFullScreen(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleFullScreen(_:)), to: nil, from: sender, for: nil)
    }

    // MARK: Shell Menu Actions

    @objc func ghostty_browseHosts(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuBrowseHosts(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_browseProfiles(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuBrowseProfiles(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_openSettings(_ sender: Any?) {
        menuOpenSettings(VNCReservedKeyboardShortcut.openSettings.notificationSender)
    }

    @objc func ghostty_toggleAIAgent(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleAIAgent(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_toggleVoiceAgent(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuToggleVoiceAgent(_:)), to: nil, from: sender, for: nil)
    }

    // MARK: Tabs Menu Actions

    @objc func ghostty_previousTab(_ sender: Any?) {
        menuPreviousTab(VNCReservedKeyboardShortcut.previousTab.notificationSender)
    }

    @objc func ghostty_nextTab(_ sender: Any?) {
        menuNextTab(VNCReservedKeyboardShortcut.nextTab.notificationSender)
    }

    @objc func ghostty_showTmuxSessions(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuShowTmuxSessions(_:)), to: nil, from: sender, for: nil)
    }

    @objc func ghostty_detachOtherClients(_ sender: Any?) {
        sendAction(#selector(Ghostty.TerminalView.menuDetachOtherClients(_:)), to: nil, from: sender, for: nil)
    }

    // One selector per tab: UIKit refuses to display a menu that repeats an
    // action, so a single ghostty_selectTab: shared by Tab 1-9 silently dropped
    // the whole Tabs menu.
    @objc func ghostty_selectTab1(_ sender: Any?) { ghostty_selectTab(1, sender) }
    @objc func ghostty_selectTab2(_ sender: Any?) { ghostty_selectTab(2, sender) }
    @objc func ghostty_selectTab3(_ sender: Any?) { ghostty_selectTab(3, sender) }
    @objc func ghostty_selectTab4(_ sender: Any?) { ghostty_selectTab(4, sender) }
    @objc func ghostty_selectTab5(_ sender: Any?) { ghostty_selectTab(5, sender) }
    @objc func ghostty_selectTab6(_ sender: Any?) { ghostty_selectTab(6, sender) }
    @objc func ghostty_selectTab7(_ sender: Any?) { ghostty_selectTab(7, sender) }
    @objc func ghostty_selectTab8(_ sender: Any?) { ghostty_selectTab(8, sender) }
    @objc func ghostty_selectTab9(_ sender: Any?) { ghostty_selectTab(9, sender) }

    private func ghostty_selectTab(_ index: Int, _ sender: Any?) {
        let selector: Selector
        switch index {
        case 1: selector = #selector(Ghostty.TerminalView.menuSelectTab1(_:))
        case 2: selector = #selector(Ghostty.TerminalView.menuSelectTab2(_:))
        case 3: selector = #selector(Ghostty.TerminalView.menuSelectTab3(_:))
        case 4: selector = #selector(Ghostty.TerminalView.menuSelectTab4(_:))
        case 5: selector = #selector(Ghostty.TerminalView.menuSelectTab5(_:))
        case 6: selector = #selector(Ghostty.TerminalView.menuSelectTab6(_:))
        case 7: selector = #selector(Ghostty.TerminalView.menuSelectTab7(_:))
        case 8: selector = #selector(Ghostty.TerminalView.menuSelectTab8(_:))
        case 9: selector = #selector(Ghostty.TerminalView.menuSelectTab9(_:))
        default: return
        }
        sendAction(selector, to: nil, from: sender, for: nil)
    }

    // MARK: App Menu Actions (legacy macOS only)
    // These are needed because CatalystAppDelegate isn't reachable in responder chain on older macOS
    // We implement the logic directly here rather than delegating, as the delegate cast can fail

    @objc func ghostty_showAbout(_ sender: Any?) { MacSupport.bridge?.showAbout() }

    @objc func ghostty_close(_ sender: Any?) {
        logger.info("ghostty_close called")
        let handled = sendAction(
            #selector(Ghostty.TerminalView.closeSplit(_:)),
            to: nil,
            from: sender,
            for: nil
        )
        logger.info("ghostty_close: sendAction returned \(handled)")
    }

    @objc func ghostty_quit(_ sender: Any?) {
        logger.info("ghostty_quit called")

        // Check if there are open tabs
        let hasOpenTabs = SessionTracker.shared.hasOpenTabs
        let tabCount = SessionTracker.shared.totalTabCount

        guard hasOpenTabs else {
            logger.info("No open tabs, quitting immediately")
            ghostty_performQuit()
            return
        }

        logger.info("Open tabs detected (\(tabCount)), showing confirmation")
        ghostty_showQuitConfirmation(tabCount: tabCount)
    }

    private func ghostty_showQuitConfirmation(tabCount: Int) {
        // Find active window scene for presenting alert
        guard let windowScene = connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first?.rootViewController else {
            logger.warning("Could not find window to present quit confirmation, quitting anyway")
            ghostty_performQuit()
            return
        }

        let message = tabCount == 1
            ? "You have 1 open terminal. Are you sure you want to quit?"
            : "You have \(tabCount) open terminals. Are you sure you want to quit?"

        let alert = UIAlertController(
            title: "Quit Shell?",
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        alert.addAction(UIAlertAction(title: "Quit", style: .destructive) { [weak self] _ in
            self?.ghostty_performQuit()
        })

        // Find the topmost presented controller to avoid presentation conflicts
        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        presenter.present(alert, animated: true)
    }

    private func ghostty_performQuit() {
        logger.info("Performing quit")

        // Stop helper process first
        MacLocalShellManager.stopAll()

        // Request destruction of all scene sessions first
        for session in connectedScenes.compactMap({ $0 as? UIWindowScene }).map({ $0.session }) {
            requestSceneSessionDestruction(session, options: nil)
        }

        // Use NSRunningApplication.current.terminate() for clean app termination
        // This properly goes through the app lifecycle unlike NSApplication.terminate
        // which doesn't always work correctly in Mac Catalyst
        guard let nsRunningAppClass = NSClassFromString("NSRunningApplication") as? NSObject.Type,
              let currentApp = nsRunningAppClass.value(forKey: "currentApplication") as? NSObject else {
            logger.error("Could not access NSRunningApplication to quit")
            return
        }

        currentApp.perform(NSSelectorFromString("terminate"))
    }

    // MARK: - Update Actions (Standalone Mac Catalyst only)

    #if STANDALONE
    @objc func ghostty_checkForUpdates(_ sender: Any?) {
        Task { @MainActor in
            UpdateManager.shared.checkForUpdates()
        }
    }
    #endif
}

class CatalystAppDelegate: AppDelegate {

    // MARK: - CloudKit Sync Debouncing

    /// Last time we auto-synced on app activation (debounce to avoid excessive syncs)
    private var lastActivationSyncDate: Date?
    private let activationSyncInterval: TimeInterval = 180 // 3 minutes

    // MARK: - Application Lifecycle

    override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Call super to register for remote notifications (CloudKit push)
        _ = super.application(application, didFinishLaunchingWithOptions: launchOptions)
        _ = MacSupport.bridge
        MacTerminalEvents.install()
        // The UIKit shim installs the NSApplication delegate as part of launch;
        // one runloop turn later it is reliably in place to take the Dock menu.
        DispatchQueue.main.async { MacDockMenu.install() }
        _ = WindowDragObserver.shared

        #if STANDALONE
        // Force Sparkle scheduler to start at launch (UpdateManager.shared is lazy)
        _ = UpdateManager.shared

        // Visor: register the global hotkey if the user has it enabled.
        VisorHotkeyManager.shared.registerIfEnabled()
        #endif

        // Mac Catalyst: Use NSWorkspace notification for app activation (Cmd-Tab)
        // scenePhase and UIApplication.didBecomeActiveNotification don't fire reliably
        setupWorkspaceActivationObserver()
        setupApplicationHideObserver()
        // AppKit owns Continuity Camera's Services handoff even in Catalyst.
        // Install after launch, once the native NSApplication subclass exists.
        DispatchQueue.main.async { [weak self] in
            self?.installContinuityPasteboardInterposer()
        }
        #if STANDALONE
        setupVisorAutohideObserver()
        // Deferred: the UIKit shim installs the NSApplication delegate as
        // part of launch; one runloop turn later it is reliably in place.
        DispatchQueue.main.async { [weak self] in
            self?.installDockReopenInterposer()
        }
        #endif

        // Disable the macOS "press and hold for accent characters" popup.
        // Terminal users need key repeat (e.g., holding h/j/k/l in vim).
        // This only affects this app, not the system-wide setting.
        UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")

        // Eagerly load saved window state so the restore-phase signal
        // (`hasPendingRegularWindowRestoration`) is authoritative inside
        // `CatalystSceneDelegate.scene(_:willConnectTo:)`, which runs before any
        // MainView.onAppear lazy-load. That gate decides whether a connecting
        // window is pre-sized from its saved frame (launch restore) or sized to
        // the last-focused window via the cascade (a genuine Cmd-N window).
        // Skipped when the device is locked at a cold/background launch — the gate
        // then falls back to false (treated as a new window), which is harmless.
        if ProtectedDataGuard.isAvailable {
            WindowStateManager.shared.ensureStateLoaded()
        }

        return true
    }

    @MainActor
    static func armContinuityPasteboardReceiver(for terminal: Ghostty.TerminalView) {
        CatalystContinuityPasteboardBridge.shared.arm(for: terminal)
    }

    @MainActor
    static func noteContinuityPasteboardTargetResigned(_ terminal: Ghostty.TerminalView) {
        CatalystContinuityPasteboardBridge.shared.noteResigned(terminal)
    }

    @MainActor
    static func continuityPasteboardMenuDidEnd(for terminal: Ghostty.TerminalView) {
        CatalystContinuityPasteboardBridge.shared.menuDidEnd(for: terminal)
    }

    private static var continuityPasteboardInterposerInstalled = false

    /// Override NSApplication's Services requestor lookup for the narrow case
    /// UIKit fails to bridge: a no-input service returning an image or PDF to
    /// the terminal whose context menu is currently open.
    private func installContinuityPasteboardInterposer() {
        guard !Self.continuityPasteboardInterposerInstalled else { return }
        let selector = NSSelectorFromString("validRequestorForSendType:returnType:")
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
              let applicationClass = object_getClass(sharedApp),
              let inheritedMethod = class_getInstanceMethod(applicationClass, selector) else {
            logger.warning("Could not install Continuity Services pasteboard receiver")
            return
        }

        let originalIMP = method_getImplementation(inheritedMethod)
        typealias ValidRequestorFunc = @convention(c) (
            NSObject, Selector, NSString?, NSString?
        ) -> AnyObject?

        let block: @convention(block) (
            NSObject, NSString?, NSString?
        ) -> AnyObject? = { application, sendType, returnType in
            if let receiver = MainActor.assumeIsolated({
                CatalystContinuityPasteboardBridge.shared.makeReceiver(
                    sendType: sendType as String?,
                    returnType: returnType as String?
                )
            }) {
                logger.info(
                    "Routing native Services result to terminal (return type: \((returnType as String?) ?? "nil", privacy: .public))"
                )
                return receiver
            }

            return unsafeBitCast(originalIMP, to: ValidRequestorFunc.self)(
                application,
                selector,
                sendType,
                returnType
            )
        }

        let replacement = imp_implementationWithBlock(block)
        // Add an override when the implementation is inherited; replacing the
        // Method returned for an inherited selector would mutate NSResponder
        // globally. If this concrete NSApplication subclass already overrides
        // it, replace only that implementation.
        if !class_addMethod(applicationClass, selector, replacement, "@@:@@"),
           let concreteMethod = class_getInstanceMethod(applicationClass, selector) {
            method_setImplementation(concreteMethod, replacement)
        }
        Self.continuityPasteboardInterposerInstalled = true
        logger.info("Installed Continuity Services pasteboard receiver")
    }

    private func setupApplicationHideObserver() {
        guard let nsApplicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let application = nsApplicationClass.value(forKey: "sharedApplication") as? NSObject else {
            logger.warning("Could not access NSApplication for hide notifications")
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidHideViaAppKit),
            name: NSNotification.Name("NSApplicationDidHideNotification"),
            object: application
        )
        logger.info("Registered for NSApplication hide notifications")
    }

    #if STANDALONE
    /// AppKit consults `applicationShouldHandleReopen:hasVisibleWindows:` on
    /// every Dock-click reopen — the only hook that reliably fires when the
    /// hidden visor's scene session swallows the reopen: after `orderOut:`
    /// the scene stays foregroundActive, so no scene event ever arrives and
    /// UIKit's reopen handling does nothing visible. Catalyst's UIKit shim
    /// owns the NSApplication delegate, so interpose the method there.
    private static var dockReopenInterposerInstalled = false

    private func installDockReopenInterposer() {
        guard !Self.dockReopenInterposerInstalled else { return }
        guard let nsAppClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let sharedApp = nsAppClass.value(forKey: "sharedApplication") as? NSObject,
              let delegate = sharedApp.value(forKey: "delegate") as? NSObject,
              let delegateClass = object_getClass(delegate) else {
            return
        }

        let selector = NSSelectorFromString("applicationShouldHandleReopen:hasVisibleWindows:")
        typealias ReopenFunc = @convention(c) (NSObject, Selector, NSObject, Bool) -> Bool
        let originalIMP: IMP? = class_getInstanceMethod(delegateClass, selector)
            .map { method_getImplementation($0) }

        let block: @convention(block) (NSObject, NSObject, Bool) -> Bool = { target, app, hasVisibleWindows in
            let handled = MainActor.assumeIsolated {
                CatalystAppDelegate.handleDockReopen(hasVisibleWindows: hasVisibleWindows)
            }
            if handled { return false }
            if let originalIMP {
                return unsafeBitCast(originalIMP, to: ReopenFunc.self)(target, selector, app, hasVisibleWindows)
            }
            return true
        }

        let imp = imp_implementationWithBlock(block)
        if let method = class_getInstanceMethod(delegateClass, selector) {
            method_setImplementation(method, imp)
        } else {
            class_addMethod(delegateClass, selector, imp, "B@:@B")
        }
        Self.dockReopenInterposerInstalled = true
    }

    /// Returns true when the reopen was handled here: no visible windows,
    /// only the hidden visor's scene connected, no summon in flight — the
    /// state where the system reopen does nothing. Opens a main window via
    /// the same nil-session activation Cmd-N uses.
    private static func handleDockReopen(hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return false }
        let scenes = UIApplication.shared.connectedScenes
        let hasVisorScene = scenes.contains { CatalystSceneDelegate.isVisorScene($0) }
        let hasRegularScene = scenes.contains {
            $0 is UIWindowScene && !CatalystSceneDelegate.isVisorScene($0)
        }
        guard hasVisorScene, !hasRegularScene,
              !VisorController.shared.isVisible,
              !VisorSceneLifecycle.summonInFlight else { return false }
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
        return true
    }

    private func setupVisorAutohideObserver() {
        guard let nsApplicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let application = nsApplicationClass.value(forKey: "sharedApplication") as? NSObject else {
            return
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActiveForVisor),
            name: NSNotification.Name("NSApplicationDidResignActiveNotification"),
            object: application
        )
    }

    @objc private func applicationDidResignActiveForVisor(_ notification: Notification) {
        Task { @MainActor in
            guard VisorSettings.shared.autohide,
                  VisorController.shared.isVisible else { return }
            VisorController.shared.hide()
        }
    }
    #endif

    private func setupWorkspaceActivationObserver() {
        // Access NSWorkspace via Objective-C runtime (not directly available in Catalyst)
        guard let nsWorkspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type,
              let workspace = nsWorkspaceClass.value(forKey: "sharedWorkspace") as? NSObject,
              let notificationCenter = workspace.value(forKey: "notificationCenter") as? NotificationCenter else {
            logger.warning("Could not access NSWorkspace for activation notifications")
            return
        }

        notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidActivateApp),
            name: NSNotification.Name("NSWorkspaceDidActivateApplicationNotification"),
            object: nil
        )
        logger.info("Registered for NSWorkspace activation notifications")
    }

    @objc private func workspaceDidActivateApp(_ notification: Notification) {
        // Check if this activation is for our app
        guard let app = notification.userInfo?["NSWorkspaceApplicationKey"] as? NSObject,
              let bundleId = app.value(forKey: "bundleIdentifier") as? String,
              bundleId == Bundle.main.bundleIdentifier else {
            return
        }

        // Ahead of the debounce: pushes the extension decrypted while the app
        // was not running must reach the arbitration ledger on every activation.

        // Debounce: only sync once every 3 minutes on activation
        if let lastSync = lastActivationSyncDate,
           Date().timeIntervalSince(lastSync) < activationSyncInterval {
            logger.debug("App activated, skipping sync (last sync \(Int(Date().timeIntervalSince(lastSync)))s ago)")
            return
        }

        logger.info("App activated via NSWorkspace, triggering CloudKit sync")
        lastActivationSyncDate = Date()

        Task { @MainActor in
            if CloudKitSyncManager.shared.isSyncEnabled {
                try? await CloudKitSyncManager.shared.syncNow()
            }
        }
    }

    @objc private func applicationDidHideViaAppKit(_ notification: Notification) {
        persistCatalystStateAndWindowGeometry(reason: "hide")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        persistCatalystStateAndWindowGeometry(reason: "terminate")

        #if STANDALONE
        // Destroy the visor scene on clean termination so the OS never
        // persists it for restoration — that keeps the common quit path
        // flash-free (the next launch has no zombie to suppress). The
        // willConnectTo backstop only has to cover crash/force-quit, where
        // this never runs. We intentionally do NOT clear
        // VisorSceneLifecycle.persistedSceneId here: if this destroy races the
        // OS's session snapshot and the scene restores anyway, the persisted
        // id is what lets the backstop recognize it reliably (the
        // configuration-name/userActivity heuristics are unreliable at cold
        // launch). The id only ever matches a scene actually being restored
        // under that exact identifier, so leaving it is harmless.
        for scene in application.connectedScenes
        where CatalystSceneDelegate.isVisorScene(scene) {
            application.requestSceneSessionDestruction(scene.session, options: nil)
        }
        #endif

        // Stop the helper process on app termination
        // Child processes on macOS don't auto-terminate when parent exits - they become orphans
        MacLocalShellManager.stopAll()
    }

    private func persistCatalystStateAndWindowGeometry(reason: String) {
        saveConnectedWindowGeometry()

        guard let state = WindowStateManager.shared.gatherState() else {
            logger.info("Catalyst \(reason): no window state available to persist")
            return
        }

        let didWrite = WindowStateManager.writeStateToDisk(state)
        logger.info("Catalyst \(reason): window state persistence \(didWrite ? "completed" : "failed")")
    }

    private func saveConnectedWindowGeometry() {
        // Capture current window geometry. windowScene(_:didUpdate:…) does not
        // fire on simple window moves on Catalyst, so hide/terminate are important
        // chances to persist a position the user dragged the window to.
        // The visor scene must never contribute: its frame (or parked
        // off-screen origin) would poison the last-focused size that new
        // main windows cascade from.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  !CatalystSceneDelegate.isVisorScene(scene) else { continue }
            let frame = windowScene.effectiveGeometry.systemFrame
            WindowSizeManager.shared.updateWindowFrame(frame)
        }
    }

    // MARK: - URL Handling

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return Self.routeAutomationURL(url, source: "appDelegate.open")
    }

    /// Shared by the app- and scene-level entry points. Handles ssh:// and
    /// returns false for anything else, which lets the caller fall through to
    /// its own handling.
    ///
    /// The notification is addressed to one window: it is delivered to every
    /// `MainView`, and without a target each open window would connect. The
    /// scene the URL arrived on is that window; an app-level open that names no
    /// scene goes to the focused one.
    @discardableResult
    static func routeAutomationURL(_ url: URL, source: String, deliveredTo scene: UIWindowScene? = nil) -> Bool {
        guard let components = SSHURLParser.parse(url) else { return false }
        logger.info("[urlopen] route source=\(source, privacy: .public) kind=ssh")
        var userInfo: [AnyHashable: Any] = [SSHURLPayload.key: SSHURLPayload(components: components)]
        if let target = scene ?? CatalystSceneDelegate.preferredRegularScene() {
            userInfo[GhosttyCommandRouting.windowSceneSessionIDKey] = target.session.persistentIdentifier
        }
        NotificationCenter.default.post(name: .sshURLReceived, object: nil, userInfo: userInfo)
        return true
    }

    // MARK: - Scene Configuration

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if options.userActivities.contains(where: { $0.activityType == MacSettingsWindow.activityType }) ||
            connectingSceneSession.configuration.name == MacSettingsWindow.configurationName {
            let config = UISceneConfiguration(name: MacSettingsWindow.configurationName, sessionRole: connectingSceneSession.role)
            config.delegateClass = MacSettingsSceneDelegate.self
            return config
        }
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = CatalystSceneDelegate.self
        return config
    }

    @objc private func handleClose(_ sender: Any?) {
        logger.info("CatalystAppDelegate.handleClose called")
        // Route to responder chain - TerminalView.closeSplit will handle it
        let handled = UIApplication.shared.sendAction(
            #selector(Ghostty.TerminalView.closeSplit(_:)),
            to: nil,
            from: sender,
            for: nil
        )
        logger.info("CatalystAppDelegate.handleClose: sendAction returned \(handled)")
    }

    @objc private func handleQuit(_ sender: Any?) {
        logger.info("handleQuit called")

        // Check if there are open tabs
        let hasOpenTabs = SessionTracker.shared.hasOpenTabs
        let tabCount = SessionTracker.shared.totalTabCount

        guard hasOpenTabs else {
            logger.info("No open tabs, quitting immediately")
            performQuit()
            return
        }

        logger.info("Open tabs detected (\(tabCount)), showing confirmation")
        showQuitConfirmation(tabCount: tabCount)
    }

    private func showQuitConfirmation(tabCount: Int) {
        // Find active window scene for presenting alert
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first?.rootViewController else {
            logger.warning("Could not find window to present quit confirmation, quitting anyway")
            performQuit()
            return
        }

        let message = tabCount == 1
            ? "You have 1 open terminal. Are you sure you want to quit?"
            : "You have \(tabCount) open terminals. Are you sure you want to quit?"

        let alert = UIAlertController(
            title: "Quit Shell?",
            message: message,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        alert.addAction(UIAlertAction(title: "Quit", style: .destructive) { [weak self] _ in
            self?.performQuit()
        })

        // Find the topmost presented controller to avoid presentation conflicts
        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        presenter.present(alert, animated: true)
    }

    private func performQuit() {
        logger.info("Performing quit")

        // Stop helper process first
        MacLocalShellManager.stopAll()

        // Request destruction of all scene sessions first
        for session in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).map({ $0.session }) {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }

        // Use NSRunningApplication.current.terminate() for clean app termination
        // This properly goes through the app lifecycle unlike NSApplication.terminate
        // which doesn't always work correctly in Mac Catalyst
        guard let nsRunningAppClass = NSClassFromString("NSRunningApplication") as? NSObject.Type,
              let currentApp = nsRunningAppClass.value(forKey: "currentApplication") as? NSObject else {
            logger.error("Could not access NSRunningApplication to quit")
            return
        }

        currentApp.perform(NSSelectorFromString("terminate"))
    }

}

// MARK: - Scene Delegate

/// Scene delegate for Catalyst windows. New (Cmd-N) windows are sized to the
/// last-focused window via `applyNewWindowCascadeGeometry`; launch-restored
/// windows are sized per-window from their saved frame in `MainView` and skip
/// the global path (see the `hasPendingRestoration` gate in `willConnectTo`).
class CatalystSceneDelegate: UIResponder, UIWindowSceneDelegate {

    static let minWindowSize = CGSize(width: 400, height: 300)

    /// True once any scene has become active — i.e. launch scene restoration
    /// is behind us. Distinguishes a cold-launch visor zombie (SwiftUI will
    /// still create the main scene on its own) from a Dock-click reopen that
    /// landed on the visor's session (nothing else will open a window).
    private(set) static var hasActivatedAnyScene = false

    /// A Dock-click reopen with no visible windows can be consumed by the
    /// visor's live-but-hidden scene session: UIKit either reconnects it
    /// (the zombie backstop destroys it) or just activates it (the hidden
    /// window never shows). Either way the user sees nothing open. When
    /// that happens with no regular scene connected, open a main window —
    /// the same nil-session activation Cmd-N uses.
    static func openMainWindowIfNoneConnected() {
        let hasRegularScene = UIApplication.shared.connectedScenes.contains { isTerminalScene($0) }
        guard !hasRegularScene else { return }
        logger.info("No regular scene; requesting main window")
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
    }

    /// A scene that hosts a `MainView`: not the visor, and not the Settings
    /// window, which is a `UIWindowScene` with no terminal in it. Anything
    /// looking for "a window to act on" has to exclude both, or a Dock-menu
    /// action or an ssh:// open lands in a window that observes nothing.
    static func isTerminalScene(_ scene: UIScene) -> Bool {
        scene is UIWindowScene && !isVisorScene(scene) &&
            scene.session.configuration.name != MacSettingsWindow.configurationName
    }

    /// The terminal scene an external request should land in:
    /// key window first, then the active one, then any.
    static func preferredRegularScene() -> UIWindowScene? {
        let regularScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { isTerminalScene($0) }
        return regularScenes.first(where: { $0.keyWindow != nil })
            ?? regularScenes.first(where: { $0.activationState == .foregroundActive })
            ?? regularScenes.first
    }

    /// Makes a notification or other external event visibly open shell.
    /// UIKit activates the process for a notification response, but Catalyst
    /// does not reliably surface a hidden/minimized window. If no regular scene
    /// exists (for example, only the hidden visor survived), create one.
    static func activateMainWindowForExternalEvent(
        scene targetScene: UIWindowScene? = nil,
        uiKitActivationAlreadyRequested: Bool = false
    ) {
        guard let scene = targetScene.flatMap({ isVisorScene($0) ? nil : $0 })
                ?? preferredRegularScene() else {
            logger.info("External activation has no regular scene; opening a main window")
            UIApplication.shared.requestSceneSessionActivation(
                nil,
                userActivity: nil,
                options: nil,
                errorHandler: { error in
                    logger.error("External activation failed to open a main window: \(error.localizedDescription)")
                }
            )
            return
        }

        logger.info("External activation surfacing regular scene")
        if !uiKitActivationAlreadyRequested
            && scene.activationState != .foregroundActive {
            UIApplication.shared.requestSceneSessionActivation(
                scene.session,
                userActivity: nil,
                options: nil,
                errorHandler: { error in
                    logger.error("External activation failed to activate scene: \(error.localizedDescription)")
                }
            )
        }

        // requestSceneSessionActivation alone can leave an AppKit window
        // miniaturized or hidden under Catalyst. Unhide the app and order the
        // NSWindow associated with this scene to the front as a backstop.
        guard let bridge = MacSupport.bridge,
              let window = MacSupport.window(for: scene.session.persistentIdentifier) else { return }
        bridge.activate(window)
    }

    // MARK: - Per-window state restoration

    /// Activity type carrying a window's id across launches. Returning a non-nil
    /// activity from `stateRestorationActivity(for:)` is also what makes UIKit
    /// persist the scene's `@SceneStorage` at all, so `MainView.sceneWindowId`
    /// comes back with the session rather than being regenerated.
    nonisolated static let windowRestorationActivityType = "dev.chr33s.shell.window"

    /// Window ids recovered at connect time, kept so a scene that quits before
    /// `WindowSceneReporter` links it still re-emits the id it was restored with.
    private static var adoptedRestorationWindowIds: [String: String] = [:]

    static func restorationWindowId(for session: UISceneSession) -> String? {
        session.stateRestorationActivity.flatMap(windowId(in:))
    }

    static func restorationWindowId(in activities: Set<NSUserActivity>) -> String? {
        activities.lazy.compactMap(windowId(in:)).first
    }

    /// Builds the activity that carries `windowId` to a scene, whether it is
    /// persisted with the session or passed to `requestSceneSessionActivation`.
    static func windowRestorationActivity(for windowId: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: windowRestorationActivityType)
        activity.userInfo = ["windowId": windowId]
        return activity
    }

    /// Pure decode of the activity payload — nonisolated so the two accessors
    /// above can stay synchronous without hopping to the main actor.
    private nonisolated static func windowId(in activity: NSUserActivity) -> String? {
        guard activity.activityType == windowRestorationActivityType,
              let windowId = activity.userInfo?["windowId"] as? String,
              !windowId.isEmpty else { return nil }
        return windowId
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Self.adoptedRestorationWindowIds.removeValue(forKey: scene.session.persistentIdentifier)
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        guard !Self.isVisorScene(scene) else { return nil }
        let sessionId = scene.session.persistentIdentifier
        guard let windowId = TerminalWindowRegistry.windowId(forSceneSessionId: sessionId)
                ?? Self.adoptedRestorationWindowIds[sessionId] else { return nil }
        return Self.windowRestorationActivity(for: windowId)
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Diagnostic: log the fields we use to detect the visor so we can
        // see what SwiftUI actually puts there if our match fails.
        let configName = session.configuration.name ?? "<nil>"
        let sceneActivityType = scene.userActivity?.activityType ?? "<nil>"
        let sceneActivityTitle = scene.userActivity?.title ?? "<nil>"
        let optionActivityType = connectionOptions.userActivities.first?.activityType ?? "<nil>"
        let optionActivityTitle = connectionOptions.userActivities.first?.title ?? "<nil>"
        logger.info("Scene willConnectTo — configName=\"\(configName)\", sceneActivityType=\"\(sceneActivityType)\", sceneActivityTitle=\"\(sceneActivityTitle)\", optionActivityType=\"\(optionActivityType)\", optionActivityTitle=\"\(optionActivityTitle)\"")

        #if STANDALONE
        // Launch backstop: once the visor has been summoned in a prior run,
        // the OS restores its UISceneSession at every launch. That restored
        // window is briefly an ordinary titled window and can steal key
        // status (dead Return key) or flash a small white window before our
        // deferred configure() can hide it. Rather than reactively recover
        // from that bad state, destroy the restored zombie outright — the
        // next summon's ensurePanel() recreates a fresh scene (the reliable
        // first-summon path). A live summon sets summonInFlight first, so we
        // only ever destroy a scene the OS restored on its own.
        let isPersistedVisorId = session.persistentIdentifier == VisorSceneLifecycle.persistedSceneId
        if (isPersistedVisorId || Self.isVisorScene(scene, connectionOptions: connectionOptions))
            && !VisorSceneLifecycle.summonInFlight {
            logger.info("Destroying restored zombie visor scene (no summon in flight)")
            // Mark the doomed session as the visor's so isVisorScene keeps
            // excluding it while the deferred destruction is pending (it may
            // have been recognized only via the persisted id).
            VisorSceneRegistry.shared.register(session: session)
            // Best-effort, ordering-neutral flash suppression before teardown.
            Self.suppressConnectingVisorWindow(for: windowScene)
            // Defer destruction: requesting it synchronously inside the scene's
            // own connection callback is reentrant and behaves inconsistently
            // on Catalyst. One runloop turn is harmless — we abandon the scene.
            // Past launch, this connection was UIKit's answer to a Dock-click
            // reopen — destroying it consumes the reopen, so make sure a main
            // window still appears. At cold launch SwiftUI creates the main
            // scene itself, so the fallback must not run there.
            let doomed = session
            let isPostLaunchReopen = Self.hasActivatedAnyScene
            DispatchQueue.main.async {
                UIApplication.shared.requestSceneSessionDestruction(doomed, options: nil)
                if isPostLaunchReopen {
                    Self.openMainWindowIfNoneConnected()
                }
            }
            return
        }
        #endif

        if Self.isVisorScene(scene, connectionOptions: connectionOptions) {
            // Visor manages its own geometry via VisorController.animateIn.
            // Just register the session so save/restore callbacks skip it;
            // DO NOT call requestGeometryUpdate here — that pins the
            // scene's geometry preference and Catalyst will fight any
            // subsequent NSWindow.setFrame call from animateIn, leaving
            // the visor stuck at whatever size we requested.
            #if STANDALONE
            VisorSceneRegistry.shared.register(session: session)
            #endif
        } else {
            windowScene.sizeRestrictions?.minimumSize = Self.minWindowSize
            // Restore-phase signal, made authoritative at this point by the eager
            // `ensureStateLoaded()` in `didFinishLaunchingWithOptions`. Use the
            // REGULAR-window signal (not `hasPendingRestoration`): the saved state
            // always carries a `visor` entry that is claimed only when the visor is
            // summoned (never on App Store builds), so `hasPendingRestoration` stays
            // true for the whole session and would make every runtime new window
            // skip the last-focused cascade sizing below.
            //
            // Per-window restoration. A scene session that has run before carries
            // its window id in the state-restoration activity we returned last
            // time; a scene the app requested for restoration carries it in the
            // activity passed to `requestSceneSessionActivation`. Either way the
            // scene is bound to exactly one saved window here, so it claims that
            // window's tabs and is pre-sized to that window's own saved frame —
            // instead of the two independent file-order guesses this replaced.
            let restoring = WindowStateManager.shared.hasPendingRegularWindowRestoration
            if restoring {
                let preferred = Self.restorationWindowId(for: session)
                    ?? Self.restorationWindowId(in: connectionOptions.userActivities)
                // Pre-size the restored window NOW, before it is first displayed,
                // so it is BORN at the right size instead of appearing at a
                // default and then visibly resizing. MainView re-confirms once its
                // scene links (and does the blank-window nudge). The single global
                // last-focused frame is NOT applied here (it would make every
                // restored window the same size).
                if let bound = WindowStateManager.shared.bindConnectingScene(preferredWindowId: preferred) {
                    Self.adoptedRestorationWindowIds[session.persistentIdentifier] = bound.windowId
                    if let frame = bound.frame {
                        let prefs = UIWindowScene.GeometryPreferences.Mac(systemFrame: frame)
                        windowScene.requestGeometryUpdate(prefs) { error in
                            logger.warning("Pre-size of restored window failed: \(error.localizedDescription)")
                        }
                        logger.info("Pre-sized restored window: \(Int(frame.width))x\(Int(frame.height))")
                    }
                }
            } else {
                applyNewWindowCascadeGeometry(to: windowScene)
            }
        }

        // Handle URLs that launched the app (cold start)
        handleURLContexts(connectionOptions.urlContexts, source: "scene.willConnect", scene: windowScene)
    }

    /// Detect the visor's UIScene. SwiftUI's `session.configuration.name`
    /// is undocumented for WindowGroups, so we probe several candidate
    /// sources. The VisorSceneRegistry layered detection covers cases
    /// where the SwiftUI-side fields don't expose the WindowGroup id at all.
    static func isVisorScene(_ scene: UIScene, connectionOptions: UIScene.ConnectionOptions? = nil) -> Bool {
        #if STANDALONE
        if VisorSceneRegistry.shared.isVisor(session: scene.session) { return true }
        #endif
        if let name = scene.session.configuration.name,
           name.localizedCaseInsensitiveContains("visor") {
            return true
        }
        if let activity = scene.userActivity, Self.isVisorActivity(activity) {
            return true
        }
        if let connectionOptions,
           connectionOptions.userActivities.contains(where: { Self.isVisorActivity($0) }) {
            return true
        }
        return false
    }

    private static func isVisorActivity(_ activity: NSUserActivity) -> Bool {
        if activity.activityType.localizedCaseInsensitiveContains("visor") { return true }
        if let title = activity.title, title.localizedCaseInsensitiveContains("visor") {
            return true
        }
        if let target = activity.targetContentIdentifier,
           target.localizedCaseInsensitiveContains("visor") {
            return true
        }
        return false
    }

    #if STANDALONE
    /// Slam the connecting (doomed) visor window's alpha to 0 so the OS can't
    /// composite a white frame in the runloop turn before its destruction
    /// lands. Alpha-only is pure NSWindow state — it does not touch ordering
    /// or styleMask, so it never deactivates the scene (the documented
    /// landmine for the hidden visor window during bring-up). Best-effort: if
    /// the window isn't claimable yet this is a no-op and the deferred
    /// destruction still fires within one runloop.
    private static func suppressConnectingVisorWindow(for windowScene: UIWindowScene) {
        guard let bridge = MacSupport.bridge else { return }
        let sessionId = windowScene.session.persistentIdentifier
        for window in bridge.windows where WindowAccessor.sceneSessionId(for: window) == sessionId {
            bridge.setAlpha(0, for: window)
        }
    }
    #endif

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        // Handle URLs opened while app is running
        handleURLContexts(URLContexts, source: "scene.openURLContexts", scene: scene as? UIWindowScene)
    }

    private func handleURLContexts(_ urlContexts: Set<UIOpenURLContext>, source: String, scene: UIWindowScene?) {
        for context in urlContexts {
            CatalystAppDelegate.routeAutomationURL(context.url, source: source, deliveredTo: scene)
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let isFirstActivation = !Self.hasActivatedAnyScene
        Self.hasActivatedAnyScene = true

        if Self.isVisorScene(scene) {
            #if STANDALONE
            // A Dock-click reopen can activate the hidden visor's live scene
            // instead of creating a main window, leaving nothing on screen.
            // Not during a summon (summonInFlight / visorShouldBeKey) and not
            // while the visor is showing — then it's a genuine stranded
            // reopen, so open a main window.
            if !isFirstActivation,
               !VisorSceneLifecycle.summonInFlight,
               !VisorWindowKeyOverride.visorShouldBeKey,
               !VisorController.shared.isVisible {
                Self.openMainWindowIfNoneConnected()
            }
            #endif
            return
        }

        saveWindowGeometry(windowScene)
        // Reopened-window recovery (#279): let this scene's WindowAccessor
        // re-validate its claimed NSWindow now that the window is on screen,
        // and re-assert blur (per-NSWindow state, idempotent on both paths).
        NotificationCenter.default.post(name: .catalystSceneDidActivate, object: windowScene)
        Ghostty.App.shared?.applyWindowBlur()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene,
              !Self.isVisorScene(scene) else { return }
        // Capture geometry before the window loses focus (e.g. user moved it then switched apps).
        // Catalyst does not fire didUpdate on simple window moves, so this is the main hook
        // for catching origin changes during the app session.
        saveWindowGeometry(windowScene)
    }

    func windowScene(_ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace, interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation, traitCollection previousTraitCollection: UITraitCollection) {
        // Persist size/position changes for the active window. Initial geometry is set
        // up front in scene(_:willConnectTo:); didUpdate only handles ongoing changes.
        if Self.isVisorScene(windowScene) { return }
        if windowScene.activationState == .foregroundActive {
            saveWindowGeometry(windowScene)
        }
    }

    /// Size a genuinely new (Cmd-N) window to the last-focused window's geometry,
    /// cascading the origin when another window already exists. Restored windows
    /// do NOT come through here — they are sized by their own per-window saved
    /// frame in `MainView` (see the `hasPendingRestoration` gate in
    /// `scene(_:willConnectTo:)`). `WindowSizeManager` is the single store backing
    /// this "next new window" default.
    private func applyNewWindowCascadeGeometry(to windowScene: UIWindowScene) {
        let stored = WindowSizeManager.shared.frameForNewWindow()
        let currentFrame = windowScene.effectiveGeometry.systemFrame

        // For windows opened while the app is already running (additional scenes),
        // skip origin restore so they cascade rather than stack on the existing
        // window. The visor's scene must not count: it is invisible (or a
        // floating overlay), and treating it as "another window" made a
        // Dock-click reopen after a visor toggle lose the stored origin.
        let hasOtherWindow = UIApplication.shared.connectedScenes.contains { other in
            other !== windowScene && other is UIWindowScene && !Self.isVisorScene(other)
        }

        let origin: CGPoint
        if let storedOrigin = stored.origin, !hasOtherWindow,
           let visibleOrigin = clampToVisibleScreen(origin: storedOrigin, size: stored.size, scene: windowScene) {
            origin = visibleOrigin
        } else {
            origin = currentFrame.origin
        }

        let newFrame = CGRect(origin: origin, size: stored.size)

        // Skip if it already matches what's on screen.
        if newFrame.equalTo(currentFrame) { return }

        logger.info("New window cascade geometry: \(newFrame.width)x\(newFrame.height) at (\(newFrame.origin.x), \(newFrame.origin.y))")
        let preferences = UIWindowScene.GeometryPreferences.Mac(systemFrame: newFrame)
        windowScene.requestGeometryUpdate(preferences) { error in
            logger.warning("requestGeometryUpdate error: \(error.localizedDescription)")
        }
    }

    /// Returns an origin that keeps the window mostly on a visible screen, or nil if no
    /// screen contains a meaningful portion of the proposed frame (e.g. a saved position
    /// from a now-disconnected display).
    private func clampToVisibleScreen(origin: CGPoint, size: CGSize, scene: UIWindowScene) -> CGPoint? {
        let proposed = CGRect(origin: origin, size: size)
        let screenBounds = scene.screen.bounds
        let intersection = proposed.intersection(screenBounds)
        let proposedArea = proposed.width * proposed.height
        guard proposedArea > 0 else { return nil }
        let coverage = (intersection.width * intersection.height) / proposedArea
        return coverage >= 0.5 ? origin : nil
    }

    private func saveWindowGeometry(_ windowScene: UIWindowScene) {
        let frame = windowScene.effectiveGeometry.systemFrame
        guard frame.size.width >= Self.minWindowSize.width,
              frame.size.height >= Self.minWindowSize.height else { return }

        WindowSizeManager.shared.updateWindowFrame(frame)
    }
}

#endif
