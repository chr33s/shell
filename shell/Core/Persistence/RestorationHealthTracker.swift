//
//  RestorationHealthTracker.swift
//  shell
//
//  Tracks restoration health using a launch checkpoint system.
//  Detects repeated restoration failures and skips restoration to allow recovery.
//

import Foundation
import os

/// Outcome of the per-launch restoration health check.
enum RestorationDecision {
    /// Restoration may proceed normally.
    case proceed
    /// Repeated crashed restorations imply the saved state itself is poisonous.
    /// Move it aside so the user starts fresh; manual recovery is still
    /// possible from the quarantined file.
    case skipQuarantineState
}

/// Tracks session restoration health and prevents crash loops.
///
/// Uses a "launch checkpoint" pattern:
/// 1. Mark restoration as "in progress" before starting
/// 2. Clear marker after successful completion
/// 3. If app crashes during restoration, marker remains set
/// 4. On next launch, if marker is set, increment failure counter
/// 5. After `failureThreshold` consecutive failures, quarantine the saved
///    state so the user gets a clean slate. The quarantined file is left on
///    disk for manual recovery.
@MainActor
@Observable
final class RestorationHealthTracker {
    static let shared = RestorationHealthTracker()

    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "RestorationHealth")

    // MARK: - Configuration

    /// Number of consecutive failed-restore launches before we treat the saved
    /// state as the suspect and quarantine it.
    private let failureThreshold = 5

    /// Time window for considering failures as consecutive (12 hours).
    /// Failures older than this are considered stale and reset.
    private let failureWindowSeconds: TimeInterval = 43200

    /// How long the app must run without crashing before we consider this launch
    /// stable enough to clear the failure counter. Surviving this window proves
    /// the previous crashes weren't part of an active loop, so the next launch
    /// can attempt restoration again.
    private let stabilityDelaySeconds: TimeInterval = 30

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let consecutiveFailures = "restoration.consecutiveFailures"
        static let lastFailureTimestamp = "restoration.lastFailureTimestamp"
        static let restorationInProgress = "restoration.inProgress"
    }

    // MARK: - Observable State

    /// Whether restoration was skipped on this launch due to repeated failures.
    ///
    /// Latched rather than posted as a notification: `evaluateRestoration()`
    /// runs while the very first window is still connecting, long before any
    /// view exists to receive a post. The flag therefore waits on the tracker
    /// until a window is on screen and claims it via
    /// `claimRestorationSkippedNotice()`.
    private(set) var restorationSkipped = false

    /// Whether the health check has been performed this launch
    private var healthCheckPerformed = false

    /// Cached decision from the first call to `evaluateRestoration()`
    private var cachedDecision: RestorationDecision = .proceed

    /// Timer that resets the failure counter once this launch proves stable
    private var stabilityTask: Task<Void, Never>?

    // MARK: - Init

    private init() {}

    // MARK: - Public API

    /// Decide whether restoration should run this launch, and if not, what to
    /// do with the saved state.
    ///
    /// Call once at app launch before attempting restoration. Subsequent calls
    /// return the cached decision.
    func evaluateRestoration() -> RestorationDecision {
        if healthCheckPerformed {
            return cachedDecision
        }
        healthCheckPerformed = true

        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970

        // Check if previous launch marked restoration in-progress but never completed
        let wasInProgress = defaults.bool(forKey: Keys.restorationInProgress)
        if wasInProgress {
            Self.logger.warning("Previous restoration did not complete - counting as failure")
            incrementFailureCount()
            defaults.set(false, forKey: Keys.restorationInProgress)
        }

        // Failure-staleness: if the failure record is older than the window,
        // assume it's stale (e.g., user resolved the issue manually long ago)
        // and start fresh.
        let lastFailureTimestamp = defaults.double(forKey: Keys.lastFailureTimestamp)
        if lastFailureTimestamp > 0 {
            let age = now - lastFailureTimestamp
            if age > failureWindowSeconds {
                let hours = Int(age / 3600)
                Self.logger.info("Failure record is stale (\(hours)h old), resetting counters")
                resetFailureCount()
                cachedDecision = .proceed
                return .proceed
            }
        }

        let failures = defaults.integer(forKey: Keys.consecutiveFailures)
        if failures < failureThreshold {
            Self.logger.info("Restoration health check passed (failures: \(failures)/\(self.failureThreshold))")
            // Belt-and-suspenders: clear phantom failures (in-progress flag set
            // but no actual completion call) once this launch proves stable.
            scheduleStabilityReset()
            cachedDecision = .proceed
            return .proceed
        }

        // Threshold exceeded — treat the saved state as the suspect, quarantine
        // it, and reset the counter so the next launch starts fresh.
        Self.logger.warning("Consecutive restoration failures (\(failures)) >= threshold (\(self.failureThreshold)), quarantining saved state")
        resetFailureCount()
        restorationSkipped = true
        cachedDecision = .skipQuarantineState
        return .skipQuarantineState
    }

    /// Schedule a one-shot reset of the failure counter after stabilityDelaySeconds.
    /// If the app crashes before the timer fires, the counter is preserved and
    /// crash-loop protection still applies on the next launch.
    private func scheduleStabilityReset() {
        guard stabilityTask == nil else { return }
        let delay = stabilityDelaySeconds
        stabilityTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let defaults = UserDefaults.standard
            let failures = defaults.integer(forKey: Keys.consecutiveFailures)
            guard failures > 0 else { return }
            Self.logger.info("Launch stable for \(delay)s, resetting failure count from \(failures)")
            self.resetFailureCount()
        }
    }

    /// Mark that restoration is starting.
    ///
    /// Call this immediately before calling `restoreWindowState()`.
    /// If the app crashes before `markRestorationCompleted()` is called,
    /// this will be detected on next launch.
    func markRestorationStarted() {
        Self.logger.info("Marking restoration as in-progress")
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Keys.restorationInProgress)
        // Force synchronize to ensure flag is persisted before potentially crashing
        defaults.synchronize()
    }

    /// Mark that restoration completed successfully.
    ///
    /// Call this after all tabs have been restored and the window is stable.
    /// This clears the in-progress flag and resets the failure counter.
    func markRestorationCompleted() {
        Self.logger.info("Restoration completed successfully, resetting failure count")
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Keys.restorationInProgress)
        resetFailureCount()
        // Force flush so a fast force-quit after restoration cannot leave the
        // stale in-progress=true flag on disk, which would be misread as a
        // failed restoration on the next launch.
        defaults.synchronize()
    }

    /// The user-facing explanation for a quarantined session, claimed by the
    /// first window able to present it.
    ///
    /// Returns non-nil at most once per launch: the flag is cleared as it is
    /// read, so a second window — or a re-mount of the same window's alert
    /// host — does not repeat the notice. Returns nil whenever restoration ran
    /// normally, which is every launch but the one after a restore crash loop.
    ///
    /// Wording is deliberately precise about the outcome: `quarantineSavedState()`
    /// moves the file aside, it does not delete it, and the counter is reset in
    /// the same breath so the next quit saves and restores as usual.
    func claimRestorationSkippedNotice() -> String? {
        guard restorationSkipped else { return nil }
        restorationSkipped = false
        Self.logger.info("Presenting restoration-quarantine notice")
        return String(
            localized: """
                Shell repeatedly failed to restore your tabs from the last \
                session, so it set that saved session aside and started with a \
                fresh window. The saved session was moved aside, not deleted. \
                Tabs will be saved and restored as usual from now on.
                """,
            comment: "Alert message shown at launch when repeated restoration failures caused the saved session to be quarantined"
        )
    }

    // MARK: - Private Helpers

    private func incrementFailureCount() {
        let defaults = UserDefaults.standard
        let current = defaults.integer(forKey: Keys.consecutiveFailures)
        let newCount = current + 1
        defaults.set(newCount, forKey: Keys.consecutiveFailures)
        defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastFailureTimestamp)
        Self.logger.warning("Incremented failure count to \(newCount)")
    }

    private func resetFailureCount() {
        let defaults = UserDefaults.standard
        defaults.set(0, forKey: Keys.consecutiveFailures)
        defaults.removeObject(forKey: Keys.lastFailureTimestamp)
    }
}
