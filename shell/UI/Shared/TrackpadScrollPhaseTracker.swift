//
//  TrackpadScrollPhaseTracker.swift
//  shell
//
//  Synthesizes a gesture "end" for trackpad scroll pans, which don't reliably
//  deliver `.ended` on Catalyst/iPad: an inactivity timer ends the gesture,
//  a short guard drops the trailing inertial events, and an EMA estimates
//  the release velocity (the recognizer reports 0 at the synthetic end).
//

import UIKit
import QuartzCore

@MainActor
final class TrackpadScrollPhaseTracker {
    /// Raw-units-per-second release velocity, smoothed over per-event deltas.
    private(set) var velocity: CGFloat = 0

    private let endTimeout: TimeInterval
    private let inertiaGuard: TimeInterval
    private let onEnd: @MainActor () -> Void
    private var endTimer: Timer?
    private var lastSampleTime: CFTimeInterval = 0
    private var guardUntil: CFTimeInterval = 0

    /// - Parameters:
    ///   - endTimeout: 0.08s comfortably exceeds the active trackpad event cadence
    ///     (~8-16ms) and mid-drag micro-pauses; don't drop below ~0.07s.
    ///   - inertiaGuard: window after `finish()` during which momentum events are ignored.
    init(endTimeout: TimeInterval = 0.08,
         inertiaGuard: TimeInterval = 0.3,
         onEnd: @escaping @MainActor () -> Void) {
        self.endTimeout = endTimeout
        self.inertiaGuard = inertiaGuard
        self.onEnd = onEnd
    }

    /// True while trailing momentum events from a just-finished swipe should be dropped.
    var isInInertiaGuard: Bool { CACurrentMediaTime() < guardUntil }

    var isArmed: Bool { endTimer != nil }

    /// (Re)arm the inactivity timer without a sample. Arm at begin so a recognizer
    /// that fails before delivering movement still gets its end.
    func arm() {
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: endTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
    }

    /// Record a per-event delta: re-arms the timer and updates the EMA velocity.
    func noteEvent(delta: CGFloat) {
        arm()
        let now = CACurrentMediaTime()
        let dt = now - lastSampleTime
        // First sample (or a stale gap): seed at ~60 events/sec instead of dividing by a tiny dt.
        if lastSampleTime == 0 || dt > 0.1 {
            velocity = delta * 60
        } else if dt > 0 {
            let alpha: CGFloat = 0.4
            velocity = velocity * (1 - alpha) + (delta / CGFloat(dt)) * alpha
        }
        lastSampleTime = now
    }

    /// End the gesture now: latch the inertia guard, clear samples, fire `onEnd`.
    /// Read `velocity` before calling (or inside `onEnd`); it is reset after `onEnd` returns.
    func finish(zeroVelocity: Bool = false) {
        endTimer?.invalidate()
        endTimer = nil
        if zeroVelocity { velocity = 0 }
        guardUntil = CACurrentMediaTime() + inertiaGuard
        onEnd()
        velocity = 0
        lastSampleTime = 0
    }

    /// Cancel without latching the inertia guard or firing `onEnd`.
    func reset() {
        endTimer?.invalidate()
        endTimer = nil
        velocity = 0
        lastSampleTime = 0
        guardUntil = 0
    }

    private func timerFired() {
        endTimer = nil
        finish()
    }
}
