//
//  TerminalSurfaceController.swift
//  shell
//
//  Owns Swiftty surface lifecycle details on behalf of TerminalView.
//

import UIKit
import os
import SwifttyKit

@MainActor
protocol TerminalSurfaceHost: AnyObject {
    var surfaceUserdata: AnyObject { get }
    var surfaceView: UIView { get }
    var surfaceLayer: CALayer { get }
    var surfaceAppPointer: swiftty_app_t? { get }
    var surfaceSwifttyApp: Swiftty.App? { get }
    var surfaceWindowID: String { get }
    var surfaceContainingTabID: UUID? { get }
    var surfaceTerminalDebugID: String { get }
    var surfaceConnectionConfig: ConnectionConfig { get }
    var surfaceTmuxPaneBinding: Swiftty.TerminalView.TmuxPaneBinding? { get }
    var surfaceIsTmuxPane: Bool { get }
    var surfaceTmuxPaneContainerLaidOut: Bool { get }
    var surfaceTmuxPaneRetired: Bool { get }
    var surfaceTmuxDetachInProgress: Bool { get }
    nonisolated var surfaceTmuxDetachInProgressAtomic: Bool { get }
    var surfaceIsTabVisible: Bool { get set }
    func surfaceInitialTabVisibility() -> Bool
    var surfacePendingScrollbackRestore: Bool { get set }
    var surfacePendingScrollbackRestoreForLayout: Bool { get set }
    var surfaceRestorationState: Swiftty.TerminalView.RestorationState { get }
    var surfaceOutputPipeline: TerminalOutputPipeline { get }
    var surfaceLogFrequentLayout: Bool { get }
    var surfaceSuppressBottomInsetUpdatesForScrollRubberBand: Bool { get }
    var surfaceCurrentBottomInsetPixels: Double { get }

    func surfaceControllerDidSetSurface(_ surface: swiftty_surface_t?)
    func surfaceRegisterForScrollbackPersistence()
    func surfaceSetupThemeOverrideSubscription()
    func surfaceApplyRestoredFontSizeOverrideIfNeeded()
    func surfaceDidNeedSessionSetup()
    func surfaceRunLayoutDeferredScrollbackRestore()
    func surfaceUpdatePTYSize()
    func surfaceFirstFrameDidFailOpen()
}

@MainActor
final class TerminalSurfaceController: NSObject {
    private unowned let host: TerminalSurfaceHost

    private(set) var surface: swiftty_surface_t?
    var slaveFd: Int32 = -1
    var responseFd: Int32 = -1

    private(set) var hasRenderedFirstFrame = false
    private var firstFrameCallbacks: [@MainActor () -> Void] = []
    private var firstFramePollLink: CADisplayLink?
    private var firstFramePollTarget: FirstFramePollTarget?
    private var firstFramePollStart: CFTimeInterval = 0

    private var lastFramebufferSize: (width: UInt32, height: UInt32)?
    private var lastContentScaleFactor: CGFloat?
    private var lastSentGridSize: (rows: UInt16, cols: UInt16)?
    private var lastSizedSessionID: ObjectIdentifier?
    private var lastBottomInsetPx: Double = -1
    private var suppressSizeUpdates = false

    init(host: TerminalSurfaceHost) {
        self.host = host
        super.init()
    }

    isolated deinit {
        firstFramePollLink?.invalidate()
    }

    var surfaceSize: swiftty_surface_size_s? {
        guard let surface else { return nil }
        return swiftty_surface_size(surface)
    }

    var sizeUpdatesSuppressed: Bool {
        suppressSizeUpdates || Swiftty.isAppBackgroundedAtomic
    }

    func setSizeUpdatesSuppressed(_ suppressed: Bool) {
        suppressSizeUpdates = suppressed
    }

    @discardableResult
    func clearSizeSuppression() -> Bool {
        guard suppressSizeUpdates else { return false }
        suppressSizeUpdates = false
        return true
    }

    func invalidateCachedSize() {
        lastFramebufferSize = nil
        lastContentScaleFactor = nil
        lastSentGridSize = nil
    }

