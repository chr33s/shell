//
//  ConnectionHealth.swift
//  shell
//
//  Connection health metrics for SSH sessions including RTT and packet loss
//

import Foundation
import SwiftUI

/// Individual ping sample for time series display
struct PingSample: Equatable, Sendable {
    let timestamp: Date
    /// RTT in milliseconds, nil indicates packet loss
    let rttMilliseconds: Double?

    var isSuccess: Bool { rttMilliseconds != nil }
}

/// Connection health metrics measured via SSH keepalive requests
struct ConnectionHealth: Equatable, Sendable {
    /// Round-trip time in milliseconds (nil if no measurement yet)
    var rttMilliseconds: Double?

    /// Packet loss percentage (0.0-100.0) over the rolling window
    var packetLossPercent: Double

    /// Number of successful pings in the current window
    var successfulPings: Int

    /// Total pings attempted in the current window
    var totalPings: Int

    /// Timestamp of last successful ping
    var lastSuccessfulPing: Date?

    /// Rolling window of ping samples for time series display
    var samples: [PingSample]

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

        let recentSamples = samples.suffix(3)
        let poorCount = recentSamples.filter { sample in
            guard let rtt = sample.rttMilliseconds else {
                return true // Packet loss counts as poor
            }
            return rtt >= 300
        }.count

        if poorCount >= 2 {
            return .poor
        }

        return quality
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
        let rttText = rttDescription
        let qualityText = quality.description
        if quality == .unknown {
            return String(localized: "Measuring...", comment: "Connection health: measuring RTT")
        }
        return "\(rttText) (\(qualityText))"
    }

    /// Whether the connection appears healthy (low loss, reasonable RTT)
    var isHealthy: Bool {
        guard let rtt = rttMilliseconds else {
            return false
        }
        return rtt < 300 && packetLossPercent < 20
    }

    /// Create an initial/empty health state
    static var initial: ConnectionHealth {
        ConnectionHealth(
            rttMilliseconds: nil,
            packetLossPercent: 0,
            successfulPings: 0,
            totalPings: 0,
            lastSuccessfulPing: nil,
            samples: []
        )
    }
}
