//
//  ConnectionHealthMonitor.swift
//  shell
//
//  Liveness evidence for an SSH connection (spec.connectivity.md §8).
//
//  Three things changed here from the original implementation, each of them
//  a correctness requirement rather than a tuning choice:
//
//  1. **The deadline is real.** The old code raced `client.sendKeepalive()`
//     against `Task.sleep` inside a `withThrowingTaskGroup`. A task group
//     waits for its children, and cancellation is cooperative — so when the
//     keepalive future was parked on a blackholed socket that never observes
//     cancellation, `group.cancelAll()` did nothing and the caller stayed
//     suspended past its own timeout. `withRecoveryDeadline` returns to the
//     caller regardless, which is what makes the deadline observable.
//
//  2. **One outstanding probe per connection.** SSH global-request replies
//     correspond to requests *by order* (RFC 4254 §4). Issuing a replacement
//     probe while an earlier one is unresolved means a late reply to the
//     first request can be mistaken for a reply to the second, turning a dead
//     link into a healthy-looking one. When a probe times out on a retained
//     connection its FIFO position is reserved and no replacement is sent
//     until it resolves or the connection is retired.
//
//  3. **The metric is honest.** Unanswered probes are a probe failure rate,
//     not packet loss, and cancelled or suspended samples are excluded from
//     the denominator instead of counting as failures.
//

import Foundation
import Citadel
import NIOCore
import os

/// Monitors SSH connection health by sending periodic keepalive requests and
/// tracking round-trip time and probe failure statistics.
@MainActor
final class ConnectionHealthMonitor {

    private nonisolated static let logger = Logger(
        subsystem: "dev.chr33s.shell", category: "ConnectionHealth")

    // MARK: - Configuration

    /// Interval between probes in seconds.
    private var pingInterval: TimeInterval

    /// Rolling window size (scales with interval to keep ~5 min of history).
    private var windowSize: Int

    /// Deadline for a single probe round trip.
    private static let probeDeadline: TimeInterval = RecoveryPolicy.default.probeDeadline

    private static func calculateWindowSize(for interval: TimeInterval) -> Int {
        let targetDuration: TimeInterval = 5 * 60
        return max(5, Int(targetDuration / max(1, interval)))
    }

    // MARK: - Dependencies

    private weak var client: SSHClient?

    // MARK: - State

    private var pingTask: Task<Void, Never>?
    private var pingHistory: [PingSample] = []
    private var isRunning = false

    /// A probe that was issued and has not resolved. While this is set, no
    /// replacement probe is sent: its FIFO position is reserved.
    private var outstandingProbeStartedAt: DispatchTime?

    /// True once an outstanding probe passed its deadline. Reported as
    /// "round trip unverified", never as "the server is gone".
    private var roundTripUnverified = false

    /// Last authenticated inbound activity from the destination, set by the
    /// session's output path. Periodic probes are deferred while this is
    /// fresh (§8.2).
    private var lastTargetActivity: DispatchTime?

    /// Set while user input has unfinished transport work. Inbound traffic
    /// alone is then not enough to suppress a round-trip check.
    var outboundProgressSuspect = false

    /// Watches the owned probe so a late answer still frees its FIFO slot.
    private var probeObserver: Task<Void, Never>?

    // MARK: - Callbacks

    /// Called when health metrics are updated.
    var onHealthUpdate: ((ConnectionHealth) -> Void)?

    /// Called when a probe deadline expires. The coordinator marks the round
    /// trip unverified and decides what, if anything, to do about it.
    var onProbeDeadlineExpired: (() -> Void)?

    /// Called with the measured RTT whenever a round trip is confirmed.
    var onRoundTripConfirmed: ((Double) -> Void)?

    /// Invoked when a timed-out probe's connection should be retired. The
    /// owner performs the graceful-close-then-abort sequence; returning from
    /// a timeout is not evidence that the channel was reclaimed (§8.3).
    var onRetireConnection: (() -> Void)?

    // MARK: - Initialization

    init(client: SSHClient, pingInterval: TimeInterval = RecoveryPolicy.default.probeInterval) {
        self.client = client
        // Guard before any timer is created: a malformed stored interval must
        // not produce a zero-interval spin loop (§14).
        self.pingInterval = pingInterval > 0 ? pingInterval : RecoveryPolicy.default.probeInterval
        self.windowSize = Self.calculateWindowSize(for: self.pingInterval)
    }

    /// Update the probe interval and restart the monitoring loop.
    func updateInterval(_ newInterval: TimeInterval) {
        let validated = newInterval > 0 ? newInterval : RecoveryPolicy.default.probeInterval
        guard validated != pingInterval else { return }

        pingInterval = validated
        windowSize = Self.calculateWindowSize(for: validated)

        // History from a different cadence is not comparable.
        pingHistory.removeAll()

        if isRunning {
            pingTask?.cancel()
            pingTask = Task { [weak self] in
                await self?.runPingLoop()
            }
        }
    }

