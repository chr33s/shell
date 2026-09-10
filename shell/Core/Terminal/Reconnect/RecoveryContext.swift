//
//  RecoveryContext.swift
//  shell
//
//  The logical session model that survives transport replacement
//  (spec.connectivity.md §5).
//
//  Nothing here holds a Task, a channel, key material, or a Ghostty pointer:
//  the context outlives every one of those, and a descriptor built from it is
//  written to device-local storage. Credentials are referenced, then resolved
//  through the existing identity layer at connection time.
//

import Foundation

// MARK: - Target identity

/// The trust scope a recovery attempt must reconnect with, unchanged.
///
/// DNS may resolve to a different address between attempts; that is transport
/// metadata. The identity below is what host-key verification and credential
/// selection are bound to, and recovery may never weaken it (§15).
struct RecoveryTargetIdentity: Equatable, Hashable, Sendable, Codable {
    var host: String
    var port: Int
    var username: String
    /// Opaque reference to the credential, resolved at connection time. Never
    /// the secret itself.
    var credentialReference: String?
    /// `user@host:port` of the configured jump host, when one applies.
    var jumpHostDescriptor: String?
    /// Explicit tmux socket selection, when the profile pins one.
    var tmuxSocket: String?

    /// Route key for the global scheduler's per-route concurrency limit.
    /// Two connections sharing this key must not dial simultaneously.
    var routeKey: String {
        var key = "\(username)@\(host):\(port)"
        if let jumpHostDescriptor { key += "|via:\(jumpHostDescriptor)" }
        if let credentialReference { key += "|cred:\(credentialReference)" }
        return key
    }

    /// Stable key for per-connection stored state (matches the existing
    /// `TmuxGatewaySessionStore` connection key shape).
    var connectionKey: String { "\(username)@\(host):\(port)" }
}

// MARK: - tmux identity

/// Server-instance and session evidence used to prove that the tmux session
/// being reattached is the *same* session (§9.1).
///
/// None of these fields is a credential or a cryptographic incarnation ID.
/// They are the strongest continuity evidence a stock tmux server exposes.
struct TmuxContinuityEvidence: Equatable, Sendable, Codable {
    /// tmux socket path in use.
    var socketPath: String?
    /// `#{pid}` of the tmux server process.
    var serverPID: Int?
    /// `#{start_time}` of the tmux server, as reported by the server.
    var serverStartTime: String?
    /// `#{session_id}` (the `$N` id), stored numerically.
    var sessionID: Int?
    /// `#{session_created}` — session creation metadata.
    var sessionCreated: String?
    /// Last observed display name. Display data only: a rename must not break
    /// continuity, and a reused name must not establish it.
    var lastObservedName: String?
    /// Window ids observed at the last successful synchronization.
    var windowIDs: [Int] = []
    /// Pane ids observed at the last successful synchronization.
    var paneIDs: [Int] = []

    /// Whether this evidence is strong enough to claim continuity at all.
    /// Legacy name-only state is deliberately insufficient (§9.1).
    var isSufficientForContinuity: Bool {
        sessionID != nil && (serverPID != nil || serverStartTime != nil) && sessionCreated != nil
    }

    /// Does `other` (freshly discovered after reattachment) describe the same
    /// session as this stored evidence?
    ///
    /// A renamed session with matching evidence is the same session. A name
    /// reused by a different session is not — which is why the name is not
    /// consulted here at all.
    func matches(_ other: TmuxContinuityEvidence) -> Bool {
        guard isSufficientForContinuity, other.isSufficientForContinuity else { return false }
        guard sessionID == other.sessionID else { return false }
        guard sessionCreated == other.sessionCreated else { return false }

        // The server must be the same *instance*. A restarted server can hand
        // out the same `$0` with a fresh creation time, so both halves matter.
        if let pid = serverPID, let otherPID = other.serverPID, pid != otherPID { return false }
        if let start = serverStartTime, let otherStart = other.serverStartTime, start != otherStart {
            return false
        }
        if let socketPath, let otherSocket = other.socketPath, socketPath != otherSocket {
            return false
        }
        return true
    }
}

// MARK: - Attempt accounting

/// Retry bookkeeping. `dialCount` counts attempts that actually *began*
/// dialing — waiting, path events, cancelled waits, and suspension consume
/// nothing (§7.1).
struct RecoveryAttemptState: Equatable, Sendable {
    /// Attempts begun in the current recovery epoch.
    var dialCount: Int = 0
    /// Monotonic deadline of the pending scheduled wait, when one exists.
    var backoffDeadline: MonotonicInstant?
    /// Bumped whenever a new recovery intent supersedes the previous one.
    var epoch: UInt64 = 0
    /// True once `dialCount` has reached the burst limit; the coordinator
    /// keeps the intent and continues at the cooldown rate.
    var inCooldown: Bool = false
    /// Monotonic instant of the most recent fast-path bypass.
    var lastFastPathBypass: MonotonicInstant?
    /// Set by explicit cancellation; blocks adoption of in-flight results.
    var isCancelled: Bool = false

    mutating func beginEpoch() {
        epoch &+= 1
        dialCount = 0
        backoffDeadline = nil
        inCooldown = false
        isCancelled = false
    }
}

// MARK: - Freshness

