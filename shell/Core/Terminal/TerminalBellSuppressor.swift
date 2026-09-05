import Foundation
import os

/// Tracks repaints we forced ourselves, per terminal, for the consumers that
/// must not mistake them for news: bells, and agent detection.
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
/// Three lifetimes, because the replays end differently and the consumers
/// need different things from them:
///
/// - **Deadline** (`suppress(_:for:)`) for a bounded forced repaint, where
///   the bytes are already on their way.
/// - **Hold** (`suppress(_:untilDrained:)`) for a gated replay, released on
///   the pipeline's own drain callback. A scrollback restore can hold its
///   gate open until the embedded session reaches `.running`, which is
///   unbounded, so no fixed deadline can cover it.
/// - **Rebuild** (`suppressRebuild(_:)`) for agent detection, which
///   re-classifies from the rebuilt *screen* and so has to see the repaint
///   SETTLE rather than merely start.
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

    /// How long a forced repaint is assumed to still be rebuilding the screen.
    /// Longer than `forcedRedraw` because bells only need the bytes to have
    /// arrived, while agent detection needs the screen to have stopped moving.
    static let forcedRebuild: TimeInterval = 10

    /// How far past the last replayed byte an open rebuild window is held.
    /// Deliberately much shorter than `forcedRebuild`: a pane that is simply
    /// working emits content edges forever, and granting each one a whole
    /// fresh interval would pin the window to its cap on every reconnect.
    private static let rebuildStreamingGrace: TimeInterval = 3

    /// A long replay extends the rebuild window repeatedly. Without a ceiling
    /// it could freeze a pane's agent notifications indefinitely, so a single
    /// unbroken window can never run more than this past the arm that opened
    /// it.
    private static let rebuildCap: TimeInterval = 30

    /// Tail after a gated replay drains. The writer has handed the bytes to
    /// the pipe by then, but the core still has to parse them.
    private static let drainTail: TimeInterval = 1

    /// A hold whose release is lost must not mute a terminal forever.
    private static let holdCap: TimeInterval = 30

    private struct State: Sendable {
        var until: Date = .distantPast
        var holds: Int = 0
        var holdExpiry: Date = .distantPast
        var rebuildUntil: Date = .distantPast
        var rebuildArmedAt: Date = .distantPast

        /// Bells only. Deliberately excludes the rebuild window: that window
        /// runs far longer than a bell is ever stale for.
        func mutesBell(_ now: Date) -> Bool {
            (holds > 0 && now < holdExpiry) || now < until
        }

        /// Whether the entry is worth keeping at all (the pruning predicate).
        func isActive(_ now: Date) -> Bool {
            mutesBell(now) || now < rebuildUntil
        }
    }

    private static let states = OSAllocatedUnfairLock<[UUID: State]>(initialState: [:])

    /// Mutes `id` for at least `interval`.
    static func suppress(_ id: UUID, for interval: TimeInterval, now: Date = Date()) {
        states.withLock { entries in
            entries = entries.filter { $0.value.isActive(now) }
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
            entries = entries.filter { $0.value.isActive(now) }
            var state = entries[id] ?? State()
            state.holds += 1
            state.holdExpiry = now.addingTimeInterval(holdCap)
            entries[id] = state
        }
        pipeline.notifyWhenOutputDrained { releaseHold(id) }
    }

    /// Marks `id` as rebuilding its screen from scratch: a tmux -CC discard
    /// recapture, or a tssh reconnect replaying its backlog. Agent detection
    /// absorbs everything it classifies inside this window, because the pane
    /// passes through blank frames and replayed transcript before the live
    /// chrome comes back and none of that is news.
    ///
    /// Arming again while a window is open re-opens the full interval. Once a
    /// window lapses the next arm is a new rebuild with a fresh cap, the same
    /// rule the drain holds use.
    static func suppressRebuild(_ id: UUID, now: Date = Date()) {
        states.withLock { entries in
            entries = entries.filter { $0.value.isActive(now) }
            var state = entries[id] ?? State()
            if now >= state.rebuildUntil { state.rebuildArmedAt = now }
            state.rebuildUntil = cappedRebuild(state, until: now.addingTimeInterval(forcedRebuild))
            entries[id] = state
        }
    }

    /// The replay is still feeding `id`. Holds an already-open window a little
    /// past the last byte, so a window can never close mid-replay on a slow
    /// link. Never OPENS one: bytes alone are not a rebuild.
    static func extendRebuild(_ id: UUID, now: Date = Date()) {
        states.withLock { entries in
            guard var state = entries[id], now < state.rebuildUntil else { return }
            state.rebuildUntil = cappedRebuild(
                state, until: now.addingTimeInterval(rebuildStreamingGrace))
            entries[id] = state
        }
    }

    private static func cappedRebuild(_ state: State, until deadline: Date) -> Date {
        min(state.rebuildArmedAt.addingTimeInterval(rebuildCap),
            max(state.rebuildUntil, deadline))
    }

    /// `id`'s open rebuild window, or nil when it isn't rebuilding. Callers
    /// park follow-up work just past `end`, and use `start` to tell state the
    /// rebuild produced from state that predates it.
    static func rebuildWindow(_ id: UUID, now: Date = Date()) -> (start: Date, end: Date)? {
        states.withLock { entries in
            guard let state = entries[id], now < state.rebuildUntil else { return nil }
            return (state.rebuildArmedAt, state.rebuildUntil)
        }
    }

    static func rebuildDeadline(_ id: UUID, now: Date = Date()) -> Date? {
        rebuildWindow(id, now: now)?.end
    }

    static func isRebuilding(_ id: UUID, now: Date = Date()) -> Bool {
        rebuildWindow(id, now: now) != nil
    }

    static func isSuppressed(_ id: UUID, now: Date = Date()) -> Bool {
        states.withLock { entries in
            guard let state = entries[id] else { return false }
            if state.mutesBell(now) { return true }
            if !state.isActive(now) { entries.removeValue(forKey: id) }
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
