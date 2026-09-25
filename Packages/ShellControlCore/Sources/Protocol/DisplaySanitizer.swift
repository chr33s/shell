import Foundation

/// Renders untrusted program-supplied text safely.
///
/// Control characters and bidirectional formatting controls are escaped
/// visibly, and authorization-relevant arguments are never silently truncated
/// (docs/specs/control-protocol.md section 11.2).
public enum DisplaySanitizer {
    /// Unicode bidi controls, which can otherwise reorder a rendered argument
    /// so it reads differently from what would execute.
    private static let bidiControls: Set<UInt32> = [
        0x200E, 0x200F, 0x061C,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069
    ]

    /// Categories that render as nothing, as something else, or as a line
    /// break. A zero-width space or a soft hyphen inside an argument is
    /// invisible, and a line separator can split one argument into what looks
    /// like two — both make the rendered text read differently from what would
    /// execute, which is exactly what bidi controls are escaped for. `Cf`
    /// covers the bidi set above as well as ZWSP, ZWNJ, ZWJ and U+FEFF.
    private static func isDeceptive(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format, .control, .lineSeparator, .paragraphSeparator,
             .privateUse, .surrogate, .unassigned:
            return true
        default:
            return scalar.value == 0x00AD
        }
    }

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
                || (scalar.value >= 0x80 && scalar.value <= 0x9F) || isDeceptive(scalar) {
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
