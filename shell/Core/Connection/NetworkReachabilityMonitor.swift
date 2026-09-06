//
//  NetworkReachabilityMonitor.swift
//  shell
//
//  Monitors network connectivity changes using NWPathMonitor.
//  Used to trigger opportunistic reconnection when network is restored.
//

import Foundation
import Network
import Combine
import os
import UIKit

/// Monitors network connectivity for reconnection triggers
@MainActor
final class NetworkReachabilityMonitor: ObservableObject {

    // MARK: - Singleton

    static let shared = NetworkReachabilityMonitor()

    // MARK: - Logger

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "NetworkReachability")

    // MARK: - Published State

    /// Whether the device currently has network connectivity
    @Published private(set) var isConnected: Bool = true

    /// The type of network connection (wifi, cellular, wired, etc.)
    @Published private(set) var connectionType: ConnectionType = .unknown

    // MARK: - Publishers

    /// Publisher that emits when connectivity is restored after being lost
    let connectivityRestored = PassthroughSubject<Void, Never>()

    /// Publisher that emits when the network path changes while staying connected
    /// on the same interface type (e.g., VPN connect/disconnect, route changes)
    let networkPathUpdated = PassthroughSubject<Void, Never>()

    // MARK: - Types

    enum ConnectionType: Equatable, CustomStringConvertible {
        case wifi
        case cellular
        case wired
        case loopback
        case unknown

        var description: String {
            switch self {
            case .wifi: return "WiFi"
            case .cellular: return "Cellular"
            case .wired: return "Ethernet"
            case .loopback: return "Loopback"
            case .unknown: return "Unknown"
            }
        }
    }

    // MARK: - Private Properties

    private var pathMonitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "dev.chr33s.shell.network-monitor", qos: .utility)
    private var isMonitoring = false
    private var previouslyConnected: Bool = true
    private var previousInterfaceNames: Set<String> = []
    private let latestPathLock = NSLock()
    private nonisolated(unsafe) var _latestPath: NWPath?

    /// Holds the latest path that arrived during a foreground resume quiet
    /// window. When the window expires, the most recent path is replayed
    /// once — collapsing any path-change burst into a single @Published
    /// flush instead of fanning multiple cascades onto the scene-update
    /// transaction frame.
    private var deferredPath: NWPath?
    private var deferredFlushScheduled = false

    /// Latest path observed while `Ghostty.isAppBackgroundedAtomic` was true.
    /// `replayBackgroundPathIfAny()` (called from the FG resume path after
    /// the gate flips) drains it and runs `handlePathUpdate` once on real
    /// main-thread runtime. Lock-protected because writes happen on
    /// `monitorQueue`. The 2026-05-04 10:18 watchdog showed three
    /// `Net.path.received` events with zero `Net.path.dispatched` over a
    /// 30s window — main was suspended and the queued MainActor tasks could
    /// never run; queueing them anyway costs scene-update budget without
    /// doing useful work, since `NetworkInfoLiveActivityBridge.deferAfterForeground`
    /// is also gated on main and can't refresh the widget while iOS holds
    /// main suspended.
    private let backgroundPathLock = NSLock()
    private nonisolated(unsafe) var _pendingBackgroundPath: NWPath?
    private let activationPathFlushLock = NSLock()
    private nonisolated(unsafe) var _activationPathFlushScheduled = false
    private nonisolated(unsafe) var _activationPathFlushGeneration: UInt64 = 0
    private nonisolated static let maxActivationPathFlushAttempts = 80

    /// True if a path with `status != .satisfied` was observed while
    /// backgrounded. Latest-wins on `_pendingBackgroundPath` would otherwise
    /// erase a down-then-up flap (the final stashed path is `.satisfied`,
    /// `isConnected` was never updated to false, so `handlePathUpdate`'s
    /// `!wasConnected && nowConnected` branch never fires and listeners that
    /// depend on `connectivityRestored` never see the recovery). The replay
    /// path uses this flag to synthesize a `connectivityRestored` send when
    /// the final path is satisfied but the network actually flapped during
    /// suspension.
    private nonisolated(unsafe) var _sawDisconnectWhileBackgrounded: Bool = false

    /// Travels alongside `deferredPath` through the resume-quiet-window
    /// deferral so a synthesized `connectivityRestored` is tied to the
    /// SPECIFIC replayed path. If a fresh `.unsatisfied` (or any other)
    /// path arrives before the deferred fire and overwrites
    /// `deferredPath`, this flag is overwritten too — the synthesis is
    /// dropped along with the stale path. Without this coupling, the
    /// monitor-wide flag could ride along with a later `.unsatisfied`
    /// path and emit a false recovery signal immediately after a
    /// connectivity loss.
    private var deferredPathSynthesizesConnectivityRestored = false

    /// Thread-safe storage for disconnect timestamp (accessed from both monitorQueue and MainActor)
    /// Uses NSLock for thread safety since it's accessed synchronously from the monitor callback
    /// Marked nonisolated(unsafe) because they're protected by disconnectTimeLock
    private let disconnectTimeLock = NSLock()
    private nonisolated(unsafe) var _lastDisconnectTime: Date?
    private nonisolated(unsafe) var _previousStatus: NWPath.Status = .satisfied

    /// How recently network must have been lost to consider it "recently disconnected" (5 seconds)
    private let recentDisconnectThreshold: TimeInterval = 5.0

    /// Thread-safe getter for last disconnect time
    private var lastDisconnectTime: Date? {
        disconnectTimeLock.lock()
        defer { disconnectTimeLock.unlock() }
        return _lastDisconnectTime
    }

    /// Thread-safe setter for last disconnect time
    private func setLastDisconnectTime(_ time: Date?) {
        disconnectTimeLock.lock()
        _lastDisconnectTime = time
        disconnectTimeLock.unlock()
    }

    // MARK: - Initialization

    private init() {
        // Start monitoring immediately
        start()
    }

    deinit {
        // Note: Can't call stop() here due to @MainActor isolation
        pathMonitor?.cancel()
    }

    // MARK: - Public Methods

    /// Starts network monitoring
    func start() {
        guard !isMonitoring else {
            Self.logger.debug("Network monitoring already active")
            return
        }

        Self.logger.info("Starting network reachability monitoring")

        let monitor = NWPathMonitor()
        pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            self.latestPathLock.lock()
            self._latestPath = path
            self.latestPathLock.unlock()

            // Record disconnect time SYNCHRONOUSLY before dispatching to MainActor
            // This ensures the timestamp is set even if the MainActor task is delayed
            self.disconnectTimeLock.lock()
            let previousStatus = self._previousStatus
            self._previousStatus = path.status
            if previousStatus == .satisfied && path.status != .satisfied {
                // Network just went down - record timestamp immediately
                self._lastDisconnectTime = Date()
            } else if previousStatus != .satisfied && path.status == .satisfied {
                // Network restored - clear timestamp
                self._lastDisconnectTime = nil
            }
            self.disconnectTimeLock.unlock()

            // Record receipt on the monitor queue (the very first observable
            // moment of an OS-driven path change). Whether we end up
            // deferring this on main is logged below in handlePathUpdate.

            // While backgrounded, do not queue a MainActor Task at all.
            // iOS holds main suspended for backgrounded apps; queued
            // `Task { @MainActor }` items pile up but cannot execute, and
            // `NetworkInfoLiveActivityBridge.deferAfterForeground` (which
            // uses `DispatchQueue.main.asyncAfter`) is gated on main too —
            // so Live Activity widget refreshes are not occurring during
            // this period either way. The 2026-05-04 10:18:15 watchdog
            // saw three `Net.path.received` events with zero
            // `Net.path.dispatched` over a 30s window. Stash the latest
            // path; the FG resume path replays it on real runtime.
            if Ghostty.isAppBackgroundedAtomic || ForegroundActivationGate.shared.isUnsafeForSceneMutation {
                let isDown = path.status != .satisfied
                self.backgroundPathLock.lock()
                self._pendingBackgroundPath = path
                if isDown {
                    self._sawDisconnectWhileBackgrounded = true
                }
                self.backgroundPathLock.unlock()
                if ForegroundActivationGate.shared.isUnsafeForSceneMutation {
                    self.noteActivationSuppressedPathAndScheduleFlush()
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }

        monitor.start(queue: monitorQueue)
        isMonitoring = true
    }

    /// Stops network monitoring
    func stop() {
        guard isMonitoring else { return }

        Self.logger.info("Stopping network reachability monitoring")
        pathMonitor?.cancel()
        pathMonitor = nil
        isMonitoring = false
    }

    /// Fully pause the path monitor while the app is backgrounded.
    ///
    /// Suppressing MainActor dispatch from `pathUpdateHandler` was not enough
    /// for the scene-update watchdog cases: the monitor queue could still
    /// receive path churn and write breadcrumbs while the process was supposed
    /// to quiesce. Cancelling the monitor removes this source entirely until
    /// the foreground gate reopens.
    func pauseForBackground() {
        guard isMonitoring else { return }
        stop()
        deferredPath = nil
        deferredPathSynthesizesConnectivityRestored = false
        deferredFlushScheduled = false
    }

    /// Resume network monitoring after the foreground gate has opened.
    func resumeAfterForeground() {
        guard !isMonitoring else { return }
        start()
    }

    /// Replay the latest path that was suppressed while backgrounded, if
    /// any. Must be called AFTER `Ghostty.isAppBackgroundedAtomic` is
    /// flipped to false — several subscribers (TrzszSession, MoshSession)
    /// drop network events while that atomic is true, so a replay before
    /// the gate flip would be drained and ignored with no second chance.
    /// Latest-wins: bursts during the backgrounded period collapse to a
    /// single replay. If a disconnect was observed during the backgrounded
    /// period and the final path is satisfied, set
    /// `pendingSyntheticConnectivityRestored` so the recovery signal is
    /// emitted at the end of `handlePathUpdate`'s non-deferred path —
    /// after connectionType and interface state are applied, and after
    /// the resume quiet window expires (the deferral path eventually
    /// re-enters this same handler post-window).
    func replayBackgroundPathIfAny() {
        backgroundPathLock.lock()
        let path = _pendingBackgroundPath
        let sawDisconnect = _sawDisconnectWhileBackgrounded
        _pendingBackgroundPath = nil
        _sawDisconnectWhileBackgrounded = false
        backgroundPathLock.unlock()
        guard let path else { return }
        let synthesizeRestored = sawDisconnect
            && path.status == .satisfied
            && isConnected
        if synthesizeRestored {
            Self.logger.info("Network flapped during background; queueing synthetic connectivityRestored tied to replayed path")
        }
        handlePathUpdate(path, synthesizeConnectivityRestored: synthesizeRestored)
    }

    private nonisolated func noteActivationSuppressedPathAndScheduleFlush() {
        activationPathFlushLock.lock()
        _activationPathFlushGeneration &+= 1
        let generation = _activationPathFlushGeneration
        let shouldSchedule = !_activationPathFlushScheduled
        if shouldSchedule {
            _activationPathFlushScheduled = true
        }
        activationPathFlushLock.unlock()

        if shouldSchedule {
            scheduleActivationPathFlush(generation: generation, attempt: 0)
        }
    }

    private nonisolated func scheduleActivationPathFlush(generation: UInt64, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            Task { @MainActor [weak self] in
                self?.flushActivationSuppressedPathIfSafe(generation: generation, attempt: attempt)
            }
        }
    }

    @MainActor
    private func flushActivationSuppressedPathIfSafe(generation: UInt64, attempt: Int) {
        activationPathFlushLock.lock()
        _activationPathFlushScheduled = false
        let latestGeneration = _activationPathFlushGeneration
        activationPathFlushLock.unlock()

        guard !Ghostty.isAppBackgroundedAtomic,
              UIApplication.shared.applicationState == .active else {
            return
        }

        guard !Ghostty.isInResumeQuietWindowAtomic,
              !ForegroundActivationGate.shared.isUnsafeForSceneMutation else {
            let nextAttempt = latestGeneration == generation ? attempt + 1 : 0
            guard nextAttempt < Self.maxActivationPathFlushAttempts else {
                return
            }

            activationPathFlushLock.lock()
            let shouldSchedule = !_activationPathFlushScheduled
            if shouldSchedule {
                _activationPathFlushScheduled = true
            }
            activationPathFlushLock.unlock()
            if shouldSchedule {
                scheduleActivationPathFlush(generation: latestGeneration, attempt: nextAttempt)
            }
            return
        }

        replayBackgroundPathIfAny()
    }

    /// Force a check of current network status
    /// Useful when app returns to foreground
    func refreshStatus() {
        // The monitor will automatically update, but we can restart it to ensure fresh state
        if isMonitoring {
            stop()
            start()
        }
    }

    /// Re-apply the latest path already delivered by NWPathMonitor without
    /// restarting the monitor. Used on foreground by sessions that only need a
    /// consolidated post-resume path signal.
    func replayLatestPathAfterResumeQuietWindow() {
        latestPathLock.lock()
        let path = _latestPath
        latestPathLock.unlock()
        guard let path else { return }


        guard !Ghostty.isAppBackgroundedAtomic, !Ghostty.isInResumeQuietWindowAtomic else {
            deferredPath = path
            deferredPathSynthesizesConnectivityRestored = false
            scheduleDeferredPathFlush()
            return
        }

        handlePathUpdate(path)
    }

    /// Check if network is currently unavailable OR was recently disconnected
    /// This helps catch race conditions where the session ends before we've updated isConnected
    /// - Returns: true if network is down or was lost within the last few seconds
    func isNetworkUnavailableOrRecentlyLost() -> Bool {
        // If currently disconnected, definitely unavailable
        if !isConnected {
            return true
        }

        // If we were recently disconnected (within threshold), consider it unavailable
        // This catches cases where session ends before our async state update
        if let lastDisconnect = lastDisconnectTime {
            let timeSinceDisconnect = Date().timeIntervalSince(lastDisconnect)
            if timeSinceDisconnect < recentDisconnectThreshold {
                Self.logger.debug("Network was recently lost (\(timeSinceDisconnect)s ago)")
                return true
            }
        }

        return false
    }

    // MARK: - Private Methods

    private func handlePathUpdate(_ path: NWPath, synthesizeConnectivityRestored: Bool = false) {
        // During the foreground resume quiet window, path-change @Published
        // mutations (`isConnected`, `connectionType`) + PassthroughSubject
        // sends are exactly the kind of cascade that FrontBoard's
        // scene-update watchdog kills the app over. Coalesce:
        // store the latest path and schedule a single replay 0.15s later
        // (matching the existing quiet-window length). Any new path that
        // arrives in the meantime overwrites `deferredPath` so we still
        // converge on the most recent state. The synthetic-restored flag
        // travels with the path so a fresh overwrite drops a stale
        // synthesis along with the stale path.
        if Ghostty.isInResumeQuietWindowAtomic ||
            ForegroundActivationGate.shared.isUnsafeForSceneMutation {
            deferredPath = path
            deferredPathSynthesizesConnectivityRestored = synthesizeConnectivityRestored
            scheduleDeferredPathFlush()
            return
        }

        // Drop any older deferred path — this fresh update supersedes it.
        // Same for the synthetic flag: if the prior payload's path was
        // overwritten by this fresh fire, its synthesis is no longer valid.
        deferredPath = nil
        deferredPathSynthesizesConnectivityRestored = false

        let wasConnected = isConnected
        let previousType = connectionType

        // Equality-guard every @Published assignment. NWPathMonitor delivers
        // bursts of updates during cellular ↔ Wi-Fi handoff, VPN setup, and
        // captive-portal probing where most fields don't actually change
        // between successive paths. Unguarded `=` on a @Published property
        // fires `objectWillChange` regardless of value, which invalidates
        // every SwiftUI body that observes this singleton (MainView reads
        // it transitively via theme/connection-status subviews). These
        // mutations × tens of bursts per minute compound into the SwiftUI
        // invalidation storms we see across the 52 crash IPS files
        // (`AG::Graph::propagate_dirty`, `AG::Graph::UpdateStack::update`,
        // `MainView.body` re-entry through `effectiveThemeColors`,
        // `LayoutEngineBox.sizeThatFits`, `_pureEffectiveUserInterfaceStyle`
        // etc — different frames, same root cause: too much main-thread
        // graph work to fit inside FrontBoard's 10 s foreground or 30 s
        // background scene-update budget). Skip writes that wouldn't change
        // anything and the cascade dies at the source.
        let nowConnected = path.status == .satisfied
        if isConnected != nowConnected { isConnected = nowConnected }

        let newType = determineConnectionType(from: path)
        if connectionType != newType { connectionType = newType }

        Self.logger.debug("""
            Network status update: \
            connected=\(nowConnected), \
            type=\(self.connectionType.description)
            """)

        // Emit connectivity events
        // Note: Timestamp recording is handled synchronously in pathUpdateHandler for thread safety
        if !wasConnected && nowConnected {
            Self.logger.info("Network connectivity restored (\(self.connectionType.description))")
            connectivityRestored.send()
        } else if wasConnected && !nowConnected {
            Self.logger.info("Network connectivity lost")
        }

        // Emit connection type change (e.g., wifi -> cellular handoff)
        if previousType != connectionType && nowConnected {
            Self.logger.info("Connection type changed: \(previousType.description) -> \(self.connectionType.description)")
        }

        // Catch path changes that don't change connection type while staying connected
        // (e.g., VPN connect/disconnect, route changes). Only fire when the
        // interface set genuinely changed; previously this also fired on
        // every same-type same-interface path event, which during instability
        // arrives many times per second and drives the same invalidation
        // storm the @Published guards above defuse.
        let currentInterfaceNames = Set(path.availableInterfaces.map { $0.name })
        let interfacesChanged = currentInterfaceNames != previousInterfaceNames
        previousInterfaceNames = currentInterfaceNames

        if interfacesChanged && nowConnected {
            networkPathUpdated.send()
        }

        previouslyConnected = nowConnected

        // Emit a synthesized `connectivityRestored` if `replayBackgroundPathIfAny`
        // observed a flap during the backgrounded period AND the path being
        // handled here is the one it asked for synthesis on. Done at the
        // very end so subscribers see all the path-derived @Published state
        // (connectionType, networkPathUpdated) updated FIRST. Honors the
        // resume quiet window: when the replay arrived during the window,
        // `handlePathUpdate` stashed both the path and the synthesis flag
        // together, and the post-window asyncAfter re-enters this function
        // with both preserved. `nowConnected` is a belt-and-suspenders gate
        // against `replayBackgroundPathIfAny` ever passing the flag for a path that
        // ended up unsatisfied by the time we got here (shouldn't happen
        // since the replay only sets the flag for `.satisfied`, but cheap
        // to assert).
        if synthesizeConnectivityRestored && nowConnected {
            Self.logger.info("Emitting synthesized connectivityRestored after background flap")
            connectivityRestored.send()
        }
    }

    private func scheduleDeferredPathFlush() {
        guard deferredPath != nil else { return }
        guard !deferredFlushScheduled else { return }
        deferredFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.deferredFlushScheduled = false
            guard self.deferredPath != nil else { return }
            guard !Ghostty.isAppBackgroundedAtomic,
                  !Ghostty.isInResumeQuietWindowAtomic,
                  !ForegroundActivationGate.shared.isUnsafeForSceneMutation else {
                self.scheduleDeferredPathFlush()
                return
            }
            if let pending = self.deferredPath {
                let synth = self.deferredPathSynthesizesConnectivityRestored
                self.deferredPath = nil
                self.deferredPathSynthesizesConnectivityRestored = false
                self.handlePathUpdate(pending, synthesizeConnectivityRestored: synth)
            }
        }
    }

    private func determineConnectionType(from path: NWPath) -> ConnectionType {
        // Check interface types in order of preference
        if path.usesInterfaceType(.wifi) {
            return .wifi
        } else if path.usesInterfaceType(.cellular) {
            return .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            return .wired
        } else if path.usesInterfaceType(.loopback) {
            return .loopback
        } else {
            return .unknown
        }
    }
}
