import Foundation

/// Animated Braille spinner for TUI progress indication.
/// Provides smooth animation with elapsed time tracking and dynamic theme-aware colors.
@MainActor
final class SpinnerAnimator {

    // MARK: - Color System

    /// Color style for the spinner, derived from terminal theme
    enum ColorStyle: Sendable {
        case connecting     // Cyan/blue - active connection in progress
        case authenticating // Yellow - waiting for auth
        case provisioning   // Magenta - creating resources (k8s pods, etc.)
        case success        // Green - operation completed
        case error          // Red - operation failed
        case reconnecting   // Orange - reconnection in progress
        case custom(rgb: (UInt8, UInt8, UInt8))  // Custom RGB color

        /// Default fallback colors for each style (work well in both light/dark)
        var defaultRGB: (UInt8, UInt8, UInt8) {
            switch self {
            case .connecting:     return (80, 200, 220)   // Bright cyan
            case .authenticating: return (230, 190, 80)   // Warm yellow
            case .provisioning:   return (200, 140, 220)  // Soft magenta
            case .success:        return (120, 220, 120)  // Bright green
            case .error:          return (240, 100, 100)  // Bright red
            case .reconnecting:   return (255, 165, 80)   // Orange (reconnecting)
            case .custom(let rgb): return rgb
            }
        }

        /// ANSI palette index for this style (0-15)
        var paletteIndex: Int {
            switch self {
            case .connecting:     return 6   // Cyan
            case .authenticating: return 3   // Yellow
            case .provisioning:   return 5   // Magenta
            case .success:        return 2   // Green
            case .error:          return 1   // Red
            case .reconnecting:   return 3   // Yellow (closest ANSI to orange)
            case .custom:         return 7   // White (fallback)
            }
        }
    }

    /// Theme colors extracted from ThemeManager
    struct ThemeColors: Sendable {
        let foreground: (UInt8, UInt8, UInt8)
        let background: (UInt8, UInt8, UInt8)
        let palette: [(UInt8, UInt8, UInt8)]  // 16-color palette
        let isLightBackground: Bool

        /// Default theme colors (Blackboard Dark, the bundled default)
        static let `default` = ThemeColors(
            foreground: (248, 248, 248),  // #F8F8F8
            background: (12, 16, 33),     // #0C1021
            palette: [
                (12, 16, 33),    // 0: Black
                (191, 57, 42),   // 1: Red
                (97, 206, 60),   // 2: Green
                (251, 222, 45),  // 3: Yellow
                (141, 166, 206), // 4: Blue
                (255, 100, 0),   // 5: Magenta
                (190, 205, 230), // 6: Cyan
                (248, 248, 248), // 7: White
                (127, 144, 170), // 8: Bright Black
                (215, 78, 65),   // 9: Bright Red
                (216, 250, 60),  // 10: Bright Green
                (251, 222, 45),  // 11: Bright Yellow
                (213, 224, 243), // 12: Bright Blue
                (255, 100, 0),   // 13: Bright Magenta
                (255, 255, 255), // 14: Bright Cyan
                (255, 255, 255)  // 15: Bright White
            ],
            isLightBackground: false
        )

        /// Create ThemeColors from ThemeManager
        static func fromThemeManager() -> ThemeColors {
            guard let themeInfo = ThemeManager.shared.currentThemeInfo else {
                return .default
            }

            let colors = themeInfo.colors

            // Parse foreground
            let fg = parseHex(colors.foreground) ?? (205, 214, 244)

            // Parse background and determine if light
            let bg = parseHex(colors.background) ?? (30, 30, 46)
            let isLight = luminance(bg) > 0.5

            // Parse palette (up to 16 colors)
            var palette: [(UInt8, UInt8, UInt8)] = []
            for hexColor in colors.palette {
                // Palette format is "index=#color", extract just the color
                let colorPart = hexColor.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? hexColor
                if let rgb = parseHex(colorPart) {
                    palette.append(rgb)
                }
            }

            // Pad palette to 16 colors with defaults if needed
            while palette.count < 16 {
                palette.append(ThemeColors.default.palette[palette.count])
            }

            return ThemeColors(
                foreground: fg,
                background: bg,
                palette: palette,
                isLightBackground: isLight
            )
        }

        /// Parse hex color string to RGB tuple
        private static func parseHex(_ hex: String) -> (UInt8, UInt8, UInt8)? {
            var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

            guard hexSanitized.count == 6 else { return nil }

            var rgbValue: UInt64 = 0
            Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

            return (
                UInt8((rgbValue & 0xFF0000) >> 16),
                UInt8((rgbValue & 0x00FF00) >> 8),
                UInt8(rgbValue & 0x0000FF)
            )
        }

