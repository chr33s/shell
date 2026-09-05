//
//  MultiplexerScrollIndicatorObserver.swift
//  shell
//
//  Observes terminal-multiplexer scroll position by scraping the top rows of
//  the visible viewport for indicators that the multiplexer renders into the
//  visible frame. Drives the existing scroll indicator UI when mouse capture
//  is active so the user gets a real scrollbar even though the multiplexer
//  owns scroll input.
//
//  Currently recognizes:
//    - tmux copy-mode `[oy/history]` (rendered at row 0 of the active pane).
//    - zellij scroll-mode ` SCROLL: rows_above/total ` (rendered on the pane
//      title bar in the pane border frame).
//
//  Both formats expose the same `(scrolled-up, total)` semantics, so a
//  single sample type and consumer (TerminalView.applyMultiplexerScrollSample)
//  serve both. Adding another multiplexer is a matter of appending a
//  `Detector` to `Self.detectors`.
//

import Foundation
import os
import GhosttyKit

extension Ghostty {

    /// Observes a terminal multiplexer's scroll-mode position indicator and
    /// emits scrollbar samples while the user is actively scrolling under
    /// mouse capture.
    @MainActor
    final class MultiplexerScrollIndicatorObserver {

        /// Which multiplexer produced a sample. Used for logging today; future
        /// per-multiplexer tweaks can branch on this without changing the
        /// consumer signature.
        enum Multiplexer: String {
            case tmux

            /// Bridge to the raw-multiplexer binding type.
            var multiplexerType: MultiplexerType {
                switch self {
                case .tmux: return .tmux
                }
            }
        }

        struct Sample: Equatable {
            /// Lines scrolled up from the live viewport. 0 = at-bottom.
            /// Maps to tmux's `oy` and zellij's `lines_below.len()`.
            let oy: UInt64
            /// Total scrollback lines. Maps to tmux's `history_size` and
            /// zellij's `scrollback_buffer_lines + lines_below.len()`.
            let history: UInt64
            /// Visible viewport height in rows.
            let viewportRows: UInt64
            /// Multiplexer that produced this sample.
            let source: Multiplexer
        }

        private enum State {
            case idle
            case probing(start: Date)
            case tracking(lastMatch: Date)
            /// Last sample is still on screen (inactivity-paused); the bar's
            /// own 1.5s auto-hide does the visual fade. Auto-expires to .idle
            /// after `fadingExpiryDelay` so the observer doesn't keep
            /// reporting `isTracking == true` indefinitely.
            case fading
        }

        // MARK: Detector

        /// One regex + provenance pair. `rowsToScan` is per-detector because
        /// the indicators live at different positions: tmux paints row 0 of
        /// the pane (status-line at top), zellij paints the pane title bar
        /// which sits below the tab bar and may be pushed down further by
        /// stacked panes.
        private struct Detector {
            let multiplexer: Multiplexer
            let regex: NSRegularExpression
            let rowsToScan: Int
        }

        // MARK: Configuration

        /// Sampling rate while probing/tracking.
        private static let sampleInterval: TimeInterval = 1.0 / 30.0

        /// Time to wait for a first regex match before giving up.
        private static let probingTimeout: TimeInterval = 0.5

        /// Inactivity timeout: no new scroll activity for this long → fade.
        private static let trackingInactivityTimeout: TimeInterval = 0.5

        /// Tolerance for transient no-match while tracking (the multiplexer
        /// occasionally redraws sans indicator mid-scroll). After this
        /// elapses with no match, we fade.
        private static let trackingNoMatchTolerance: TimeInterval = 0.2

        /// Sanity cap on parsed `history` to defend against absurd or
        /// malicious top-row content. Real multiplexer sessions cap
        /// scrollback well below this; values above it are virtually certain
        /// to be false-positive matches and would risk overflow when added
        /// to viewportRows in `applyMultiplexerScrollSample`.
        private static let maxPlausibleHistory: UInt64 = 10_000_000

        /// How long .fading persists before we auto-expire to .idle and emit
        /// nil (so handleScrollbar's shadow gate in TerminalView releases).
        /// Slightly longer than the 1.5s indicator auto-hide so the visual
        /// fade completes first.
        private static let fadingExpiryDelay: TimeInterval = 2.0

