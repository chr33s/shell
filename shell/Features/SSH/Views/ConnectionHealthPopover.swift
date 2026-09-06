//
//  ConnectionHealthPopover.swift
//  shell
//
//  Detail readout for the tab-bar connection-health dot, shown on pointer
//  hover (see `TabHoverController` / `TabBarItem`).
//
//  Scope note: this used to carry a 110-line `HealthTimeSeriesChart` Canvas
//  that drew a 5-minute RTT sparkline. Nothing outside its own `#Preview`
//  blocks ever rendered it, and a chart does not make the terminal render,
//  establish an SSH identity, make SSH connect, make tmux work, or make any of
//  those sync — so it was dropped rather than wired up. What survives is the
//  part the monitor actually exists to report: the numbers it measures on
//  every probe (`ConnectionHealthMonitor.updateHealth`) and previously threw
//  away — RTT, packet loss, sample counts, and the age of the last reply.
//

import SwiftUI

// MARK: - Health Popover

/// Popover body showing the connection-health metrics for one tab.
///
/// Presented inside a system popover, which supplies the card chrome — this
/// view draws no background, shadow or border of its own.
struct ConnectionHealthPopover: View {
    let health: ConnectionHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: quality dot + "23ms (Excellent)" / "Measuring…"
            HStack(spacing: 8) {
                Circle()
                    .fill(health.quality.color)
                    .frame(width: 10, height: 10)

                Text(health.statusDescription)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }

            if health.totalPings > 0 {
                Divider()

                metricRow(
                    Text("Packet loss"),
                    value: Text(String(format: "%.1f%%", health.packetLossPercent)),
                    // The indicator turns red at 2-of-3 poor samples; call out
                    // loss on the same side of "this link is bad" so the two
                    // readouts cannot disagree.
                    valueColor: health.packetLossPercent > 10 ? .appDanger : .primary
                )

                metricRow(
                    Text("Replies"),
                    value: Text("\(health.successfulPings)/\(health.totalPings)"),
                    valueColor: .primary
                )

                if let lastPing = health.lastSuccessfulPing {
                    metricRow(
                        Text("Last reply"),
                        value: Text(lastPing, format: .relative(presentation: .numeric)),
                        valueColor: .primary
                    )
                }
            }
        }
        .padding(14)
        .frame(width: 220)
    }

    private func metricRow(_ label: Text, value: Text, valueColor: Color) -> some View {
        HStack {
            label
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(valueColor)
        }
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

// MARK: - Previews

#Preview("Health Popover - Excellent") {
    ConnectionHealthPopover(health: ConnectionHealth(
        rttMilliseconds: 23,
        packetLossPercent: 0,
        successfulPings: 10,
        totalPings: 10,
        lastSuccessfulPing: Date(),
        samples: []
    ))
    .padding()
}

#Preview("Health Popover - Fair with Loss") {
    ConnectionHealthPopover(health: ConnectionHealth(
        rttMilliseconds: 185,
        packetLossPercent: 13.3,
        successfulPings: 13,
        totalPings: 15,
        lastSuccessfulPing: Date().addingTimeInterval(-45),
        samples: []
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
