//
//  ConnectionHealthPopover.swift
//  shell
//
//  Floating popover showing connection health metrics on tab hover
//

import SwiftUI

// MARK: - Time Series Chart

/// Line chart showing RTT over time with packet loss indicators
struct HealthTimeSeriesChart: View {
    let samples: [PingSample]

    private let chartWidth: CGFloat = 240
    private let chartHeight: CGFloat = 80

    /// Get color for a specific RTT value based on quality thresholds
    private func colorForRTT(_ rtt: Double) -> Color {
        switch rtt {
        case ..<50: return .appSuccess
        case 50..<150: return .appSuccess.opacity(0.8)
        case 150..<300: return .appWarning
        default: return .appDanger
        }
    }

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }

            let successfulSamples = samples.filter { $0.isSuccess }

            // Calculate Y-axis range with headroom
            let maxRTT = successfulSamples.compactMap { $0.rttMilliseconds }.max() ?? 100
            let yMax = max(maxRTT * 1.2, 50) // At least 50ms range, 20% headroom

            // Time range (use actual sample timestamps)
            let timeRange: TimeInterval = 5 * 60 // 5 minutes
            let now = Date()
            let startTime = now.addingTimeInterval(-timeRange)

            // Helper to convert sample to point
            func point(for sample: PingSample) -> CGPoint {
                let timeFraction = sample.timestamp.timeIntervalSince(startTime) / timeRange
                let x = timeFraction * size.width

                if let rtt = sample.rttMilliseconds {
                    let yFraction = 1.0 - (rtt / yMax) // Invert Y
                    let y = yFraction * size.height
                    return CGPoint(x: x, y: y)
                }
                return CGPoint(x: x, y: size.height) // Bottom for losses
            }

            // Draw subtle grid lines at 100ms, 200ms, 300ms
            let gridColor = Color.primary.opacity(0.1)
            for ms in stride(from: 100.0, through: min(yMax, 500), by: 100.0) {
                let yFraction = 1.0 - (ms / yMax)
                let y = yFraction * size.height
                var gridPath = Path()
                gridPath.move(to: CGPoint(x: 0, y: y))
                gridPath.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(gridPath, with: .color(gridColor), lineWidth: 0.5)
            }

            // Draw line segments with per-point colors
            if successfulSamples.count >= 2 {
                let sortedSamples = successfulSamples.sorted { $0.timestamp < $1.timestamp }

                for i in 1..<sortedSamples.count {
                    let fromSample = sortedSamples[i - 1]
                    let toSample = sortedSamples[i]
                    let fromPoint = point(for: fromSample)
                    let toPoint = point(for: toSample)

                    var segmentPath = Path()
                    segmentPath.move(to: fromPoint)
                    segmentPath.addLine(to: toPoint)

                    // Color based on destination point's RTT
                    let segmentColor = colorForRTT(toSample.rttMilliseconds!)
                    context.stroke(segmentPath, with: .color(segmentColor), lineWidth: 2)
                }
            }

            // Draw successful ping dots with per-point colors
            for sample in successfulSamples {
                let pt = point(for: sample)
                let dotRect = CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)
                let dotColor = colorForRTT(sample.rttMilliseconds!)
                context.fill(Circle().path(in: dotRect), with: .color(dotColor))
            }

            // Draw packet loss indicators (red dots at bottom)
            let lostSamples = samples.filter { !$0.isSuccess }
            for sample in lostSamples {
                let timeFraction = sample.timestamp.timeIntervalSince(startTime) / timeRange
                let x = timeFraction * size.width
                // Position loss dots at bottom with small offset
                let dotRect = CGRect(x: x - 4, y: size.height - 8, width: 8, height: 8)
                context.fill(Circle().path(in: dotRect), with: .color(.appDanger))
            }
        }
        .frame(width: chartWidth, height: chartHeight)
    }
}

// MARK: - Health Popover