        /// Calculate relative luminance (WCAG 2.0 formula)
        private static func luminance(_ rgb: (UInt8, UInt8, UInt8)) -> Double {
            func adjust(_ component: UInt8) -> Double {
                let c = Double(component) / 255.0
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * adjust(rgb.0) + 0.7152 * adjust(rgb.1) + 0.0722 * adjust(rgb.2)
        }

        /// Get the RGB color for a given style, using palette colors
        func colorFor(style: ColorStyle) -> (UInt8, UInt8, UInt8) {
            let index = style.paletteIndex
            guard index < palette.count else {
                return style.defaultRGB
            }

            let paletteColor = palette[index]

            // For light backgrounds, we might want to use brighter variants (indices 8-15)
            // to ensure good contrast
            if isLightBackground {
                // Check if the palette color has enough contrast with background
                let contrast = contrastRatio(paletteColor, background)
                if contrast < 4.5 {
                    // Try the bright variant (index + 8)
                    let brightIndex = index + 8
                    if brightIndex < palette.count {
                        let brightColor = palette[brightIndex]
                        if contrastRatio(brightColor, background) > contrast {
                            return brightColor
                        }
                    }
                    // Fall back to default which is designed for contrast
                    return style.defaultRGB
                }
            }

            return paletteColor
        }

        /// Calculate contrast ratio between two colors
        private func contrastRatio(_ c1: (UInt8, UInt8, UInt8), _ c2: (UInt8, UInt8, UInt8)) -> Double {
            let l1 = ThemeColors.luminance(c1) + 0.05
            let l2 = ThemeColors.luminance(c2) + 0.05
            return max(l1, l2) / min(l1, l2)
        }

        /// Get a dimmed version of the foreground for secondary text (like elapsed time)
        var dimmedForeground: (UInt8, UInt8, UInt8) {
            if isLightBackground {
                // Lighten towards background for dim effect on light bg
                return (
                    UInt8(min(255, Int(foreground.0) + 60)),
                    UInt8(min(255, Int(foreground.1) + 60)),
                    UInt8(min(255, Int(foreground.2) + 60))
                )
            } else {
                // Darken towards background for dim effect on dark bg
                return (
                    UInt8(max(0, Int(foreground.0) - 60)),
                    UInt8(max(0, Int(foreground.1) - 60)),
                    UInt8(max(0, Int(foreground.2) - 60))
                )
            }
        }
    }

    // MARK: - ANSI Escape Sequences

    private enum ANSI {
        static let reset = "\u{1B}[0m"
        static let bold = "\u{1B}[1m"
        static let dim = "\u{1B}[2m"

        // Cursor positioning
        static let cursorHome = "\u{1B}[H"              // CUP - cursor to 1,1 (home)
        static let carriageReturn = "\r"

        // Erase operations
        static let clearToEndOfScreen = "\u{1B}[J"      // ED 0 - clear from cursor to end of screen
        static let clearToEndOfLine = "\u{1B}[K"        // EL 0 - clear from cursor to end of line

        // Synchronized output (Ghostty/modern terminals) - batch updates atomically
        static let syncOutputStart = "\u{1B}[?2026h"    // Begin synchronized update
        static let syncOutputEnd = "\u{1B}[?2026l"      // End synchronized update (renders)

        // Auto-wrap control (DECAWM) - prevents line wrapping at right margin
        static let disableAutoWrap = "\u{1B}[?7l"
        static let enableAutoWrap = "\u{1B}[?7h"

