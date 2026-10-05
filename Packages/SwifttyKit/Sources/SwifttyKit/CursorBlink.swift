import Foundation

/// Cursor blink styles: `normal` is on/off; the rest are opacity curves
/// over time, sampled while the surface is focused.
enum CursorBlink {
    enum Mode: String {
        case normal, breathing, heartbeat, pulse, candle, shell
        case neonFlicker = "neon_flicker"
    }

    /// Opacity in `0...1` at time `t` (seconds); `normal` blinks on/off
    /// elsewhere and is always 1 here.
    static func alpha(_ mode: Mode, at t: Double) -> Double {
        switch mode {
        case .normal:
            return 1
        case .breathing:
            return 0.15 + 0.85 * (0.5 + 0.5 * cos(2 * .pi * t / 2.4))
        case .shell:
            return 0.35 + 0.65 * (0.5 + 0.5 * cos(2 * .pi * t / 3.6))
        case .pulse:
            let phase = t.truncatingRemainder(dividingBy: 1.2)
            return 0.15 + 0.85 * exp(-4 * phase)
        case .heartbeat:
            let phase = t.truncatingRemainder(dividingBy: 1.3)
            func beat(_ x: Double) -> Double { exp(-pow(x / 0.07, 2)) }
            return 0.25 + 0.75 * max(beat(phase - 0.1), 0.8 * beat(phase - 0.35))
        case .neonFlicker:
            // Mostly lit, with brief dips on a deterministic pseudo-random beat.
            let slot = UInt64(t / 0.08)
            var h = slot &* 0x9E37_79B9_7F4A_7C15
            h ^= h >> 29
            return h % 17 == 0 ? 0.25 : h % 23 == 0 ? 0.6 : 1
        case .candle:
            let n = sin(t * 7.3) * 0.5 + sin(t * 11.9 + 1.3) * 0.3 + sin(t * 3.1 + 0.7) * 0.2
            return 0.7 + 0.3 * n
        }
    }
}
