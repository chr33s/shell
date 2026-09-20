#if !targetEnvironment(macCatalyst)

import Foundation

/// Shell glob pattern matching (`*`, `?`, `[...]`, `\` escapes), shared by
/// `case` patterns, `[[ ]]` comparisons, and `${var#pattern}`-family stripping.
nonisolated enum ShellGlob {

    /// Backslash-escape glob metacharacters so a string matches literally.
    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "*" || ch == "?" || ch == "[" || ch == "]" || ch == "\\" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    /// Match an entire string against a shell glob pattern.
    static func match(_ string: some StringProtocol, pattern: String) -> Bool {
        if pattern == "*" { return true }
        return matchAnchored(Array(string), Array(pattern))
    }

    /// Anchored glob match, linear in `s.count × p.count`.
    ///
    /// The previous implementation recursed once per candidate split at every
    /// `*` ("try 0..n characters, then recurse"). That is exponential: a
    /// pattern like `*a*a*a*a*a*a*a*a*b` against a run of `a`s never returns,
    /// and nothing inside the matcher polls for cancellation — so a `case`
    /// branch or a `${v##…}` strip could wedge the shell with no way out.
    /// This is the standard single-backtrack-point algorithm instead: on a
    /// mismatch it rewinds only to the most recent `*` and advances that
    /// star's consumption by one, which is enough for anchored globs and
    /// needs no recursion at all.
    private static func matchAnchored(_ s: [Character], _ p: [Character]) -> Bool {
        var si = 0, pi = 0
        // Where to resume if the tail after the last `*` fails to line up.
        var starPi = -1
        var starSi = 0

        while si < s.count {
            if pi < p.count, p[pi] != "*", let nextPi = matchOne(s[si], p, pi) {
                si += 1
                pi = nextPi
                continue
            }
            if pi < p.count, p[pi] == "*" {
                starPi = pi
                starSi = si
                pi += 1
                continue
            }
            guard starPi >= 0 else { return false }
            // Let the last `*` swallow one more character and retry its tail.
            starSi += 1
            si = starSi
            pi = starPi + 1
        }

        // Trailing `*`s may match nothing.
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// Whether `c` matches the single-character pattern element at `pi`, and
    /// the index just past that element. Returns nil when it does not match.
    private static func matchOne(_ c: Character, _ p: [Character], _ pi: Int) -> Int? {
        if p[pi] == "\\", pi + 1 < p.count {
            // Escaped pattern character matches literally
            return c == p[pi + 1] ? pi + 2 : nil
        }
        if p[pi] == "?" { return pi + 1 }
        if p[pi] == "[" {
            guard let (matched, nextPi) = matchClass(c, p, pi + 1) else {
                // Unterminated class: treat '[' literally
                return c == "[" ? pi + 1 : nil
            }
            return matched ? nextPi : nil
        }
        return c == p[pi] ? pi + 1 : nil
    }

    /// Match one character against a `[...]` class starting just past the `[`.
    /// Returns (matched, index past the closing `]`), or nil if unterminated.
    private static func matchClass(_ c: Character, _ p: [Character], _ start: Int) -> (Bool, Int)? {
        var pi = start
        var negate = false
        if pi < p.count && (p[pi] == "!" || p[pi] == "^") {
            negate = true
            pi += 1
        }

        var matched = false
        var first = true
        while pi < p.count {
            // A `]` in first position is a literal member, not the terminator
            if p[pi] == "]" && !first { break }
            first = false

            // Range `a-z` — but a `-` before the closing `]` is a literal
            if pi + 2 < p.count && p[pi + 1] == "-" && p[pi + 2] != "]" {
                if c >= p[pi] && c <= p[pi + 2] { matched = true }
                pi += 3
            } else {
                if c == p[pi] { matched = true }
                pi += 1
            }
        }

        guard pi < p.count else { return nil } // no closing ]
        return (negate ? !matched : matched, pi + 1)
    }

    // MARK: - Prefix/suffix stripping (${v#pat}, ${v##pat}, ${v%pat}, ${v%%pat})

    /// Remove the shortest (`#`) or longest (`##`) leading portion matching
    /// the pattern. True glob semantics: every split point is tested with a
    /// full anchored match, so multi-wildcard patterns like `*.*` work.
    static func stripPrefix(_ value: String, pattern: String, greedy: Bool) -> String {
        let chars = Array(value)
        let lengths = greedy
            ? AnySequence((0...chars.count).reversed())
            : AnySequence(0...chars.count)
        for i in lengths where match(String(chars[0..<i]), pattern: pattern) {
            return String(chars[i...])
        }
        return value
    }

    /// Remove the shortest (`%`) or longest (`%%`) trailing portion matching the pattern.
    static func stripSuffix(_ value: String, pattern: String, greedy: Bool) -> String {
        let chars = Array(value)
        let lengths = greedy
            ? AnySequence((0...chars.count).reversed())
            : AnySequence(0...chars.count)
        for i in lengths where match(String(chars[(chars.count - i)...]), pattern: pattern) {
            return String(chars[0..<(chars.count - i)])
        }
        return value
    }
}

#endif