        /// Detectors are tried in order on every tick; the first valid match
        /// wins. tmux is listed first so existing tmux sessions retain their
        /// well-tested code path on the hot tick.
        private static let detectors: [Detector] = [
            Detector(
                multiplexer: .tmux,
                // tmux's default copy-mode-position-format is rendered at the
                // very start of the active pane's row 0: column 0 of the
                // screen for full-screen tmux, or just after the vertical
                // pane-divider (`│` and friends) for vertical splits. To
                // avoid false-positives on other alt-screen mouse apps that
                // contain `[N/M]` in their content (vim/less status lines,
                // htop counters, source code, progress markers), require the
                // `[` to be at start-of-text or immediately after whitespace
                // / a known pane-divider glyph, and the `]` to be followed
                // by whitespace, a divider, or end-of-text. This is
                // positional, not just word-boundary.
                //
                // Divider glyphs covered: U+2502/2503/2551 (light/heavy/
                // double vertical), U+2506/2507/250A/250B (broken vertical
                // variants), U+2575/2577 (half-bar fragments tmux uses on
                // small panes).
                // swiftlint:disable:next force_try
                regex: try! NSRegularExpression(
                    pattern: #"(?:^|[\s│┃║┆┇┊┋╵╷])\[(\d+)/(\d+)\](?=[\s│┃║┆┇┊┋]|$)"#
                ),
                rowsToScan: 2
            )
        ]

        /// Maximum row count any detector wants to read. Computed once so we
        /// only call into the surface once per tick.
        private static let maxRowsToScan: Int = detectors.map(\.rowsToScan).max() ?? 0

        // MARK: Dependencies

        private let surfaceProvider: () -> ghostty_surface_t?
        private let gridSizeProvider: () -> (rows: UInt16, cols: UInt16)?
        private let altScreenActive: () -> Bool
        private let mouseCaptured: () -> Bool
        private let onSample: (Sample?) -> Void

        // MARK: State

        private var state: State = .idle
        private var lastActivity: Date = .distantPast
        private var lastSuccessfulMatch: Date = .distantPast
        private var sampleTimer: Timer?
        /// One-shot timer that transitions .fading → .idle so we don't leak
        /// `isTracking == true` indefinitely after the user stops scrolling.
        private var fadingExpiryTimer: Timer?
        private var lastSample: Sample?

        private nonisolated static let logger = Logger(
            subsystem: "dev.chr33s.shell",
            category: "MultiplexerScrollIndicator"
        )

        // MARK: Init / Teardown

        init(
            surfaceProvider: @escaping () -> ghostty_surface_t?,
            gridSizeProvider: @escaping () -> (rows: UInt16, cols: UInt16)?,
            altScreenActive: @escaping () -> Bool,
            mouseCaptured: @escaping () -> Bool,
            onSample: @escaping (Sample?) -> Void
        ) {
            self.surfaceProvider = surfaceProvider
            self.gridSizeProvider = gridSizeProvider
            self.altScreenActive = altScreenActive
            self.mouseCaptured = mouseCaptured
            self.onSample = onSample
        }

        func tearDown() {
            stopTimer()
            cancelFadingExpiry()
            state = .idle
            lastSample = nil
        }

        // MARK: Public API

        /// True iff the observer is currently delivering multiplexer-derived
        /// scrollbar values. Used by `TerminalView.updateScrollIndicatorVisibility`
        /// to keep the indicator visible during mouse capture.
        var isTracking: Bool {
            switch state {
            case .tracking, .fading: return true
            case .idle, .probing: return false
            }
        }

        /// Most recent sample emitted (nil if not tracking).
        var currentSample: Sample? { lastSample }

        /// Call from scroll handlers (or the central native scroll sender) whenever
        /// the user generates scroll activity. The observer self-gates on
        /// `mouseCaptured()` and `altScreenActive()` so unconditional calls are
        /// safe.
        func notifyScrollActivity() {
            guard mouseCaptured(), altScreenActive() else {
                if isTracking { reset() }
                return
            }

            lastActivity = Date()

            switch state {
            case .idle:
                state = .probing(start: lastActivity)
                startTimer()
            case .probing:
                // Already probing; timer keeps firing. Refresh start so we
                // don't time out mid-flick.
                state = .probing(start: lastActivity)
            case .tracking, .fading:
                // Resume tracking on any new activity.
                cancelFadingExpiry()
                state = .tracking(lastMatch: lastSuccessfulMatch)
                if sampleTimer == nil { startTimer() }
            }
        }

        /// Force-reset to idle. Called when capture exits or the surface goes
        /// away.
        func reset() {
            stopTimer()
            cancelFadingExpiry()
            state = .idle
            if lastSample != nil {
                lastSample = nil
                onSample(nil)
            }
        }

        // MARK: Sampling

        private func startTimer() {
            stopTimer()
            // Add to .common so the timer keeps firing during scroll/pan
            // tracking. With the default scheduledTimer (.default mode),
            // ticks pause mid-gesture and the bar wouldn't update until
            // the user lifted their fingers.
            let timer = Timer(
                timeInterval: Self.sampleInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tick()
                }
            }
            timer.tolerance = Self.sampleInterval * 0.5
            RunLoop.main.add(timer, forMode: .common)
            sampleTimer = timer
        }

