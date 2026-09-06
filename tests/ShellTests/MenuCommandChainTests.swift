//
//  MenuCommandChainTests.swift
//  ShellTests
//
//  Pins every menu / keyboard command that `UIApplication+CommandFallback`
//  routes: the ObjC selector the menu item sends, the notification it posts,
//  and the userInfo that tells the receiver *which* split, tab or direction.
//
//  WHY THIS IS THE CENTREPIECE OF THE COHERENT-REMOVAL SUITE
//  ========================================================
//  Nothing in this file names a Swift symbol from the app. Selectors are built
//  with `NSSelectorFromString`; notifications are matched by their raw string
//  ("dev.chr33s.shell.newTab"), never by `.newTab`. That is deliberate and it
//  is the whole point:
//
//    * A test written as `UIApplication.shared.menuNewTab(nil)` or
//      `expectation(forNotification: .newTab)` compile-depends on the very
//      things it guards. Delete `menuNewTab` and `.newTab` together — exactly
//      what happened to the ⌘T tmux path and the local-shell pipeline
//      callback — and that test stops compiling, so the same sweep deletes it.
//      It cannot fail, so it protects nothing.
//    * Every reference here is resolved at *run* time. Delete the selector and
//      `responds(to:)` returns false. Delete the notification and nothing
//      arrives. Rename either one and the test goes red while still compiling.
//      A sweep cannot take this file with it.
//
//  The table below is an independent record of what the app is supposed to do,
//  not a derivation of what it currently does. Removing a command therefore
//  requires deleting its row here as a separate, visible act — which is the
//  speed bump the four defects this session all slipped past.
//
//  Determinism: `ghostty_postNotification` posts synchronously on the calling
//  thread, so every assertion is made after `perform` returns. No waiting, no
//  expectations, no timeouts. Observers are removed in `defer`.
//
//  NOT COVERED HERE: which *responder* wins when a terminal is focused.
//  `TerminalView` implements many of the same selectors and takes priority in
//  the responder chain; this file drives `UIApplication` directly, which is
//  the documented fallback path used when no terminal is in the chain (all
//  tabs closed on iPad / Catalyst). `testTerminalViewImplementsEveryResponder…`
//  pins that the focused-pane half of each pair still exists.
//

import XCTest
import UIKit

@testable import Shell

@MainActor
final class MenuCommandChainTests: XCTestCase {

    /// One menu command: the selector a menu item sends, the notification the
    /// app-level fallback turns it into, and the userInfo that disambiguates
    /// commands sharing a notification.
    struct Command {
        let selector: String
        let posts: String
        let userInfo: [String: AnyHashable]

        init(_ selector: String, posts: String, userInfo: [String: AnyHashable]) {
            self.selector = selector
            self.posts = posts
            self.userInfo = userInfo
        }
    }

