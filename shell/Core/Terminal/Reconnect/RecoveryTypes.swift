//
//  RecoveryTypes.swift
//  shell
//
//  Typed vocabulary for connection recovery (spec.connectivity.md §5-§7).
//
//  Everything here is a value type with no UIKit, Ghostty, or network
//  dependency, so `RecoveryCoordinator` policy can be exercised in a unit
//  test with an injected clock. Nothing in this file may import Citadel or
//  SwiftUI.
//

import Foundation

// MARK: - Intent

/// Why this logical connection exists. Recovery policy branches on the typed
/// intent — never on command text (CON-04: replay safety is never inferred).
enum RecoveryIntent: Equatable, Sendable {
    /// Reattach to a specific, already-existing tmux session.
    case attachExistingTmux
    /// An interactive remote shell with no multiplexer continuity promise.
    case interactiveShell
    /// A single non-interactive `exec` command. Never re-dispatched.
    case oneShotCommand

    /// Whether a *new* transport can restore the user's previous terminal.
    /// Plain SSH cannot: a replacement transport is a new shell (CON-09).
    var promisesSessionContinuity: Bool {
        self == .attachExistingTmux
    }

    /// Whether an automatic replacement attempt may run at all after the
    /// work may already have been dispatched remotely.
    var allowsAutomaticRedial: Bool {
        self != .oneShotCommand
    }
}

// MARK: - Observable state

/// Stage within `recovering`. Split out so the UI can name the hop that is
/// actually in progress without the state enum growing associated-value noise.
enum RecoveryStage: String, Equatable, Sendable, CaseIterable {
    case connecting
    case authenticating
    case attaching
    case synchronizing
}

/// Why recovery stopped and is waiting for a human (§6). Network restoration
/// never bypasses these.
enum RecoveryAttentionReason: Equatable, Sendable {
    case hostTrustRejected
    case credentialUnavailable
    case authenticationCancelled
    case commandOutcomeUnknown
    case tmuxSessionMissing
    case tmuxIdentityAmbiguous
    case unsupportedRecovery
    case protocolIncompatible
    case burstExhausted
    case autoReconnectDisabled
    /// A keepalive went unanswered and nothing since has proved the link
    /// carries traffic. The remote process is NOT known to be gone — which is
    /// why a plain shell is offered a choice rather than being replaced.
    case roundTripUnverified
}

/// Observable recovery state (§6). Internal transport detail may be richer;
/// this is the surface the UI and tests assert on.
enum RecoveryState: Equatable, Sendable {
    case live
    case suspect
    case waitingForConnectivity
    case recovering(stage: RecoveryStage)
    case waitingForRetry(deadline: MonotonicInstant)
    case awaitingUser(reason: RecoveryAttentionReason)
    case suspended(savedIntent: RecoveryIntent)
    case stopped
    case exited

    /// States where an automatic attempt is still expected to follow.
    var isActiveRecovery: Bool {
        switch self {
        case .suspect, .waitingForConnectivity, .recovering, .waitingForRetry:
            return true
        case .live, .awaitingUser, .suspended, .stopped, .exited:
            return false
        }
    }

    /// `stopped` and `exited` are terminal for their intent: only a new user
    /// action starts another one.
    var isTerminal: Bool {
        self == .stopped || self == .exited
    }

    /// Whether remote input may be delivered. Only a fully live,
    /// current-generation connection accepts keystrokes (§10).
    var acceptsRemoteInput: Bool {
        self == .live
    }
}

// MARK: - Failure classification

/// Which hop a failure is attributed to. A jump-host rejection must never be
/// reported as a destination rejection (§15).
enum RecoveryHop: String, Equatable, Sendable {
    case jumpHost
    case destination
    case tmuxServer
    case local
}

/// Typed failure domain. Classification is by error *type*, never by matching
/// substrings of a localized message (§7.3).
enum RecoveryFailureDomain: String, Equatable, Sendable {
    case transportUnavailable
    case timeout
    case authenticationNeeded
    case authenticationRejected
    case hostTrustRejected
    case cancelled
    case sessionMissing
    case remoteExit
    case protocolMismatch
    case resourceLimit
    /// The stored configuration cannot produce a connection at all (a profile
    /// referencing a deleted identity, say). Retrying it changes nothing.
    case configurationInvalid
    case unknown
}

/// A classified failure: domain plus the hop that produced it.
struct RecoveryFailure: Equatable, Sendable {
    var domain: RecoveryFailureDomain
    var hop: RecoveryHop
    /// Untrusted, display-only detail. Never parsed to make policy decisions.
    var detail: String?

    init(domain: RecoveryFailureDomain, hop: RecoveryHop = .destination, detail: String? = nil) {
        self.domain = domain
        self.hop = hop
        self.detail = detail
    }

