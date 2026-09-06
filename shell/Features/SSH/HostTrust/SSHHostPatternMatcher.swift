//
//  SSHHostPatternMatcher.swift
//  shell
//
//  OpenSSH-style glob matching for hostnames, ported from OpenSSH's match.c
//  `match_pattern`. Used to match a connection hostname against a certificate's
//  `validPrincipals` (NIOSSH's own `validate` does exact-match only, so we
//  pre-match here to support wildcard principals like `*.dc1.example.com`).
//

import Foundation

enum SSHHostPatternMatcher {
    /// Single-pattern glob match with OpenSSH semantics: `*` matches any run of
    /// characters (including none), `?` matches exactly one character. No other
    /// metacharacters are special. Iterative with backtracking (no recursion,
    /// so it can't blow the stack on adversarial input).
    nonisolated static func matchGlob(_ string: String, pattern: String) -> Bool {
        let str = Array(string)
        let pat = Array(pattern)
        var si = 0
        var pi = 0
        var starIndex = -1
        var matchIndex = 0

        while si < str.count {
            if pi < pat.count, pat[pi] == "?" || pat[pi] == str[si] {
                si += 1
                pi += 1
            } else if pi < pat.count, pat[pi] == "*" {
                starIndex = pi
                matchIndex = si
                pi += 1
            } else if starIndex != -1 {
                pi = starIndex + 1
                matchIndex += 1
                si = matchIndex
            } else {
                return false
            }
        }

        while pi < pat.count, pat[pi] == "*" {
            pi += 1
        }
        return pi == pat.count
    }
}
