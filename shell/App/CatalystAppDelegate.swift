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

        // Mac Catalyst: Use NSWorkspace notification for app activation (Cmd-Tab)
        // scenePhase and UIApplication.didBecomeActiveNotification don't fire reliably
        setupWorkspaceActivationObserver()
        setupApplicationHideObserver()
        // AppKit owns Continuity Camera's Services handoff even in Catalyst.
        // Install after launch, once the native NSApplication subclass exists.
        DispatchQueue.main.async { [weak self] in
            self?.installContinuityPasteboardInterposer()
        }

        // Disable the macOS "press and hold for accent characters" popup.
        // Terminal users need key repeat (e.g., holding h/j/k/l in vim).
        // This only affects this app, not the system-wide setting.
        UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")

        // Eagerly load saved window state so the restore-phase signal
        // (`hasPendingRestoration`) is authoritative inside
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
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
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

}

// MARK: - Scene Delegate

/// Scene delegate for Catalyst windows. New (Cmd-N) windows are sized to the
/// last-focused window via `applyNewWindowCascadeGeometry`; launch-restored
/// windows are sized per-window from their saved frame in `MainView` and skip
/// the global path (see the `hasPendingRestoration` gate in `willConnectTo`).
class CatalystSceneDelegate: UIResponder, UIWindowSceneDelegate {

    static let minWindowSize = CGSize(width: 400, height: 300)

    /// A scene that hosts a `MainView`: not the Settings window, which is a
    /// `UIWindowScene` with no terminal in it. Anything looking for "a window
    /// to act on" has to exclude it, or a Dock-menu action or an ssh:// open
    /// lands in a window that observes nothing.
    static func isTerminalScene(_ scene: UIScene) -> Bool {
        scene is UIWindowScene &&
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
        let sessionId = scene.session.persistentIdentifier
        guard let windowId = TerminalWindowRegistry.windowId(forSceneSessionId: sessionId)
                ?? Self.adoptedRestorationWindowIds[sessionId] else { return nil }
        return Self.windowRestorationActivity(for: windowId)
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        windowScene.sizeRestrictions?.minimumSize = Self.minWindowSize
        // Restore-phase signal, made authoritative at this point by the eager
        // `ensureStateLoaded()` in `didFinishLaunchingWithOptions`.
        //
        // Per-window restoration. A scene session that has run before carries
        // its window id in the state-restoration activity we returned last
        // time; a scene the app requested for restoration carries it in the
        // activity passed to `requestSceneSessionActivation`. Either way the
        // scene is bound to exactly one saved window here, so it claims that
        // window's tabs and is pre-sized to that window's own saved frame —
        // instead of the two independent file-order guesses this replaced.
        let restoring = WindowStateManager.shared.hasPendingRestoration
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

        // Handle URLs that launched the app (cold start)
        handleURLContexts(connectionOptions.urlContexts, source: "scene.willConnect", scene: windowScene)
    }

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

        saveWindowGeometry(windowScene)
        // Reopened-window recovery (#279): let this scene's WindowAccessor
        // re-validate its claimed NSWindow now that the window is on screen,
        // and re-assert blur (per-NSWindow state, idempotent on both paths).
        NotificationCenter.default.post(name: .catalystSceneDidActivate, object: windowScene)
        Ghostty.App.shared?.applyWindowBlur()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // Capture geometry before the window loses focus (e.g. user moved it then switched apps).
        // Catalyst does not fire didUpdate on simple window moves, so this is the main hook
        // for catching origin changes during the app session.
        saveWindowGeometry(windowScene)
    }

    func windowScene(_ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace, interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation, traitCollection previousTraitCollection: UITraitCollection) {
        // Persist size/position changes for the active window. Initial geometry is set
        // up front in scene(_:willConnectTo:); didUpdate only handles ongoing changes.
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
        // window.
        let hasOtherWindow = UIApplication.shared.connectedScenes.contains { other in
            other !== windowScene && other is UIWindowScene
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
