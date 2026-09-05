//
//  ConnectionHealthMonitor.swift
//  shell
//
//  Monitors SSH connection health via keepalive requests
//

import Foundation
import Citadel
import NIOCore

/// Monitors SSH connection health by sending periodic keepalive requests
/// and tracking RTT and packet loss statistics.
@MainActor
final class ConnectionHealthMonitor {

    // MARK: - Configuration

    /// Interval between keepalive pings in seconds (configurable)
    private var pingInterval: TimeInterval

    /// Rolling window size for packet loss calculation (scales with interval to maintain ~5 min history)
    private var windowSize: Int

    /// Timeout for individual ping responses in seconds
    private static let pingTimeout: TimeInterval = 10.0

    /// Calculate window size to maintain approximately 5 minutes of history
    private static func calculateWindowSize(for interval: TimeInterval) -> Int {
        let targetDuration: TimeInterval = 5 * 60 // 5 minutes
        return max(5, Int(targetDuration / interval))
    }

    // MARK: - Dependencies

    private weak var client: SSHClient?

    // MARK: - State

    private var pingTask: Task<Void, Never>?
    private var pingHistory: [PingResult] = []
    private var isRunning = false

    /// Result of a single ping attempt
    private struct PingResult {
        let timestamp: Date
        /// RTT in milliseconds, nil if timeout/failure
        let rttMilliseconds: Double?

        var isSuccess: Bool { rttMilliseconds != nil }
    }

    // MARK: - Callbacks

    /// Called when health metrics are updated
    var onHealthUpdate: ((ConnectionHealth) -> Void)?

    // MARK: - Initialization

    init(client: SSHClient, pingInterval: TimeInterval = 15.0) {
        self.client = client
        self.pingInterval = pingInterval
        self.windowSize = Self.calculateWindowSize(for: pingInterval)
    }

    /// Update the ping interval and restart the monitoring loop
    func updateInterval(_ newInterval: TimeInterval) {
        guard newInterval != pingInterval else { return }

        pingInterval = newInterval
        windowSize = Self.calculateWindowSize(for: newInterval)

        // Clear history when interval changes to avoid mixing data from different intervals
        pingHistory.removeAll()

        // Restart the ping loop if running
        if isRunning {
            pingTask?.cancel()
            pingTask = Task { [weak self] in
                await self?.runPingLoop()
            }
        }
    }

    // MARK: - Public Methods

    /// Start the health monitoring loop
    func start() {
        guard !isRunning else { return }

        isRunning = true
        pingHistory.removeAll()

        pingTask = Task { [weak self] in
            await self?.runPingLoop()
        }
    }

    /// Stop the health monitoring loop
    func stop() {
        guard isRunning else { return }

        isRunning = false
        pingTask?.cancel()
        pingTask = nil
    }

    /// Reset the measurement window (e.g., after network change)
    func resetWindow() {
        pingHistory.removeAll()
        // Immediately publish empty/initial state
        onHealthUpdate?(.initial)
    }

    // MARK: - Private Methods

    private func runPingLoop() async {
        while isRunning && !Task.isCancelled {
            await sendPingAndUpdateHealth()

            // Wait for next interval
            do {
                try await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
            } catch {
                // Task was cancelled
                break
            }
        }
    }

    private func sendPingAndUpdateHealth() async {
        guard let client = client, client.isConnected else { return }

        let result = await sendKeepalive()
        recordResult(result)
        let health = calculateHealth()
        onHealthUpdate?(health)
    }

    private func sendKeepalive() async -> PingResult {
        guard let client = client else {
            return PingResult(timestamp: Date(), rttMilliseconds: nil)
        }

        let startTime = DispatchTime.now()

        do {
            // Race the keepalive against a timeout
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await client.sendKeepalive()
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.pingTimeout * 1_000_000_000))
                    throw KeepaliveError.timeout
                }

                // Wait for first to complete
                try await group.next()
                group.cancelAll()
            }

            let rttMs = Self.calculateRTT(from: startTime)
            return PingResult(timestamp: Date(), rttMilliseconds: rttMs)

        } catch is CancellationError {
            return PingResult(timestamp: Date(), rttMilliseconds: nil)
        } catch KeepaliveError.timeout {
            return PingResult(timestamp: Date(), rttMilliseconds: nil)
        } catch {
            // Check if this is a "request refused" error - this still proves connection is alive!
            // SSH servers are allowed to refuse unknown global requests, but the refusal
            // is itself a valid response that confirms the connection is working.
            let errorString = String(describing: error)
            if errorString.contains("globalRequestRefused") || errorString.contains("RequestRefused") {
                let rttMs = Self.calculateRTT(from: startTime)
                return PingResult(timestamp: Date(), rttMilliseconds: rttMs)
            }

            return PingResult(timestamp: Date(), rttMilliseconds: nil)
        }
    }

    /// Calculate RTT in milliseconds from a start time
    private static func calculateRTT(from startTime: DispatchTime) -> Double {
        let endTime = DispatchTime.now()
        let rttNanoseconds = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
        return Double(rttNanoseconds) / 1_000_000.0  // Convert to milliseconds
    }

    private func recordResult(_ result: PingResult) {
        pingHistory.append(result)

        // Trim to window size
        if pingHistory.count > windowSize {
            pingHistory.removeFirst(pingHistory.count - windowSize)
        }
    }

    private func calculateHealth() -> ConnectionHealth {
        guard !pingHistory.isEmpty else {
            return .initial
        }

        let successful = pingHistory.filter { $0.isSuccess }
        let total = pingHistory.count

        // Calculate packet loss percentage
        let lossPercent = total > 0
            ? Double(total - successful.count) / Double(total) * 100.0
            : 0.0

        // Get most recent RTT (or average of last few successful pings)
        let recentRTT: Double?
        if let lastSuccess = successful.last {
            recentRTT = lastSuccess.rttMilliseconds
        } else {
            recentRTT = nil
        }

        // Convert internal PingResult to public PingSample for time series display
        let samples = pingHistory.map { PingSample(timestamp: $0.timestamp, rttMilliseconds: $0.rttMilliseconds) }

        return ConnectionHealth(
            rttMilliseconds: recentRTT,
            packetLossPercent: lossPercent,
            successfulPings: successful.count,
            totalPings: total,
            lastSuccessfulPing: successful.last?.timestamp,
            samples: samples
        )
    }

    // MARK: - Errors

    private enum KeepaliveError: Error {
        case timeout
    }

    // MARK: - Deinit

    nonisolated deinit {
        pingTask?.cancel()
    }
}