    /// A pipe-backed surface sizes its session from the pty_resize action,
    /// which the IO thread sends once the terminal has resized. Sending right
    /// after swiftty_surface_set_size raced its 25 ms resize coalescing: the
    /// application's redraw could be parsed into the old grid. Other backends
    /// keep sizing straight after the surface call.
    var sizesSessionFromPtyResizeAction: Bool { slaveFd >= 0 }

    /// Grid the IO thread last reported through pty_resize.
    private var appliedGrid: (rows: UInt16, cols: UInt16)?
    /// Layout-requested grid whose acknowledgement releases the deferred
    /// scrollback replay. The constructor's provisional resize acknowledges
    /// too and must not release it into that grid.
    private var restoreGrid: (rows: UInt16, cols: UInt16)?

    func notePtyResizeApplied(rows: UInt16, cols: UInt16) {
        appliedGrid = (rows: rows, cols: cols)
        guard let restoreGrid, restoreGrid.rows == rows, restoreGrid.cols == cols else { return }
        runLayoutRestore()
    }

    /// True when the IO thread already applied this framebuffer, so set_size
    /// queues nothing and no action follows. Evaluate before that call: it
    /// updates the requested size at once, synchronously on Catalyst.
    func surfaceHasAppliedFramebuffer(for size: CGSize, scale: CGFloat) -> Bool {
        guard sizesSessionFromPtyResizeAction, let surfaceSize, let appliedGrid,
              appliedGrid.rows == surfaceSize.rows, appliedGrid.cols == surfaceSize.columns
        else { return false }
        return surfaceSize.width_px == UInt32(size.width * scale)
            && surfaceSize.height_px == UInt32(size.height * scale)
    }

    /// Main-actor follow-up once the surface call returned.
    private func completeSurfaceResize(needsRestore: Bool) {
        let restorePending = needsRestore && host.surfacePendingScrollbackRestoreForLayout
        guard sizesSessionFromPtyResizeAction else {
            host.surfaceUpdatePTYSize()
            if restorePending { runLayoutRestore() }
            return
        }
        guard restorePending, let size = surfaceSize else { return }
        if let appliedGrid, appliedGrid.rows == size.rows, appliedGrid.cols == size.columns {
            runLayoutRestore()
        } else {
            restoreGrid = (rows: size.rows, cols: size.columns)
        }
    }

    /// Claim the deferred restore only when this main-actor callback actually
    /// runs. Clearing it before the IO/main queue hops lets a concurrent
    /// transport `.running` event mistake "queued" for "already restored" and
    /// replay at stale dimensions; a second queued size callback could then
    /// replay it again. ROOTSHELL-TMUX (id=layout-restore-main-actor-claim)
    private func runLayoutRestore() {
        restoreGrid = nil
        guard host.surfacePendingScrollbackRestoreForLayout else { return }
        host.surfacePendingScrollbackRestoreForLayout = false
        host.surfaceRunLayoutDeferredScrollbackRestore()
    }

    func shouldSendPTYSize(for sessionID: ObjectIdentifier, gridSize: (rows: UInt16, cols: UInt16)) -> Bool {
        if lastSizedSessionID != sessionID {
            lastSizedSessionID = sessionID
            lastSentGridSize = nil
        }
        return lastSentGridSize.map { $0 != gridSize } ?? true
    }

    func markPTYSizeSent(_ gridSize: (rows: UInt16, cols: UInt16)) {
        lastSentGridSize = gridSize
    }

    var lastSentPTYGridDescription: String {
        lastSentGridSize.map { "\($0.rows)x\($0.cols)" } ?? "nil"
    }

    func notifyOnFirstFrame(_ callback: @escaping @MainActor () -> Void) {
        if hasRenderedFirstFrame {
            callback()
        } else {
            firstFrameCallbacks.append(callback)
        }
    }

    /// The core's "IOSurfaceLayer": each presented frame lands in its `contents`.
    func rendererLayer() -> CALayer? {
        host.surfaceLayer.sublayers?.first {
            String(cString: object_getClassName($0)) == "IOSurfaceLayer"
        }
    }

