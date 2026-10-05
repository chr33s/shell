//
//  SwifttyApp.swift
//  shell
//
//  Wrapper around swiftty_app_t for iOS
//

import Foundation
import SwiftUI
import Combine
import os
import UniformTypeIdentifiers
import SwifttyKit

protocol SwifttyActionDelegate: AnyObject {
    /// Called after terminal content changes for this exact surface.
    func handleSurfaceContentChanged()

    /// Called when the terminal title changes
    func handleTitleChange(_ title: String)

    /// Called when the current working directory changes
    func handlePwdChange(_ pwd: String)

    /// Called when a bell/beep is requested
    func handleBell()

    /// Called when terminal cell size changes
    func handleCellSizeChange(width: CGFloat, height: CGFloat)

    /// Called after the IO thread resized the terminal of a pipe-backed
    /// surface. The session's window change follows from here, never from
    /// the swiftty_surface_set_size call, which only queues the resize.
    func handlePTYResize(rows: Int, cols: Int, widthPx: Int, heightPx: Int)

    /// Called when mouse shape changes
    func handleMouseShape(shape: Int)

    /// Called when mouse visibility changes (hide-while-typing)
    func handleMouseVisibility(visible: Bool)

    /// Called when desktop notification is requested
    func handleDesktopNotification(title: String?, body: String?)

    /// Called when scrollbar state changes
    func handleScrollbar(total: UInt64, offset: UInt64, len: UInt64)

    /// Called when progress report is requested
    func handleProgressReport(_ report: Swiftty.Action.ProgressReport)

    /// Called when search should start
    func handleStartSearch(_ startSearch: Swiftty.Action.StartSearch)

    /// Called when search should end
    func handleEndSearch()

    /// Called when total search match count changes
    func handleSearchTotal(_ total: UInt?)

    /// Called when selected search match changes
    func handleSearchSelected(_ selected: UInt?)

    /// Called synchronously when mouse hovers over a link. URL is nil when leaving a link.
    func handleMouseOverLink(url: String?)
}

extension Swiftty {
    /// True while the host app is fully backgrounded (not `.active`, not
    /// `.inactive`).
    ///
    /// Used as a central gate for `@Published` / `@Observable` mutations on the
    /// main actor. Under background QoS, main-thread work takes many times
    /// longer than foreground, so per-output / per-tick scene updates pile up
    /// fast enough to trip the 30 s scene-update watchdog (0x8BADF00D). While
    /// backgrounded, callers should cache new values in non-observed storage
    /// and skip the `@Published` write; a foreground replay path pushes the
    /// cached values through when visibility returns.
    @MainActor
    static var isAppBackgrounded: Bool {
        UIApplication.shared.applicationState == .background
    }

    /// Thread-safe mirror of `isAppBackgrounded` readable from non-main threads.
    ///
    /// `UIApplication.applicationState` must be read on main, so callbacks that
    /// fire from Swiftty's IO thread or session batcher threads cannot read
    /// `isAppBackgrounded` directly. They consult this atomic mirror instead to
    /// short-circuit `Task { @MainActor in ... }` creation while the app is
    /// backgrounded. `MainViewLifecycle.handleAppBackgrounded` /
    /// `handleAppForegrounded` keep this in sync with the real state.
    nonisolated static var isAppBackgroundedAtomic: Bool {
        get { isAppBackgroundedFlag.withLock { $0 } }
        set { isAppBackgroundedFlag.withLock { $0 = newValue } }
    }

    private nonisolated static let isAppBackgroundedFlag = OSAllocatedUnfairLock(initialState: false)

    /// True whenever presenting a frame could land in the system's secure-mode
    /// lock snapshot (FrontBoard 0x2BAD45EC kills the process for it). Armed at
    /// launch so background/protected-data launches, which never see
    /// willResignActive or didEnterBackground, start protected; re-armed on
    /// willResignActive and didEnterBackground; cleared only on didBecomeActive
    /// (AppDelegate.installLifecycleObservers). Enforced at the delivery point
    /// of occlusion(true) pushes and direct surface draws rather than at the
    /// emit site, so a push queued before the lock cannot land inside the
    /// secure window. Inert on Catalyst: no secure mode there, and windows
    /// legitimately draw while the app is inactive.
    nonisolated static var isSecureDrawProhibitedAtomic: Bool {
        get {
            #if targetEnvironment(macCatalyst)
            return false
            #else
            return secureDrawProhibitedFlag.withLock { $0 }
            #endif
        }
        set { secureDrawProhibitedFlag.withLock { $0 = newValue } }
    }

    private nonisolated static let secureDrawProhibitedFlag = OSAllocatedUnfairLock(initialState: true)