    /// Whether an automatic replacement attempt is allowed to follow.
    /// `unknown` gets the bounded burst, then requires attention (§7.3).
    var isAutomaticallyRetryable: Bool {
        switch domain {
        case .transportUnavailable, .timeout, .resourceLimit, .unknown:
            return true
        case .authenticationNeeded, .authenticationRejected, .hostTrustRejected,
             .cancelled, .sessionMissing, .remoteExit, .protocolMismatch,
             .configurationInvalid:
            return false
        }
    }

    /// The attention state this failure lands in when it is not retryable.
    var attentionReason: RecoveryAttentionReason? {
        switch domain {
        case .authenticationNeeded: return .credentialUnavailable
        case .authenticationRejected: return .authenticationCancelled
        case .hostTrustRejected: return .hostTrustRejected
        case .sessionMissing: return .tmuxSessionMissing
        case .protocolMismatch: return .protocolIncompatible
        case .configurationInvalid: return .unsupportedRecovery
        case .cancelled, .remoteExit: return nil
        case .transportUnavailable, .timeout, .resourceLimit, .unknown: return nil
        }
    }
}

// MARK: - Readiness

/// What a readiness event actually proves (§9.5). `transportEstablished` alone
/// is never reported to the user as a restored session (CON-03).
enum RecoveryReadinessKind: String, Equatable, Sendable {
    /// TCP + SSH authentication completed. Proves nothing about a terminal.
    case transportEstablished
    /// PTY allocated, shell/exec request accepted, I/O handlers installed.
    case terminalReady
    /// tmux topology committed AND the visible pane's contents synchronized.
    case tmuxSessionRestored
    /// A new remote shell was opened. Explicitly NOT a restored session.
    case newShellOpened
}

/// Readiness evidence. Carries the generation so a superseded attempt's late
/// readiness cannot be adopted (CON-02).
struct RecoveryReadiness: Equatable, Sendable {
    var kind: RecoveryReadinessKind
    var generation: UInt64
}

// MARK: - Outcome shown to the user

/// The three outcomes Shell must distinguish (§1).
enum RecoveryOutcome: String, Equatable, Sendable {
    case sessionRestored
    case newShellOpened
    case commandOutcomeUnknown
}

// MARK: - Path evidence

/// Destination-relevant reachability evidence. A generic `NWPathMonitor`
/// result is a hint, not an absolute gate (§7.2), so `unknown` remains
/// eligible for a bounded attempt.
enum RecoveryPathEligibility: String, Equatable, Sendable {
    /// A usable route to the destination is plausible.
    case eligible
    /// Evidence establishes there is no usable route. Pause dialing.
    case unavailable
    /// VPN on-demand / unknown interface state. Still allowed one bounded try.
    case unknown

    var permitsDialing: Bool { self != .unavailable }
}

// MARK: - Monotonic time

/// A monotonic instant. Retry arithmetic must never use wall-clock time (§7.3);
/// wall clock is reserved for presentation.
struct MonotonicInstant: Equatable, Comparable, Hashable, Sendable {
    /// Seconds since an arbitrary fixed origin.
    var seconds: TimeInterval

    init(seconds: TimeInterval) { self.seconds = seconds }

    static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.seconds < rhs.seconds
    }

    func advanced(by interval: TimeInterval) -> MonotonicInstant {
        MonotonicInstant(seconds: seconds + interval)
    }

    func elapsed(since earlier: MonotonicInstant) -> TimeInterval {
        seconds - earlier.seconds
    }
}

/// Monotonic clock abstraction so tests never sleep.
protocol RecoveryClock: Sendable {
    var now: MonotonicInstant { get }
}

/// Production clock: `DispatchTime.uptimeNanoseconds` does not move backwards
/// and is unaffected by wall-clock adjustments.
struct SystemRecoveryClock: RecoveryClock {
    nonisolated init() {}
    var now: MonotonicInstant {
        MonotonicInstant(seconds: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000)
    }
}

/// Jitter abstraction so backoff schedules are deterministic under test.
protocol RecoveryJitterSource: Sendable {
    /// Returns a value in `0..<1`.
    func nextUnitInterval() -> Double
}

struct SystemRecoveryJitter: RecoveryJitterSource {
    nonisolated init() {}
    func nextUnitInterval() -> Double { Double.random(in: 0..<1) }
}

/// Deterministic jitter for tests: a seeded linear congruential generator.
/// Not for cryptographic use — it only shapes retry timing.
final class SeededRecoveryJitter: RecoveryJitterSource, @unchecked Sendable {
    private let lock = NSLock()
    private var state: UInt64

    init(seed: UInt64 = 0x2545_F491_4F6C_DD1D) {
        self.state = seed == 0 ? 1 : seed
    }

    func nextUnitInterval() -> Double {
        lock.lock()
        defer { lock.unlock() }
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}
