//
//  RecoveryInputGate.swift
//  shell
//
//  Input safety and backpressure for a recovering connection
//  (spec.connectivity.md §10).
//
//  Two rules drive everything here:
//
//   * While a connection is not live on the current generation, raw keystrokes
//     are NOT silently queued. Silently buffering a password and then
//     replaying it into whatever reconnects is the failure this prevents.
//     Selection, search, copy, and local cancellation stay available; the user
//     may explicitly open the compose overlay, review the destination, and
//     send.
//   * While it IS live, input stays ordered but bounded. Overflow suspends or
//     visibly rejects production. Dropping the oldest bytes or reordering a
//     control key around a paste is never an option (CON-06).
//

import Foundation

/// Every path that can produce bytes destined for the remote end. All of them
/// are gated; there is no back door for "just this one" source.
enum RecoveryInputSource: String, Equatable, Sendable, CaseIterable {
    case hardwareKeyboard
    case softwareKeyboard
    case paste
    case accessibilityAction
    case macro
    /// A reply the terminal itself generated (DA, DSR, bracketed-paste ack…).
    case terminalReply
    /// A tmux control-mode command routed from the UI.
    case tmuxCommand
}

/// What the gate decided about one production attempt.
enum RecoveryInputDecision: Equatable, Sendable {
    /// Deliver it now.
    case accept
    /// Not live on this generation. Nothing is queued; the UI explains and
    /// offers the compose overlay.
    case rejectNotLive
    /// A retired generation tried to write. Cached terminal replay must never
    /// generate replies toward a new connection.
    case rejectStaleGeneration
    /// The pending-input budget is full. Production must suspend or fail
    /// visibly before acceptance — never silently drop.
    case rejectBudgetExhausted(pendingBytes: Int, budgetBytes: Int)
}

/// Ordered, bounded input admission for one logical connection.
@MainActor
final class RecoveryInputGate {

    private let policy: RecoveryPolicy
    private(set) var pendingBytes = 0
    private(set) var generation: UInt64
    private(set) var isLive = false

    /// Latest desired terminal size. Resize is "latest wins" and is applied on
    /// attach; every intermediate rotation is discarded (§10). No other
    /// ordered action gets this treatment.
    private(set) var latestRequestedSize: TerminalGridSize?

    /// Fires when production should stop (budget full) or may continue.
    var onBackpressureChange: ((Bool) -> Void)?

    init(generation: UInt64, policy: RecoveryPolicy = .default) {
        self.generation = generation
        self.policy = policy
    }

    // MARK: - Lifecycle

    /// Adopt a new generation. Anything the old generation had pending is
    /// discarded rather than migrated: data bound to a retired writer must not
    /// be copied to its replacement.
    func adoptGeneration(_ newGeneration: UInt64) {
        generation = newGeneration
        pendingBytes = 0
        isLive = false
        onBackpressureChange?(false)
    }

    func setLive(_ live: Bool) {
        isLive = live
    }

    // MARK: - Admission

    func admit(_ byteCount: Int, from source: RecoveryInputSource, generation: UInt64) -> RecoveryInputDecision {
        guard generation == self.generation else { return .rejectStaleGeneration }
        guard isLive else { return .rejectNotLive }
        _ = source
        guard pendingBytes + byteCount <= policy.pendingInputBudgetBytes else {
            onBackpressureChange?(true)
            return .rejectBudgetExhausted(
                pendingBytes: pendingBytes, budgetBytes: policy.pendingInputBudgetBytes)
        }
        pendingBytes += byteCount
        return .accept
    }

    /// The writer confirmed `byteCount` bytes left the pending queue.
    func noteWritten(_ byteCount: Int) {
        let wasFull = pendingBytes >= policy.pendingInputBudgetBytes
        pendingBytes = max(0, pendingBytes - byteCount)
        if wasFull && pendingBytes < policy.pendingInputBudgetBytes {
            onBackpressureChange?(false)
        }
    }

    /// Record a desired size. Only the newest survives.
    func requestSize(_ size: TerminalGridSize) {
        latestRequestedSize = size
    }

    /// Consume the pending size at attach time.
    func takeRequestedSize() -> TerminalGridSize? {
        defer { latestRequestedSize = nil }
        return latestRequestedSize
    }

    /// Generation retirement: stop the old writer, cancel paste production,
    /// and discard connection-bound unsent data with an interruption
    /// indication. Bytes already accepted by a socket or an SSH write API are
    /// NOT reclassified as safe to replay.
    func retire() {
        pendingBytes = 0
        isLive = false
        latestRequestedSize = nil
        onBackpressureChange?(false)
    }
}

// MARK: - Draft

/// A local, memory-only draft of input the user composed while the connection
/// was not live.
///
/// It is bound to a logical target, capped, never auto-submitted, never
/// synced, never logged, and never added to shell history. App termination or
/// memory eviction may lose it; the UI must not promise otherwise.
@MainActor
final class RecoveryInputDraft {

    let logicalSessionID: UUID
    private let byteCap: Int
    private(set) var text: String = ""

    /// True when the last append was clipped by the cap. The UI shows this
    /// rather than silently truncating.
    private(set) var didClip = false

    init(logicalSessionID: UUID, policy: RecoveryPolicy = .default) {
        self.logicalSessionID = logicalSessionID
        self.byteCap = policy.draftByteCap
    }

    var byteCount: Int { text.utf8.count }
    var isEmpty: Bool { text.isEmpty }

    /// Append explicitly-composed text. Returns the number of bytes accepted.
    @discardableResult
    func append(_ addition: String) -> Int {
        let remaining = byteCap - byteCount
        guard remaining > 0 else {
            didClip = true
            return 0
        }
        let additionBytes = addition.utf8.count
        if additionBytes <= remaining {
            text += addition
            didClip = false
            return additionBytes
        }
        // Clip on a character boundary so the draft never holds a split UTF-8
        // sequence.
        var accepted = ""
        var used = 0
        for character in addition {
            let size = String(character).utf8.count
            if used + size > remaining { break }
            accepted.append(character)
            used += size
        }
        text += accepted
        didClip = true
        return used
    }

    func replace(with newText: String) {
        text = ""
        didClip = false
        _ = append(newText)
    }

    /// Clear the draft. Called when its logical target closes, and after the
    /// user explicitly sends it.
    func clear() {
        text = ""
        didClip = false
    }

    /// Hand the draft to the caller for an explicit, user-confirmed send.
    /// There is deliberately no automatic caller of this.
    func takeForExplicitSend() -> String {
        defer { clear() }
        return text
    }
}
