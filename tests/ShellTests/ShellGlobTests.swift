import Foundation
import XCTest

@testable import Shell

/// Pins shell glob semantics and its running time.
///
/// THE REGRESSION THIS EXISTS FOR: `matchHelper` recursed once per candidate
/// split at every `*`, which is exponential. `*a*a*a*a*a*a*a*a*b` against a run
/// of `a`s never returned, and nothing in the matcher polls for cancellation —
/// so a `case` branch or a `${v##…}` strip wedged the shell with no way out.
/// The semantics tests below exist so the linear rewrite that fixed it cannot
/// quietly change what matches.
final class ShellGlobTests: XCTestCase {

    // MARK: - The regression

    /// The shape that used to hang. A generous deadline: the point is
    /// "returns at all", not a benchmark.
    func testAPathologicalWildcardPatternCompletesQuickly() {
        let subject = String(repeating: "a", count: 64)
        let pattern = String(repeating: "*a", count: 12) + "*b"
        let started = Date()
        XCTAssertFalse(ShellGlob.match(subject, pattern: pattern))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    func testAPathologicalStripCompletesQuickly() {
        let subject = String(repeating: "a", count: 64)
        let pattern = String(repeating: "*a", count: 12) + "*b"
        let started = Date()
        XCTAssertEqual(ShellGlob.stripPrefix(subject, pattern: pattern, greedy: true), subject)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    // MARK: - Semantics

    func testLiteralsAndEmptyCases() {
        XCTAssertTrue(ShellGlob.match("", pattern: ""))
        XCTAssertTrue(ShellGlob.match("", pattern: "*"))
        XCTAssertTrue(ShellGlob.match("", pattern: "**"))
        XCTAssertFalse(ShellGlob.match("a", pattern: ""))
        XCTAssertFalse(ShellGlob.match("", pattern: "a"))
        XCTAssertTrue(ShellGlob.match("abc", pattern: "abc"))
        XCTAssertFalse(ShellGlob.match("abc", pattern: "abd"))
    }

    func testStarIsAnchoredAtBothEnds() {
        XCTAssertTrue(ShellGlob.match("abc", pattern: "a*"))
        XCTAssertTrue(ShellGlob.match("abc", pattern: "*c"))
        XCTAssertTrue(ShellGlob.match("abc", pattern: "a*c"))
        XCTAssertTrue(ShellGlob.match("ac", pattern: "a*c"))
        XCTAssertFalse(ShellGlob.match("abc", pattern: "a*d"))
        XCTAssertFalse(ShellGlob.match("abcd", pattern: "*c"))
        XCTAssertTrue(ShellGlob.match("a.b.c", pattern: "*.*.*"))
    }

    func testQuestionMarkMatchesExactlyOne() {
        XCTAssertTrue(ShellGlob.match("abc", pattern: "a?c"))
        XCTAssertFalse(ShellGlob.match("ac", pattern: "a?c"))
        XCTAssertFalse(ShellGlob.match("abbc", pattern: "a?c"))
    }

    func testCharacterClasses() {
        XCTAssertTrue(ShellGlob.match("b", pattern: "[abc]"))
        XCTAssertFalse(ShellGlob.match("d", pattern: "[abc]"))
        XCTAssertTrue(ShellGlob.match("d", pattern: "[!abc]"))
        XCTAssertTrue(ShellGlob.match("d", pattern: "[^abc]"))
        XCTAssertTrue(ShellGlob.match("m", pattern: "[a-z]"))
        XCTAssertFalse(ShellGlob.match("M", pattern: "[a-z]"))
        XCTAssertTrue(ShellGlob.match("file1.txt", pattern: "file[0-9].txt"))
        // An unterminated class is a literal '['
        XCTAssertTrue(ShellGlob.match("[abc", pattern: "[abc"))
    }

    func testEscapesMatchLiterally() {
        XCTAssertTrue(ShellGlob.match("a*b", pattern: "a\\*b"))
        XCTAssertFalse(ShellGlob.match("axb", pattern: "a\\*b"))
        XCTAssertTrue(ShellGlob.match("a?b", pattern: "a\\?b"))
        XCTAssertTrue(ShellGlob.match("a[b", pattern: "a\\[b"))
        XCTAssertTrue(ShellGlob.match(ShellGlob.escape("*?[]\\"), pattern: ShellGlob.escape(ShellGlob.escape("*?[]\\"))))
    }

    func testStripPrefixShortestAndLongest() {
        XCTAssertEqual(ShellGlob.stripPrefix("a.b.c", pattern: "*.", greedy: false), "b.c")
        XCTAssertEqual(ShellGlob.stripPrefix("a.b.c", pattern: "*.", greedy: true), "c")
        XCTAssertEqual(ShellGlob.stripPrefix("a.b.c", pattern: "x", greedy: false), "a.b.c")
    }

    func testStripSuffixShortestAndLongest() {
        XCTAssertEqual(ShellGlob.stripSuffix("a.b.c", pattern: ".*", greedy: false), "a.b")
        XCTAssertEqual(ShellGlob.stripSuffix("a.b.c", pattern: ".*", greedy: true), "a")
        XCTAssertEqual(ShellGlob.stripSuffix("a.b.c", pattern: "x", greedy: false), "a.b.c")
    }
}
