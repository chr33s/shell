import Foundation

/// Animated Braille spinner for in-place TUI progress indication.
/// Uses save/restore cursor position to preserve terminal history above the animation.
/// Suitable for use within local shell sessions where full-screen clearing is not desired.
@MainActor
final class InlineSpinnerAnimator {

    // MARK: - ANSI Escape Sequences

    private enum ANSI {
        static let reset = "\u{1B}[0m"

        // Erase operations
        static let clearToEndOfScreen = "\u{1B}[J"

        // Synchronized output (prevents flicker)
        static let syncOutputStart = "\u{1B}[?2026h"
        static let syncOutputEnd = "\u{1B}[?2026l"

        // Auto-wrap control (DECAWM) - prevents line wrapping at right margin
        static let disableAutoWrap = "\u{1B}[?7l"
        static let enableAutoWrap = "\u{1B}[?7h"

        /// Move cursor up N lines (relative positioning)
        static func cursorUp(_ n: Int) -> String {
            n > 0 ? "\u{1B}[\(n)A" : ""
        }

        /// True color (24-bit) foreground
        static func fg(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String {
            return "\u{1B}[38;2;\(r);\(g);\(b)m"
        }
    }

    // MARK: - Spinner Animation

    /// Braille spinner frames (10 frames, ~80ms each = 0.8 second cycle)
    static let frames: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// Current frame index
    private var frameIndex: Int = 0

    /// Animation timer
    private var timer: Timer?

    /// Start time for elapsed time calculation
    private var startTime: Date?

    /// Callback invoked on each frame with the full status string
    private var onFrame: ((String) -> Void)?

    /// Current status message to display after spinner
    private var currentMessage: String = ""

    /// Current color style
    private var colorStyle: SpinnerAnimator.ColorStyle = .connecting

    /// Current theme colors (cached, refreshed on start)
    private var themeColors: SpinnerAnimator.ThemeColors = .default

    /// Terminal width for layout decisions
    private var terminalWidth: Int = 80

    /// Whether the first frame has been emitted
    private var isFirstFrame: Bool = true

    /// Number of lines in the last emitted frame (for cursor-up positioning)
    private var lastLineCount: Int = 0

    /// Whether the spinner is currently animating
    var isAnimating: Bool { timer != nil }

    /// Current spinner character
    var currentFrame: Character {
        Self.frames[frameIndex]
    }

    // MARK: - Public API

    /// Returns the ANSI sequence needed to clear all spinner content.
    /// Call this before stop() to get valid cleanup.
    func getCleanupSequence() -> String {
        guard lastLineCount > 0 else { return "" }

        // Cursor is at end of last line. Move up (lineCount-1) to reach first line,
        // then clear everything from there down. Re-enable auto-wrap as safety reset.
        var sequence = ANSI.syncOutputStart
        if lastLineCount > 1 {
            sequence += ANSI.cursorUp(lastLineCount - 1)
        }
        sequence += "\r"
        sequence += ANSI.clearToEndOfScreen
        sequence += ANSI.enableAutoWrap
        sequence += ANSI.syncOutputEnd
        return sequence
    }

    /// Starts animating with the given status message and color style.
    func start(
        message: String,
        style: SpinnerAnimator.ColorStyle = .connecting,
        terminalWidth: Int = 80,
        onFrame: @escaping (String) -> Void
    ) {
        // If already animating with same message and style, just update callback
        if isAnimating && currentMessage == message && colorStyle == style {
            self.onFrame = onFrame
            return
        }

        stop()

        // Refresh theme colors on start
        themeColors = SpinnerAnimator.ThemeColors.fromThemeManager()

        currentMessage = message
        colorStyle = style
        self.terminalWidth = max(40, terminalWidth)
        frameIndex = 0
        self.onFrame = onFrame
        startTime = Date()
        isFirstFrame = true
        lastLineCount = 0

        // Immediately emit first frame
        emitFrame()

        // Start timer for subsequent frames (80ms = ~12.5 FPS)
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.advanceFrame()
            }
        }
    }

    /// Updates the status message and optionally the style without restarting animation.
    func updateMessage(_ message: String, style: SpinnerAnimator.ColorStyle? = nil) {
        guard isAnimating else { return }
        currentMessage = message
        if let style = style {
            colorStyle = style
        }
        emitFrame()
    }

    /// Stops the animation and cleans up resources.
    func stop() {
        timer?.invalidate()
        timer = nil
        onFrame = nil
        startTime = nil
        frameIndex = 0
        isFirstFrame = true
        lastLineCount = 0
    }

    // MARK: - Private Methods

    /// Advances to the next frame and notifies callback.
    private func advanceFrame() {
        frameIndex = (frameIndex + 1) % Self.frames.count
        emitFrame()
    }

    /// Emits the current frame to the callback with full color formatting.
    private func emitFrame() {
        let rgb = themeColors.colorFor(style: colorStyle)
        let dimRGB = themeColors.dimmedForeground
        let elapsedString = formatElapsedTime()

        let spinnerColor = ANSI.fg(rgb.0, rgb.1, rgb.2)
        let dimColor = ANSI.fg(dimRGB.0, dimRGB.1, dimRGB.2)

        // Build content - try single line first, fall back to multi-line if too wide
        let content: String
        let lineCount: Int

        // Calculate single-line content length (without ANSI codes)
        // Format: "⠋ message [time]"
        let singleLineVisibleLength = 2 + currentMessage.count + 1 + elapsedString.count

        if singleLineVisibleLength <= terminalWidth {
            content = "\(ANSI.disableAutoWrap)\(spinnerColor)\(currentFrame)\(ANSI.reset) \(currentMessage) \(dimColor)\(elapsedString)\(ANSI.reset)\(ANSI.enableAutoWrap)"
            lineCount = 1
        } else {
            // Need multi-line layout — wrap each line to prevent unintentional wrapping
            let line1 = "\(ANSI.disableAutoWrap)\(spinnerColor)\(currentFrame)\(ANSI.reset) \(currentMessage)\(ANSI.enableAutoWrap)"
            let line2 = "\(ANSI.disableAutoWrap)\(dimColor)  \(elapsedString)\(ANSI.reset)\(ANSI.enableAutoWrap)"
            content = "\(line1)\r\n\(line2)"
            lineCount = 2
        }

        var output = ANSI.syncOutputStart

        if isFirstFrame {
            // First frame: pre-allocate space by outputting newlines, then move back up
            // This forces any necessary scrolling to happen before we render content
            output += String(repeating: "\n", count: lineCount)
            output += ANSI.cursorUp(lineCount)
            output += "\r"
            output += content
            isFirstFrame = false
        } else {
            // Subsequent frames: cursor is at end of last line of previous frame.
            // Move up (lastLineCount-1) lines to reach the first line, clear, output new content.
            if lastLineCount > 1 {
                output += ANSI.cursorUp(lastLineCount - 1)
            }
            output += "\r"
            output += ANSI.clearToEndOfScreen
            output += content
        }

        output += ANSI.syncOutputEnd

        lastLineCount = lineCount
        onFrame?(output)
    }

    /// Formats the elapsed time since animation started.
    private func formatElapsedTime() -> String {
        guard let startTime = startTime else { return "" }

        let elapsed = Date().timeIntervalSince(startTime)

        if elapsed < 60 {
            return String(format: "[%.1fs]", elapsed)
        } else {
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            return "[\(minutes)m \(seconds)s]"
        }
    }

    deinit {
        timer?.invalidate()
    }
}
