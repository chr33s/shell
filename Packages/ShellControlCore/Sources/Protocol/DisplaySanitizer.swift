import Foundation

/// Renders untrusted program-supplied text safely.
///
/// Control characters and bidirectional formatting controls are escaped
/// visibly, and authorization-relevant arguments are never silently truncated
/// (spec.watch.md section 6).
public enum DisplaySanitizer {
    /// Unicode bidi controls, which can otherwise reorder a rendered argument
    /// so it reads differently from what would execute.
    private static let bidiControls: Set<UInt32> = [
        0x200E, 0x200F, 0x061C,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    public struct Result: Sendable, Hashable {
        public let text: String
        /// True when anything was escaped, so the UI can mark the value.
        public let didEscape: Bool
        /// True when the value exceeded the display budget. The caller must
        /// offer the full value rather than pretending it showed everything.
        public let isTruncated: Bool
    }

    public static func sanitize(_ input: String, maxScalars: Int = 512) -> Result {
        var output = String()
        var didEscape = false
        var count = 0
        var isTruncated = false
        for scalar in input.unicodeScalars {
            if count >= maxScalars { isTruncated = true; break }
            count += 1
            if bidiControls.contains(scalar.value) || scalar.value < 0x20 || scalar.value == 0x7F
                || (scalar.value >= 0x80 && scalar.value <= 0x9F)
            {
                didEscape = true
                output += String(format: "<U+%04X>", scalar.value)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return Result(text: output, didEscape: didEscape, isTruncated: isTruncated)
    }

    /// One display line per argument, so a space inside an argument can never
    /// look like an argument boundary.
    public static func argumentLines(_ argv: [String], maxScalars: Int = 512) -> [Result] {
        argv.map { sanitize($0, maxScalars: maxScalars) }
    }
}
