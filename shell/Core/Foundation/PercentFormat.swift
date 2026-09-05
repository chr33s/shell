import Foundation

// Percent values must be formatted, never glued to a literal "%". A
// localized "\(n)%" bakes in English convention: French wants a narrow
// no-break space before the sign, Turkish leads with it, Arabic can use
// its own digits. It also produces "%lld%%" keys in the string catalog
// that no translator can correct (and that Xcode warns about).
nonisolated extension FormatStyle where Self == FloatingPointFormatStyle<Double>.Percent {
    /// A 0...1 fraction as a whole-number percent: 0.42 renders "42%".
    /// Rounds rather than truncates, so 0.29 can't land on "28%".
    static var wholePercent: FloatingPointFormatStyle<Double>.Percent {
        FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0))
    }
}