/// Popover view displaying connection health metrics with time series chart
struct ConnectionHealthPopover: View {
    let health: ConnectionHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row: RTT with quality indicator and loss percentage
            HStack {
                // Quality dot and RTT
                HStack(spacing: 8) {
                    Circle()
                        .fill(health.quality.color)
                        .frame(width: 10, height: 10)

                    Text(health.statusDescription)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }

                Spacer()

                // Packet loss
                if health.totalPings > 0 {
                    HStack(spacing: 4) {
                        Text("Loss:")
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.7))
                        Text(String(format: "%.1f%%", health.packetLossPercent))
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                            .foregroundStyle(health.packetLossPercent > 10 ? .appDanger : .primary.opacity(0.7))
                    }
                }
            }

            // Time series chart
            if !health.samples.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HealthTimeSeriesChart(samples: health.samples)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.03))
                    )

                    // Time axis labels
                    HStack {
                        Text("5m ago")
                            .font(.caption2)
                            .foregroundStyle(.primary.opacity(0.5))
                        Spacer()
                        Text("now")
                            .font(.caption2)
                            .foregroundStyle(.primary.opacity(0.5))
                    }
                }
            }

            // Footer: sample count
            if health.totalPings > 0 {
                Text("\(health.successfulPings)/\(health.totalPings) samples")
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.6))
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground))
                .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
        )
    }
}

/// Compact inline health indicator for tab bar
struct ConnectionHealthIndicator: View {
    let health: ConnectionHealth
    var textColor: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(health.indicatorQuality.color)
                .frame(width: 6, height: 6)

            if let rtt = health.rttMilliseconds {
                Text("\(Int(rtt))ms")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(textColor.opacity(0.8))
            }
        }
    }
}

// MARK: - Preview Helpers

/// Generate sample ping data for previews
private func generateSampleData(
    count: Int,
    baseRTT: Double,
    variance: Double,
    lossRate: Double = 0
) -> [PingSample] {
    let now = Date()
    let interval: TimeInterval = 15 // 15 seconds between pings

    return (0..<count).map { index in
        let timestamp = now.addingTimeInterval(-Double(count - 1 - index) * interval)
        let isLoss = Double.random(in: 0...1) < lossRate

        if isLoss {
            return PingSample(timestamp: timestamp, rttMilliseconds: nil)
        } else {
            let rtt = baseRTT + Double.random(in: -variance...variance)
            return PingSample(timestamp: timestamp, rttMilliseconds: max(1, rtt))
        }
    }
}

// MARK: - Previews

#Preview("Health Popover - Excellent") {
    let samples = generateSampleData(count: 10, baseRTT: 25, variance: 8)
    return ConnectionHealthPopover(health: ConnectionHealth(
        rttMilliseconds: 23,
        packetLossPercent: 0,
        successfulPings: 10,
        totalPings: 10,
        lastSuccessfulPing: Date(),
        samples: samples
    ))
    .padding()
}

#Preview("Health Popover - Fair with Loss") {
    let samples = generateSampleData(count: 15, baseRTT: 180, variance: 50, lossRate: 0.15)
    return ConnectionHealthPopover(health: ConnectionHealth(
        rttMilliseconds: 185,
        packetLossPercent: 13.3,
        successfulPings: 13,
        totalPings: 15,
        lastSuccessfulPing: Date(),
        samples: samples
    ))
    .padding()
}

#Preview("Health Popover - Poor") {
    let samples = generateSampleData(count: 12, baseRTT: 450, variance: 100, lossRate: 0.2)
    return ConnectionHealthPopover(health: ConnectionHealth(
        rttMilliseconds: 450,
        packetLossPercent: 16.7,
        successfulPings: 10,
        totalPings: 12,
        lastSuccessfulPing: Date(),
        samples: samples
    ))
    .padding()
}

#Preview("Health Popover - Unknown") {
    ConnectionHealthPopover(health: .initial)
        .padding()
}

#Preview("Health Indicator") {
    HStack(spacing: 20) {
        ConnectionHealthIndicator(health: ConnectionHealth(
            rttMilliseconds: 23,
            packetLossPercent: 0,
            successfulPings: 10,
            totalPings: 10,
            lastSuccessfulPing: Date(),
            samples: []
        ))

        ConnectionHealthIndicator(health: ConnectionHealth(
            rttMilliseconds: 150,
            packetLossPercent: 5,
            successfulPings: 9,
            totalPings: 10,
            lastSuccessfulPing: Date(),
            samples: []
        ))

        ConnectionHealthIndicator(health: .initial)
    }
    .padding()
}

#Preview("Chart Only") {
    let samples = generateSampleData(count: 20, baseRTT: 80, variance: 30, lossRate: 0.1)
    return HealthTimeSeriesChart(samples: samples)
        .padding()
        .background(Color(uiColor: .systemBackground))
}
