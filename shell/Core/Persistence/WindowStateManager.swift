//
//  WindowStateManager.swift
//  shell
//
//  Manages persistence of window/tab state for app restoration.
//  Saves state periodically and on app background, restores on launch.
//

import Foundation
import UIKit
import os

/// Manages persistence of window/tab state for app restoration
@MainActor
final class WindowStateManager {
    static let shared = WindowStateManager()

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "WindowStateManager")

    // MARK: - Settings

    /// UserDefaults key for session persistence enabled setting
    static let sessionPersistenceEnabledKey = "sessionPersistenceEnabled"

    /// Whether session persistence is enabled (default: true)
    static var isSessionPersistenceEnabled: Bool {
        SettingsStore.shared.value(Settings.SessionRestore.sessionPersistence)
    }

    // MARK: - Configuration

    /// State file name
    private let stateFileName = "window_state.json"

    /// Maximum age of state before discarding (7 days)
    private let maxStateAgeDays: Double = 7

    /// State file URL (Documents/.ghostty/window_state.json)
    private var stateFileURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        return ghosttyDir.appendingPathComponent(stateFileName)
    }

    // MARK: - State

    /// Pending restoration state (set after loading, cleared after all windows restored)
    private(set) var pendingRestoration: AppWindowState?

    // MARK: - Internal State

    /// Track which windows have been restored to avoid double-restore
    private var restoredWindowIds: Set<String> = []

    /// Registered windows and their state provider closures
    private var registeredWindows: [String: @MainActor () -> SerializableWindow?] = [:]

    /// Saved windows we have asked Catalyst to open a scene for, so a second
    /// pass does not request the same window twice.
    private var requestedWindowIds: Set<String> = []

    /// Saved windows bound to a connecting scene at `willConnectTo`, in connect
    /// order, waiting for that scene's `MainView` to claim them. A scene is
    /// bound to exactly one saved window, so the same id drives both the
    /// pre-size and the eventual claim; they can no longer disagree.
    private var connectingWindowIds: [String] = []

    /// Bounds same-launch retries when Catalyst rejects scene activation.
    /// Reset after a window successfully claims saved state.
    private var regularRestorationActivationRetryCount = 0
    private let maxRegularRestorationActivationRetries = 3

    /// Last save time (to debounce rapid saves)
    private var lastSaveTime: Date?

    /// Minimum interval between saves (5 seconds)
    private let minSaveInterval: TimeInterval = 5.0

    /// Periodic autosave interval (30 seconds)
    private let autosaveInterval: TimeInterval = 30.0

    /// Timer for periodic autosaves while windows are open
    private var autosaveTimer: Timer?

    /// App lifecycle observers used to keep autosave off the main runloop while backgrounded.
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Whether we've attempted to load state (to avoid multiple attempts)
    private var hasAttemptedLoad: Bool = false

    /// Whether this launch has ever observed a non-empty serializable window
    /// state. Flipped to true the first time `saveAllState` or `gatherState`
    /// produces a non-empty `windows` array. Used to distinguish a transient
    /// empty state mid-restoration (must NOT clear the saved file — that was
    /// the launch-then-quit data-loss bug) from a user-driven close-all
    /// (legitimate, should clear).
    private var hasObservedNonEmptyState: Bool = false

    /// True once this launch has seen a real populated window state. MainView's
    /// background-transition code consults this to decide whether a `nil`
    /// `gatherState()` result means "user closed everything" (clear the file)
    /// or "restoration hasn't run yet" (preserve the file).
    var hasObservedNonEmptyStateThisLaunch: Bool { hasObservedNonEmptyState }

    /// Mark that this launch has materialized a populated window state.
    ///
    /// Called by `MainView.restoreWindowState` immediately after at least one
    /// tab has been appended. Setting the flag here (rather than waiting for
    /// the next `saveAllState` / `gatherState` to flip it implicitly) closes
    /// a window between restoration completing and the first save firing —
    /// without it, a user who closes the final Catalyst window the moment
    /// after restoration would see `unregisterWindow` skip the clear and
    /// resurrect the closed window on the next launch.
    ///
    /// Deliberately not invoked from `getPendingState`: that runs before
    /// restoration can fail (e.g. `buildNode` returning nil for every tab),
    /// and we want a 0-tab restoration to leave the file in place so the next
    /// launch can retry.
    func markPopulatedStateMaterialized() {
        hasObservedNonEmptyState = true
    }

    private init() {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.stopAutosaveTimer()
                }
            }
        )

        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    ForegroundActivationGate.shared.runWhenSafe(
                        reason: "windowState.autosaveTimer",
                        timeoutPolicy: .fireIfNotBackgrounded
                    ) {
                        self?.startAutosaveTimerIfNeeded()
                    }
                }
            }
        )
    }

    // MARK: - Window Registration

    /// Register a window for state saving
    /// The closure captures the MainView's ability to serialize its current state
    func registerWindow(
        windowId: String,
        stateProvider: @escaping @MainActor () -> SerializableWindow?
    ) {
        registeredWindows[windowId] = stateProvider
        Self.logger.info("Registered window \(windowId) for state saving (\(self.registeredWindows.count) total)")
        startAutosaveTimerIfNeeded()
    }

    /// Unregister a window (call on window close)
    func unregisterWindow(windowId: String) {
        registeredWindows.removeValue(forKey: windowId)
        Self.logger.info("Unregistered window \(windowId) (\(self.registeredWindows.count) remaining)")

        // Save remaining windows when one closes. Defer to the next runloop
        // tick so the synchronous state-gathering walk (provider() calls
        // serializing terminals/tabs) doesn't run inside a scene-update
        // transaction. MainView calls this from window/scene teardown; a
        // one-tick delay keeps the gather off the FrontBoard ACK path.
        // App-backgrounding has its own explicit save in MainViewLifecycle so
        // a missed save here is benign.
        if !registeredWindows.isEmpty {
            Task { @MainActor [weak self] in
                self?.saveAllState()
            }
        } else {
            #if targetEnvironment(macCatalyst)
            if let pendingState = unrestoredPendingState() {
                Self.logger.info("Last live window unregistered while pending saved windows remain — saving pending-only state")
                Self.writeStateToDisk(pendingState)
                stopAutosaveTimer()
                return
            }

            // Catalyst: scene phase changes don't reliably fire on last-window
            // close (no scene remains to deliver the phase change), so the
            // BG-transition path can't be the only cleanup hook. iOS does NOT
            // take this branch — UIScene.didDisconnectNotification fires on
            // force-quit (and on memory-pressure scene reclaim while
            // backgrounded), and clearing here would wipe valid sessions.
            // Pre-restoration teardown (`hasObservedNonEmptyState == false`)
            // still leaves the file alone to match the launch-then-quit
            // data-loss fix.
            if hasObservedNonEmptyState && Self.isSessionPersistenceEnabled {
                Self.logger.info("Last window unregistered after observed populated state — clearing saved state")
                clearSavedState()
            }
            #endif
            stopAutosaveTimer()
        }
    }

    // MARK: - Saving State

    /// Save all window states to disk
    func saveAllState() {
        // Check if session persistence is enabled
        guard Self.isSessionPersistenceEnabled else {
            Self.logger.debug("Session persistence disabled, skipping save")
            return
        }

        // Debounce rapid saves
        if let lastSave = lastSaveTime,
           Date().timeIntervalSince(lastSave) < minSaveInterval {
            Self.logger.debug("Skipping save - too soon since last save")
            return
        }

        guard !registeredWindows.isEmpty else {
            // Distinguish transient pre-restoration emptiness from a real
            // user-driven close-all. If we've already observed a populated
            // state in this launch, the empty registration is the user
            // closing the last window and we should clear. Otherwise it's a
            // pre-restoration blip and the file must stay (the launch-then-
            // quit data-loss bug).
            if hasObservedNonEmptyState {
                Self.logger.info("All windows unregistered after observed populated state — clearing saved state")
                clearSavedState()
            } else {
                Self.logger.debug("No windows registered yet (pre-restoration), leaving state file intact")
            }
            return
        }

        Self.logger.info("Saving state for \(self.registeredWindows.count) registered windows")

        let liveWindows = registeredWindows.compactMap { (id, provider) -> SerializableWindow? in
            guard let window = provider() else {
                Self.logger.warning("Failed to get state for window \(id)")
                return nil
            }
            return window
        }
        let windows = includingUnrestoredPendingWindows(liveWindows)

        guard !windows.isEmpty else {
            // All providers returned nil. If we've previously observed a
            // populated state this launch, the user has closed every tab and
            // we should clear. Otherwise restoration simply hasn't completed
            // yet and we must preserve the file.
            if hasObservedNonEmptyState {
                Self.logger.info("All providers returned nil after observed populated state — clearing saved state")
                clearSavedState()
            } else {
                Self.logger.debug("No valid window states yet (pre-restoration), leaving state file intact")
            }
            return
        }

        // We have live populated state this tick — record it so future empty
        // ticks can be interpreted as user-driven close-all. Pending-only
        // windows are preserved snapshots, not newly materialized live state.
        if !liveWindows.isEmpty {
            hasObservedNonEmptyState = true
        }

        let state = AppWindowState(windows: windows)

        // Dispatch JSON encode + atomic file write off the main actor. The
        // writeQueue inside writeStateToDisk serializes concurrent writers and
        // rejects stale snapshots via its high-water mark. Background transitions
        // use MainViewLifecycle's explicit background task; autosave must not ask
        // UIKit for one during scene updates.
        Task.detached(priority: .utility) {
            let didWrite = Self.writeStateToDisk(state)

            // Only advance the debounce timestamp after a successful write,
            // so a transient I/O failure lets the next save retry immediately
            // rather than being suppressed for minSaveInterval.
            if didWrite {
                await MainActor.run {
                    Self.shared.lastSaveTime = Date()
                }
            }
        }
    }

    /// Delete the saved-state file from disk.
    ///
    /// Called only from legitimate-clear paths:
    ///   - `loadSavedState` on decode failure, version mismatch, or > 7-day
    ///     staleness;
    ///   - the future user-explicit "clear saved sessions" action.
    ///
    /// **Not** called from routine save / load / quit paths. Atomic writes in
    /// `writeStateToDisk` already replace the file safely, and proactive
    /// deletion on the routine path was the cause of the launch-then-quit
    /// data-loss bug. Crash-loop protection uses `quarantineSavedState` (move
    /// aside, not delete), which does not go through this function.
    ///
    /// Coordinated with background writers via `writeQueue` so that in-flight
    /// detached tasks cannot resurrect the file after it is removed.
    func clearSavedState() {
        let url = stateFileURL
        Self.writeQueue.sync {
            // Advance high-water mark to reject any in-flight snapshots.
            // Reset to distantPast would let them through; Date() ensures
            // only snapshots gathered after this clear can write.
            Self._lastWrittenAt = Date()

            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    Self.logger.info("Cleared saved state file")
                }
            } catch {
                Self.logger.warning("Failed to clear state file: \(error.localizedDescription)")
            }
        }
    }

    /// Move the saved state file aside to a quarantine path. Used when
    /// repeated skip cycles indicate the state itself is causing crashes,
    /// so the next launch starts fresh while the file remains available
    /// for manual recovery if desired.
    func quarantineSavedState() {
        let url = stateFileURL
        let quarantineURL = url.deletingPathExtension().appendingPathExtension("quarantined.json")
        Self.writeQueue.sync {
            // Advance high-water mark so in-flight saves don't resurrect the file.
            Self._lastWrittenAt = Date()

            guard FileManager.default.fileExists(atPath: url.path) else {
                Self.logger.info("No state file to quarantine")
                return
            }

            do {
                if FileManager.default.fileExists(atPath: quarantineURL.path) {
                    try FileManager.default.removeItem(at: quarantineURL)
                }
                try FileManager.default.moveItem(at: url, to: quarantineURL)
                Self.logger.warning("Quarantined saved state to \(quarantineURL.lastPathComponent)")
            } catch {
                Self.logger.error("Failed to quarantine state file: \(error.localizedDescription) — falling back to delete")
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Loading State

    /// Idempotently load saved state from disk, sharing the same `hasAttemptedLoad`
    /// guard `getPendingState` uses so an eager call (e.g. from
    /// `didFinishLaunchingWithOptions`, before the first scene connects) does not
    /// cause `getPendingState` to load a *second* time — a re-load resets
    /// `restoredWindowIds` / the scene bindings and would
    /// wipe in-flight restoration progress. Call this early so `hasPendingRestoration`
    /// is authoritative at `scene(_:willConnectTo:)` time (the Catalyst geometry gate).
    func ensureStateLoaded() {
        guard !hasAttemptedLoad else { return }
        hasAttemptedLoad = true
        _ = loadSavedState()
    }

    /// Load saved state from disk (call once at app launch)
    @discardableResult
    func loadSavedState() -> AppWindowState? {

        guard FileManager.default.fileExists(atPath: stateFileURL.path) else {
            Self.logger.info("No saved state file found")
            ScrollbackPersistenceManager.shared.cleanupOrphanedFiles(activeTerminalIds: [])
            return nil
        }

        do {
            let data = try Data(contentsOf: stateFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(AppWindowState.self, from: data)

            // Version check
            guard state.version == AppWindowState.currentVersion else {
                Self.logger.warning("State version mismatch: \(state.version) vs \(AppWindowState.currentVersion), discarding")
                clearSavedState()
                ScrollbackPersistenceManager.shared.cleanupOrphanedFiles(activeTerminalIds: [])
                return nil
            }

            // Staleness check
            let ageInDays = Date().timeIntervalSince(state.savedAt) / 86400
            if ageInDays > maxStateAgeDays {
                Self.logger.info("Saved state is \(Int(ageInDays)) days old (max: \(Int(self.maxStateAgeDays))), discarding")
                clearSavedState()
                ScrollbackPersistenceManager.shared.cleanupOrphanedFiles(activeTerminalIds: [])
                return nil
            }

            let activeTerminalIds = state.allTerminalIds

            // Clean up orphaned scrollback files (terminals not in saved state)
            ScrollbackPersistenceManager.shared.cleanupOrphanedFiles(activeTerminalIds: activeTerminalIds)

            Self.logger.info("Loaded saved state: \(state.summary), saved \(self.formatAge(state.savedAt)) ago")


            pendingRestoration = state
            restoredWindowIds.removeAll()
            requestedWindowIds.removeAll()
            connectingWindowIds.removeAll()
            regularRestorationActivationRetryCount = 0
            return state

        } catch {
            Self.logger.error("Failed to load saved state: \(error.localizedDescription)")
            clearSavedState()
            ScrollbackPersistenceManager.shared.cleanupOrphanedFiles(activeTerminalIds: [])
            return nil
        }
    }

    /// Get pending state for this window and mark it restored.
    ///
    /// A window normally matches by id: `@SceneStorage` restores `windowId` with
    /// the scene session, so a returning window asks for exactly its own state.
    /// A scene the app opened itself for restoration has no stored id, so
    /// `willConnectTo` bound one to it up front; that binding is consumed here in
    /// connect order.
    func getPendingState(forWindowId windowId: String) -> SerializableWindow? {
        // Check if session persistence is enabled
        guard Self.isSessionPersistenceEnabled else {
            Self.logger.debug("Session persistence disabled, skipping restoration")
            ScrollbackPersistenceManager.shared.cleanupOrphanedFiles(activeTerminalIds: [])
            return nil
        }

        // Check restoration health first - skip if repeated failures detected.
        switch RestorationHealthTracker.shared.evaluateRestoration() {
        case .proceed:
            break
        case .skipQuarantineState:
            Self.logger.warning("Quarantining saved state after repeated restoration failures - state appears to be the cause")
            quarantineSavedState()
            return nil
        }

        // Lazily load state on first access (no-op if an eager launch load already ran).
        ensureStateLoaded()

        guard let state = pendingRestoration,
              !restoredWindowIds.contains(windowId) else {
            return nil
        }

        let window = state.windows.first { $0.id == windowId }
            ?? takeConnectingWindow(from: state)
        guard let window else { return nil }

        restoredWindowIds.insert(window.id)
        connectingWindowIds.removeAll { $0 == window.id }
        if requestedWindowIds.remove(window.id) != nil {
            regularRestorationActivationRetryCount = 0
        }
        Self.logger.info("Retrieved pending state for window \(window.id): \(window.tabs.count) tabs")

        // If all windows have retrieved their pending state, drop the
        // in-memory copy. We deliberately do NOT delete the file here —
        // restoration may still fail (buildNode returns nil, async
        // Catalyst path crashes, etc.) and the file is the only source of
        // truth for the next launch. The next successful `saveAllState`
        // will atomically replace it with a fresh snapshot.
        if restoredWindowIds.count >= state.windows.count {
            pendingRestoration = nil
            Self.logger.info("All \(state.windows.count) windows restored, cleared pending state (file preserved until next save)")
        }
        return window
    }

    /// Next saved window bound to a connecting scene, skipping any that were
    /// claimed by id in the meantime.
    private func takeConnectingWindow(from state: AppWindowState) -> SerializableWindow? {
        while let id = connectingWindowIds.first {
            connectingWindowIds.removeFirst()
            guard !restoredWindowIds.contains(id),
                  let window = state.windows.first(where: { $0.id == id }) else { continue }
            return window
        }
        return nil
    }

    /// Mark a window as restored without retrieving its state
    func markWindowRestored(windowId: String) {
        guard let state = pendingRestoration else { return }

        restoredWindowIds.insert(windowId)

        if restoredWindowIds.count >= state.windows.count {
            pendingRestoration = nil
            // File is preserved — the next successful save replaces it
            // atomically. See the matching note in `getPendingState`.
            Self.logger.info("All windows restored (marked), cleared pending state (file preserved until next save)")
        }
    }

    // MARK: - Query Methods

    /// Get count of windows still needing restoration
    var pendingWindowCount: Int {
        guard let state = pendingRestoration else { return 0 }
        return state.windows.count - restoredWindowIds.count
    }

    /// Whether there is pending restoration state
    var hasPendingRestoration: Bool {
        pendingRestoration != nil && pendingWindowCount > 0
    }

    /// Bind a connecting scene to the saved window it will restore, and return
    /// that window's saved frame so the scene can be pre-sized before it is first
    /// displayed — otherwise it appears at a default size and visibly resizes.
    ///
    /// `preferred` is the id the scene carried in its state-restoration activity.
    /// A scene with no id (the launch scene, whose session the system did not
    /// preserve) is given the first saved window nothing else has taken; that is
    /// the one place window identity has to be assigned rather than recovered.
    /// Returns the bound window's id and saved frame, or nil when every saved
    /// window is already spoken for.
    func bindConnectingScene(preferredWindowId preferred: String?) -> (windowId: String, frame: CGRect?)? {
        guard let state = pendingRestoration else { return nil }
        let taken = restoredWindowIds.union(connectingWindowIds)
        let window: SerializableWindow?
        if let preferred, !taken.contains(preferred) {
            window = state.windows.first { $0.id == preferred }
        } else {
            window = state.windows.first { !taken.contains($0.id) }
        }
        guard let window else { return nil }
        connectingWindowIds.append(window.id)
        Self.logger.info("Bound connecting scene to saved window \(window.id)")
        return (window.id, Self.frame(of: window))
    }

    private static func frame(of window: SerializableWindow) -> CGRect? {
        guard let x = window.frameOriginX, let y = window.frameOriginY,
              let w = window.frameWidth, let h = window.frameHeight,
              w >= 1, h >= 1 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Get all window IDs that need restoration
    var pendingWindowIds: [String] {
        guard let state = pendingRestoration else { return [] }
        return state.windows.map(\.id).filter { !restoredWindowIds.contains($0) }
    }

    /// Saved regular windows that still need a scene: not yet restored, not bound
    /// to a connecting scene, and not already requested. Reserves them so a second
    /// pass does not ask for the same windows again.
    func claimWindowIdsNeedingScenes() -> [String] {
        guard let state = pendingRestoration else { return [] }
        let taken = restoredWindowIds.union(connectingWindowIds).union(requestedWindowIds)
        let ids = state.windows.map(\.id).filter { !taken.contains($0) }
        requestedWindowIds.formUnion(ids)
        return ids
    }

    /// Release a window's scene reservation after `requestSceneSessionActivation`
    /// reports failure.
    ///
    /// - Returns: True when another same-launch retry should be scheduled.
    func releaseSceneRequest(forWindowId windowId: String) -> Bool {
        guard requestedWindowIds.remove(windowId) != nil else { return false }
        guard hasPendingRestoration else { return false }
        guard regularRestorationActivationRetryCount < maxRegularRestorationActivationRetries else {
            Self.logger.warning("Regular window restoration activation retry limit reached")
            return false
        }
        regularRestorationActivationRetryCount += 1
        return true
    }

    /// Check if a specific window has pending state
    func hasPendingState(forWindowId windowId: String) -> Bool {
        guard let state = pendingRestoration,
              !restoredWindowIds.contains(windowId) else {
            return false
        }
        return state.windows.contains { $0.id == windowId }
    }

    // MARK: - Helpers

    private func startAutosaveTimerIfNeeded() {
        guard autosaveTimer == nil, !registeredWindows.isEmpty else { return }

        autosaveTimer = Timer.scheduledTimer(withTimeInterval: autosaveInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard UIApplication.shared.applicationState == .active else { return }
            Task { @MainActor in
                self.saveAllState()
            }
        }
    }

    private func stopAutosaveTimer() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }

    private func unrestoredPendingState() -> AppWindowState? {
        guard let state = pendingRestoration else { return nil }
        let windows = state.windows.filter { !restoredWindowIds.contains($0.id) }
        guard !windows.isEmpty else { return nil }
        return AppWindowState(windows: windows)
    }

    /// Preserve saved windows that have not been materialized yet. This keeps
    /// not-yet-opened windows from being dropped by a save taken after only
    /// part of the saved app state has been restored.
    private func includingUnrestoredPendingWindows(_ liveWindows: [SerializableWindow]) -> [SerializableWindow] {
        guard let state = pendingRestoration else { return liveWindows }

        var windows = liveWindows
        var liveIds = Set(liveWindows.map(\.id))
        for pendingWindow in state.windows where !restoredWindowIds.contains(pendingWindow.id) {
            guard !liveIds.contains(pendingWindow.id) else { continue }
            windows.append(pendingWindow)
            liveIds.insert(pendingWindow.id)
        }
        return windows
    }

    private func formatAge(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "\(Int(interval))s"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h"
        } else {
            return "\(Int(interval / 86400))d"
        }
    }
}

// MARK: - Convenience Extensions

extension WindowStateManager {
    /// Force save regardless of debounce (use for background transition)
    func forceSaveAllState() {
        lastSaveTime = nil  // Reset debounce
        saveAllState()
    }

    /// Gather current window state without performing any I/O.
    /// Returns nil if persistence is disabled or no windows are registered.
    func gatherState() -> AppWindowState? {
        guard Self.isSessionPersistenceEnabled else { return nil }
        guard !registeredWindows.isEmpty else { return nil }

        let liveWindows = registeredWindows.compactMap { (_, provider) -> SerializableWindow? in
            provider()
        }
        let windows = includingUnrestoredPendingWindows(liveWindows)
        guard !windows.isEmpty else { return nil }

        // Record that we've observed live populated state this launch — the
        // background-transition path uses this to decide whether a later
        // empty `gatherState()` is a user-driven close-all (clear the file)
        // or a transient pre-restoration result (preserve the file). Pending
        // snapshots are carried forward but don't count as live materialized
        // state.
        if !liveWindows.isEmpty {
            hasObservedNonEmptyState = true
        }

        // Reset debounce to prevent autosave timer from redundant save
        lastSaveTime = Date()

        return AppWindowState(windows: windows)
    }

    /// Serializes the freshness check and file write so an older snapshot that passes
    /// the check cannot race ahead of a newer one that also passed the check.
    /// The high-water mark lives inside the queue's serial execution — no separate lock needed.
    nonisolated private static let writeQueue = DispatchQueue(label: "dev.chr33s.shell.windowstate.write")
    /// Access only from writeQueue. Uses nonisolated(unsafe) because all access
    /// is serialized through writeQueue — never accessed from the main actor.
    nonisolated(unsafe) private static var _lastWrittenAt = Date.distantPast

    /// Write pre-gathered state to disk. Can be called from any thread.
    /// Serialized: stale-check + write + high-water update are atomic with respect
    /// to concurrent callers, so out-of-order detached tasks cannot overwrite fresher state.
    /// Returns `true` if the snapshot was persisted (or intentionally skipped due to
    /// staleness); returns `false` on a caught I/O error so callers can
    /// avoid advancing a retry-debounce timer on failure.
    @discardableResult
    nonisolated static func writeStateToDisk(_ state: AppWindowState) -> Bool {
        writeQueue.sync { () -> Bool in
            if state.savedAt <= _lastWrittenAt {
                logger.debug("Skipping stale background state write (savedAt already superseded)")
                return true
            }

            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
            let fileURL = ghosttyDir.appendingPathComponent("window_state.json")

            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(state)

                try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)

                // Advance only after successful write so a failure leaves room for fallback.
                _lastWrittenAt = state.savedAt

                logger.info("Background state save completed: \(state.summary)")
                return true
            } catch {
                logger.error("Background state save failed: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Check if state file exists
    var hasStateFile: Bool {
        FileManager.default.fileExists(atPath: stateFileURL.path)
    }

    /// Get state file size (for debugging)
    var stateFileSize: Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: stateFileURL.path) else {
            return nil
        }
        return attrs[.size] as? Int
    }
}