    /// Catalyst-aware "transport read thread is frozen by suspension" signal for
    /// the tmux -CC recovery/resume watchdogs. Uses the LIVE `applicationState`,
    /// not `isAppBackgroundedAtomic`: that mirror stays TRUE until the
    /// foreground-resume drain gate opens (`MainViewLifecycle` ~1331), which can
    /// stall and strand the watchdogs (resume spins forever → "Reconnecting tmux"
    /// stuck; recovery never escalates). Always false on Catalyst (no background
    /// thread freeze). ROOTSHELL-TMUX (id=tmux-watchdog-live-fgstate)
    @MainActor
    static var isTransportFrozenByBackground: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return isAppBackgrounded
        #endif
    }

    /// True for a brief window after the app foregrounds — used by bisection
    /// gates to suppress specific tssh-driven state mutations while the
    /// SwiftUI scene-update transaction is settling.
    ///
    /// Implemented as a deadline timestamp rather than a Bool + timer:
    /// rapid background/foreground bounces would otherwise schedule
    /// per-resume `asyncAfter` clear timers that race with each other —
    /// the first timer to fire would close the window even if a later
    /// resume had extended it. Reading "now < deadline" is O(1) and has
    /// no scheduling state to coordinate, so each foreground call to
    /// `extendResumeQuietWindow(by:)` simply pushes the deadline forward
    /// from the current moment.
    nonisolated static var isInResumeQuietWindowAtomic: Bool {
        let deadline = resumeQuietWindowDeadline.withLock { $0 }
        return Date().timeIntervalSinceReferenceDate < deadline
    }

    /// Push the resume quiet window deadline `seconds` into the future from
    /// now. Idempotent across rapid bounces: if a later resume calls this
    /// while the window is still open, the deadline only moves forward
    /// (never backward), so a fast back-to-back bounce can't shorten the
    /// quiet window of the most recent resume.
    nonisolated static func extendResumeQuietWindow(by seconds: TimeInterval) {
        let target = Date().timeIntervalSinceReferenceDate + seconds
        resumeQuietWindowDeadline.withLock { current in
            if target > current {
                current = target
            }
        }
    }

    private nonisolated static let resumeQuietWindowDeadline = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    /// Same shape as `isInResumeQuietWindowAtomic` but with a longer
    /// deadline, scoped specifically to suppress per-session health-status
    /// publishes (TerminalView.applyConnectionHealth) for longer than the
    /// general resume window. Heartbeat-driven connectionHealth fan-out
    /// across many tssh sessions is one of the noisier mutation sources
    /// after resume; allowing it to settle for ~1.5s while still letting
    /// other quiet-window gates expire after ~150ms keeps the UI feeling
    /// responsive without re-introducing the storm.
    nonisolated static var isInResumeHealthQuietWindowAtomic: Bool {
        let deadline = resumeHealthQuietWindowDeadline.withLock { $0 }
        return Date().timeIntervalSinceReferenceDate < deadline
    }

    /// Push the health-specific quiet window forward (only-grow semantics,
    /// matches `extendResumeQuietWindow`).
    nonisolated static func extendResumeHealthQuietWindow(by seconds: TimeInterval) {
        let target = Date().timeIntervalSinceReferenceDate + seconds
        resumeHealthQuietWindowDeadline.withLock { current in
            if target > current {
                current = target
            }
        }
    }

    private nonisolated static let resumeHealthQuietWindowDeadline = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)

    @MainActor
    @Observable
    final class App {
        enum Readiness: String {
            case loading, error, ready
        }

        /// Shared instance for global access (primarily for window configuration)
        /// Note: The app is still created as @StateObject in RootShellApp, this just provides access
        nonisolated(unsafe) static var shared: App?

        /// Static mapping of app pointers to App instances for callback access
        /// Using Int (pointer address) as key instead of ObjectIdentifier to avoid wrapper object issues
        private nonisolated(unsafe) static var appInstances: [Int: Weak<App>] = [:]

        /// Weak wrapper for App instances
        private nonisolated struct Weak<T: AnyObject> {
            weak var value: T?
        }

        /// The readiness state of the app
        var readiness: Readiness = .loading

        /// The global app configuration
        private(set) var config: Config

        /// The swiftty app instance
        nonisolated(unsafe) var app: swiftty_app_t?

        /// Mapping of surface pointers to their action delegates
        /// Using Int (pointer address) as key instead of ObjectIdentifier to avoid wrapper object issues
        private var surfaceDelegates: [Int: WeakActionDelegate] = [:]

        /// Weak wrapper for action delegates
        private struct WeakActionDelegate {
            weak var delegate: SwifttyActionDelegate?
        }

        /// Registry of active surface pointers
        private var activeSurfaces: Set<UnsafeMutableRawPointer> = []

        /// Surface-content events are shared by agent detection and tmux pane
        /// identity refresh. Keep the core signal on while either consumer
        /// needs it; otherwise disabling detection would also freeze inactive
        /// tmux pane titles.
        private var attentionContentEventsEnabled = false
        private var tmuxContentEventInterests: Set<UUID> = []
        private var appliedContentEventsEnabled = false

        /// Whether there are any active Swiftty surfaces
        var hasActiveSurfaces: Bool {
            !activeSurfaces.isEmpty
        }

        /// The number of active surfaces
        var surfaceCount: Int {
            activeSurfaces.count
        }

        /// Publisher that emits when the number of active surfaces changes
        let surfaceCountDidChange = PassthroughSubject<Void, Never>()

        /// Mapping of surface pointers to window IDs
        private var surfaceWindowMap: [Int: String] = [:]

        /// Mapping of surface pointers to tab UUIDs
        private var surfaceTabMap: [Int: UUID] = [:]

        /// Subscription to theme changes
        private var themeSubscription: AnyCancellable?

        /// Subscription to font size changes
        private var fontSizeSubscription: AnyCancellable?

        /// Subscription to font family changes
        private var fontFamilySubscription: AnyCancellable?

        /// Subscription to ligatures changes
        private var ligaturesSubscription: AnyCancellable?

        /// Subscription to font feature changes
        private var fontFeaturesSubscription: AnyCancellable?

        /// Subscription to per-font cell adjustment changes
        private var cellAdjustmentsSubscription: AnyCancellable?

        /// Subscription to transparency changes
        private var transparencySubscription: AnyCancellable?

        /// Observer token for cursor config changes
        private var cursorObserver: NSObjectProtocol?

        /// Observer token for selection config changes
        private var selectionObserver: NSObjectProtocol?

        /// Observer token for power-tier changes
        private var powerObserver: NSObjectProtocol?

        /// Last animated-cursor throttle we pushed through the config
        /// reload, so tier changes that don't affect the cursor are free.
        private var lastAppliedCursorThrottle: Bool?

        init() {
            // Initialize ios_system environment variables FIRST, wherever the
            // interpreter is the local shell backend (always off Catalyst, and the
            // sandboxed Catalyst build).
            //
            // IMPORTANT: setenv() calls must complete BEFORE SwifttyKit
            // spawns any background thread. POSIX setenv/getenv are not thread-safe
            // against each other; a concurrent getenv iteration can dereference freed
            // environ entries. See TestFlight crash 16CB397E-97E0-461E-B78E-41FBFA38CC18
            // (build 65) — a runtime thread faulted reading environ while
            // ios_system's initializeEnvironment() was still setting XDG_CACHE_HOME /
            // XDG_CONFIG_HOME / XDG_STATE_HOME / XDG_DATA_HOME.
            let usesInterpreter = LocalShellBackend.current == .interpreter
            if usesInterpreter {
                initializeEnvironment()
            }

            // Now safe to initialize swiftty (may spawn threads that read env vars).
            Swiftty.initialize()

            // Register ios_system command dictionaries and direct function entry points.
            // These mutate ios_system's commandList global, not environ — safe post-init.
            if usesInterpreter {
                for name in ["commandDictionary", "extraCommandsDictionary"] {
                    guard let path = Bundle.main.path(forResource: name, ofType: "plist") else {
                        logger.warning("\(name).plist not found in bundle")
                        continue
                    }
                    if let error = addCommandList(path) {
                        logger.error("Failed to load \(name): \(error.localizedDescription)")
                    } else {
                        logger.info("Loaded \(name).plist")
                    }
                }
                // Re-open the user's folder grants and tell ios_system's `cd` about them.
                LocalShellFolders.shared.activate()
            }

            // Initialize the global configuration
            self.config = Config()
            if self.config.config == nil {
                logger.error("Config creation failed")
                readiness = .error
                return
            }

            // Set as shared instance for global access (after all properties initialized)
            Swiftty.App.shared = self

            // Create runtime configuration with callbacks
            var runtime_cfg = Self.makeRuntimeConfig(userdata: Unmanaged.passUnretained(self).toOpaque())

            // Create the swiftty app
            guard let app = swiftty_app_new(&runtime_cfg, config.config) else {
                logger.critical("swiftty_app_new returned nil!")
                readiness = .error
                return
            }
            self.app = app

            // Register this instance for callback access
            // Use raw pointer address as key (not ObjectIdentifier which creates new wrapper each time)
            let appId = Int(bitPattern: app)
            Self.appInstances[appId] = Weak(value: self)

            // Every generated config already includes the saved theme, font
            // size, font family (including nil/default), and other preferences.
            // Load and deliver it once before creating surfaces instead of
            // rewriting/reparsing the same file for each appearance setting.
            self.reloadGlobalConfig()

            // Blur is applied per-window by WindowAccessor when it claims each
            // NSWindow, and re-asserted on scene activation — no launch-time
            // delayed pass needed here.

            // Listen for theme changes
            self.setupThemeSubscription()

            // Listen for font size changes
            self.setupFontSizeSubscription()

            // Listen for font family changes
            self.setupFontFamilySubscription()

            // Listen for ligatures changes
            self.setupLigaturesSubscription()

            // Listen for font feature changes
            self.setupFontFeaturesSubscription()

            // Listen for per-font cell adjustment changes
            self.setupCellAdjustmentsSubscription()

            // Listen for cursor config changes
            self.setupCursorSubscription()

            // Listen for selection config changes
            self.setupSelectionSubscription()

            // Listen for transparency changes (Catalyst). Without this the
            // new opacity only reached surfaces through the config written at
            // the next launch, so the Settings slider appeared to do nothing.
            self.setupTransparencySubscription()

            // Listen for power-tier changes (battery saver / refresh cap)
            self.setupPowerSubscription()

            self.readiness = .ready
        }

        nonisolated deinit {
            // Free the app on deinit
            // Capture the app pointer to avoid capturing self
            let appPtr = self.app
            if let appPtr = appPtr {
                // Free directly - swiftty_app_free should be thread-safe
                swiftty_app_free(appPtr)
            }
        }

        // MARK: - App Operations

        /// Set to true when the app enters background to prevent Metal rendering
        /// while the device is locked, which causes iOS to kill the process
        /// ("insecure drawing while in secure mode").
        ///
        /// On Mac Catalyst this flag is NOT checked because macOS does not kill
        /// apps for background Metal draws, and scenePhase transitions are
        /// unreliable — the flag can get stuck true, freezing all rendering.
        var isInBackground = false {
            didSet {
                guard isInBackground != oldValue else { return }
                applySurfaceContentEventInterests()
                TmuxController.applicationBackgroundStateDidChange(isInBackground)
            }
        }

        /// Gate the optional per-surface content signal in Swiftty itself.
        /// This setter owns the agent-detection interest. Tmux controllers
        /// register their independent interest below.
        func setSurfaceContentEventsEnabled(_ enabled: Bool) {
            attentionContentEventsEnabled = enabled
            applySurfaceContentEventInterests()
        }

        /// Register or release a live tmux controller's need for pane-content
        /// edges. The ID is unique to one controller lifetime, so a delayed
        /// deinit release can never remove a replacement controller's interest.
        func setTmuxSurfaceContentEventsEnabled(_ enabled: Bool, interestID: UUID) {
            if enabled {
                tmuxContentEventInterests.insert(interestID)
            } else {
                tmuxContentEventInterests.remove(interestID)
            }
            applySurfaceContentEventInterests()
        }

        private func applySurfaceContentEventInterests() {
            let enabled = !isInBackground
                && (attentionContentEventsEnabled || !tmuxContentEventInterests.isEmpty)
            guard enabled != appliedContentEventsEnabled, let app else { return }
            appliedContentEventsEnabled = enabled
            swiftty_app_set_surface_content_events_enabled(app, enabled)
        }

        // MARK: - Config Delivery

        /// Push a rebuilt config to the core app and its surfaces, serialized on
        /// `swifttyAPIQueue`.
        ///
        /// Every surface-lifetime call runs on that serial queue, including
        /// `swiftty_surface_free`. `swiftty_app_update_config` walks Swiftty's own
        /// surface list, which still holds a surface until its queued free actually
        /// runs, so pushing a config from the main thread could deinit the same
        /// `DerivedConfig` a teardown is deiniting and free its link regexes twice.
        ///
        /// `swiftty_app_update_config` both stores the config that newly created
        /// surfaces inherit and fans it out to every surface Swiftty knows about, so
        /// it always overwrites surfaces carrying a tab/window theme override. Those
        /// are put back afterwards with a config built from their own theme; skipping
        /// them is not enough, because the fan-out already reached them.
        ///
        /// Override configs are built here on the main actor; ownership transfers to
        /// the queue, which frees them once the push completes.
        ///
        /// - Parameter completion: run on the main actor after the SwifttyKit calls land. Use
        ///   this for anything that must observe the new config; a timer cannot, since
        ///   the queue may be behind a teardown's save wait.
        /// - Returns: how many surfaces took the global config and how many were put
        ///   back on their override.
        @discardableResult
        private func pushConfig(
            app: swiftty_app_t,
            globalConfig: swiftty_config_t,
            completion: (@MainActor @Sendable () -> Void)? = nil
        ) -> (updated: Int, overridden: Int) {
            // One theme for the whole app: no per-tab or per-window overrides.
            let overrideSurfaces: [(UnsafeMutableRawPointer, UnsafeMutableRawPointer)] = []
            let overridden = 0

            nonisolated(unsafe) let appPtr = app
            nonisolated(unsafe) let cfg = globalConfig
            nonisolated(unsafe) let overrides = overrideSurfaces
            Swiftty.TerminalView.swifttyAPIQueue.async {
                swiftty_app_update_config(appPtr, cfg)
                for (surface, surfaceConfig) in overrides {
                    swiftty_surface_update_config(surface, surfaceConfig)
                    swiftty_config_free(surfaceConfig)
                }
                if let completion {
                    Task { @MainActor in completion() }
                }
            }

            return (activeSurfaces.count - overridden, overridden)
        }

        /// Push the current global config, for callers outside this type that have
        /// already rewritten the config file. Goes through
        /// `pushConfig(app:globalConfig:completion:)` so per-surface theme overrides
        /// survive the app-level fan-out.
        func pushGlobalConfigToApp() {
            guard let app = self.app, let cfg = config.config else { return }
            pushConfig(app: app, globalConfig: cfg)
        }

        /// Push a config to a single surface on `swifttyAPIQueue`, for the same
        /// reason as `pushConfig(app:globalConfig:completion:)`.
        ///
        /// - Parameter owned: when true the config was built for this call and is
        ///   freed on the queue once the push completes.
        private func pushConfig(
            toSurface surface: swiftty_surface_t,
            config surfaceConfig: swiftty_config_t,
            owned: Bool
        ) {
            nonisolated(unsafe) let surface = surface
            nonisolated(unsafe) let surfaceConfig = surfaceConfig
            Swiftty.TerminalView.swifttyAPIQueue.async {
                swiftty_surface_update_config(surface, surfaceConfig)
                if owned { swiftty_config_free(surfaceConfig) }
            }
        }

        func requestClose(surface: swiftty_surface_t) {
            swiftty_surface_request_close(surface)
        }

        func changeFontSize(surface: swiftty_surface_t, delta: Int) {
            let action = delta > 0 ? "increase_font_size:\(delta)" : "decrease_font_size:\(-delta)"
            let actionLen = UInt(action.utf8.count)
            nonisolated(unsafe) let surface = surface
            Swiftty.TerminalView.swifttyAPIQueue.async {
                action.withCString { cAction in
                    if !swiftty_surface_binding_action(surface, cAction, actionLen) {
                        Swiftty.logger.warning("font size action failed")
                    }
                }
            }
        }

        func resetFontSize(surface: swiftty_surface_t) {
            let action = "reset_font_size"
            let actionLen = UInt(action.utf8.count)
            nonisolated(unsafe) let surface = surface
            Swiftty.TerminalView.swifttyAPIQueue.async {
                action.withCString { cAction in
                    if !swiftty_surface_binding_action(surface, cAction, actionLen) {
                        Swiftty.logger.warning("reset font size action failed")
                    }
                }
            }
        }

        // MARK: - Theme Management

        /// Set up subscription to theme changes
        private func setupThemeSubscription() {
            themeSubscription = ThemeManager.shared.themeDidChange
                .sink { [weak self] _ in
                    self?.applyCurrentTheme()
                }
        }

        /// Apply the current theme from ThemeManager
        /// Respects per-surface overrides - surfaces with tab/window overrides are skipped
        func applyCurrentTheme() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            #if !targetEnvironment(macCatalyst)
            // Update bat's terminal palette so next bat invocation uses new colors
            #endif

            guard let app = self.app else {
                logger.warning("Cannot apply theme: app is nil")
                return
            }

            let themeName = ThemeManager.shared.currentTheme
            logger.info("Applying theme: \(themeName)")

            // Apply theme to the config (this replaces config.config with new pointer)
            if config.setTheme(themeName), let newCfg = config.config {
                let (updatedCount, overriddenCount) = pushConfig(app: app, globalConfig: newCfg)

                logger.info("Theme applied: \(updatedCount) surfaces updated, \(overriddenCount) kept on their override")
            } else {
                logger.error("Failed to apply theme: \(themeName)")
            }
        }

        // MARK: - Per-Surface Theme Overrides

        /// Apply a specific theme to a single surface (for per-tab/per-window overrides)
        /// This does not affect the global config or other surfaces.
        /// - Parameters:
        ///   - surface: The swiftty surface to apply the theme to
        ///   - themeName: The theme name to apply
        func applyThemeToSurface(_ surface: swiftty_surface_t, themeName: String) {
            logger.info("Applying theme override to surface: \(themeName)")

            guard let surfaceConfig = Swiftty.Config.createConfigForTheme(themeName) else {
                logger.error("Failed to create config for surface theme: \(themeName)")
                return
            }

            pushConfig(toSurface: surface, config: surfaceConfig, owned: true)

            logger.info("Applied theme override to surface: \(themeName)")
        }

        /// Refresh a surface to the app's single global theme.
        /// - Parameters:
        ///   - surface: The swiftty surface to refresh
        ///   - tabId: Unused; kept so call sites stay unchanged
        ///   - windowId: Unused; kept so call sites stay unchanged
        func refreshSurfaceTheme(_ surface: swiftty_surface_t, tabId: UUID?, windowId: String?) {
            guard let globalConfig = config.config else { return }
            pushConfig(toSurface: surface, config: globalConfig, owned: false)
            logger.info("Surface theme refreshed to global: \(ThemeManager.shared.currentTheme)")
        }

        // MARK: - Font Size Management

        /// Set up subscription to font size changes
        private func setupFontSizeSubscription() {
            fontSizeSubscription = FontManager.shared.fontSizeDidChange
                .sink { [weak self] _ in
                    self?.applyCurrentFontSize()
                }
        }

        /// Apply the current font size from FontManager
        func applyCurrentFontSize() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply font size: app is nil")
                return
            }

            let fontSize = Int(FontManager.shared.currentFontSize)
            logger.info("Applying font size: \(fontSize)")

            // Apply font size to the config (this replaces config.config with new pointer)
            if config.setFontSize(fontSize), let newCfg = config.config {
                // Update all active surfaces individually, respecting theme overrides
                logger.info("Updating \(self.activeSurfaces.count) active surfaces with new font size")

                pushConfig(app: app, globalConfig: newCfg)

                logger.info("Font size applied successfully to app and \(self.activeSurfaces.count) surfaces")
            } else {
                logger.error("Failed to apply font size: \(fontSize)")
            }
        }

        // MARK: - Font Family Management

        /// Set up subscription to font family changes
        private func setupFontFamilySubscription() {
            fontFamilySubscription = FontManager.shared.fontFamilyDidChange
                .sink { [weak self] _ in
                    self?.applyCurrentFontFamily()
                }
        }

        /// Apply the current font family from FontManager
        func applyCurrentFontFamily() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply font family: app is nil")
                return
            }

            let fontFamily = FontManager.shared.currentFontFamily
            logger.info("Applying font family: \(fontFamily ?? "Swiftty Default")")

            // If font family is nil, we need to remove it from config
            // by writing config without font-family line
            if let family = fontFamily {
                // Apply font family to the config (this replaces config.config with new pointer)
                if config.setFontFamily(family), let newCfg = config.config {
                    // Update all active surfaces individually, respecting theme overrides
                    logger.info("Updating \(self.activeSurfaces.count) active surfaces with new font family")

                    pushConfig(app: app, globalConfig: newCfg)

                    logger.info("Font family applied successfully to app and \(self.activeSurfaces.count) surfaces")
                } else {
                    logger.error("Failed to apply font family: \(family)")
                }
            } else {
                // Reset to default by rewriting config without font-family
                // This forces a config reload with just theme and size
                let currentTheme = ThemeManager.shared.currentTheme
                let currentFontSize = Int(FontManager.shared.currentFontSize)

                if config.setTheme(currentTheme) && config.setFontSize(currentFontSize) {
                    if let currentCfg = config.config {
                        pushConfig(app: app, globalConfig: currentCfg)
                    }

                    logger.info("Reset to Swiftty default font")
                }
            }
        }

        // MARK: - Font Ligatures Management

        /// Set up subscription to ligatures changes
        private func setupLigaturesSubscription() {
            ligaturesSubscription = FontManager.shared.ligaturesDidChange
                .sink { [weak self] _ in
                    self?.applyCurrentLigatures()
                }
        }

        /// Apply the current ligatures setting from FontManager
        func applyCurrentLigatures() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply ligatures: app is nil")
                return
            }

            let ligaturesEnabled = FontManager.shared.ligaturesEnabled
            logger.info("Applying ligatures: \(ligaturesEnabled ? "enabled" : "disabled")")

            // Ligatures are applied via config file, so we need to reload the config
            // by triggering a font size update (which writes the config with ligatures setting)
            let currentFontSize = Int(FontManager.shared.currentFontSize)

            // setFontSize replaces config.config with new pointer
            if config.setFontSize(currentFontSize), let newCfg = config.config {
                // Update all active surfaces individually, respecting theme overrides
                logger.info("Updating \(self.activeSurfaces.count) active surfaces with new ligatures setting")

                pushConfig(app: app, globalConfig: newCfg)

                logger.info("Ligatures applied successfully to app and \(self.activeSurfaces.count) surfaces")
            } else {
                logger.error("Failed to apply ligatures setting")
            }
        }

        // MARK: - Font Features Management

        /// Set up subscription to font feature changes
        private func setupFontFeaturesSubscription() {
            fontFeaturesSubscription = FontManager.shared.fontFeaturesDidChange
                .sink { [weak self] in
                    self?.applyCurrentFontFeatures()
                }
        }

        /// Apply the current font feature settings from FontManager
        func applyCurrentFontFeatures() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply font features: app is nil")
                return
            }

            logger.info("Applying font feature changes")

            // Font features are applied via config file, so reload the config
            // by triggering a font size update (which writes the config with feature settings)
            let currentFontSize = Int(FontManager.shared.currentFontSize)

            if config.setFontSize(currentFontSize), let newCfg = config.config {
                pushConfig(app: app, globalConfig: newCfg)

                logger.info("Font features applied to app and \(self.activeSurfaces.count) surfaces")
            } else {
                logger.error("Failed to apply font features")
            }
        }

        // MARK: - Cell Adjustments Management

        /// Set up subscription to per-font cell adjustment changes
        private func setupCellAdjustmentsSubscription() {
            cellAdjustmentsSubscription = FontManager.shared.cellAdjustmentsDidChange
                .sink { [weak self] in
                    self?.applyCellAdjustments()
                }
        }

        /// Apply the current cell adjustments by rewriting the config file
        /// (which embeds `adjust-cell-width` / `adjust-cell-height` lines)
        /// and notifying the app + active surfaces.
        func applyCellAdjustments() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply cell adjustments: app is nil")
                return
            }

            logger.info("Applying cell adjustment changes")

            // Reuse the font-size reload path: setFontSize rewrites the config
            // file (which now includes adjust-cell-* lines) and reloads it.
            let currentFontSize = Int(FontManager.shared.currentFontSize)

            if config.setFontSize(currentFontSize), let newCfg = config.config {
                pushConfig(app: app, globalConfig: newCfg)

                logger.info("Cell adjustments applied to app and \(self.activeSurfaces.count) surfaces")
            } else {
                logger.error("Failed to apply cell adjustments")
            }
        }

        // MARK: - Transparency Management

        /// Set up subscription to transparency changes
        private func setupTransparencySubscription() {
            #if targetEnvironment(macCatalyst)
            transparencySubscription = TransparencyManager.shared.transparencyDidChange
                .sink { [weak self] in
                    self?.applyCurrentTransparency()
                }
            #endif
        }

        /// Set up listener for power-tier changes
        private func setupPowerSubscription() {
            powerObserver = NotificationCenter.default.addObserver(
                forName: .powerTierChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.applyCurrentFrameRateRange()
                    // Saver tier also downgrades animated cursor blink modes;
                    // reuse the cursor config path to push the change. That
                    // path reloads the whole swiftty config, so only pay for
                    // it when the downgrade itself flips — the adaptive
                    // refresh setting makes full<->reduced transitions
                    // common, and neither of those touches the cursor.
                    let throttle = PowerManager.shared.throttleAnimatedCursor
                    if throttle != self.lastAppliedCursorThrottle {
                        self.lastAppliedCursorThrottle = throttle
                        self.applyCursorConfig()
                    }
                }
            }

            // PowerManager may have broadcast before this observer existed
            // (it is created eagerly at launch), and a missed broadcast is
            // never re-sent, so converge on the current tier now.
            lastAppliedCursorThrottle = PowerManager.shared.throttleAnimatedCursor
            if !activeSurfaces.isEmpty {
                applyCurrentFrameRateRange()
            }
        }

        /// Push the current power-tier frame-rate range to every live
        /// surface. iOS/visionOS only in effect (no-op inside SwifttyKit on
        /// macOS, whose CVDisplayLink always follows the display).
        func applyCurrentFrameRateRange() {
            let range = PowerManager.shared.coreFrameRange
            let surfaceCount = activeSurfaces.count
            for surfacePtr in activeSurfaces {
                swiftty_surface_set_frame_rate_range(surfacePtr, range.min, range.max, range.preferred)
            }
            let tierName = PowerManager.shared.tier.displayName
            logger.info("Applied frame-rate range (\(tierName)) to \(surfaceCount) surfaces")
        }

        private func setupCursorSubscription() {
            cursorObserver = NotificationCenter.default.addObserver(
                forName: .cursorConfigChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.applyCursorConfig()
                }
            }
        }

        /// Apply cursor config changes by reloading config
        func applyCursorConfig() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            logger.info("Cursor config changed, reloading config...")
            reloadGlobalConfig()
        }

        /// Rewrite the generated config from every manager and push it once.
        /// Used after a batched settings change instead of one rewrite per key.
        func reloadGlobalConfig() {
            guard let app = self.app else {
                logger.warning("Cannot reload config: app is nil")
                return
            }
            #if !targetEnvironment(macCatalyst)
            #endif
            let currentTheme = ThemeManager.shared.currentTheme
            guard config.setTheme(currentTheme), let newCfg = config.config else {
                logger.warning("Failed to rewrite config for reload")
                return
            }
            pushConfig(app: app, globalConfig: newCfg)
        }

        /// Set up listener for selection config changes
        private func setupSelectionSubscription() {
            selectionObserver = NotificationCenter.default.addObserver(
                forName: .selectionConfigChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.applySelectionConfig()
                }
            }
        }

        /// Apply selection config changes by reloading config
        func applySelectionConfig() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply selection config: app is nil")
                return
            }

            logger.info("Selection config changed, reloading config...")

            let currentTheme = ThemeManager.shared.currentTheme
            guard config.setTheme(currentTheme), let newCfg = config.config else {
                logger.warning("Failed to set theme for selection config")
                return
            }

            pushConfig(app: app, globalConfig: newCfg)
        }

        /// Apply imported Swiftty keybind config changes by reloading the app config.
        func applyKeybindConfig() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            guard let app = self.app else {
                logger.warning("Cannot apply keybind config: app is nil")
                return
            }

            logger.info("Keybind config changed, reloading config...")

            let currentTheme = ThemeManager.shared.currentTheme
            guard config.setTheme(currentTheme), let newCfg = config.config else {
                logger.warning("Failed to set theme for keybind config")
                return
            }

            pushConfig(app: app, globalConfig: newCfg)
        }

        /// Apply the current transparency settings from TransparencyManager
        func applyCurrentTransparency() {
            guard !SettingsStore.shared.isApplyingBatch else { return }
            #if targetEnvironment(macCatalyst)
            guard let app = self.app else {
                logger.warning("Cannot apply transparency: app is nil")
                return
            }

            let opacity = TransparencyManager.shared.backgroundOpacity
            logger.info("Applying transparency: opacity=\(opacity)")

            // Force config reload by setting both theme and font size
            // This will write the new opacity/blur values to the config file
            // Both setTheme and setFontSize replace config.config with new pointer
            let currentTheme = ThemeManager.shared.currentTheme
            let currentFontSize = Int(FontManager.shared.currentFontSize)

            if config.setTheme(currentTheme) && config.setFontSize(currentFontSize), let newCfg = config.config {
                // Update all active surfaces individually, respecting theme overrides.
                // Override surfaces get a rebuilt config so they pick up the new
                // transparency settings from TransparencyManager.
                logger.info("Updating \(self.activeSurfaces.count) active surfaces with new transparency")

                // Re-apply the window material once the new opacity has landed.
                pushConfig(app: app, globalConfig: newCfg) { [weak self] in
                    self?.applyWindowBlur()
                }

                logger.info("Transparency applied successfully")
            } else {
                logger.error("Failed to apply transparency")
            }
            #endif
        }

        /// Apply the background material to every visible NSWindow (Mac Catalyst only).
        func applyWindowBlur() {
            #if targetEnvironment(macCatalyst)
            applyWindowBlurToAllWindows()
            #endif
        }

        #if targetEnvironment(macCatalyst)

        /// Apply (or remove) blur for a single NSWindow based on the current
        /// transparency settings. Unlike the global sweep this has no
        /// `isVisible` gate: CGS blur is window-server state that sticks once
        /// set on a valid window, so WindowAccessor can call this the moment
        /// it claims a freshly created NSWindow.
        func applyWindowBlur(to nsWindow: NSObject) {
            guard let bridge = MacSupport.bridge else { return }
            // The NSApplication.windows sweep includes the bundle's own glass backdrops.
            guard !bridge.isMaterialBackdrop(nsWindow) else { return }
            let manager = TransparencyManager.shared
            let opacity = manager.backgroundOpacity
            let style = manager.blurStyle

            if style != .standard, opacity < 1.0 {
                bridge.setVisualEffectBlur(false, for: nsWindow)
                bridge.applyGlassBackdrop(nsWindow, clear: style == .glassClear)
                return
            }

            bridge.removeGlassBackdrop(nsWindow)
            bridge.setVisualEffectBlur(opacity < 1.0 && manager.blurEnabled, for: nsWindow)
        }

        /// Re-assert the material on every visible window. Both the CGS and the
        /// NSVisualEffectView paths run the same sweep; `applyWindowBlur(to:)`
        /// decides per window what the current settings call for.
        private func applyWindowBlurToAllWindows() {
            guard let bridge = MacSupport.bridge else {
                logger.warning("Failed to get NSWindows for blur application")
                return
            }
            let windows = bridge.windows
            var appliedCount = 0
            for window in windows where bridge.isVisible(window) {
                applyWindowBlur(to: window)
                appliedCount += 1
            }
            logger.info("Applied window material to \(appliedCount)/\(windows.count) visible window(s)")
        }

        #endif

        /// Register a surface to receive config updates
        /// - Parameter surface: The swiftty_surface_t pointer
        func registerSurface(_ surface: swiftty_surface_t) {
            let ptr = UnsafeMutableRawPointer(mutating: surface)
            activeSurfaces.insert(ptr)
            logger.debug("Registered surface, total active: \(self.activeSurfaces.count)")

            // Sync the current power-tier frame-rate range so surfaces created
            // while throttled (Low Power Mode, manual cap) match the rest.
            let range = PowerManager.shared.coreFrameRange
            if range.max != 0 {
                swiftty_surface_set_frame_rate_range(ptr, range.min, range.max, range.preferred)
            }

            // Notify that surface count changed (triggers window configuration update)
            surfaceCountDidChange.send()
        }

        /// Unregister a surface from config updates
        /// - Parameter surface: The swiftty_surface_t pointer
        func unregisterSurface(_ surface: swiftty_surface_t) {
            let ptr = UnsafeMutableRawPointer(mutating: surface)
            activeSurfaces.remove(ptr)

            // Also remove from window map
            let surfaceId = Int(bitPattern: surface)
            surfaceWindowMap.removeValue(forKey: surfaceId)

            // Notify that surface count changed (triggers window configuration update)
            surfaceCountDidChange.send()

            logger.debug("Unregistered surface, total active: \(self.activeSurfaces.count)")
        }

        // MARK: - Window Association Management

        /// Register a surface's association with a window
        /// - Parameters:
        ///   - surface: The swiftty_surface_t pointer
        ///   - windowId: The window identifier
        func registerSurfaceWindow(_ surface: swiftty_surface_t, windowId: String) {
            let surfaceId = Int(bitPattern: surface)
            surfaceWindowMap[surfaceId] = windowId
            logger.debug("Registered surface \(String(format: "0x%lx", surfaceId)) to window \(windowId)")
        }

        /// Unregister a surface's window association
        /// - Parameter surface: The swiftty_surface_t pointer
        func unregisterSurfaceWindow(_ surface: swiftty_surface_t) {
            let surfaceId = Int(bitPattern: surface)
            surfaceWindowMap.removeValue(forKey: surfaceId)
            logger.debug("Unregistered surface \(String(format: "0x%lx", surfaceId)) from window")
        }

        /// Get the window ID for a surface
        /// - Parameter surface: The swiftty_surface_t pointer
        /// - Returns: The window ID if registered, nil otherwise
        func windowId(for surface: swiftty_surface_t) -> String? {
            let surfaceId = Int(bitPattern: surface)
            return surfaceWindowMap[surfaceId]
        }

        // MARK: - Tab Association Management

        /// Register a surface's association with a tab
        /// - Parameters:
        ///   - surface: The swiftty_surface_t pointer
        ///   - tabId: The tab UUID
        func registerSurfaceTab(_ surface: swiftty_surface_t, tabId: UUID) {
            let surfaceId = Int(bitPattern: surface)
            surfaceTabMap[surfaceId] = tabId
            logger.debug("Registered surface \(String(format: "0x%lx", surfaceId)) to tab \(tabId)")
        }

        /// Unregister a surface's tab association
        /// - Parameter surface: The swiftty_surface_t pointer
        func unregisterSurfaceTab(_ surface: swiftty_surface_t) {
            let surfaceId = Int(bitPattern: surface)
            surfaceTabMap.removeValue(forKey: surfaceId)
            logger.debug("Unregistered surface \(String(format: "0x%lx", surfaceId)) from tab")
        }

        /// Get the tab ID for a surface
        /// - Parameter surface: The swiftty_surface_t pointer
        /// - Returns: The tab UUID if registered, nil otherwise
        func tabId(for surface: swiftty_surface_t) -> UUID? {
            let surfaceId = Int(bitPattern: surface)
            return surfaceTabMap[surfaceId]
        }

        // MARK: - Surface Delegate Management

        func registerSurfaceDelegate(_ surface: swiftty_surface_t, delegate: SwifttyActionDelegate) {
            // Use raw pointer address as key (not ObjectIdentifier which creates new wrapper each time)
            let surfaceId = Int(bitPattern: surface)
            surfaceDelegates[surfaceId] = WeakActionDelegate(delegate: delegate)
        }

        func unregisterSurfaceDelegate(_ surface: swiftty_surface_t) {
            // Use raw pointer address as key (not ObjectIdentifier which creates new wrapper each time)
            let surfaceId = Int(bitPattern: surface)
            surfaceDelegates.removeValue(forKey: surfaceId)
        }

        /// The live `TerminalView` registered as `surface`'s action delegate, or
        /// nil when no live view owns it. Every `TerminalView` registers itself
        /// here for its own surface (it IS the `SwifttyActionDelegate`).
        ///
        /// This resolves a possibly-stale raw `swiftty_surface_t` WITHOUT
        /// dereferencing it — the safe alternative to `swiftty_surface_userdata`
        /// when the pointer was saved elsewhere and may now dangle (e.g. a tmux
        /// pane's `parentSurface`, which outlives its gateway). The map is keyed
        /// by pointer VALUE (no surface deref) and holds the view WEAKLY; its
        /// entry is removed synchronously (main actor) in `TerminalView.cleanup()`
        /// before the surface is freed on a background queue, and the weak ref
        /// independently drops to nil if the view deallocates via the deinit
        /// safety-net. So a non-nil result is always a live view whose surface is
        /// still alive — there is no window where it returns a freed object.
        /// (id=tmux-stale-parent-surface)
        func surfaceView(for surface: swiftty_surface_t) -> TerminalView? {
            surfaceDelegates[Int(bitPattern: surface)]?.delegate as? TerminalView
        }

        // MARK: - Runtime Callbacks

        private nonisolated static func action(_ app: swiftty_app_t, target: swiftty_target_s, action: swiftty_action_s) -> Bool {
            // Look up the App instance using raw pointer address
            let appId = Int(bitPattern: app)

            guard let appInstance = appInstances[appId]?.value else {
                Swiftty.logger.error("Action callback: No App instance found for pointer \(String(format: "0x%lx", appId))")
                return true
            }

            // Drop UI-state action callbacks while backgrounded so the
            // post-resume Task storm doesn't trip the scene-update watchdog
            // (0x8BADF00D). Each gate-safe case checks `isBackgrounded` early
            // and returns. Without this, the surface keeps producing
            // events while backgrounded (servers continue to send prompts,
            // titles, scrollbar updates etc.); each event spawned a
            // `Task { @MainActor in ... }` from the IO thread; on resume,
            // hundreds-to-thousands of those Tasks flushed at once and
            // bogged down the main thread for >30s. Latest-state-wins is the
            // correct invariant here — the next post-resume event resyncs.
            //
            // Exceptions (NOT gated):
            //   - DESKTOP_NOTIFICATION: user-visible alert; must fire while
            //     backgrounded so notifications go through.
            //   - MOUSE_OVER_LINK: synchronous call, no Task spawned.
            //   - OPEN_URL: rare and user-initiated.
            let isBackgrounded = Swiftty.isAppBackgroundedAtomic

            // Handle specific actions
            switch action.tag {
            case SWIFTTY_ACTION_SURFACE_CONTENT_CHANGED:
                if isBackgrounded { return true }
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surfaceId = Int(bitPattern: target.target.surface)
                    Task { @MainActor in
                        appInstance.surfaceDelegates[surfaceId]?.delegate?
                            .handleSurfaceContentChanged()
                    }
                }
                return true

            case SWIFTTY_ACTION_SET_TITLE:
                if isBackgrounded { return true }
                let titleAction = action.action.set_title

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    guard let titleCStr = titleAction.title else { return true }
                    guard let title = String(cString: titleCStr, encoding: .utf8) else { return true }

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleTitleChange(title)
                        } else {
                            Swiftty.logger.error("No delegate found for set_title action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Set title action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_TMUX_RECONCILE:
                // tmux control mode topology reconcile. The payload is an
                // opaque TmuxReconcilePayload retained for us; we own it and
                // must free it with swiftty_tmux_reconcile_free. The op batch
                // carries live viewer pane references, so batches are applied
                // in arrival order by the surface's TmuxController, which maps
                // windows to tabs and panes to splits.
                if target.tag == SWIFTTY_TARGET_SURFACE,
                   let payload = action.action.tmux_reconcile {
                    let surface = target.target.surface
                    // Decode synchronously (reads the payload's op accessors).
                    // Do NOT free the payload yet: it holds viewer-pane refcounts
                    // that keep the panes whose
                    // raw pointers the ops carry alive until applyTmuxReconcile has
                    // used them on the main actor. Free it AFTER apply.
                    let ops = TmuxReconcileDecoder.decode(payload)
                    // Off-main anchor (runs on the swiftty tick thread): keeps
                    // firing even if the main actor wedges, so a "decoded" line
                    // with no following "apply begin" is the wedge fingerprint.
                    // Route to the viewer-owner surface's TerminalView, which
                    // owns the per-connection TmuxController. The payload's
                    // refcounts keep the viewer pane boxes alive across this hop,
                    // so applying on the next main-actor turn is safe.
                    if let userdata = swiftty_surface_userdata(surface) {
                        // Take a STRONG ref to the owner here, while the surface
                        // (and its userdata owner) is still alive, and carry it
                        // across the hop. The payload refcounts protect the viewer
                        // panes but NOT this Swift owner; closing the tab/surface
                        // before the task runs would otherwise use freed memory.
                        let owner = Unmanaged<Swiftty.TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                        let delivery = TmuxReconcileDelivery(
                            owner: owner, ops: ops, payload: payload,
                            generation: swiftty_tmux_reconcile_generation(payload))
                        // Serialize the apply in ARRIVAL order. The action callback
                        // is off the main actor and a bare per-batch Task has no
                        // cross-task ordering guarantee, so a stale full-topology
                        // snapshot could otherwise land after a newer one and
                        // resurrect a closed pane / stale layout. See
                        // id=tmux-reconcile-serialize.
                        TmuxReconcileSerializer.shared.enqueue {
                            delivery.owner.applyTmuxReconcile(delivery.ops, generation: delivery.generation)
                            // Release the payload (and its viewer-pane holds) only
                            // now that apply has consumed the raw pointers.
                            swiftty_tmux_reconcile_free(delivery.payload)
                        }
                    } else {
                        // No owner surface to apply to: nothing will use the
                        // pointers, so free now (releases the pane holds).
                        swiftty_tmux_reconcile_free(payload)
                    }
                }
                return true

            case SWIFTTY_ACTION_TMUX_PANE_SYNCED:
                // A pane's captured contents were replayed: visible-pane sync
                // evidence for recovery readiness (mobile-connectivity §8.5).
                // Serialized with reconcile applies so it is judged against
                // the topology that was current when the viewer emitted it.
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let info = action.action.tmux_pane_synced
                    if let userdata = swiftty_surface_userdata(target.target.surface) {
                        let owner = Unmanaged<Swiftty.TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                        let pane = Int(clamping: info.pane_id)
                        let generation = info.generation
                        TmuxReconcileSerializer.shared.enqueue {
                            owner.tmuxController?.notePaneSynced(pane, generation: generation)
                        }
                    }
                }
                return true

            case SWIFTTY_ACTION_TMUX_COMMAND_RESPONSE:
                // Response to an app-issued tmux query (session dashboard).
                // The body pointer is borrowed for THIS callback only — copy
                // it here on the callback thread, then hop. Tag-keyed (no
                // ordering requirement), so a bare Task is fine; do NOT route
                // through TmuxReconcileSerializer (would add latency behind
                // topology applies). Never gated on isBackgrounded: a pending
                // continuation must always resolve.
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let response = action.action.tmux_command_response
                    let body: String
                    if let ptr = response.body, response.body_len > 0 {
                        body = String(decoding: UnsafeBufferPointer(start: ptr, count: Int(response.body_len)), as: UTF8.self)
                    } else {
                        body = ""
                    }
                    let reply = TmuxCommandReply(tag: response.tag, body: body, isError: response.is_err)
                    if let userdata = swiftty_surface_userdata(surface) {
                        let owner = Unmanaged<Swiftty.TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                        Task { @MainActor in
                            owner.tmuxController?.handleCommandReply(reply)
                        }
                    }
                }
                return true

            case SWIFTTY_ACTION_TMUX_SESSIONS_CHANGED:
                // Session list churn on the tmux server: nudge the dashboard.
                // Rare event; cheap notification; not gated on isBackgrounded
                // (the dashboard also refreshes on appear, so a dropped nudge
                // would only matter mid-display anyway).
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    if let userdata = swiftty_surface_userdata(surface) {
                        let owner = Unmanaged<Swiftty.TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                        Task { @MainActor in
                            owner.tmuxController?.noteSessionsChanged()
                        }
                    }
                }
                return true

            case SWIFTTY_ACTION_TMUX_SESSION_CHANGED:
                // The session this gateway is attached to (startup / switch /
                // rename). Copy the borrowed name on the callback thread.
                // Not gated on isBackgrounded: it drives the per-connection
                // reconnect-name persistence, which must stay correct.
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let info = action.action.tmux_session_changed
                    let name: String
                    if let ptr = info.name, info.name_len > 0 {
                        name = String(decoding: UnsafeBufferPointer(start: ptr, count: Int(info.name_len)), as: UTF8.self)
                    } else {
                        name = ""
                    }
                    let sessionId = Int(clamping: info.session_id)
                    let generation = info.generation
                    if let userdata = swiftty_surface_userdata(surface) {
                        let owner = Unmanaged<Swiftty.TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                        Task { @MainActor in
                            if let controller = owner.tmuxController {
                                controller.updateCurrentSession(id: sessionId, name: name, generation: generation)
                            } else {
                                // Startup ordering: the identity arrives before
                                // the first reconcile creates the controller.
                                // Stash it; applyTmuxReconcile flushes it.
                                // ROOTSHELL-TMUX (id=tmux-session-info-stash)
                                owner.pendingTmuxSessionInfo = (id: sessionId, name: name, generation: generation)
                            }
                        }
                    }
                }
                return true

            case SWIFTTY_ACTION_PWD:
                if isBackgrounded { return true }
                let pwdAction = action.action.pwd

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    guard let pwdCStr = pwdAction.pwd else { return true }
                    guard let pwd = String(cString: pwdCStr, encoding: .utf8) else { return true }

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handlePwdChange(pwd)
                        } else {
                            Swiftty.logger.error("No delegate found for pwd action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("PWD action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_RING_BELL:
                if isBackgrounded { return true }
                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleBell()
                        } else {
                            Swiftty.logger.error("No delegate found for ring_bell action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Ring bell action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_MOUSE_SHAPE:
                if isBackgrounded { return true }
                let mouseShape = action.action.mouse_shape

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let shape = Int(mouseShape.rawValue)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleMouseShape(shape: shape)
                        } else {
                            Swiftty.logger.error("No delegate found for mouse_shape action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Mouse shape action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_MOUSE_VISIBILITY:
                if isBackgrounded { return true }
                let visibility = action.action.mouse_visibility

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let visible = (visibility == SWIFTTY_MOUSE_VISIBLE)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleMouseVisibility(visible: visible)
                        } else {
                            Swiftty.logger.error("No delegate found for mouse_visibility action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Mouse visibility action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_DESKTOP_NOTIFICATION:
                let notificationAction = action.action.desktop_notification

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let title = notificationAction.title != nil ? String(cString: notificationAction.title!, encoding: .utf8) : nil
                    let body = notificationAction.body != nil ? String(cString: notificationAction.body!, encoding: .utf8) : nil

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleDesktopNotification(title: title, body: body)
                        } else {
                            Swiftty.logger.error("No delegate found for desktop_notification action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Desktop notification action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_SCROLLBAR:
                if isBackgrounded { return true }
                let scrollbar = action.action.scrollbar

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    // Use raw pointer address as key (not ObjectIdentifier which creates new wrapper each time)
                    let surfaceId = Int(bitPattern: surface)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleScrollbar(
                                total: scrollbar.total,
                                offset: scrollbar.offset,
                                len: scrollbar.len
                            )
                        } else {
                            Swiftty.logger.error("No delegate found for surface \(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Scrollbar action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_CELL_SIZE:
                if isBackgrounded { return true }
                let cellSize = action.action.cell_size

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleCellSizeChange(
                                width: CGFloat(cellSize.width),
                                height: CGFloat(cellSize.height)
                            )
                        } else {
                            Swiftty.logger.error("No delegate found for cell size action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Cell size action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_PTY_RESIZE:
                // Delivered while backgrounded too: updatePTYSize applies the
                // suppression gate itself, as the set_size hop used to.
                let resize = action.action.pty_resize
                guard target.tag == SWIFTTY_TARGET_SURFACE else { return true }
                let surfaceId = Int(bitPattern: target.target.surface)
                Task { @MainActor in
                    appInstance.surfaceDelegates[surfaceId]?.delegate?.handlePTYResize(
                        rows: Int(resize.rows), cols: Int(resize.cols),
                        widthPx: Int(resize.width_px), heightPx: Int(resize.height_px)
                    )
                }
                return true

            case SWIFTTY_ACTION_PROGRESS_REPORT:
                if isBackgrounded { return true }
                let progressReportAction = action.action.progress_report

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let report = Swiftty.Action.ProgressReport(c: progressReportAction)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleProgressReport(report)
                        } else {
                            Swiftty.logger.error("No delegate found for progress_report action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Progress report action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_START_SEARCH:
                if isBackgrounded { return true }
                let startSearchAction = action.action.start_search

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let startSearch = Swiftty.Action.StartSearch(c: startSearchAction)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleStartSearch(startSearch)
                        } else {
                            Swiftty.logger.error("No delegate found for start_search action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Start search action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_END_SEARCH:
                if isBackgrounded { return true }
                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleEndSearch()
                        } else {
                            Swiftty.logger.error("No delegate found for end_search action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("End search action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_SEARCH_TOTAL:
                if isBackgrounded { return true }
                let searchTotal = action.action.search_total

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let total: UInt? = searchTotal.total >= 0 ? UInt(searchTotal.total) : nil

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleSearchTotal(total)
                        } else {
                            Swiftty.logger.error("No delegate found for search_total action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Search total action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_SEARCH_SELECTED:
                if isBackgrounded { return true }
                let searchSelected = action.action.search_selected

                // Route to the appropriate surface delegate
                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let selected: UInt? = searchSelected.selected >= 0 ? UInt(searchSelected.selected) : nil

                    Task { @MainActor in
                        if let delegate = appInstance.surfaceDelegates[surfaceId]?.delegate {
                            delegate.handleSearchSelected(selected)
                        } else {
                            Swiftty.logger.error("No delegate found for search_selected action, surfaceId=\(String(format: "0x%lx", surfaceId))")
                        }
                    }
                } else {
                    Swiftty.logger.warning("Search selected action but target is not SURFACE (tag=\(target.tag.rawValue))")
                }

                return true

            case SWIFTTY_ACTION_MOUSE_OVER_LINK:
                let mouseOverLink = action.action.mouse_over_link

                if target.tag == SWIFTTY_TARGET_SURFACE {
                    let surface = target.target.surface
                    let surfaceId = Int(bitPattern: surface)

                    let url: String?
                    if let urlPtr = mouseOverLink.url, mouseOverLink.len > 0 {
                        let buf = UnsafeRawBufferPointer(start: urlPtr, count: Int(mouseOverLink.len))
                        url = String(bytes: buf, encoding: .utf8)
                    } else {
                        url = nil
                    }

                    // Call delegate synchronously — probeForLink() depends on this
                    // being resolved before swiftty_surface_mouse_pos() returns.
                    // That call is made on the main thread; a mouse position
                    // sent from the surface API queue hops instead.
                    Self.onMain {
                        appInstance.surfaceDelegates[surfaceId]?.delegate?.handleMouseOverLink(url: url)
                    }
                }

                return true

            case SWIFTTY_ACTION_OPEN_URL:
                let openUrl = action.action.open_url
                guard let urlPtr = openUrl.url, openUrl.len > 0 else { return true }
                let buf = UnsafeRawBufferPointer(start: urlPtr, count: Int(openUrl.len))
                let urlString = String(bytes: buf, encoding: .utf8) ?? ""

                Task { @MainActor in
                    guard let url = URL(string: urlString) else { return }
                    await UIApplication.shared.open(url)
                }

                return true

            default:
                return true
            }
        }

        private nonisolated static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: swiftty_clipboard_e,
            state: UnsafeMutableRawPointer?
        ) -> Bool {
            #if os(iOS) || os(visionOS)
            // Extract TerminalView from userdata (same pattern as macOS SurfaceView)
            // For clipboard operations, Swiftty passes the surface's userdata, not the app's
            guard let userdata = userdata else {
                Swiftty.logger.warning("readClipboard called with nil userdata")
                return false
            }
            let terminalView = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
            nonisolated(unsafe) let state = state

            // Complete the clipboard request with the data
            // This triggers Swiftty's paste encoding (bracketed paste, newline conversion, etc.)
            @MainActor func complete() -> Bool {
                guard let surface = terminalView.surface else {
                    Swiftty.logger.warning("readClipboard: surface is nil")
                    return false
                }
                // Return false if there is no text-like clipboard content so
                // performable paste bindings can pass through to the terminal.
                guard let text = UIPasteboard.general.opinionatedStringContents() else {
                    return false
                }
                text.withCString { ptr in
                    swiftty_surface_complete_clipboard_request(surface, ptr, state, false)
                }
                return true
            }

            if Thread.isMainThread {
                return MainActor.assumeIsolated { complete() }
            }
            // Off the main thread (a paste binding sent from the surface API
            // queue): UIPasteboard and the view are main-actor state, so the
            // request completes asynchronously, which Swiftty supports. The
            // binding is treated as performed.
            Task { @MainActor in _ = complete() }
            return true
            #else
            return false
            #endif
        }

        private nonisolated static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            string: UnsafePointer<CChar>?,
            state: UnsafeMutableRawPointer?,
            request: swiftty_clipboard_request_e
        ) {
            #if os(iOS) || os(visionOS)
            // Swiftty detected potentially unsafe paste (e.g., multi-line content)
            // and is asking for confirmation.
            // In a mobile app context, we auto-confirm since the user's intent is clear
            // (whether via UI action or OSC-52 request from a terminal app they're running).
            guard let userdata = userdata else { return }
            guard let string = string else { return }

            let terminalView = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
            // `string` is only valid for this call; copy it before any hop.
            let text = String(cString: string)
            nonisolated(unsafe) let state = state

            // Complete the request with confirmation (last parameter = true)
            Self.onMain {
                guard let surface = terminalView.surface else { return }
                text.withCString { ptr in
                    swiftty_surface_complete_clipboard_request(surface, ptr, state, true)
                }
            }
            #endif
        }

        private nonisolated static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: swiftty_clipboard_e,
            content: UnsafePointer<swiftty_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            #if os(iOS) || os(visionOS)
            guard let content = content, len > 0 else { return }

            // Swiftty can emit multiple representations for a single copy (e.g.
            // `.mixed` emits text/plain + text/html). Route each to its proper
            // UIPasteboard UTI so HTML markup never lands in the plain-text slot.
            // Keep the callback payload Sendable so off-main UIKit and
            // observable state work can be deferred until after Swiftty
            // releases its surface mutex.
            var item: [String: String] = [:]
            for i in 0..<len {
                let entry = content[i]
                guard let mimePtr = entry.mime, let dataPtr = entry.data else { continue }
                let mime = String(cString: mimePtr)
                let data = String(cString: dataPtr)
                guard !data.isEmpty else { continue }
                guard let uti = Self.pasteboardUTI(forMime: mime) else { continue }
                item[uti] = data
            }

            guard !item.isEmpty else { return }

            // The selection clipboard means
            // copy-on-select; anything else arriving here is an OSC 52 write
            // from a program running in the session (explicit Copy never
            // routes through this callback on iOS).
            //
            // Copy-on-select invokes this callback on the surface API queue while
            // still holding the surface mutex. UIPasteboard notifications may
            // synchronously target the main queue, while the main thread can be
            // waiting on that same mutex for a surface query. Defer that off-main
            // path. Main-thread callbacks must update the pasteboard synchronously:
            // Swiftty drains ordered OSC 52 writes and reads during one app tick, so
            // a following read must see this write before the callback returns.
            //
            // Resolve the surface's userdata to a strong TerminalView reference
            // here (a thread-safe retain / pointer arithmetic), then read its
            // @MainActor-isolated `title`/`connectionConfig` INSIDE the main-actor
            // task. Capturing the strong reference keeps the view alive across the
            // hop; the property reads never happen off the main actor.
            let text = item[UTType.utf8PlainText.identifier]
            _ = (location == SWIFTTY_CLIPBOARD_SELECTION)
            _ = text.flatMap { _ in
                userdata.map {
                    Unmanaged<TerminalView>.fromOpaque($0).takeUnretainedValue()
                }
            }

            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    Self.applyPasteboardItem(item)
                }
            } else {
                Task { @MainActor in
                    Self.applyPasteboardItem(item)
                }
            }
            #endif
        }

        #if os(iOS) || os(visionOS)
        @MainActor
        private static func applyPasteboardItem(_ item: [String: String]) {
            var pasteboardItem: [String: Any] = [:]
            for (uti, value) in item {
                pasteboardItem[uti] = value
            }
            UIPasteboard.general.items = [pasteboardItem]
        }

        /// Map a Swiftty clipboard mime type to the corresponding UIPasteboard UTI.
        /// Mirrors the macOS mapping in `NSPasteboard+Extension.swift`.
        private nonisolated static func pasteboardUTI(forMime mime: String) -> String? {
            switch mime {
            case "text/plain":
                return UTType.utf8PlainText.identifier
            case "text/html":
                return UTType.html.identifier
            default:
                return UTType(mimeType: mime)?.identifier
            }
        }
        #endif

        /// Built outside the main-actor `init` so the callback closures are
        /// nonisolated. Swiftty invokes them on whichever thread called into it,
        /// including the surface API queue; closures formed inside `init` would
        /// inherit main-actor isolation and trap there under Swift 6.
        private nonisolated static func makeRuntimeConfig(userdata: UnsafeMutableRawPointer) -> swiftty_runtime_config_s {
            swiftty_runtime_config_s(
                userdata: userdata,
                supports_selection_clipboard: true,
                action_cb: { app, target, action in return App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state in App.readClipboard(userdata, location: loc, state: state) },
                confirm_read_clipboard_cb: { userdata, str, state, request in
                    App.confirmReadClipboard(userdata, string: str, state: state, request: request)
                },
                write_clipboard_cb: { userdata, loc, content, len, confirm in
                    App.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
                },
                close_surface_cb: { userdata, processAlive in
                    App.closeSurface(userdata, processAlive: processAlive)
                }
            )
        }

        /// Runs `body` synchronously when a Swiftty callback arrives on the main
        /// thread, and on the next main-actor turn when it arrives on the
        /// surface API queue (config pushes, key and mouse events sent there).
        private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
            if Thread.isMainThread {
                MainActor.assumeIsolated(body)
            } else {
                Task { @MainActor in body() }
            }
        }

        /// Required by `swiftty_runtime_config_s`, but intentionally a no-op:
        /// every surface is created with `use_external_io`, so SwifttyKit owns no
        /// child process whose exit could raise this. Tab/pane teardown is driven
        /// entirely by the app's own session-end path posting `.closeSplit`.
        private nonisolated static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {}
    }
}
