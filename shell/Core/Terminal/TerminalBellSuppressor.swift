import Foundation
import os

/// Tracks repaints we forced ourselves, per terminal, so that the bells they
/// provoke are not mistaken for news.
///
/// A tssh reattach makes the remote redraw from both ends: the app sends a
/// resize jiggle (`TrzszSession.attemptResume`) and tsshd's attach handler
/// does its own unconditionally. The remote answers that repaint with a BEL
/// somewhere in the byte stream. Backgrounded output makes it worse — the
/// core's `GHOSTTY_ACTION_RING_BELL` guard drops bells while backgrounded,
/// but the *bytes* are buffered and replayed once we return, so a whole
/// suspension's worth fires at once. None of those carry information: we
/// asked for the bytes.
///
/// Two lifetimes, because the replays end differently:
///
/// - **Deadline** (`suppress(_:for:)`) for a bounded forced repaint, where
///   the bytes are already on their way.
/// - **Hold** (`suppress(_:untilDrained:)`) for a gated replay, released on
///   the pipeline's own drain callback. A scrollback restore can hold its
///   gate open until the embedded session reaches `.running`, which is
///   unbounded, so no fixed deadline can cover it.
///
/// Deliberately `nonisolated`: the trzsz backlog is released from
/// `TrzszGoTransport.flushBackgroundedOutput` on a Go callback thread, and
/// arming has to land *before* those bytes reach the core. Hopping to the
/// main actor first would let the bell win the race.
///
/// Suppressing a tmux -CC gateway covers its panes: the panes are separate
/// surfaces that the gateway's session never sees, so `ringBell()` checks
/// the pane's `tmuxPaneBinding.parentUUID` as well as its own id rather than
/// fanning out at arm time.
nonisolated enum TerminalBellSuppressor {
    /// One forced-repaint round trip (reattach, tmux recapture).
    static let forcedRedraw: TimeInterval = 3

    /// Tail after a gated replay drains. The writer has handed the bytes to
    /// the pipe by then, but the core still has to parse them.
    private static let drainTail: TimeInterval = 1

    /// A hold whose release is lost must not mute a terminal forever.
    private static let holdCap: TimeInterval = 30

    private struct State: Sendable {
        var until: Date = .distantPast
        var holds: Int = 0
        var holdExpiry: Date = .distantPast

        /// Whether the terminal is muted — and, since that is the only thing
        /// an entry records, whether the entry is worth keeping at all.
        func mutesBell(_ now: Date) -> Bool {
            (holds > 0 && now < holdExpiry) || now < until
        }
    }

    private static let states = OSAllocatedUnfairLock<[UUID: State]>(initialState: [:])

    /// Mutes `id` for at least `interval`.
    static func suppress(_ id: UUID, for interval: TimeInterval, now: Date = Date()) {
        states.withLock { entries in
            entries = entries.filter { $0.value.mutesBell(now) }
            var state = entries[id] ?? State()
            state.until = max(state.until, now.addingTimeInterval(interval))
            entries[id] = state
        }
    }

    /// Mutes `id` until `pipeline` reports its buffered bytes have drained.
    /// Call immediately after releasing a scrollback-restore gate.
    @MainActor
    static func suppress(_ id: UUID, untilDrained pipeline: TerminalOutputPipeline) {
        let now = Date()
        states.withLock { entries in
            entries = entries.filter { $0.value.mutesBell(now) }
            var state = entries[id] ?? State()
            state.holds += 1
            state.holdExpiry = now.addingTimeInterval(holdCap)
            entries[id] = state
        }
        pipeline.notifyWhenOutputDrained { releaseHold(id) }
    }

    static func isSuppressed(_ id: UUID, now: Date = Date()) -> Bool {
        states.withLock { entries in
            guard let state = entries[id] else { return false }
            if state.mutesBell(now) { return true }
            entries.removeValue(forKey: id)
            return false
        }
    }

    private static func releaseHold(_ id: UUID) {
        let now = Date()
        states.withLock { entries in
            guard var state = entries[id], state.holds > 0 else { return }
            state.holds -= 1
            if state.holds == 0 { state.holdExpiry = .distantPast }
            // The core is still parsing what just drained.
            state.until = max(state.until, now.addingTimeInterval(drainTail))
            entries[id] = state
        }
    }
}