    /// The command chain, recorded independently of the code that implements
    /// it. Keep in sync with `shell/App/UIApplication+CommandFallback.swift`
    /// *deliberately* — an accidental drift is the bug this file exists to
    /// catch.
    static let commands: [Command] = [
        Command("menuCreateLocalShell:", posts: "dev.chr33s.shell.createLocalShell", userInfo: [:]),
        Command("menuNewTab:", posts: "dev.chr33s.shell.newTab", userInfo: [:]),
        Command("menuNewWindow:", posts: "dev.chr33s.shell.newWindow", userInfo: [:]),
        Command("menuDuplicateTabWithSSH:", posts: "dev.chr33s.shell.duplicateTabWithSSH", userInfo: [:]),
        Command("menuSplitRight:", posts: "dev.chr33s.shell.createSplit", userInfo: ["direction": "right"]),
        Command("menuSplitDown:", posts: "dev.chr33s.shell.createSplit", userInfo: ["direction": "down"]),
        Command("menuNavigateSplitLeft:", posts: "dev.chr33s.shell.navigateSplit", userInfo: ["direction": "left"]),
        Command("menuNavigateSplitRight:", posts: "dev.chr33s.shell.navigateSplit", userInfo: ["direction": "right"]),
        Command("menuNavigateSplitUp:", posts: "dev.chr33s.shell.navigateSplit", userInfo: ["direction": "up"]),
        Command("menuNavigateSplitDown:", posts: "dev.chr33s.shell.navigateSplit", userInfo: ["direction": "down"]),
        Command("menuToggleSplitZoom:", posts: "dev.chr33s.shell.toggleSplitZoom", userInfo: [:]),
        Command("menuEqualizeSplits:", posts: "dev.chr33s.shell.equalizeSplits", userInfo: [:]),
        Command("menuOpenSettings:", posts: "dev.chr33s.shell.openSettings", userInfo: [:]),
        Command("menuBrowseHosts:", posts: "dev.chr33s.shell.browseHosts", userInfo: [:]),
        Command("menuBrowseProfiles:", posts: "dev.chr33s.shell.browseProfiles", userInfo: [:]),
        Command("menuToggleTabBar:", posts: "dev.chr33s.shell.toggleTabBar", userInfo: [:]),
        Command("menuMoveTabToNewWindow:", posts: "dev.chr33s.shell.moveTabToNewWindow", userInfo: [:]),
        Command("menuMergeAllWindows:", posts: "dev.chr33s.shell.mergeAllWindows", userInfo: [:]),
        Command("menuToggleGroupMode:", posts: "dev.chr33s.shell.toggleGroupMode", userInfo: [:]),
        Command("menuPreviousGroup:", posts: "dev.chr33s.shell.previousGroup", userInfo: [:]),
        Command("menuNextGroup:", posts: "dev.chr33s.shell.nextGroup", userInfo: [:]),
        Command("menuToggleTransparency:", posts: "dev.chr33s.shell.toggleTransparency", userInfo: [:]),
        Command("menuToggleTitleBar:", posts: "dev.chr33s.shell.toggleTitleBar", userInfo: [:]),
        Command("menuPreviousTab:", posts: "dev.chr33s.shell.previousTab", userInfo: [:]),
        Command("menuNextTab:", posts: "dev.chr33s.shell.nextTab", userInfo: [:]),
        Command("menuShowTmuxSessions:", posts: "dev.chr33s.shell.showTmuxSessions", userInfo: [:]),
        Command("menuDetachOtherClients:", posts: "dev.chr33s.shell.detachOtherClients", userInfo: [:]),
        Command("menuSelectTab1:", posts: "dev.chr33s.shell.selectTab", userInfo: ["tabIndex": 1]),
        Command("menuSelectTab2:", posts: "dev.chr33s.shell.selectTab", userInfo: ["tabIndex": 2]),
        Command("menuSelectTab3:", posts: "dev.chr33s.shell.selectTab", userInfo: ["tabIndex": 3]),
        Command("menuSelectTab4:", posts: "dev.chr33s.shell.selectTab", userInfo: ["tabIndex": 4]),
        Command("menuSelectTab5:", posts: "dev.chr33s.shell.selectTab", userInfo: ["tabIndex": 5]),
        Command("menuSelectTab6:", posts: "dev.chr33s.shell.selectTab", userInfo: ["tabIndex": 6]),
        Command("menuSelectTab7:", posts: "dev.chr33s.shell.selectTab", userInfo: ["tabIndex": 7]),
        Command("menuSelectTab8:", posts: "dev.chr33s.shell.selectTab", userInfo: ["tabIndex": 8]),
        Command("menuSelectTab9:", posts: "dev.chr33s.shell.selectTab", userInfo: ["tabIndex": 9]),
        Command("increaseFontSize:", posts: "dev.chr33s.shell.increaseFontSize", userInfo: [:]),
        Command("decreaseFontSize:", posts: "dev.chr33s.shell.decreaseFontSize", userInfo: [:]),
        Command("resetFontSizeToDefault:", posts: "dev.chr33s.shell.resetFontSize", userInfo: [:]),
        Command("findInTerminal:", posts: "dev.chr33s.shell.startSearch", userInfo: [:]),
    ]

    // MARK: - Helpers