/// Liveness evidence, kept per-source because they answer different questions
/// (§8.1). A healthy SSH channel may still carry a stale pane.
struct RecoveryFreshness: Equatable, Sendable {
    /// Last authenticated inbound traffic from the *destination* connection,
    /// not merely its bastion.
    var lastTargetActivity: MonotonicInstant?
    /// Last completed request/reply round trip.
    var lastConfirmedRoundTrip: MonotonicInstant?
    /// Measured RTT of `lastConfirmedRoundTrip`, in milliseconds.
    var lastRoundTripMilliseconds: Double?
    /// When the visible pane's state was last known synchronized.
    var lastPaneSync: MonotonicInstant?
    /// A probe is outstanding. At most one per SSH connection (§8.3).
    var probeOutstanding: Bool = false

    /// Age of the last confirmed round trip. `nil` when none has completed,
    /// which is displayed as "not yet verified" rather than as zero.
    func roundTripAge(now: MonotonicInstant) -> TimeInterval? {
        lastConfirmedRoundTrip.map { now.elapsed(since: $0) }
    }

    /// Age of the last authenticated inbound byte from the destination.
    func targetActivityAge(now: MonotonicInstant) -> TimeInterval? {
        lastTargetActivity.map { now.elapsed(since: $0) }
    }

    /// Whether a periodic probe can be skipped because recent inbound traffic
    /// already establishes freshness (§8.2).
    func inboundFreshnessSuppressesProbe(
        now: MonotonicInstant,
        interval: TimeInterval,
        outboundSuspect: Bool
    ) -> Bool {
        // Outstanding user input with unfinished transport work means inbound
        // traffic alone proves the server is talking, not that our writes are
        // landing. Never suppress the round-trip check in that case.
        guard !outboundSuspect else { return false }
        guard let age = targetActivityAge(now: now) else { return false }
        return age < interval
    }
}

// MARK: - Presentation

/// Local, view-side identity that survives transport replacement (§5, §12).
/// Deliberately holds no viewer pointer: a freed surface must never be
/// retained across a recovery.
struct RecoveryPresentationState: Equatable, Sendable {
    var tabID: UUID?
    var paneID: UUID?
    var isSelected: Bool = false
    /// Latest requested size. Only the newest is applied on reattach — every
    /// intermediate rotation/keyboard resize is discarded (§10).
    var latestRequestedSize: TerminalGridSize?
    /// Whether the retained display is stale (frozen last-valid screen).
    var isStale: Bool = false
}

/// Plain grid dimensions, decoupled from `TerminalPTY.TerminalSize` so the
/// context stays free of terminal-layer imports.
struct TerminalGridSize: Equatable, Sendable, Codable {
    var rows: UInt16
    var cols: UInt16
}

// MARK: - Context

/// The logical connection, owned above the SSH session object.
///
/// The SSH session, its channels, and its Ghostty surface are all replaceable
/// below this. The `logicalSessionID` is what the user thinks of as "my
/// session", and it never changes across a recovery.
struct RecoveryContext: Equatable, Sendable {
    /// Local UUID retained across replacement transports. Gateway-scoped for
    /// control mode: projected panes share their gateway's context (CON-01).
    let logicalSessionID: UUID

    /// Monotonically advancing local generation. Incremented *before* retiring
    /// a transport or changing intent, so a superseded callback can be
    /// recognised the moment it arrives (CON-02).
    ///
    /// This is an ownership token only: not a server instance id, and not a
    /// resumable-stream byte offset.
    private(set) var connectionGeneration: UInt64 = 1

    var intent: RecoveryIntent
    var targetIdentity: RecoveryTargetIdentity
    var tmuxIdentity: TmuxContinuityEvidence?

    /// Whether this connection can actually *prove* tmux continuity.
    ///
    /// True for control mode, which has a command channel to ask the server
    /// for session and server metadata over. Regular tmux mode has no such
    /// channel, so it attaches by name without creating and reports
    /// attachment readiness — it never claims the pane-by-pane guarantee
    /// (§9.2). Holding a regular-mode recovery open waiting for a
    /// verification that can never arrive would hang it forever.
    var verifiesTmuxContinuity: Bool = false
    /// Snapshot of the applicable settings. Configuration changes are adopted
    /// at an explicit boundary, never mid-recovery (§5).
    var recoveryPreference: RecoveryPolicy
    var attemptState = RecoveryAttemptState()
    var freshness = RecoveryFreshness()
    var presentationState = RecoveryPresentationState()

    init(
        logicalSessionID: UUID = UUID(),
        intent: RecoveryIntent,
        targetIdentity: RecoveryTargetIdentity,
        policy: RecoveryPolicy = .default
    ) {
        self.logicalSessionID = logicalSessionID
        self.intent = intent
        self.targetIdentity = targetIdentity
        self.recoveryPreference = policy
    }

    /// Retire the current generation and return the new one. Every
    /// asynchronous callback carrying an older generation must be discarded.
    @discardableResult
    mutating func advanceGeneration() -> UInt64 {
        connectionGeneration &+= 1
        return connectionGeneration
    }

    /// Whether a callback tagged with `generation` may still mutate state.
    func isCurrent(_ generation: UInt64) -> Bool {
        generation == connectionGeneration && !attemptState.isCancelled
    }
}
