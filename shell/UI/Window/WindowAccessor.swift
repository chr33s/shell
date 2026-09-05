//
//  WindowAccessor.swift
//  shell
//
//  Window transparency configuration for iOS and Mac Catalyst
//

import SwiftUI
import Combine
import Foundation
import os
import ObjectiveC

#if canImport(UIKit)
import UIKit

// Associated object key for storing scene session ID on NSWindow
private var sceneSessionIdKey: UInt8 = 0

extension Notification.Name {
    /// Posted by CatalystSceneDelegate.sceneDidBecomeActive so per-window
    /// accessors can re-validate their claimed NSWindow after a reopen.
    static let catalystSceneDidActivate = Notification.Name("dev.chr33s.shell.catalystSceneDidActivate")
}

#if targetEnvironment(macCatalyst)
import AppKit

extension WindowAccessor {
    @MainActor
    static func keyState(forSceneSessionId sceneSessionId: String) -> Bool? {
        guard !sceneSessionId.isEmpty else { return nil }
        guard let bridge = MacSupport.bridge,
              let window = MacSupport.window(for: sceneSessionId) else { return nil }
        return bridge.isKeyWindow(window)
    }

    static func sceneSessionId(for nsWindow: NSObject) -> String? {
        objc_getAssociatedObject(nsWindow, &sceneSessionIdKey) as? String
    }

