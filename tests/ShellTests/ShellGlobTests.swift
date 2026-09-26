import Foundation
import Testing

@testable import Shell

/// Pins shell glob semantics and its running time.
///
/// THE REGRESSION THIS EXISTS FOR: `matchHelper` recursed once per candidate
/// split at every `*`, which is exponential. `*a*a*a*a*a*a*a*a*b` against a run
/// of `a`s never returned, and nothing in the matcher polls for cancellation —
/// so a `case` branch or a `${v##…}` strip wedged the shell with no way out.
/// The semantics tests below exist so the linear rewrite that fixed it cannot
/// quietly change what matches.
@Suite
final class ShellGlobTests {

    // MARK: - The regression

    /// The shape that used to hang. A generous deadline: the point is
    /// "returns at all", not a benchmark.
    @Test
    func testAPathologicalWildcardPatternCompletesQuickly() throws {
        let subject = String(repeating: "a", count: 64)
        let pattern = String(repeating: "*a", count: 12) + "*b"
        let started = Date()
        #expect(!(ShellGlob.match(subject, pattern: pattern)))
        #expect(Date().timeIntervalSince(started) < 2.0)
    }

    @Test
    func testAPathologicalStripCompletesQuickly() throws {
        let subject = String(repeating: "a", count: 64)
        let pattern = String(repeating: "*a", count: 12) + "*b"
        let started = Date()
        #expect(ShellGlob.stripPrefix(subject, pattern: pattern, greedy: true) == subject)
        #expect(Date().timeIntervalSince(started) < 2.0)
    }

    // MARK: - Semantics

    @Test
    func testLiteralsAndEmptyCases() throws {
        #expect(ShellGlob.match("", pattern: ""))
        #expect(ShellGlob.match("", pattern: "*"))
        #expect(ShellGlob.match("", pattern: "**"))
        #expect(!(ShellGlob.match("a", pattern: "")))
        #expect(!(ShellGlob.match("", pattern: "a")))
        #expect(ShellGlob.match("abc", pattern: "abc"))
        #expect(!(ShellGlob.match("abc", pattern: "abd")))
    }

    @Test
    func testStarIsAnchoredAtBothEnds() throws {
        #expect(ShellGlob.match("abc", pattern: "a*"))
        #expect(ShellGlob.match("abc", pattern: "*c"))
        #expect(ShellGlob.match("abc", pattern: "a*c"))
        #expect(ShellGlob.match("ac", pattern: "a*c"))
        #expect(!(ShellGlob.match("abc", pattern: "a*d")))
        #expect(!(ShellGlob.match("abcd", pattern: "*c")))
        #expect(ShellGlob.match("a.b.c", pattern: "*.*.*"))
    }

    @Test
    func testQuestionMarkMatchesExactlyOne() throws {
        #expect(ShellGlob.match("abc", pattern: "a?c"))
        #expect(!(ShellGlob.match("ac", pattern: "a?c")))
        #expect(!(ShellGlob.match("abbc", pattern: "a?c")))
    }

    @Test
    func testCharacterClasses() throws {
        #expect(ShellGlob.match("b", pattern: "[abc]"))
        #expect(!(ShellGlob.match("d", pattern: "[abc]")))
        #expect(ShellGlob.match("d", pattern: "[!abc]"))
        #expect(ShellGlob.match("d", pattern: "[^abc]"))
        #expect(ShellGlob.match("m", pattern: "[a-z]"))
        #expect(!(ShellGlob.match("M", pattern: "[a-z]")))
        #expect(ShellGlob.match("file1.txt", pattern: "file[0-9].txt"))
        // An unterminated class is a literal '['
        #expect(ShellGlob.match("[abc", pattern: "[abc"))
    }

    @Test
    func testEscapesMatchLiterally() throws {
        #expect(ShellGlob.match("a*b", pattern: "a\\*b"))
        #expect(!(ShellGlob.match("axb", pattern: "a\\*b")))
        #expect(ShellGlob.match("a?b", pattern: "a\\?b"))
        #expect(ShellGlob.match("a[b", pattern: "a\\[b"))
        #expect(ShellGlob.match(ShellGlob.escape("*?[]\\"), pattern: ShellGlob.escape(ShellGlob.escape("*?[]\\"))))
    }

    @Test
    func testStripPrefixShortestAndLongest() throws {
        #expect(ShellGlob.stripPrefix("a.b.c", pattern: "*.", greedy: false) == "b.c")
        #expect(ShellGlob.stripPrefix("a.b.c", pattern: "*.", greedy: true) == "c")
        #expect(ShellGlob.stripPrefix("a.b.c", pattern: "x", greedy: false) == "a.b.c")
    }

    @Test
    func testStripSuffixShortestAndLongest() throws {
        #expect(ShellGlob.stripSuffix("a.b.c", pattern: ".*", greedy: false) == "a.b")
        #expect(ShellGlob.stripSuffix("a.b.c", pattern: ".*", greedy: true) == "a")
        #expect(ShellGlob.stripSuffix("a.b.c", pattern: "x", greedy: false) == "a.b.c")
    }
}