    // MARK: - Public Methods

    /// Start periodic monitoring.
    ///
    /// With periodic monitoring disabled in settings this loop must not run at
    /// all; the caller enforces that. Event-driven validation
    /// (`validateNow(reason:)`) remains part of recovery either way (§8.2).
    func start() {
        guard !isRunning else { return }

        isRunning = true
        pingHistory.removeAll()
        roundTripUnverified = false

        pingTask = Task { [weak self] in
            await self?.runPingLoop()
        }
    }

    /// Stop the monitoring loop.
    func stop() {
        guard isRunning else { return }

        isRunning = false
        pingTask?.cancel()
        pingTask = nil
    }

    /// Why a one-shot validation was requested.
    enum ValidationReason: String {
        case pathChange
        case foregroundActivation
        case staleUserInteraction
        case transportError
    }

    /// Run one bounded validation of the existing transport.
    ///
    /// This is the path that stays available when periodic monitoring is off.
    /// It validates the transport *before* replacing it, so a Wi-Fi-to-cellular
    /// handoff does not tear down a connection that is still working (§8.2).
    @discardableResult
    func validateNow(reason: ValidationReason) async -> Bool {
        // A fresh request/reply that already validated this transport after
        // the event makes an extra probe pointless.
        if outstandingProbeStartedAt != nil {
            // A probe is already in flight and its answer is the validation;
            // issuing a second one would break reply ordering. Whether the
            // transport is *validated* is a different question — if that probe
            // already blew its deadline, the honest answer is no.
            Self.logger.debug("Skipping \(reason.rawValue) validation: probe already outstanding")
            return !roundTripUnverified
        }
        if hasRecentConfirmedRoundTrip(within: RecoveryPolicy.default.transportHandoffGrace) {
            return true
        }
        let sample = await sendKeepalive()
        record(sample)
        publishHealth()
        return sample.isSuccess
    }

    /// Authenticated inbound traffic arrived from the destination. A local
    /// write must never call this (§8.2).
    ///
    /// This clears the "round trip unverified" banner: bytes from the
    /// destination prove the link carries traffic. It deliberately does not
    /// invent an RTT — `rttMeasuredAt` keeps its old timestamp, so the popover
    /// shows an aged measurement rather than a fresh one it never took.
    /// Without the clear, that banner outlived the condition it described for
    /// the rest of the connection.
    func noteTargetActivity() {
        lastTargetActivity = DispatchTime.now()
        guard roundTripUnverified else { return }
        roundTripUnverified = false
        publishHealth()
    }

    // MARK: - Private Methods

    private func runPingLoop() async {
        while isRunning && !Task.isCancelled {
            await sendPingAndUpdateHealth()

            do {
                try await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
            } catch {
                break
            }
        }
    }

    private func sendPingAndUpdateHealth() async {
        guard let client, client.isConnected else { return }

        // At most one unresolved probe per connection. Its FIFO slot stays
        // reserved until it resolves or the connection is retired.
        guard outstandingProbeStartedAt == nil else {
            Self.logger.debug("Probe still outstanding; not issuing a replacement")
            return
        }

        // Recent authenticated inbound traffic already establishes freshness —
        // unless our own writes are the thing in doubt.
        if !outboundProgressSuspect, let last = lastTargetActivity,
           elapsedSeconds(since: last) < pingInterval {
            return
        }

        let sample = await sendKeepalive()
        record(sample)
        publishHealth()
    }

    private func sendKeepalive() async -> PingSample {
        guard let client else {
            return PingSample(timestamp: Date(), rttMilliseconds: nil, wasCancelled: true)
        }

        let startTime = DispatchTime.now()
        outstandingProbeStartedAt = startTime

        // The probe is owned separately from the deadline. `withRecoveryDeadline`
        // hands control back when the deadline expires, but the underlying
        // keepalive may still be parked on a socket that never observes
        // cancellation — and the spec says its FIFO slot stays reserved until
        // it resolves *or the connection is retired* (§8.3). This observer is
        // the "until it resolves" half: without it a single stalled probe
        // reserves the slot forever and the connection is never probed again.
        let probe = Task<Void, Error> { [weak client] in
            guard let client else { throw CancellationError() }
            _ = try await client.sendKeepalive()
        }
        probeObserver = Task { @MainActor [weak self] in
            let result = await probe.result
            self?.noteOutstandingProbeResolved(result, startedAt: startTime)
        }

        let outcome = await withRecoveryDeadline(
            seconds: Self.probeDeadline,
            generation: 0,
            onAbandon: { [weak self] in
                Task { @MainActor [weak self] in self?.handleProbeDeadlineExpired() }
            }
        ) {
            try await probe.value
        }

        switch outcome {
        case .completed:
            return PingSample(timestamp: Date(), rttMilliseconds: Self.calculateRTT(from: startTime))

        case .failed(let error):
            // A server is entitled to refuse an unknown global request, and
            // the refusal is itself a round trip: it proves the connection
            // carried a request and returned an answer. An authentication
            // rejection or a local error proves nothing of the sort.
            if Self.isGlobalRequestRefusal(error) {
                return PingSample(timestamp: Date(), rttMilliseconds: Self.calculateRTT(from: startTime))
            }
            return PingSample(timestamp: Date(), rttMilliseconds: nil)

        case .superseded:
            // Cancelled or retired: excluded from the failure denominator,
            // because it says nothing about the link.
            return PingSample(timestamp: Date(), rttMilliseconds: nil, wasCancelled: true)

        case .overallExpired, .inactivityExpired:
            // The slot stays reserved. The observer above releases it if the
            // probe ever answers; `releaseOutstandingProbe()` releases it when
            // the connection is retired.
            return PingSample(timestamp: Date(), rttMilliseconds: nil)
        }
    }