    private func startFirstFramePolling() {
        guard firstFramePollLink == nil,
              !hasRenderedFirstFrame,
              host.surfaceIsTabVisible,
              !Swiftty.isSecureDrawProhibitedAtomic else { return }
        firstFramePollStart = CACurrentMediaTime()
        let target = FirstFramePollTarget(controller: self)
        let link = CADisplayLink(target: target, selector: #selector(FirstFramePollTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        firstFramePollTarget = target
        firstFramePollLink = link
    }

    fileprivate func firstFramePollTick() {
        guard host.surfaceIsTabVisible,
              !Swiftty.isSecureDrawProhibitedAtomic else {
            suspendFirstFramePolling()
            return
        }
        if rendererLayer()?.contents != nil {
            markFirstFrameRendered()
        } else if CACurrentMediaTime() - firstFramePollStart > 2.0 {
            markFirstFrameRendered(failOpen: true)
        }
    }

    private func markFirstFrameRendered(failOpen: Bool = false) {
        // Visibility can change on the same main-run-loop turn as a poll tick.
        // Keep first-frame tracking pending when the surface is now hidden so a
        // later selection can restart it; never promote a hidden pane to visible.
        if failOpen && (!host.surfaceIsTabVisible || Swiftty.isSecureDrawProhibitedAtomic) {
            suspendFirstFramePolling()
            return
        }
        suspendFirstFramePolling()
        guard !hasRenderedFirstFrame else { return }
        hasRenderedFirstFrame = true
        if failOpen {
            Swiftty.logger.warning("First frame poll timed out; treating surface as rendered")
            if host.surfaceIsTmuxPane {
                host.surfaceFirstFrameDidFailOpen()
            }
        }
        let callbacks = firstFrameCallbacks
        firstFrameCallbacks = []
        for callback in callbacks { callback() }
    }

    private func suspendFirstFramePolling() {
        firstFramePollLink?.invalidate()
        firstFramePollLink = nil
        firstFramePollTarget = nil
    }

    func resetFirstFrameTracking() {
        suspendFirstFramePolling()
        hasRenderedFirstFrame = false
        firstFrameCallbacks = []
    }

    func createSurfaceIfNeeded() {
        guard surface == nil else { return }
        createSurface()
    }

    private func createTmuxPaneSurface(
        app: swiftty_app_t,
        cfg: inout swiftty_surface_config_s,
        binding: Swiftty.TerminalView.TmuxPaneBinding
    ) {
        let surface = swiftty_surface_new_tmux_pane(
            app,
            binding.parentSurface,
            UInt(binding.windowId),
            UInt(binding.paneId),
            binding.viewerTerminal,
            binding.viewerPane,
            &cfg)

        guard let surface else {
            Swiftty.logger.error("Failed to create tmux pane surface (window=\(binding.windowId) pane=\(binding.paneId))")
            return
        }

        installSurface(surface)

        if let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
           let target = controller.overrideFontSize(forWindowId: binding.windowId) {
            let delta = Int((target - FontManager.shared.currentFontSize).rounded())
            if delta != 0 {
                host.surfaceSwifttyApp?.changeFontSize(surface: surface, delta: delta)
            }
        }

        setInitialOcclusion(on: surface)
        Swiftty.logger.info("tmux pane surface created (window=\(binding.windowId) pane=\(binding.paneId))")
        startFirstFramePolling()
    }

    private func createSurface() {
        Swiftty.logger.info("createSurface() called, checking appPtr...")

        guard let app = host.surfaceAppPointer else {
            Swiftty.logger.error("Cannot create surface: app pointer is nil")
            return
        }

        var surfaceCfg = swiftty_surface_config_new()
        surfaceCfg.platform_tag = SWIFTTY_PLATFORM_IOS
        surfaceCfg.platform = swiftty_platform_u(ios: swiftty_platform_ios_s(
            uiview: Unmanaged.passUnretained(host.surfaceView).toOpaque()
        ))
        surfaceCfg.userdata = Unmanaged.passUnretained(host.surfaceUserdata).toOpaque()
        surfaceCfg.scale_factor = host.surfaceView.contentScaleFactor

        // Swiftty starts its renderer thread before the constructor returns.
        // Pass the selected-tab state into construction so an inactive regular
        // or tmux pane never performs the initial full-size Metal draw.
        let initiallyVisible = host.surfaceInitialTabVisibility()
        host.surfaceIsTabVisible = initiallyVisible
        surfaceCfg.initially_visible = initiallyVisible && !Swiftty.isSecureDrawProhibitedAtomic

        if let binding = host.surfaceTmuxPaneBinding {
            createTmuxPaneSurface(app: app, cfg: &surfaceCfg, binding: binding)
            return
        }

        let hasSSH = host.surfaceConnectionConfig.sshConfig != nil
        Swiftty.logger.info("Platform check: isMacCatalyst=\(PlatformDetection.isMacCatalyst), hasSSH=\(hasSSH)")

        surfaceCfg.use_external_io = true
        logSurfaceConfiguration()

        let scaleFactor = host.surfaceView.contentScaleFactor
        Swiftty.logger.info("Creating surface with scale factor: \(scaleFactor)")
        let newSurface = swiftty_surface_new(app, &surfaceCfg)
        Swiftty.logger.info("swiftty_surface_new returned: \(newSurface != nil ? "success" : "nil")")

        guard let newSurface else {
            Swiftty.logger.error("Failed to create swiftty surface - swiftty_surface_new returned nil")
            return
        }

        installSurface(newSurface)
        host.surfaceApplyRestoredFontSizeOverrideIfNeeded()

        slaveFd = swiftty_surface_get_slave_fd(newSurface)
        responseFd = swiftty_surface_response_read_fd(newSurface)
        host.surfaceOutputPipeline.configure(fd: slaveFd)

        if slaveFd >= 0 && responseFd >= 0 {
            Swiftty.logger.info("Got FDs for external I/O - slave: \(self.slaveFd), response: \(self.responseFd)")
        } else {
            Swiftty.logger.error("FDs not available but expected (slave: \(self.slaveFd), response: \(self.responseFd))")
        }

        configureRestoredScrollbackIfNeeded()
        host.surfaceRegisterForScrollbackPersistence()

        Swiftty.logger.info("Setting up PTY and shell session...")
        host.surfaceDidNeedSessionSetup()
        Swiftty.logger.info("PTY and shell setup initiated")

        setInitialOcclusion(on: newSurface)
        startFirstFramePolling()
    }

    private func installSurface(_ surface: swiftty_surface_t) {
        Swiftty.logger.info("Surface created successfully, ptr=\(String(describing: surface))")
        self.surface = surface
        host.surfaceControllerDidSetSurface(surface)

        host.surfaceSwifttyApp?.registerSurface(surface)
        Swiftty.logger.info("Surface registered for config updates")

        host.surfaceSwifttyApp?.registerSurfaceWindow(surface, windowId: host.surfaceWindowID)
        let windowID = host.surfaceWindowID
        Swiftty.logger.info("Surface registered to window \(windowID)")

        if let tabId = host.surfaceContainingTabID {
            host.surfaceSwifttyApp?.registerSurfaceTab(surface, tabId: tabId)
            Swiftty.logger.info("Surface registered to tab \(tabId)")
        }

        host.surfaceSetupThemeOverrideSubscription()
        host.surfaceSwifttyApp?.refreshSurfaceTheme(
            surface,
            tabId: host.surfaceContainingTabID,
            windowId: host.surfaceWindowID
        )

        if let delegate = host.surfaceUserdata as? SwifttyActionDelegate {
            host.surfaceSwifttyApp?.registerSurfaceDelegate(surface, delegate: delegate)
            Swiftty.logger.info("Surface delegate registered")
        }
    }

    private func logSurfaceConfiguration() {
        switch host.surfaceConnectionConfig {
        case .ssh:
            Swiftty.logger.info("Surface config: SSH session - using external I/O (pipes)")
        case .local:
            switch LocalShellBackend.current {
            case .nativePTY:
                Swiftty.logger.info("Surface config: Local shell - using external I/O (native PTY)")
            case .interpreter:
                Swiftty.logger.info("Surface config: Local shell - using external I/O (ios_system pipes)")
            }
        case .shellLaunchedSSH:
            Swiftty.logger.info("Surface config: Shell-launched SSH session - using external I/O (pipes)")
        }
    }

    private func configureRestoredScrollbackIfNeeded() {
        guard case .pendingReconnection = host.surfaceRestorationState else { return }
        host.surfaceOutputPipeline.enableScrollbackRestoreGate()
        switch host.surfaceConnectionConfig {
        case .local, .shellLaunchedSSH:
            host.surfacePendingScrollbackRestoreForLayout = true
        default:
            host.surfacePendingScrollbackRestore = true
        }

        if host.surfacePendingScrollbackRestoreForLayout {
            // `host` is unowned; capture it weakly so this deferred Task no-ops
            // rather than trapping if the view is torn down during the 2s wait.
            Task { @MainActor [weak host] in
                try? await Task.sleep(for: .seconds(2))
                guard let host, host.surfacePendingScrollbackRestoreForLayout else { return }
                host.surfacePendingScrollbackRestoreForLayout = false
                host.surfaceRunLayoutDeferredScrollbackRestore()
            }
        }
    }

    private func setInitialOcclusion(on surface: swiftty_surface_t) {
        // A new surface is born visible in the core with a running display
        // link, so a surface created while the secure-draw latch is armed
        // (background launch, locked-device state restore) must be actively
        // occluded, not just skipped. surfaceIsTabVisible is left untouched
        // so the foreground reconcile re-asserts true after unlock.
        if Swiftty.isSecureDrawProhibitedAtomic {
            swiftty_surface_set_occlusion(surface, false)
            _ = swiftty_surface_drain_renderer_to_idle(surface, 100_000_000)
            return
        }
        let visible = host.surfaceInitialTabVisibility()
        host.surfaceIsTabVisible = visible
        nonisolated(unsafe) let surfacePtr = surface
        Swiftty.TerminalView.swifttyAPIQueue.async {
            swiftty_surface_set_occlusion(surfacePtr, visible)
        }
        Swiftty.logger.info("Initial occlusion set: visible=\(visible)")
    }

    func updateBottomInset() {
        guard let surface else { return }
        guard !host.surfaceSuppressBottomInsetUpdatesForScrollRubberBand else { return }
        // The overlay round trip's safe-area shuffle moves this inset in
        // lockstep with the (dropped) size change — applying it against the
        // unchanged surface size would reflow the grid on its own. Dropped
        // together with the size (never-sized surfaces exempt); the
        // latch-release flush re-applies both.
        if lastFramebufferSize != nil,
           KeyboardTracker.shared.isPreservingKeyboardForOverlay(in: host.surfaceView.window) {
            return
        }
        let insetPx = host.surfaceCurrentBottomInsetPixels
        if abs(insetPx - lastBottomInsetPx) < 0.5 { return }
        lastBottomInsetPx = insetPx
        #if targetEnvironment(macCatalyst)
        swiftty_surface_set_bottom_inset(surface, insetPx)
        #else
        nonisolated(unsafe) let surfacePtr = surface
        Swiftty.TerminalView.swifttyAPIQueue.async {
            swiftty_surface_set_bottom_inset(surfacePtr, insetPx)
        }
        #endif
    }

    func sizeDidChange(_ size: CGSize) {
        guard let surface else {
            Swiftty.logger.warning("sizeDidChange called but surface is nil")
            return
        }

        if size.width < 1 || size.height < 1 {
            return
        }

        if host.surfaceTmuxPaneRetired {
            return
        }

        if sizeUpdatesSuppressed {
            Swiftty.logger.info("sizeDidChange: SUPPRESSED during background transition (size=\(size.width)x\(size.height))")
            return
        }

        // Never drop a never-sized surface's first size (same rule as the
        // overlay-preservation guard below): its grid is at default dims and
        // wrong no matter what. A tab opened or first displayed while a
        // keyboard transition is in flight — including the minimized-keyboard
        // pill a pencil tap summons — otherwise renders a default-sized grid
        // with the theme background filling the rest of the drawable.
        if lastFramebufferSize != nil, KeyboardTracker.shared.isKeyboardAnimating {
            Swiftty.logger.debug("sizeDidChange: SKIPPED during keyboard animation (size=\(size.width)x\(size.height))")
            return
        }

        // While an overlay owns the keyboard, the physical keyboard hide/
        // re-show shuffles the container bottom safe area (the home-indicator
        // inset is subsumed by the keyboard while it is up), wobbling bounds
        // by ~34pt even though the reported keyboard layout is frozen. Drop
        // pushes for the round trip; the latch release posts
        // .overlayKeyboardPreservationEnded and the flush self-dedupes when
        // bounds returned to the size last sent. Never drop a never-sized
        // surface's first size (tab created while an overlay is open).
        if lastFramebufferSize != nil,
           KeyboardTracker.shared.isPreservingKeyboardForOverlay(in: host.surfaceView.window) {
            return
        }

        if host.surfaceTmuxDetachInProgress {
            return
        }

        let scale = host.surfaceView.contentScaleFactor
        let framebufferWidth = UInt32(size.width * scale)
        let framebufferHeight = UInt32(size.height * scale)
        let previousScale = lastContentScaleFactor

        if host.surfaceIsTmuxPane, !host.surfaceTmuxPaneContainerLaidOut {
            return
        }

        if let lastFramebufferSize,
           let lastContentScaleFactor,
           lastFramebufferSize.width == framebufferWidth,
           lastFramebufferSize.height == framebufferHeight,
           lastContentScaleFactor == scale {
            return
        }

        lastFramebufferSize = (width: framebufferWidth, height: framebufferHeight)
        lastContentScaleFactor = scale

        if host.surfaceLogFrequentLayout {
            Swiftty.logger.debug("sizeDidChange: size=\(size.width)x\(size.height), scale=\(scale), framebuffer=\(framebufferWidth)x\(framebufferHeight)")
        }

        let needsRestore = host.surfacePendingScrollbackRestoreForLayout

        if previousScale == nil || previousScale != scale {
            setContentScaleAndSize(
                surface: surface,
                scale: scale,
                framebufferWidth: framebufferWidth,
                framebufferHeight: framebufferHeight,
                needsRestore: needsRestore
            )
            return
        }

        setSize(
            surface: surface,
            framebufferWidth: framebufferWidth,
            framebufferHeight: framebufferHeight,
            needsRestore: needsRestore
        )
    }

    private func setContentScaleAndSize(
        surface: swiftty_surface_t,
        scale: CGFloat,
        framebufferWidth: UInt32,
        framebufferHeight: UInt32,
        needsRestore: Bool
    ) {
        #if targetEnvironment(macCatalyst)
        guard !host.surfaceTmuxDetachInProgressAtomic else { return }
        swiftty_surface_set_content_scale(surface, scale, scale)
        swiftty_surface_set_size(surface, framebufferWidth, framebufferHeight)
        Swiftty.TerminalView.swifttyAPIQueue.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.completeSurfaceResize(needsRestore: needsRestore)
            }
        }
        #else
        nonisolated(unsafe) let surfacePtr = surface
        nonisolated(unsafe) let hostRef = host
        Swiftty.TerminalView.swifttyAPIQueue.async { [weak self] in
            guard let self else { return }
            guard hostRef.surfaceTmuxDetachInProgressAtomic != true else { return }
            swiftty_surface_set_content_scale(surfacePtr, scale, scale)
            swiftty_surface_set_size(surfacePtr, framebufferWidth, framebufferHeight)
            Task { @MainActor in
                self.completeSurfaceResize(needsRestore: needsRestore)
            }
        }
        #endif
    }

    private func setSize(
        surface: swiftty_surface_t,
        framebufferWidth: UInt32,
        framebufferHeight: UInt32,
        needsRestore: Bool
    ) {
        #if targetEnvironment(macCatalyst)
        guard !host.surfaceTmuxDetachInProgressAtomic else { return }
        swiftty_surface_set_size(surface, framebufferWidth, framebufferHeight)
        Swiftty.TerminalView.swifttyAPIQueue.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.completeSurfaceResize(needsRestore: needsRestore)
            }
        }
        #else
        nonisolated(unsafe) let surfacePtr = surface
        nonisolated(unsafe) let hostRef = host
        Swiftty.TerminalView.swifttyAPIQueue.async { [weak self] in
            guard let self else { return }
            guard hostRef.surfaceTmuxDetachInProgressAtomic != true else { return }
            swiftty_surface_set_size(surfacePtr, framebufferWidth, framebufferHeight)
            Task { @MainActor in
                self.completeSurfaceResize(needsRestore: needsRestore)
            }
        }
        #endif
    }

    func setOcclusion(_ visible: Bool) {
        let terminalID = host.surfaceTerminalDebugID
        Swiftty.logger.info("setOcclusion(\(visible)): terminal=\(terminalID)")
        host.surfaceIsTabVisible = visible

        if !visible {
            // An occluded surface is not expected to produce a frame. Leaving
            // its watchdog armed turns that normal state into a timeout and,
            // for tmux panes, historically woke the hidden renderer again.
            suspendFirstFramePolling()
        }

        guard surface != nil else {
            Swiftty.logger.debug("setOcclusion(\(visible)): no surface")
            return
        }

        if visible {
            startFirstFramePolling()
        }

        // Defer the SwifttyKit occlusion call onto a follow-up main-queue tick
        // before hopping to the background API queue. The C call can dispatch
        // CADisplayLink work back to main; one extra tick lets UIKit finish the
        // current keyboard/scene event before we touch the display link. Re-read
        // the live surface here so teardown that already ran leaves us with nil,
        // and teardown after this call preserves serial queue ordering.
        DispatchQueue.main.async { [weak self] in
            guard let self, let surface = self.surface else { return }
            // Secure-draw latch: while the device may be locked, occlusion(true)
            // forces an immediate present in the core (even when redundant),
            // which FrontBoard kills as insecure drawing (0x2BAD45EC). Drop
            // true here and again at the final hop; false always delivers.
            // surfaceIsTabVisible keeps the intent, and the foreground resume
            // re-asserts from the tab model after the latch clears.
            if visible && Swiftty.isSecureDrawProhibitedAtomic {
                return
            }
            nonisolated(unsafe) let surfacePtr = surface
            Swiftty.TerminalView.swifttyAPIQueue.async {
                if visible && Swiftty.isSecureDrawProhibitedAtomic { return }
                swiftty_surface_set_occlusion(surfacePtr, visible)
            }
        }
    }

    @discardableResult
    func pauseRendererForBackground(timeoutNanoseconds: UInt64 = 200_000_000) -> Bool {
        host.surfaceIsTabVisible = false
        suspendFirstFramePolling()
        guard let surface else {
            Swiftty.logger.debug("pauseRendererForBackground: no surface")
            return true
        }

        swiftty_surface_set_occlusion(surface, false)
        return swiftty_surface_drain_renderer_to_idle(surface, timeoutNanoseconds)
    }

    @discardableResult
    func drainRendererToIdleSync(timeoutNanoseconds: UInt64 = 200_000_000) -> Bool {
        host.surfaceIsTabVisible = false
        suspendFirstFramePolling()
        guard let surface else { return true }
        return swiftty_surface_drain_renderer_to_idle(surface, timeoutNanoseconds)
    }

    func teardownSurface() {
        guard let surface else {
            resetFirstFrameTracking()
            return
        }

        host.surfaceSwifttyApp?.unregisterSurfaceTab(surface)
        host.surfaceSwifttyApp?.unregisterSurfaceWindow(surface)
        host.surfaceSwifttyApp?.unregisterSurfaceDelegate(surface)
        host.surfaceSwifttyApp?.unregisterSurface(surface)

        self.surface = nil
        appliedGrid = nil
        restoreGrid = nil
        host.surfaceControllerDidSetSurface(nil)
        slaveFd = -1
        responseFd = -1

        nonisolated(unsafe) let surfacePtr = surface
        Swiftty.TerminalView.swifttyAPIQueue.async {
            let saveCompleted = ScrollbackPersistenceManager.waitForSurfaceSave(surfacePtr)
            if saveCompleted {
                Swiftty.logger.info("Freeing Swiftty surface on background queue...")
                swiftty_surface_free(surfacePtr)
                Swiftty.logger.info("Swiftty surface freed")
            } else {
                Swiftty.logger.warning("Scrollback save did not complete in 500ms; leaking surface to avoid use-after-free")
            }
        }

        resetFirstFrameTracking()
    }
}

