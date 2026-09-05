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
        return matchHelper(Array(string), 0, Array(pattern), 0)
    }

    private static func matchHelper(_ s: [Character], _ si: Int,
                                    _ p: [Character], _ pi: Int) -> Bool {
        var si = si, pi = pi

        while pi < p.count {
            if p[pi] == "*" {
                pi += 1
                // Try matching * with 0..n characters
                for i in si...s.count {
                    if matchHelper(s, i, p, pi) { return true }
                }
                return false
            }

            if p[pi] == "\\", pi + 1 < p.count {
                // Escaped pattern character matches literally
                guard si < s.count, s[si] == p[pi + 1] else { return false }
                si += 1
                pi += 2
                continue
            }

            if si >= s.count { return false }

            if p[pi] == "?" {
                si += 1
                pi += 1
            } else if p[pi] == "[" {
                guard let (matched, nextPi) = matchClass(s[si], p, pi + 1) else {
                    // Unterminated class: treat '[' literally
                    if s[si] != "[" { return false }
                    si += 1
                    pi += 1
                    continue
                }
                if !matched { return false }
                si += 1
                pi = nextPi
            } else {
                if s[si] != p[pi] { return false }
                si += 1
                pi += 1
            }
        }

        return si == s.count
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