        private func stopTimer() {
            sampleTimer?.invalidate()
            sampleTimer = nil
        }

        private func tick() {
            // Bail out conditions: capture exited, alt screen left, surface gone.
            guard mouseCaptured(), altScreenActive(), surfaceProvider() != nil else {
                reset()
                return
            }

            let now = Date()
            let sample = sample(now: now)

            switch state {
            case .idle:
                stopTimer()

            case .probing(let start):
                if let sample = sample {
                    state = .tracking(lastMatch: now)
                    lastSuccessfulMatch = now
                    emit(sample)
                } else if now.timeIntervalSince(start) > Self.probingTimeout {
                    state = .idle
                    stopTimer()
                }

            case .tracking:
                if let sample = sample {
                    lastSuccessfulMatch = now
                    state = .tracking(lastMatch: now)
                    emit(sample)
                } else if now.timeIntervalSince(lastSuccessfulMatch) > Self.trackingNoMatchTolerance {
                    // The position indicator disappeared. Don't guess at a
                    // position — go straight to .idle so handleScrollbar
                    // releases its shadow gate immediately. Emit nil so the
                    // bar hides and shadow values get restored.
                    stopTimer()
                    cancelFadingExpiry()
                    state = .idle
                    if lastSample != nil {
                        lastSample = nil
                        onSample(nil)
                    }
                    return
                }

                // Inactivity-driven fade. Last sample remains valid (user
                // paused mid-scroll), so the existing 1.5s auto-hide on
                // the indicator UIView does the visual fade. We move to
                // .fading and arm an expiry timer so we eventually return
                // to .idle even if the user never scrolls again.
                if now.timeIntervalSince(lastActivity) > Self.trackingInactivityTimeout {
                    state = .fading
                    stopTimer()
                    scheduleFadingExpiry()
                }

            case .fading:
                stopTimer()
            }
        }

        // MARK: Fading expiry

        private func scheduleFadingExpiry() {
            cancelFadingExpiry()
            let timer = Timer(
                timeInterval: Self.fadingExpiryDelay,
                repeats: false
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fadingExpired()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            fadingExpiryTimer = timer
        }

        private func cancelFadingExpiry() {
            fadingExpiryTimer?.invalidate()
            fadingExpiryTimer = nil
        }

        private func fadingExpired() {
            // Only act if we're still in .fading. notifyScrollActivity()
            // could have promoted us back to .tracking after the timer
            // fired but before this main-actor hop ran.
            guard case .fading = state else { return }
            state = .idle
            if lastSample != nil {
                lastSample = nil
                onSample(nil)
            }
        }

        private func emit(_ sample: Sample) {
            guard sample != lastSample else { return }
            lastSample = sample
            onSample(sample)
        }

        // MARK: Read + parse

        private func sample(now: Date) -> Sample? {
            guard let surface = surfaceProvider() else { return nil }
            guard let grid = gridSizeProvider(), grid.rows > 0, grid.cols > 0 else { return nil }

            let cols = Int(grid.cols)
            let rowsToScan = min(Self.maxRowsToScan, Int(grid.rows))
            guard rowsToScan > 0 else { return nil }

            guard let text = Ghostty.Surface.readTopRows(
                rowsToScan,
                cols: cols,
                surface: surface
            ) else {
                Self.logger.debug("sample: read_text returned nil")
                return nil
            }

            // Try detectors in priority order; first valid match wins. The
            // text we read covers `maxRowsToScan` rows, so detectors that
            // wanted fewer rows still see at least their expected window —
            // they just have a slightly larger search space, which is fine
            // because their patterns are tightly anchored.
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for detector in Self.detectors {
                guard let parsed = parse(text: text, range: range, detector: detector) else {
                    continue
                }
                return Sample(
                    oy: parsed.oy,
                    history: parsed.history,
                    viewportRows: UInt64(grid.rows),
                    source: detector.multiplexer
                )
            }
            return nil
        }

        private func parse(
            text: String,
            range: NSRange,
            detector: Detector
        ) -> (oy: UInt64, history: UInt64)? {
            guard let match = detector.regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges == 3,
                  let oyRange = Range(match.range(at: 1), in: text),
                  let historyRange = Range(match.range(at: 2), in: text),
                  let oy = UInt64(text[oyRange]),
                  let history = UInt64(text[historyRange]),
                  // Sanity gate against false positives: the format must
                  // describe a plausible scroll position. Both tmux and
                  // zellij always emit 0 ≤ oy ≤ history with history ≥ 1.
                  history >= 1,
                  history <= Self.maxPlausibleHistory,
                  oy <= history
            else {
                return nil
            }
            return (oy, history)
        }
    }
}
