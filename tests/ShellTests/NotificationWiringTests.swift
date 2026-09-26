//
//  NotificationWiringTests.swift
//  ShellTests
//
//  Every `Notification.Name` the app declares is both posted and observed.
//
//  WHAT THIS CATCHES THAT THE COMPILER CANNOT
//  ==========================================
//  NotificationCenter is a name-matched, untyped channel: posting to a name
//  nobody listens for is not an error, it is a no-op. A menu item stays
//  enabled, the user picks it, and nothing happens. Nine commands were found
//  broken this way in this codebase, by a human doing exactly the scan below
//  by hand and reading every match.
//
//  It also catches the mirror image — an observer for a name nothing posts —
//  which is how a feature ends up wired to a sender that was refactored away.
//
//  SCOPE, HONESTLY
//  ===============
//  This is a **lint**, not a behavioral test. It reads the app's Swift source
//  as text and classifies each reference to a declared name as a post or an
//  observe. It proves the two sides exist; it cannot prove the observer does
//  anything useful with what arrives, and it cannot prove either side is
//  reachable at run time. `MenuCommandChainTests` is the behavioral half for
//  the commands that have one.
//
//  It is a lint that survives a coherent removal, which is why it is here:
//  nothing in this file names a Swift symbol, so deleting a notification and
//  its observer together cannot delete the check. The scan is derived from the
//  source at run time, so it needs no allowlist to maintain — at the time of
//  writing every declared name is both posted and observed, with no
//  exceptions, and it is worth keeping that number at zero.
//
//  If a name is ever *deliberately* posted for an external consumer with no
//  in-app observer, add it to `postedWithoutInAppObserver` with a comment
//  saying who listens. Do not widen the regexes to make a real gap disappear.
//

import Foundation
import Testing

@testable import Shell

@Suite
final class NotificationWiringTests {

    /// Names deliberately posted with no in-app observer (external consumers,
    /// system integrations). Empty, and should stay that way.
    static let postedWithoutInAppObserver: Set<String> = []

    /// Names deliberately observed that only the system posts.
    static let observedWithoutInAppPoster: Set<String> = []

    // MARK: - Scanner