    /// The outstanding probe finished — possibly long after its deadline.
    ///
    /// A late reply resolves *its own* request and frees the slot. It is never
    /// allowed to acknowledge a newer request, which is why only one probe is
    /// ever outstanding in the first place (RFC 4254 §4 reply ordering).
    private func noteOutstandingProbeResolved(
        _ result: Result<Void, Error>,
        startedAt: DispatchTime
    ) {
        guard outstandingProbeStartedAt == startedAt else { return }
        outstandingProbeStartedAt = nil

        let confirmed: Bool
        switch result {
        case .success:
            confirmed = true
        case .failure(let error):
            confirmed = Self.isGlobalRequestRefusal(error)
        }

        guard confirmed else { return }
        roundTripUnverified = false
        onRoundTripConfirmed?(Self.calculateRTT(from: startedAt))
        publishHealth()
    }

    private func handleProbeDeadlineExpired() {
        roundTripUnverified = true
        Self.logger.info("Keepalive deadline expired; round trip unverified")
        onProbeDeadlineExpired?()
        publishHealth()
    }

    /// Release a reserved FIFO slot. Called when the connection is retired, so
    /// a replacement transport starts with a clean probe queue.
    func releaseOutstandingProbe() {
        probeObserver?.cancel()
        probeObserver = nil
        outstandingProbeStartedAt = nil
        roundTripUnverified = false
    }

    private static func isGlobalRequestRefusal(_ error: Error) -> Bool {
        // Citadel surfaces this as an untyped error today, so the string is
        // the only discriminator available. It is confined to this one
        // question — "was this a protocol-level refusal?" — and never used to
        // decide recovery policy.
        let description = String(describing: error)
        return description.contains("globalRequestRefused") || description.contains("RequestRefused")
    }

    private static func calculateRTT(from startTime: DispatchTime) -> Double {
        let endTime = DispatchTime.now()
        let rttNanoseconds = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
        return Double(rttNanoseconds) / 1_000_000.0
    }

    private func elapsedSeconds(since instant: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - instant.uptimeNanoseconds) / 1_000_000_000
    }

    private func hasRecentConfirmedRoundTrip(within window: TimeInterval) -> Bool {
        guard let last = pingHistory.last(where: { $0.isSuccess }) else { return false }
        return Date().timeIntervalSince(last.timestamp) < window
    }

    private func record(_ sample: PingSample) {
        pingHistory.append(sample)
        if pingHistory.count > windowSize {
            pingHistory.removeFirst(pingHistory.count - windowSize)
        }
    }

    private func publishHealth() {
        onHealthUpdate?(calculateHealth())
    }

    func calculateHealth() -> ConnectionHealth {
        guard !pingHistory.isEmpty else {
            var initial = ConnectionHealth.initial
            initial.roundTripUnverified = roundTripUnverified
            return initial
        }

        // Cancelled and suspended samples are not evidence about the link, so
        // they are excluded from both numerator and denominator.
        let counted = pingHistory.filter(\.countsTowardFailureRate)
        let successful = counted.filter(\.isSuccess)
        let total = counted.count

        let failurePercent = total > 0
            ? Double(total - successful.count) / Double(total) * 100.0
            : 0.0

        let lastSuccess = successful.last

        return ConnectionHealth(
            rttMilliseconds: lastSuccess?.rttMilliseconds,
            probeFailurePercent: failurePercent,
            successfulPings: successful.count,
            totalPings: total,
            lastSuccessfulPing: lastSuccess?.timestamp,
            rttMeasuredAt: lastSuccess?.timestamp,
            roundTripUnverified: roundTripUnverified,
            samples: pingHistory
        )
    }

    // MARK: - Deinit

    nonisolated deinit {
        pingTask?.cancel()
        probeObserver?.cancel()
    }
}
