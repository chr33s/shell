import Foundation
import GhosttyKit

/// Terminal display-cell width helpers.
///
/// Terminals lay text out in fixed cells, not Swift `Character`s. East-Asian-wide
/// glyphs (CJK), most emoji, and emoji-presentation sequences occupy 2 cells;
/// combining marks occupy 0. We consult ghostty's own SIMD width table so widths
/// match exactly what ghostty draws.
///
/// Unlike `RFWidth` (which is gated to the iOS-only `rf` file browser), this lives
/// in the shared utilities layer and compiles on every platform — including Mac
/// Catalyst — because `ghostty_simd_codepoint_width` is a plain C symbol from
/// GhosttyKit (also used un-gated by the Mosh client).
nonisolated enum DisplayWidth {
    /// Display-cell width of a single Unicode scalar (-1 null, 0 zero-width, 1+ cells).
    private static func scalarWidth(_ scalar: UInt32) -> Int {
        return Int(ghostty_simd_codepoint_width(scalar))
    }

    /// Display-cell width of a single grapheme cluster (1 normal, 2 wide).
    static func width(of char: Character) -> Int {
        var base = 0
        var hasVS16 = false
        for scalar in char.unicodeScalars {
            if scalar.value == 0xFE0F { hasVS16 = true; continue } // emoji presentation selector
            let w = scalarWidth(scalar.value)
            if w > 0 { base = max(base, w) }
        }
        if hasVS16 { return 2 }
        return max(base, 1) // a visible grapheme is at least 1 cell
    }

    /// Display-cell width of a string.
    static func width(of string: String) -> Int {
        var total = 0
        for ch in string { total += width(of: ch) }
        return total
    }
}