        /// True color (24-bit) foreground
        static func fg(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String {
            return "\u{1B}[38;2;\(r);\(g);\(b)m"
        }

        /// True color (24-bit) background
        static func bg(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String {
            return "\u{1B}[48;2;\(r);\(g);\(b)m"
        }

        /// 256-color foreground (fallback)
        static func fg256(_ index: Int) -> String {
            return "\u{1B}[38;5;\(index)m"
        }

        /// Cursor to specific position (1-indexed)
        static func cursorTo(row: Int, col: Int) -> String {
            return "\u{1B}[\(row);\(col)H"
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
    private var colorStyle: ColorStyle = .connecting

    /// Current theme colors (cached, refreshed on start)
    private var themeColors: ThemeColors = .default

    /// Terminal width in columns (for content fitting and line count calculation)
    private var terminalWidth: Int = 80

    /// Number of lines the previous frame occupied (for multi-line cleanup)
    private var lastLineCount: Int = 1

    /// Peak line count seen during this animation (for robust cleanup)
    private var peakLineCount: Int = 1

    /// Whether the spinner is currently animating
    var isAnimating: Bool { timer != nil }

    /// Current spinner character
    var currentFrame: Character {
        Self.frames[frameIndex]
    }

    // MARK: - Public API

    /// Update terminal width (call when terminal resizes during animation)
    func updateTerminalWidth(_ width: Int) {
        self.terminalWidth = max(20, width)  // Minimum 20 cols
    }

    /// Returns the ANSI sequence needed to clear all lines used by the spinner.
    /// Call this before stopping to get the cleanup sequence for final output.
    func getCleanupSequence() -> String {
        // Use synchronized output + absolute positioning for robust cleanup
        // Re-enable auto-wrap as safety reset
        return ANSI.syncOutputStart
            + ANSI.cursorHome
            + ANSI.clearToEndOfScreen
            + ANSI.enableAutoWrap
            + ANSI.syncOutputEnd
    }

    /// Starts animating with the given status message and color style.
    /// - Parameters:
    ///   - message: The status message to display (e.g., "Connecting to host...")
    ///   - style: The color style for the spinner
    ///   - terminalWidth: Terminal width in columns for content fitting
    ///   - onFrame: Callback invoked on each animation frame with the full status string
    func start(message: String, style: ColorStyle = .connecting, terminalWidth: Int = 80, onFrame: @escaping (String) -> Void) {
        // If already animating with same message and style, just update callback
        if isAnimating && currentMessage == message && colorStyle == style {
            self.onFrame = onFrame
            return
        }

        stop()

        // Refresh theme colors on start
        themeColors = ThemeColors.fromThemeManager()

        currentMessage = message
        colorStyle = style
        self.terminalWidth = max(20, terminalWidth)
        frameIndex = 0
        self.onFrame = onFrame
        startTime = Date()

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
    /// Preserves elapsed time tracking.
    func updateMessage(_ message: String, style: ColorStyle? = nil) {
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
        lastLineCount = 1
        peakLineCount = 1
    }

    // MARK: - Private Methods

    /// Advances to the next frame and notifies callback.
    private func advanceFrame() {
        frameIndex = (frameIndex + 1) % Self.frames.count
        emitFrame()
    }

    /// Emits the current frame to the callback with full color formatting.
    /// Uses synchronized output and absolute cursor positioning for robust multi-line handling.
    /// This approach works regardless of terminal width or content wrapping.
    private func emitFrame() {
        let rgb = themeColors.colorFor(style: colorStyle)
        let dimRGB = themeColors.dimmedForeground
        let elapsedString = formatElapsedTime()

        let spinnerColor = ANSI.fg(rgb.0, rgb.1, rgb.2)
        let dimColor = ANSI.fg(dimRGB.0, dimRGB.1, dimRGB.2)

        // Build the styled status line
        let statusLine = "\(ANSI.disableAutoWrap)\(spinnerColor)\(currentFrame)\(ANSI.reset) \(currentMessage) \(dimColor)\(elapsedString)\(ANSI.reset)\(ANSI.enableAutoWrap)"

        // Use synchronized output + absolute positioning for robust multi-line cleanup:
        // 1. syncOutputStart - begin batching (prevents flicker)
        // 2. cursorHome - go to absolute position 1,1 (not affected by scrolling)
        // 3. clearToEndOfScreen - clear everything (handles any amount of wrapped content)
        // 4. statusLine - write new content (can wrap freely)
        // 5. syncOutputEnd - render all changes atomically
        let output = ANSI.syncOutputStart
            + ANSI.cursorHome
            + ANSI.clearToEndOfScreen
            + statusLine
            + ANSI.syncOutputEnd

        onFrame?(output)
    }

    /// Formats the elapsed time since animation started.
    /// - Returns: Formatted string like "[3.2s]" or "[1m 23s]"
    private func formatElapsedTime() -> String {
        guard let startTime = startTime else { return "" }

        let elapsed = Date().timeIntervalSince(startTime)

        if elapsed < 60 {
            // Under 60 seconds: show with one decimal
            return String(format: "[%.1fs]", elapsed)
        } else {
            // 60 seconds or more: show minutes and seconds
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            return "[\(minutes)m \(seconds)s]"
        }
    }

    deinit {
        timer?.invalidate()
    }
}

// MARK: - ColorStyle Equatable

extension SpinnerAnimator.ColorStyle: Equatable {
    static func == (lhs: SpinnerAnimator.ColorStyle, rhs: SpinnerAnimator.ColorStyle) -> Bool {
        switch (lhs, rhs) {
        case (.connecting, .connecting),
             (.authenticating, .authenticating),
             (.provisioning, .provisioning),
             (.success, .success),
             (.error, .error):
            return true
        case (.custom(let lrgb), .custom(let rrgb)):
            return lrgb == rrgb
        default:
            return false
        }
    }
}