    /// Removes a scene-session claim. Used by the visor's stolen-claim
    /// recovery: when this accessor's key-window heuristic claims the
    /// visor's NSWindow during the launch race, the visor identifies its
    /// window by geometry and clears the bad claim so both accessors can
    /// re-claim their true windows.
    static func clearSceneSessionClaim(for nsWindow: NSObject) {
        objc_setAssociatedObject(nsWindow, &sceneSessionIdKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

/// Snapshot of every input that affects the Catalyst NSWindow + titlebar
/// configuration. Lets `TransparentWindowView` skip the expensive AppKit
/// configuration / forced `display()` reconfigure when none of these changed.
///
/// The six reconfigure triggers (surface count, tab count, transparency,
/// theme, tab-bar toggle, and the *very* chatty global
/// `UserDefaults.didChangeNotification`) otherwise re-run the whole AppKit
/// configuration pass many times during a single window open — a major source of
/// the open-time flashing.
private struct WindowConfigSignature: Equatable {
    var shouldApplyTransparency: Bool
    var opacity: CGFloat
    var usesGlass: Bool
    var themeBackgroundHex: String
    var tabCount: Int
    var tabsInTitlebar: Bool
    var tabBarHidden: Bool
    var hideTitleBar: Bool
    var topTabStyle: TopTabStyle
}
#endif

/// A hidden view that configures window-level transparency
/// Based on the pattern from the transparent reference project
struct WindowAccessor: UIViewRepresentable {
    var windowTitle: String = ""

    func makeUIView(context: Context) -> UIView {
        let view = TransparentWindowView()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        #if targetEnvironment(macCatalyst)
        (uiView as? TransparentWindowView)?.updateWindowTitle(windowTitle)
        #else
        if let transparentView = uiView as? TransparentWindowView {
            transparentView.pendingSceneTitle = windowTitle
            transparentView.applySceneTitle()
        }
        #endif
    }
}

/// Internal view that accesses the UIWindow to configure transparency
private class TransparentWindowView: UIView {
    private var cancellables = Set<AnyCancellable>()
    private var titlebarInsetRetryCount = 0
    private var titlebarInsetRetryTask: DispatchWorkItem?

    /// Scene title to apply once the view is in a window (iPad/iPhone)
    var pendingSceneTitle: String?

    /// Title last handed to the OS for the current window. `updateUIView`
    /// runs on every SwiftUI update of the accessor, and the OS-side write
    /// (FrontBoard scene settings / AppKit titlebar) is far from free.
    private var lastAppliedTitle: String?

    #if targetEnvironment(macCatalyst)
    /// Window title to apply once the view is in a window (macCatalyst)
    var pendingWindowTitle: String?

    /// Last configuration that was fully applied to the NSWindow. `configureWindow()`
    /// short-circuits when the live signature matches this, so the burst of
    /// reconfigure triggers fired during a window open no longer each re-run the
    /// AppKit configuration + `display()`.
    private var lastAppliedConfig: WindowConfigSignature?

    /// True while a `makeNSWindowTransparent()` pass is already queued for the
    /// next runloop turn, so a burst of triggers collapses into one pass.
    private var nsWindowConfigScheduled = false

    /// The NSWindow the last full pass configured. Weak: when AppKit
    /// deallocates the window after a close, this goes nil and the dedup
    /// guard stops trusting `lastAppliedConfig`.
    private weak var claimedNSWindow: NSObject?

    /// True when the last blur assertion ran while the claimed window was
    /// actually on screen. CGS blur binds to `windowNumber`, which only
    /// exists once the window has a window device — a call made any earlier
    /// is a silent no-op. On reopen the claim can run while the window is
    /// key but not yet ordered in, so the dedup guard uses this to force one
    /// more pass once the window is visible.
    private var blurAssertedWhileVisible = false
    #endif

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "WindowAccessor")

    #if !targetEnvironment(macCatalyst)
    func applySceneTitle() {
        guard let title = pendingSceneTitle, let windowScene = window?.windowScene else { return }
        guard title != lastAppliedTitle else { return }
        windowScene.title = title
        lastAppliedTitle = title
    }
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A different window knows nothing of the last title we applied.
        lastAppliedTitle = nil

        #if targetEnvironment(macCatalyst)
        guard self.window != nil else { return }

        // New window (or re-attach to a different one): force a fresh apply.
        lastAppliedConfig = nil

        // Initial configuration
        configureWindow()

        // Apply any window title that was set before the view was in a window
        if let title = pendingWindowTitle {
            updateWindowTitle(title)
        }

        // Subscribe to changes that should trigger reconfiguration
        setupSubscriptions()
        #else
        // Apply any scene title that was set before the view was in a window
        if self.window != nil {
            applySceneTitle()
        }
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func setupSubscriptions() {
        // didMoveToWindow calls this on every re-attach; drop the previous
        // window's subscriptions so they don't accumulate.
        cancellables.removeAll()

        // A freshly created NSWindow often isn't key when the first configure
        // pass runs, and makeNSWindowTransparent() skips claiming in that case.
        // Re-run the pass the moment our window becomes key so a reopened
        // window (closed then relaunched from the Dock) gets claimed and
        // configured deterministically.
        NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, let window = notification.object as? UIWindow,
                      window === self.window else { return }
                self.configureWindow()
            }
            .store(in: &cancellables)

        // AppKit posts this when the claimed window actually reaches the
        // screen — the earliest point where a windowNumber-bound CGS blur
        // call can stick. The dedup guard turns this into a no-op when the
        // blur was already asserted on a visible window.
        NotificationCenter.default.publisher(for: Notification.Name("NSWindowDidChangeOcclusionStateNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let nsWindow = notification.object as? NSObject,
                      nsWindow === self.claimedNSWindow else { return }
                self.configureWindow()
            }
            .store(in: &cancellables)

        // Re-validate when our scene activates. On a Dock-click reopen this
        // fires before the new NSWindow is on screen (the occlusion
        // observer above covers the visibility moment), but it is the
        // reliable early hook for claiming a replaced window.
        NotificationCenter.default.publisher(for: .catalystSceneDidActivate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, let scene = notification.object as? UIWindowScene,
                      scene === self.window?.windowScene else { return }
                self.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for surface count changes
        Ghostty.App.shared?.surfaceCountDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for tab count changes (for drag blocker)
        SessionTracker.shared.tabCountDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for transparency setting changes
        TransparencyManager.shared.transparencyDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for theme changes to update title bar color
        ThemeManager.shared.themeDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for tab bar visibility changes (for drag blocker)
        NotificationCenter.default.publisher(for: .toggleTabBar)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // Listen for "tabs in titlebar" setting changes. Skipped during an
        // external settings batch; `.settingsDidChange` fires once afterwards.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard !SettingsStore.shared.isApplyingBatch else { return }
                self?.configureWindow()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .settingsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.configureWindow()
            }
            .store(in: &cancellables)

        // AppKit rebuilds titlebar views on fullscreen exit, resurrecting the
        // chrome the hidden-titlebar style hides. Force a full reconfigure of
        // our claimed NSWindow when that happens.
        NotificationCenter.default.publisher(for: Notification.Name("NSWindowDidExitFullScreenNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      SettingsStore.shared.get(Settings.Window.hideTitleBar),
                      let nsWindow = notification.object as? NSObject,
                      let sceneSessionId = self.window?.windowScene?.session.persistentIdentifier,
                      WindowAccessor.sceneSessionId(for: nsWindow) == sceneSessionId else {
                    return
                }
                self.lastAppliedConfig = nil
                self.configureWindow()
            }
            .store(in: &cancellables)
    }

    #if targetEnvironment(macCatalyst)
    /// Updates the NSWindow title for dock menu and Mission Control display
    func updateWindowTitle(_ title: String) {
        pendingWindowTitle = title
        guard let uiWindow = self.window else { return }
        guard title != lastAppliedTitle else { return }

        let sceneSessionId = uiWindow.windowScene?.session.persistentIdentifier ?? ""
        guard !sceneSessionId.isEmpty else { return }

        guard let bridge = MacSupport.bridge,
              let nsWindow = MacSupport.window(for: sceneSessionId) else { return }
        bridge.setTitle(title, for: nsWindow)
        lastAppliedTitle = title

        // Setting the title can resurrect native title UI (macOS 15+); keep
        // the hidden-titlebar style asserted.
        if SettingsStore.shared.get(Settings.Window.hideTitleBar) {
            configureTitleBar(for: nsWindow, transparent: true, tabCount: SessionTracker.shared.tabCount(forSceneSessionId: sceneSessionId))
        }
    }
    #endif

    private func configureWindow() {
        guard self.window != nil else { return }

        // Skip the entire reconfigure when nothing that affects the window or
        // titlebar has changed. Most of the reconfigure triggers — especially
        // the global UserDefaults.didChangeNotification observer — fire
        // repeatedly during a single window open; without this guard each one
        // re-runs the AppKit configuration pass plus a forced `display()`, which
        // is a major contributor to the open-time flashing.
        let signature = currentWindowConfigSignature()
        if let signature, signature == lastAppliedConfig {
            if claimedWindowStateMatches(signature) { return }
            // The applied record no longer reflects the live NSWindow: on a
            // window reopen Catalyst can reconnect the scene with a brand new
            // NSWindow (or reset the old one's state) without invalidating
            // anything the signature tracks, which left reopened windows
            // opaque (#279). Force a full pass.
            lastAppliedConfig = nil
        }

        let shouldApplyTransparency = signature?.shouldApplyTransparency ?? false

        applyUIWindowAppearance(shouldApplyTransparency: shouldApplyTransparency)

        // Coalesce the AppKit window configuration onto the next runloop turn
        // so a burst of triggers collapses into a single reconfiguration pass.
        scheduleNSWindowConfiguration()
    }

    /// Applies the UIKit-side window appearance. Split out because SwiftUI's
    /// scene bring-up re-asserts an opaque window background and can land
    /// after configureWindow's write (#279 reopen) — the AppKit pass calls
    /// this again so both sides are asserted in the same runloop turn.
    private func applyUIWindowAppearance(shouldApplyTransparency: Bool) {
        guard let window = self.window else { return }

        if shouldApplyTransparency {
            // Using a very low alpha value (0.001) instead of pure clear
            // This matches ghostty macOS behavior and provides better visual results
            window.backgroundColor = .white.withAlphaComponent(0.001)
            window.isOpaque = false

            // Ensure the root view controller's view is also transparent
            if let rootView = window.rootViewController?.view {
                rootView.backgroundColor = .clear
                rootView.isOpaque = false
            }
        } else {
            // No active surfaces - use system background color (adapts to light/dark mode)
            window.backgroundColor = .systemBackground
            window.isOpaque = true

            if let rootView = window.rootViewController?.view {
                rootView.backgroundColor = .systemBackground
                rootView.isOpaque = true
            }
        }
    }

    /// True when the NSWindow the last full pass configured is still alive,
    /// on screen, and carrying the opacity that pass applied. Cheap (typed property
    /// reads, no window-list scan), so the dedup guard can run it on every
    /// reconfigure trigger to catch a replaced or externally reset NSWindow.
    private func claimedWindowStateMatches(_ signature: WindowConfigSignature) -> Bool {
        guard let nsWindow = claimedNSWindow else { return false }
        // Only demand on-screen visibility while the scene is active: a
        // miniaturized window reports isVisible == false and must not be
        // treated as stale by every background trigger.
        if window?.windowScene?.activationState == .foregroundActive,
           MacSupport.bridge?.isVisible(nsWindow) != true {
            return false
        }
        guard let opaque = MacSupport.bridge?.isOpaque(nsWindow) else { return false }
        guard opaque == !signature.shouldApplyTransparency else { return false }
        // Blur asserted before the window had a window device did nothing;
        // report a mismatch once the window is on screen so the full pass
        // re-runs with a valid windowNumber.
        if !blurAssertedWhileVisible,
           MacSupport.bridge?.isVisible(nsWindow) == true {
            return false
        }
        // UIKit side: SwiftUI's scene bring-up re-asserts an opaque window
        // background, and on a reopened window that lands AFTER our configure
        // pass, leaving the UIWindow opaque while the NSWindow underneath is
        // transparent (#279). Treat it as divergence so the next trigger
        // repaints the UIKit side too.
        if let uiWindow = self.window {
            let bgAlpha = uiWindow.backgroundColor?.cgColor.alpha ?? 0
            let uiTransparent = !uiWindow.isOpaque && bgAlpha < 0.5
            if uiTransparent != signature.shouldApplyTransparency { return false }
            if signature.shouldApplyTransparency,
               let rootView = uiWindow.rootViewController?.view,
               (rootView.backgroundColor?.cgColor.alpha ?? 0) > 0.5 {
                return false
            }
        }
        return true
    }

    /// Computes the current window configuration signature, or nil if the view
    /// isn't in a window yet. Reads only cheap state (no AppKit calls), so
    /// it is safe to evaluate on every reconfigure trigger.
    private func currentWindowConfigSignature() -> WindowConfigSignature? {
        guard let uiWindow = self.window else { return nil }
        let sceneSessionId = uiWindow.windowScene?.session.persistentIdentifier ?? ""
        let hasActiveSurfaces = Ghostty.App.shared?.hasActiveSurfaces ?? false
        let opacity = TransparencyManager.shared.backgroundOpacity
        let store = SettingsStore.shared
        return WindowConfigSignature(
            shouldApplyTransparency: hasActiveSurfaces && opacity < 1.0,
            opacity: opacity,
            usesGlass: TransparencyManager.shared.usesGlass,
            themeBackgroundHex: ThemeManager.shared.currentThemeInfo?.colors.background ?? "",
            tabCount: SessionTracker.shared.tabCount(forSceneSessionId: sceneSessionId),
            tabsInTitlebar: store.get(Settings.Window.tabsInTitlebar),
            tabBarHidden: store.get(Settings.Tabs.barHidden),
            hideTitleBar: store.get(Settings.Window.hideTitleBar),
            topTabStyle: store.get(Settings.Tabs.topTabStyle)
        )
    }

    /// Coalesces NSWindow reconfiguration: many triggers can fire in one runloop
    /// turn during window open, so collapse them into a single
    /// `makeNSWindowTransparent()` pass (which reads live state at execution).
    private func scheduleNSWindowConfiguration() {
        guard !nsWindowConfigScheduled else { return }
        nsWindowConfigScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nsWindowConfigScheduled = false
            self.makeNSWindowTransparent()
        }
    }

    /// True when some connected UIScene's session matches `sessionId`.
    /// Distinguishes stale NSWindow claims (safe to reclaim) from live
    /// ones (never steal).
    private static func isLiveSceneSession(_ sessionId: String) -> Bool {
        UIApplication.shared.connectedScenes.contains {
            $0.session.persistentIdentifier == sessionId
        }
    }

    /// Configures the underlying NSWindow for transparency on Mac Catalyst
    /// Uses Objective-C runtime to access AppKit classes
    private func makeNSWindowTransparent() {
        guard let uiWindow = self.window else { return }

        #if STANDALONE && targetEnvironment(macCatalyst)
        // The visor hosts a full MainView, so this accessor also lives in the
        // visor scene — but its NSWindow is a borderless panel owned entirely
        // by VisorWindowAccessor. Claiming it here (the key path can win the
        // race before the visor's own claim lands) applies titlebar/opacity
        // configuration meant for regular windows and desyncs the panel from
        // its UIKit scene. Never touch NSWindows from the visor's scene.
        if let session = uiWindow.windowScene?.session,
           VisorSceneRegistry.shared.isVisor(session: session) {
            return
        }
        #endif

        // Check if there are active Ghostty surfaces
        let hasActiveSurfaces = Ghostty.App.shared?.hasActiveSurfaces ?? false
        let opacity = TransparencyManager.shared.backgroundOpacity

        // Only apply transparency if:
        // 1. There are active Ghostty surfaces, AND
        // 2. Opacity is less than 1.0
        // Otherwise, use a solid background color
        let shouldApplyTransparency = hasActiveSurfaces && opacity < 1.0

        guard let bridge = MacSupport.bridge else { return }
        let windows = bridge.windows

        // Get our scene session ID for matching. A view whose scene already
        // detached (window teardown) must not claim anything: a dying view
        // can otherwise claim an unrelated window with an empty id via the
        // single-window path (#279).
        let sceneSessionId = uiWindow.windowScene?.session.persistentIdentifier ?? ""
        guard !sceneSessionId.isEmpty else { return }

        // Find our specific NSWindow using stored scene session ID
        // Strategy:
        // 1. Look for NSWindow already tagged with our sceneSessionId
        // 2. If only one window exists, claim it
        // 3. If not found and we're key window, claim the key NSWindow
        //
        // A claim can go stale on window reopen: the scene session reconnects
        // with the same persistentIdentifier while the closed window's
        // NSWindow can still sit in NSApp.windows carrying our claim —
        // configuring that dead window left reopened windows opaque (#279).
        // Drop the claim from an invisible window and fall through to claim
        // the live one.
        var claimedWindow = windows.first(where: { window in
            let storedId = objc_getAssociatedObject(window, &sceneSessionIdKey) as? String
            return storedId == sceneSessionId
        })
        if let candidate = claimedWindow,
           bridge.isVisible(candidate) != true {
            objc_setAssociatedObject(candidate, &sceneSessionIdKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            claimedWindow = nil
        }

        let nsWindow: NSObject

        if let claimedWindow {
            nsWindow = claimedWindow
        } else if windows.count == 1 {
            // Only one window - claim it
            let candidate = windows[0]
            #if STANDALONE && targetEnvironment(macCatalyst)
            // Never claim the visor's window. A stolen claim makes the
            // visor's own resolveNSWindow() skip its window forever, and
            // the unconfigured visor stays on screen as a small white
            // window at launch.
            if VisorWindowClaims.isVisorWindow(candidate) {
                Self.logger.debug("Only NSWindow is the visor's; waiting to claim")
                return
            }
            #endif
            nsWindow = candidate
            objc_setAssociatedObject(nsWindow, &sceneSessionIdKey, sceneSessionId, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            Self.logger.info("Claimed single NSWindow for scene \(sceneSessionId)")
        } else if uiWindow.isKeyWindow {
            // Multiple windows - claim the key NSWindow if we're the key UIWindow
            guard let keyWindow = windows.first(where: { window in
                // Find unclaimed key window
                #if STANDALONE && targetEnvironment(macCatalyst)
                if VisorWindowClaims.isVisorWindow(window) { return false }
                #endif
                let storedId = objc_getAssociatedObject(window, &sceneSessionIdKey) as? String
                let isKey = bridge.isKeyWindow(window) == true
                return isKey && storedId == nil
            }) ?? windows.first(where: { window in
                // Fallback: reclaim a key window only when its existing
                // claim is stale (no live scene session). Stealing a live
                // claim (another terminal window's, or the visor's)
                // misroutes window configuration; the visor case left an
                // unconfigured white window on screen at launch.
                #if STANDALONE && targetEnvironment(macCatalyst)
                if VisorWindowClaims.isVisorWindow(window) { return false }
                #endif
                guard bridge.isKeyWindow(window) == true else { return false }
                if let storedId = objc_getAssociatedObject(window, &sceneSessionIdKey) as? String,
                   storedId != sceneSessionId,
                   Self.isLiveSceneSession(storedId) {
                    return false
                }
                return true
            }) else {
                Self.logger.warning("Could not find key NSWindow to claim")
                return
            }
            nsWindow = keyWindow
            objc_setAssociatedObject(nsWindow, &sceneSessionIdKey, sceneSessionId, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            Self.logger.info("Claimed key NSWindow for scene \(sceneSessionId)")
        } else {
            // Not key window and haven't claimed a window yet - skip
            Self.logger.debug("Skipping non-key window \(sceneSessionId), waiting to claim")
            return
        }

        // Track the resolved window so the dedup guard can detect it being
        // replaced or externally reset (see claimedWindowStateMatches).
        if claimedNSWindow !== nsWindow {
            // A replacement NSWindow starts with its default title.
            lastAppliedTitle = nil
            if let pending = pendingWindowTitle { updateWindowTitle(pending) }
        }
        claimedNSWindow = nsWindow

        // Fast path: if this exact configuration was already applied, don't
        // rebuild the titlebar / drag blockers or force another `display()`.
        // The only thing that still needs polling is the titlebar leading inset,
        // which only becomes measurable once the traffic-light buttons exist —
        // this is what the inset retry loop is for, and keeping it lightweight
        // avoids 8 full configuration passes per window open.
        if let last = lastAppliedConfig, currentWindowConfigSignature() == last {
            if last.hideTitleBar {
                // Buttons are hidden — nothing to measure; cancel any retries.
                scheduleTitlebarInsetRetryIfNeeded(hasInset: true, hasWindows: true)
                return
            }
            let inset = titlebarLeadingInset(for: nsWindow)
            if let inset {
                TitlebarLayoutManager.shared.updateLeadingInset(inset)
            }
            scheduleTitlebarInsetRetryIfNeeded(hasInset: inset != nil, hasWindows: true)
            return
        }

        let tabCount = SessionTracker.shared.tabCount(forSceneSessionId: sceneSessionId)
        let window = nsWindow
        bridge.configureBackground(shouldApplyTransparency, for: window)

        // Configure title bar for integrated tab appearance
        configureTitleBar(for: window, transparent: shouldApplyTransparency, tabCount: tabCount)

        // With the titlebar hidden the buttons can't be measured; keep the
        // persisted inset warm for restore and cancel the retry loop.
        let hideTitleBar = SettingsStore.shared.get(Settings.Window.hideTitleBar)
        if hideTitleBar {
            scheduleTitlebarInsetRetryIfNeeded(hasInset: true, hasWindows: true)
        } else {
            if let leadingInset = titlebarLeadingInset(for: window) {
                TitlebarLayoutManager.shared.updateLeadingInset(leadingInset)
            }

            scheduleTitlebarInsetRetryIfNeeded(
                hasInset: titlebarLeadingInset(for: window) != nil,
                hasWindows: true
            )
        }

        bridge.refresh(window)

        // Record what we just applied so unchanged reconfigure triggers (and the
        // titlebar inset retries) take the fast path above.
        lastAppliedConfig = currentWindowConfigSignature()

        // Blur is per-NSWindow state and dies with the old window on reopen;
        // re-assert it in the same pass that configures the claimed window.
        Ghostty.App.shared?.applyWindowBlur(to: window)

        // Re-assert the UIKit side: SwiftUI's scene bring-up repaints the
        // UIWindow opaque between configureWindow's write and this pass on a
        // reopened window (#279).
        applyUIWindowAppearance(shouldApplyTransparency: shouldApplyTransparency)

        blurAssertedWhileVisible = bridge.isVisible(window) == true
    }

    private func scheduleTitlebarInsetRetryIfNeeded(hasInset: Bool, hasWindows: Bool) {
        guard !hasInset, hasWindows else {
            titlebarInsetRetryCount = 0
            titlebarInsetRetryTask?.cancel()
            titlebarInsetRetryTask = nil
            return
        }

        guard titlebarInsetRetryCount < 8 else { return }
        titlebarInsetRetryCount += 1

        titlebarInsetRetryTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.makeNSWindowTransparent()
        }
        titlebarInsetRetryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
    }

    private func titlebarLeadingInset(for window: NSObject) -> CGFloat? {
        guard let inset = MacSupport.bridge?.titlebarLeadingInset(window), inset > 0 else { return nil }
        return inset
    }

    private func configureTitleBar(for window: NSObject, transparent: Bool, tabCount: Int) {
        let store = SettingsStore.shared
        let tabsInTitlebar = store.get(Settings.Window.tabsInTitlebar)
        let tabBarHidden = store.get(Settings.Tabs.barHidden)
        MacSupport.bridge?.configureTitlebar(
            window,
            hidden: store.get(Settings.Window.hideTitleBar),
            separatorHidden: store.get(Settings.Tabs.topTabStyle).usesStripLayout && tabsInTitlebar && !tabBarHidden,
            tabsInTitlebar: tabsInTitlebar,
            tabBarHidden: tabBarHidden,
            tabCount: tabCount
        )
    }
    #endif
}
#endif
