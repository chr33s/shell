//
//  ConnectionHealth.swift
//  shell
//
//  Connection health metrics for SSH sessions: round-trip time and probe
//  failure rate (spec.connectivity.md §8.1). Not packet loss — the SSH layer
//  cannot observe IP datagrams.
//

import Foundation
import SwiftUI

/// Individual probe sample for time series display.
struct PingSample: Equatable, Sendable {
    let timestamp: Date
    /// RTT in milliseconds; nil means the probe did not resolve in time.
    ///
    /// Deliberately NOT "packet loss": an SSH global request that goes
    /// unanswered tells us the round trip was not confirmed. It says nothing
    /// about IP datagrams, and the SSH layer cannot observe them
    /// (spec.connectivity.md §8.1).
    let rttMilliseconds: Double?

    /// Cancelled and intentionally-suspended samples are excluded from the
    /// failure denominator entirely — they are not evidence about the link.
    let wasCancelled: Bool

    var isSuccess: Bool { rttMilliseconds != nil }
    var countsTowardFailureRate: Bool { !wasCancelled }

    init(timestamp: Date, rttMilliseconds: Double?, wasCancelled: Bool = false) {
        self.timestamp = timestamp
        self.rttMilliseconds = rttMilliseconds
        self.wasCancelled = wasCancelled
    }
}

/// Connection health metrics measured via SSH keepalive requests
struct ConnectionHealth: Equatable, Sendable {
    /// Round-trip time in milliseconds (nil if no measurement yet)
    var rttMilliseconds: Double?

    /// Percentage of probes (0.0-100.0) that did not resolve in the rolling
    /// window, excluding cancelled and suspended samples.
    ///
    /// This is a *probe failure rate*, not packet loss. Reporting it as loss
    /// invented an IP-level measurement the SSH layer never made (§8.1).
    var probeFailurePercent: Double

    /// Number of successful probes in the current window
    var successfulPings: Int

    /// Total probes counted in the current window (cancelled ones excluded)
    var totalPings: Int

    /// Timestamp of last successful probe
    var lastSuccessfulPing: Date?

    /// When `rttMilliseconds` was measured. RTT is always displayed with its
    /// age: a stale historical RTT must not imply current health (§8.1).
    var rttMeasuredAt: Date?

    /// True while a probe is outstanding past its deadline. The round trip is
    /// unverified — which is not the same as the remote process being dead.
    var roundTripUnverified: Bool = false

    /// Rolling window of probe samples for time series display
    var samples: [PingSample]

    /// Age of the current RTT reading, or nil when nothing was ever measured.
    var rttAge: TimeInterval? {
        rttMeasuredAt.map { Date().timeIntervalSince($0) }
    }

    /// RTT with its age attached, e.g. "23ms (12s ago)". An unqualified
    /// number would keep claiming a healthy link long after the last reply.
    var ageQualifiedRTTDescription: String {
        guard rttMilliseconds != nil else {
            return String(localized: "Not verified", comment: "Connection health: no confirmed round trip")
        }
        guard let age = rttAge, age >= 1 else { return rttDescription }
        let ageText = RecoveryStatusPresentation.formatAge(age)
        return String(
            localized: "\(rttDescription) (\(ageText) ago)",
            comment: "Connection health: RTT with the age of the measurement")
    }

    /// Connection quality tier derived from RTT
    enum Quality: Sendable {
        case excellent  // < 50ms
        case good       // 50-150ms
        case fair       // 150-300ms
        case poor       // > 300ms
        case unknown    // No data yet

        var color: Color {
            switch self {
            case .excellent: return .green
            case .good: return .green.opacity(0.8)
            case .fair: return .yellow
            case .poor: return .red
            case .unknown: return .gray
            }
        }

        var description: String {
            switch self {
            case .excellent: return String(localized: "Excellent", comment: "Connection quality: excellent")
            case .good: return String(localized: "Good", comment: "Connection quality: good")
            case .fair: return String(localized: "Fair", comment: "Connection quality: fair")
            case .poor: return String(localized: "Poor", comment: "Connection quality: poor")
            case .unknown: return String(localized: "Unknown", comment: "Connection quality: no data")
            }
        }
    }

    /// Derive quality tier from current RTT
    var quality: Quality {
        guard let rtt = rttMilliseconds else {
            return .unknown
        }
        switch rtt {
        case ..<50:
            return .excellent
        case 50..<150:
            return .good
        case 150..<300:
            return .fair
        default:
            return .poor
        }
    }

    /// Quality for UI indicator display (with debouncing for poor state)
    /// Requires 2 of last 3 samples to be poor before showing red
    var indicatorQuality: Quality {
        guard samples.count >= 2 else {
            return quality
        }

        let recentSamples = samples.suffix(3).filter(\.countsTowardFailureRate)
        let poorCount = recentSamples.filter { sample in
            guard let rtt = sample.rttMilliseconds else {
                return true // An unresolved probe counts as poor
            }
            return rtt >= 300
        }.count

        if poorCount >= 2 {
            return .poor
        }

        // Debounce fix: this used to fall through to the raw `quality`, so a single
        // >= 300ms sample still painted the indicator red — exactly the case the
        // 2-of-3 rule exists to suppress. Demote an undebounced poor tier to .fair;
        // .unknown/.excellent/.good/.fair pass through unchanged.
        let tier = quality
        return tier == .poor ? .fair : tier
    }

    /// Human-readable RTT description
    var rttDescription: String {
        guard let rtt = rttMilliseconds else {
            return "—"
        }
        if rtt < 1 {
            return "<1ms"
        }
        return "\(Int(rtt))ms"
    }

    /// Human-readable status combining RTT and quality
    var statusDescription: String {
        if roundTripUnverified {
            return String(
                localized: "Round trip unverified",
                comment: "Connection health: probe deadline expired")
        }
        let rttText = ageQualifiedRTTDescription
        let qualityText = quality.description
        if quality == .unknown {
            return String(localized: "Measuring...", comment: "Connection health: measuring RTT")
        }
        return "\(rttText) (\(qualityText))"
    }

    /// Create an initial/empty health state
    static var initial: ConnectionHealth {
        ConnectionHealth(
            rttMilliseconds: nil,
            probeFailurePercent: 0,
            successfulPings: 0,
            totalPings: 0,
            lastSuccessfulPing: nil,
            rttMeasuredAt: nil,
            samples: []
        )
    }
}