@MainActor
private final class FirstFramePollTarget: NSObject {
    weak var controller: TerminalSurfaceController?

    init(controller: TerminalSurfaceController) {
        self.controller = controller
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let controller else {
            link.invalidate()
            return
        }
        controller.firstFramePollTick()
    }
}

extension Swiftty.TerminalView: TerminalSurfaceHost {
    var surfaceUserdata: AnyObject { self }
    var surfaceView: UIView { self }
    var surfaceLayer: CALayer { layer }
    var surfaceAppPointer: swiftty_app_t? { appPtr }
    var surfaceSwifttyApp: Swiftty.App? { swifttyAppRef }
    var surfaceWindowID: String { windowId }
    var surfaceContainingTabID: UUID? { containingTabID }
    var surfaceTerminalDebugID: String { String(uuid.uuidString.prefix(8)) }
    var surfaceConnectionConfig: ConnectionConfig { connectionConfig }
    var surfaceTmuxPaneBinding: TmuxPaneBinding? { tmuxPaneBinding }
    var surfaceIsTmuxPane: Bool { isTmuxPane }
    var surfaceTmuxPaneContainerLaidOut: Bool { tmuxPaneContainerLaidOut }
    var surfaceTmuxPaneRetired: Bool { tmuxPaneRetired }
    var surfaceTmuxDetachInProgress: Bool { isTmuxDetachInProgress }
    nonisolated var surfaceTmuxDetachInProgressAtomic: Bool { tmuxDetachInProgressAtomic }
    var surfaceIsTabVisible: Bool {
        get { isTabVisible }
        set { isTabVisible = newValue }
    }
    func surfaceInitialTabVisibility() -> Bool {
        if hasExplicitTabVisibility {
            return isTabVisible
        }
        guard let tabID = containingTabID else {
            return isTabVisible
        }
        let model = TerminalWindowRegistry.tabsModel(for: windowId)
            ?? TmuxWindowRegistry.tabsModel(for: windowId)
        return model.map { $0.selectedTabID == tabID } ?? isTabVisible
    }
    var surfacePendingScrollbackRestore: Bool {
        get { pendingScrollbackRestore }
        set { pendingScrollbackRestore = newValue }
    }
    var surfacePendingScrollbackRestoreForLayout: Bool {
        get { pendingScrollbackRestoreForLayout }
        set { pendingScrollbackRestoreForLayout = newValue }
    }
    var surfaceRestorationState: RestorationState { restorationState }
    var surfaceOutputPipeline: TerminalOutputPipeline { outputPipeline }
    var surfaceLogFrequentLayout: Bool { Self.logFrequentLayout }
    var surfaceSuppressBottomInsetUpdatesForScrollRubberBand: Bool {
        suppressBottomInsetUpdatesForScrollRubberBand
    }
    var surfaceCurrentBottomInsetPixels: Double { currentBottomInsetPixels() }

    func surfaceControllerDidSetSurface(_ surface: swiftty_surface_t?) {
        self.surface = surface
    }

    func surfaceRegisterForScrollbackPersistence() {
        ScrollbackPersistenceManager.shared.registerTerminal(self)
    }

    func surfaceSetupThemeOverrideSubscription() {
    }

    func surfaceApplyRestoredFontSizeOverrideIfNeeded() {
        applyRestoredFontSizeOverrideIfNeeded()
    }

    func surfaceDidNeedSessionSetup() {
        setupPTYAndShell()
    }

    func surfaceRunLayoutDeferredScrollbackRestore() {
        runLayoutDeferredScrollbackRestore()
    }

    func surfaceUpdatePTYSize() {
        updatePTYSize()
    }

    func surfaceFirstFrameDidFailOpen() {
        guard isTabVisible else {
            Swiftty.logger.debug("Ignoring first-frame fail-open for hidden terminal=\(self.surfaceTerminalDebugID)")
            return
        }
        _ = reassertVisibleIfNeeded(
            shouldFocus: isLogicallyFocused,
            reason: "first-frame-fail-open"
        )
    }

}