    /// Sends `selector` to `UIApplication.shared` and returns every
    /// notification named `name` that arrived while it ran.
    private func notifications(named name: String, whileSending selector: Selector) -> [Notification] {
        var received: [Notification] = []
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name(name), object: nil, queue: nil
        ) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        UIApplication.shared.perform(selector, with: nil)
        return received
    }

    // MARK: - The chain, end to end

    /// Every recorded command still exists as an ObjC selector on
    /// `UIApplication`, and sending it posts exactly the notification the menu
    /// item promises, carrying exactly the userInfo the receiver switches on.
    ///
    /// This one test covers all 40 rows rather than generating 40 cases so a
    /// mass removal reports every casualty in a single failure, instead of the
    /// runner listing 40 individually-red tests with no shared story.
    func testEveryMenuCommandStillDispatchesItsNotification() throws {
        var missingSelector: [String] = []
        var postedNothing: [String] = []
        var wrongUserInfo: [String] = []

        for command in Self.commands {
            let selector = NSSelectorFromString(command.selector)
            guard UIApplication.shared.responds(to: selector) else {
                missingSelector.append(command.selector)
                continue
            }

            let received = notifications(named: command.posts, whileSending: selector)
            guard let notification = received.first else {
                postedNothing.append("\(command.selector) -> \(command.posts)")
                continue
            }

            // Only the keys this command is responsible for are checked. The
            // fallback also stamps `windowSceneSessionID` so an untargeted
            // command lands in the focused window; that is asserted separately.
            for (key, expected) in command.userInfo {
                let actual = notification.userInfo?[key] as? AnyHashable
                if actual != expected {
                    wrongUserInfo.append(
                        "\(command.selector): userInfo[\(key)] was \(actual.map { "\($0)" } ?? "nil"), expected \(expected)"
                    )
                }
            }
        }

        XCTAssertEqual(
            missingSelector, [],
            """
            Menu commands are no longer implemented on UIApplication. If these were \
            removed on purpose, delete their rows from `MenuCommandChainTests.commands` \
            in the same change — that deletion is the review signal this test exists \
            to force. See shell/App/UIApplication+CommandFallback.swift.
            """
        )
        XCTAssertEqual(
            postedNothing, [],
            """
            These selectors exist but posted nothing. The command is a dead \
            chain: the menu item is enabled, the user picks it, and the app does \
            nothing. This is the exact failure mode that hid nine broken commands \
            in this codebase.
            """
        )
        XCTAssertEqual(
            wrongUserInfo, [],
            """
            A command posted the right notification with the wrong payload. \
            Commands that share a notification are told apart *only* by this \
            userInfo, so a swapped value silently sends the user to the wrong \
            split, tab or direction.
            """
        )
    }

    /// The four split-navigation commands share one notification and are told
    /// apart *only* by their `direction` payload, so a copy-paste slip between
    /// arms produces two menu items that do the same thing and one direction
    /// the user can no longer reach. Driven against the real selectors rather
    /// than the table above, so a mistake in production fails here even if the
    /// table was updated to match it.
    func testSplitNavigationCommandsPostFourDistinctDirections() {
        var directions: [String: String] = [:]
        for selector in [
            "menuNavigateSplitLeft:", "menuNavigateSplitRight:",
            "menuNavigateSplitUp:", "menuNavigateSplitDown:",
        ] {
            let received = notifications(
                named: "dev.chr33s.shell.navigateSplit",
                whileSending: NSSelectorFromString(selector)
            )
            directions[selector] = received.first?.userInfo?["direction"] as? String
        }

        XCTAssertEqual(
            Set(directions.values.compactMap { $0 }), ["left", "right", "up", "down"],
            """
            Split navigation no longer posts four distinct directions: \(directions). \
            Two commands claiming the same direction means one of them is unreachable \
            and the other fires twice as often as the user expects.
            """
        )
    }

    /// `menuSelectTab1…9` differ only by `tabIndex`, and the indices are
    /// 1-based — a 0-based slip selects the wrong tab for every shortcut.
    /// Also driven against the real selectors.
    func testSelectTabCommandsPostDistinctOneBasedIndices() {
        var indices: [Int] = []
        for n in 1...9 {
            let received = notifications(
                named: "dev.chr33s.shell.selectTab",
                whileSending: NSSelectorFromString("menuSelectTab\(n):")
            )
            if let index = received.first?.userInfo?["tabIndex"] as? Int { indices.append(index) }
        }

        XCTAssertEqual(
            indices, Array(1...9),
            """
            ⌘1…⌘9 no longer post 1…9 in order. These indices are 1-based; an \
            off-by-one sends every shortcut to its neighbour's tab.
            """
        )
    }

    /// Untargeted commands are stamped with the scene they should land in.
    /// Without it a command raised with no terminal focused would be ambiguous
    /// across windows, and the menu's checkmarks (which resolve the same way)
    /// could describe a different window than the one that acts.
    func testFallbackCommandsAreStampedWithTheActiveWindowScene() throws {
        let sceneID = try XCTUnwrap(
            UIApplication.shared.ghostty_activeWindowSceneSessionID(),
            "Test host has no foreground window scene; the stamping path cannot be exercised."
        )

        let received = notifications(
            named: "dev.chr33s.shell.newTab",
            whileSending: NSSelectorFromString("menuNewTab:")
        )

        XCTAssertEqual(
            received.first?.userInfo?["windowSceneSessionID"] as? String, sceneID,
            "Fallback commands must carry the active scene id, or a multi-window command lands in an arbitrary window."
        )
    }

    // MARK: - Responder-chain half

    /// When a terminal *is* focused it, not `UIApplication`, handles these
    /// commands. Both halves must exist: deleting the `TerminalView` method
    /// leaves the command working only when no pane is focused, which reads to
    /// a user as "the shortcut works sometimes".
    ///
    /// Looked up by string for the same reason as everything else here — a
    /// `#selector(...)` reference would be swept along with the method.
    func testTerminalViewImplementsEveryResponderSideCommand() {
        // Commands the focused terminal must handle itself. Not the whole
        // fallback table: font-size and search commands are handled elsewhere
        // in the chain, and `menuSelectTab1…9` are listed once as a group.
        let responderSelectors = [
            "menuNewTab:", "menuNewWindow:", "menuCreateLocalShell:", "menuDuplicateTabWithSSH:",
            "menuPreviousTab:", "menuNextTab:", "menuSelectTab1:", "menuSelectTab9:",
            "menuSplitRight:", "menuSplitLeft:", "menuSplitDown:", "menuSplitUp:",
            "menuNavigateSplitLeft:", "menuNavigateSplitRight:",
            "menuNavigateSplitUp:", "menuNavigateSplitDown:",
            "menuToggleSplitZoom:", "menuEqualizeSplits:",
            "menuOpenSettings:", "menuBrowseHosts:", "menuBrowseProfiles:",
            "menuToggleTabBar:", "menuToggleGroupMode:",
            "menuPreviousGroup:", "menuNextGroup:",
            "menuShowTmuxSessions:", "menuDetachOtherClients:",
            "menuToggleTransparency:", "menuToggleTitleBar:", "menuToggleFullScreen:",
            "menuClearScreen:", "menuScrollPageUp:", "menuScrollPageDown:",
            "menuScrollToTop:", "menuScrollToBottom:",
            "menuToggleCompose:", "menuToggleMouseCapture:", "menuCycleInputSource:",
        ]

        let missing = responderSelectors.filter {
            !Ghostty.TerminalView.instancesRespond(to: NSSelectorFromString($0))
        }

        XCTAssertEqual(
            missing, [],
            """
            Ghostty.TerminalView no longer implements these menu selectors, so the \
            command silently falls through to the app-level fallback (or nowhere) \
            whenever a pane is focused. See shell/UI/Terminal/TerminalView+Keyboard.swift.
            """
        )
    }

    /// `.previousGroup` / `.nextGroup` are on the fork's keep-list and have no
    /// other coverage: they are posted by the fallback, handled by the focused
    /// terminal, and observed by `MainView`. Pinned explicitly so the pair
    /// cannot be swept as "unused tab navigation".
    func testGroupNavigationCommandsSurviveOnBothResponderPaths() {
        for (selector, name) in [
            ("menuPreviousGroup:", "dev.chr33s.shell.previousGroup"),
            ("menuNextGroup:", "dev.chr33s.shell.nextGroup"),
        ] {
            let sel = NSSelectorFromString(selector)
            XCTAssertTrue(
                UIApplication.shared.responds(to: sel),
                "\(selector) was removed from the app-level fallback."
            )
            XCTAssertTrue(
                Ghostty.TerminalView.instancesRespond(to: sel),
                "\(selector) was removed from the focused-terminal responder."
            )
            XCTAssertEqual(
                notifications(named: name, whileSending: sel).count, 1,
                "\(selector) no longer posts \(name)."
            )
        }
    }
}