    private struct Wiring {
        var declared: [String: String] = [:]  // symbol -> raw value
        var posted: Set<String> = []
        var observed: Set<String> = []
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid test regular expression: \(pattern)")
        }
    }

    /// `static let foo = Notification.Name("dev.chr33s.shell.foo")`
    private static let declaration = regex(
        #"static let (\w+) = Notification\.Name\("([^"]+)"\)"#
    )

    /// A `[String: Notification.Name]` lookup table. `SettingsRefreshHub`
    /// posts through one of these, so its values are posts even though no
    /// `post(` appears near them.
    private static let postTable = regex(
        #":\s*Notification\.Name\]\s*=\s*\[(?:.|\n)*?\n\s*\]"#
    )

    /// Call sites that consume a name rather than send it. `forName:` covers
    /// both `addObserver` spellings; `observe`/`observeOnMainActor` are
    /// `MainViewObserverBag`'s wrappers.
    private static let observeContext = regex(
        #"addObserver|forName:|publisher\(\s*for:|notifications\(\s*named:|\bobserve\(|\bobserveOnMainActor\("#
    )

    /// How far back a reference looks for the call it belongs to. Generous
    /// enough to span the multi-line argument lists this codebase uses.
    private static let contextWindow = 200

    private func scan() -> Wiring {
        Self.scan(sources: SourceTree.swiftFiles().compactMap {
            try? String(contentsOf: $0, encoding: .utf8)
        })
    }

    private static func scan(sources: [String]) -> Wiring {
        var wiring = Wiring()
        var texts: [String] = []

        for text in sources {
            let range = NSRange(text.startIndex..., in: text)
            for match in declaration.matches(in: text, range: range) {
                guard let symbol = Range(match.range(at: 1), in: text),
                      let raw = Range(match.range(at: 2), in: text) else { continue }
                wiring.declared[String(text[symbol])] = String(text[raw])
            }
            // Blank out the declarations so a name is never counted as a use
            // of itself, keeping offsets (and therefore windows) intact.
            texts.append(
                declaration.stringByReplacingMatches(
                    in: text, range: range,
                    withTemplate: String(repeating: " ", count: 40)
                )
            )
        }

        for text in texts {
            let full = NSRange(text.startIndex..., in: text)

            // Values of a post table are posts.
            for table in postTable.matches(in: text, range: full) {
                guard let block = Range(table.range, in: text) else { continue }
                let body = String(text[block])
                for symbol in wiring.declared.keys where body.contains(".\(symbol)") {
                    wiring.posted.insert(symbol)
                }
            }

            for symbol in wiring.declared.keys {
                // Optionally qualified (`Self.x`, `KeyboardToolbarManager.x`)
                // or leading-dot inferred (`.x`).
                guard let uses = try? NSRegularExpression(
                    pattern: #"(?<![A-Za-z0-9_])(?:[A-Z]\w*\.)?\.?"# + NSRegularExpression.escapedPattern(for: symbol) + #"(?![A-Za-z0-9_])"#
                ) else { continue }

                for use in uses.matches(in: text, range: full) {
                    let start = use.range.location
                    let window = NSRange(
                        location: max(0, start - contextWindow),
                        length: min(contextWindow, start)
                    )
                    guard let before = Range(window, in: text) else { continue }
                    let context = String(text[before])

                    // `post`, `postNotification`, and this codebase's
                    // `postAppTabSwipeNotification` helper all match.
                    if context.lowercased().contains("post") {
                        wiring.posted.insert(symbol)
                    } else if observeContext.firstMatch(
                        in: context, range: NSRange(context.startIndex..., in: context)
                    ) != nil {
                        wiring.observed.insert(symbol)
                    }
                }
            }
        }
        return wiring
    }

    // MARK: - Tests

    /// Scanner health, checked against a fixture rather than the size of the
    /// production source: routing internal commands through typed handlers is
    /// supposed to shrink the number of declared names, and a floor on that
    /// count would fail exactly the refactors this lint exists to support.
    @Test func testScannerClassifiesFixture() {
        // Each reference is classified by the call within `contextWindow`
        // characters before it, so the sections are padded apart the way
        // unrelated call sites are in real files.
        let padding = "\n// " + String(repeating: "-", count: Self.contextWindow) + "\n"
        let fixture = [
            """
            extension Notification.Name {
                static let fixturePosted = Notification.Name("fixture.posted")
                static let fixtureObserved = Notification.Name("fixture.observed")
                static let fixtureTabled = Notification.Name("fixture.tabled")
                static let fixtureUnused = Notification.Name("fixture.unused")
            }
            """,
            """
            func send() {
                NotificationCenter.default.post(name: .fixturePosted, object: nil)
            }
            """,
            """
            func listen() {
                NotificationCenter.default.addObserver(forName: .fixtureObserved, object: nil, queue: nil) { _ in }
            }
            """,
            """
            let table: [String: Notification.Name] = [
                "a": .fixtureTabled
            ]
            """,
        ].joined(separator: padding)
        let wiring = Self.scan(sources: [fixture])
        #expect(wiring.declared == [
            "fixturePosted": "fixture.posted",
            "fixtureObserved": "fixture.observed",
            "fixtureTabled": "fixture.tabled",
            "fixtureUnused": "fixture.unused",
        ])
        #expect(wiring.posted == ["fixturePosted", "fixtureTabled"])
        #expect(wiring.observed == ["fixtureObserved"])
    }

    /// A notification with no observer is a command that does nothing when the
    /// user invokes it. This is the check that found nine dead command chains
    /// in this codebase when it was run by hand.
    @Test(.enabled(if: SourceTree.isAvailable, "App sources are not readable from this build"))
    func testEveryPostedNotificationHasAnObserver() throws {
        try SourceTree.requireSources()
        let wiring = scan()

        let dead = wiring.posted
            .subtracting(wiring.observed)
            .subtracting(Self.postedWithoutInAppObserver)
            .map { "\($0) (\(wiring.declared[$0] ?? "?"))" }
            .sorted()

        #expect(dead == [], """
            These notifications are posted but nothing observes them. Whatever \
            posts them — a menu item, a keybind, a gesture — now does nothing at \
            all when the user invokes it, and the compiler cannot see it because \
            NotificationCenter matches on names, not types.
            """)
    }

    /// The mirror image: an observer for a name nothing sends. Harmless at run
    /// time, but it means the feature it belongs to is already dead and the
    /// next reader will assume otherwise.
    @Test(.enabled(if: SourceTree.isAvailable, "App sources are not readable from this build"))
    func testEveryObservedNotificationHasAPoster() throws {
        try SourceTree.requireSources()
        let wiring = scan()

        let orphaned = wiring.observed
            .subtracting(wiring.posted)
            .subtracting(Self.observedWithoutInAppPoster)
            .map { "\($0) (\(wiring.declared[$0] ?? "?"))" }
            .sorted()

        #expect(orphaned == [], "These notifications are observed but never posted; the sender was removed or renamed and the observer is now dead code.")
    }

    /// A declared name that is neither posted nor observed is a leftover of a
    /// half-finished removal.
    @Test(.enabled(if: SourceTree.isAvailable, "App sources are not readable from this build"))
    func testNoNotificationIsDeclaredButUnused() throws {
        try SourceTree.requireSources()
        let wiring = scan()

        let unused = Set(wiring.declared.keys)
            .subtracting(wiring.posted)
            .subtracting(wiring.observed)
            .sorted()

        #expect(unused == [], "Declared but neither posted nor observed — delete the declaration or finish the wiring.")
    }

    /// Names are matched as strings across process and module boundaries, so a
    /// duplicate raw value silently merges two unrelated channels: posting one
    /// fires the other's observers too.
    @Test(.enabled(if: SourceTree.isAvailable, "App sources are not readable from this build"))
    func testDeclaredNotificationRawValuesAreUnique() throws {
        try SourceTree.requireSources()
        let wiring = scan()

        var owners: [String: [String]] = [:]
        for (symbol, raw) in wiring.declared { owners[raw, default: []].append(symbol) }
        let collisions = owners.filter { $0.value.count > 1 }
            .map { "\($0.key) declared by \($0.value.sorted().joined(separator: ", "))" }
            .sorted()

        #expect(collisions == [], "Two names share a raw value, so posting either one triggers both sets of observers.")
    }

    /// `SettingsRefreshHub.liveApplyNotifications` documents this rule in a
    /// comment — "Every entry must have a live observer — a name posted here
    /// and observed nowhere is a silent no-op" — and nothing enforced it.
    /// These are live-apply settings: with no observer, changing the setting
    /// appears to work and simply never reaches the running terminal.
    @Test(.enabled(if: SourceTree.isAvailable, "App sources are not readable from this build"))
    func testLiveApplySettingNotificationsAreObserved() throws {
        try SourceTree.requireSources()
        let wiring = scan()

        for name in ["forceASCIIKeyboardChanged", "keyboardToolbarHardwareSettingChanged"] {
            #expect(wiring.declared.keys.contains(name), "\(name) is no longer declared; SettingsRefreshHub's live-apply table has lost an entry.")
            #expect(wiring.observed.contains(name), "\(name) is posted by SettingsRefreshHub but observed nowhere, so the setting never reaches a live terminal.")
        }
    }
}
