//
//  RecoveryPolicy.swift
//  shell
//
//  Injectable scheduling policy for connection recovery
//  (spec.connectivity.md §7.2, §7.3, §8, §10).
//
//  Every number here is a *proposed default*, not a measured optimum, and
//  none of them is a user-facing tuning knob in the first release (§14). They
//  live in one injectable struct so the deterministic regression suite can
//  pin a schedule instead of sleeping through the real one.
//

import Foundation

struct RecoveryPolicy: Equatable, Sendable {

    // MARK: - Burst and cooldown

    /// Attempts in the rapid burst. Sourced from `autoReconnectMaxAttempts`
    /// ("Attempts per recovery burst"), NOT a session-lifetime cap: reaching
    /// it retains the intent and drops to the cooldown rate (§7.2).
    var burstAttempts: Int = 5

    /// Cap for the equal-jitter backoff base `b`.
    var maxBurstBackoff: TimeInterval = 30

    /// Cooldown between attempts once the burst is exhausted.
    var cooldownInterval: TimeInterval = 60

    /// Fractional jitter applied to `cooldownInterval` (±20%).
    var cooldownJitterFraction: Double = 0.2

    // MARK: - Path events

    /// Trailing debounce applied to path notifications.
    var pathCoalesceDebounce: TimeInterval = 0.5

    /// Hard ceiling on how long coalescing may defer a path event.
    var pathCoalesceMaxDeferral: TimeInterval = 2.0

    /// Minimum spacing between fast-path bypasses for one logical connection.
    var fastPathBypassInterval: TimeInterval = 5.0

    /// How long a connection must stay ready before its failure history is
    /// cleared (so a flapping link cannot reset its own backoff).
    var stableReadyPeriod: TimeInterval = 30

    // MARK: - Global scheduling

    /// Concurrent automatic attempts across the whole app.
    var globalConcurrentAttempts: Int = 2

    /// Concurrent automatic attempts per equivalent endpoint/credential route.
    var perRouteConcurrentAttempts: Int = 1

    // MARK: - Stage deadlines

    /// TCP connect cap. Preserved from the existing source (§7.3).
    var connectDeadline: TimeInterval = 30

    /// Interactive login allowance. Spans human interaction (host-key
    /// approval, biometric unlock, OTP entry) and is deliberately generous.
    var interactiveLoginDeadline: TimeInterval = 300

    /// No-progress deadline for the attach/synchronize stages. Valid,
    /// generation-matched progress resets this.
    var stageInactivityDeadline: TimeInterval = 10

    /// Overall per-stage deadline. Progress does NOT reset this.
    var stageOverallDeadline: TimeInterval = 30

    // MARK: - Liveness

    /// Periodic keepalive interval when health monitoring is enabled.
    var probeInterval: TimeInterval = 15

    /// Deadline for a single keepalive round trip.
    var probeDeadline: TimeInterval = 10

    /// Grace period after a path change / foreground activation during which
    /// the existing transport is validated rather than replaced.
    var transportHandoffGrace: TimeInterval = 2

    /// Graceful-close budget before invoking the verified abort path.
    var gracefulCloseBudget: TimeInterval = 2

    // MARK: - Input

    /// Pending (accepted but not yet written) input budget per connection.
    var pendingInputBudgetBytes: Int = 256 * 1024

    /// Cap on a local, memory-only, never-auto-submitted input draft.
    var draftByteCap: Int = 64 * 1024

    // MARK: - Diagnostics

    /// Bounded in-memory diagnostic ring depth per coordinator.
    var diagnosticRingDepth: Int = 128

    init() {}

    nonisolated static let `default` = RecoveryPolicy()

    // MARK: - Derived schedule

    /// Equal-jitter delay before burst attempt `n` (1-based).
    ///
    /// Attempt 1 is immediate (subject to global scheduling and event
    /// coalescing). For `n >= 2` the base is `b = min(maxBurstBackoff, 2^(n-2))`
    /// and the delay is drawn uniformly from `[b/2, b]` — equal jitter, so two
    /// connections dropped by the same outage do not redial in lockstep.
    func burstDelay(forAttempt n: Int, jitter: RecoveryJitterSource) -> TimeInterval {
        guard n >= 2 else { return 0 }
        let base = min(maxBurstBackoff, pow(2, Double(n - 2)))
        let half = base / 2
        return half + jitter.nextUnitInterval() * half
    }

    /// Cooldown delay after the burst is exhausted, jittered ±`cooldownJitterFraction`.
    func cooldownDelay(jitter: RecoveryJitterSource) -> TimeInterval {
        let spread = cooldownInterval * cooldownJitterFraction
        return cooldownInterval - spread + jitter.nextUnitInterval() * 2 * spread
    }

    /// Load the parts of the policy that the settings registry owns. Only
    /// `burstAttempts` is user-visible; everything else stays internal (§14).
    @MainActor
    static func fromSettings() -> RecoveryPolicy {
        var policy = RecoveryPolicy.default

        let attempts = SettingsStore.shared.value(Settings.Connections.autoReconnectMaxAttempts)
        // A stored 0 (or a negative value from a hand-edited config) keeps the
        // default rather than disabling the burst entirely — the master gate
        // for "no automatic attempts" is `autoReconnectEnabled`.
        if attempts > 0 { policy.burstAttempts = attempts }

        let interval = SettingsStore.shared.value(Settings.Connections.healthProbeInterval)
        // Validate before any timer is created from it: a malformed stored
        // value must not produce a zero-interval spin loop.
        if interval > 0 { policy.probeInterval = TimeInterval(interval) }

        return policy
    }
}
