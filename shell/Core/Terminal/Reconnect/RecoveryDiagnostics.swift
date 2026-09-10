//
//  RecoveryDiagnostics.swift
//  shell
//
//  Bounded in-memory diagnostic ring for one recovery coordinator
//  (spec.connectivity.md §15).
//
//  What is deliberately absent is the point of this file: no commands, no
//  terminal text, no draft input, no credentials, no authentication answers,
//  no resume secrets. Everything recorded is either a fixed enum case, a
//  counter, or a duration. There is no analytics service and nothing here
//  leaves the device unless the user explicitly exports it.
//

import Foundation

/// One recorded recovery event.
struct RecoveryDiagnosticEvent: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case stateChange
        case attemptBegan
        case attemptFailed
        case attemptSucceeded
        case probeSent
        case probeResolved
        case probeDeadlineExpired
        case pathEvent
        case lifecycle
        case inputGated
        case generationRetired
    }

    var kind: Kind
    /// Observable state at the moment of the event.
    var state: RecoveryState
    /// Stage within `recovering`, when applicable.
    var stage: RecoveryStage?
    /// Typed reason code. Never a free-form server string.
    var failure: RecoveryFailure?
    var generation: UInt64
    /// 1-based ordinal within the current recovery epoch.
    var attemptOrdinal: Int
    /// Monotonic timestamp, for elapsed-time arithmetic.
    var at: MonotonicInstant
    /// Elapsed time attributable to this event, when it measures something.
    var elapsed: TimeInterval?
    var pathEligibility: RecoveryPathEligibility?
    /// Bytes transferred, when the event measures throughput.
    var byteCount: Int?
}

/// Fixed-capacity ring buffer. Oldest events are overwritten, so a session
/// left recovering overnight cannot grow this without bound (CON-08).
struct RecoveryDiagnosticRing: Sendable {
    private var storage: [RecoveryDiagnosticEvent] = []
    private var writeIndex = 0
    let capacity: Int

    init(capacity: Int = RecoveryPolicy.default.diagnosticRingDepth) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }

    mutating func record(_ event: RecoveryDiagnosticEvent) {
        if storage.count < capacity {
            storage.append(event)
            writeIndex = storage.count % capacity
        } else {
            storage[writeIndex] = event
            writeIndex = (writeIndex + 1) % capacity
        }
    }

    /// Events in chronological order, oldest first.
    var events: [RecoveryDiagnosticEvent] {
        guard storage.count == capacity else { return storage }
        return Array(storage[writeIndex...] + storage[..<writeIndex])
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        writeIndex = 0
    }

    /// Redacted, human-readable export. Identifying fields are omitted by
    /// default: the host is not named, and `RecoveryFailure.detail` (which may
    /// echo an untrusted server string) is dropped entirely.
    func redactedExport() -> String {
        events.map { event in
            var parts = [
                String(format: "%.3f", event.at.seconds),
                event.kind.rawValue,
                Self.describe(event.state),
                "gen=\(event.generation)",
                "attempt=\(event.attemptOrdinal)",
            ]
            if let stage = event.stage { parts.append("stage=\(stage.rawValue)") }
            if let failure = event.failure {
                parts.append("fail=\(failure.domain.rawValue)@\(failure.hop.rawValue)")
            }
            if let elapsed = event.elapsed {
                parts.append(String(format: "elapsed=%.3f", elapsed))
            }
            if let path = event.pathEligibility { parts.append("path=\(path.rawValue)") }
            if let bytes = event.byteCount { parts.append("bytes=\(bytes)") }
            return parts.joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    private static func describe(_ state: RecoveryState) -> String {
        switch state {
        case .live: return "live"
        case .suspect: return "suspect"
        case .waitingForConnectivity: return "waitingForConnectivity"
        case .recovering(let stage): return "recovering(\(stage.rawValue))"
        case .waitingForRetry: return "waitingForRetry"
        case .awaitingUser(let reason): return "awaitingUser(\(reason))"
        case .suspended: return "suspended"
        case .stopped: return "stopped"
        case .exited: return "exited"
        }
    }
}
