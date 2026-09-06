//
//  CoherentRemovalTripwireTests.swift
//  ShellTests
//
//  Source-text tripwires for wiring a unit test cannot reach.
//
//  READ THIS BEFORE TRUSTING ANYTHING IN THIS FILE
//  ===============================================
//  These are **not** behavioral tests and must not be counted as coverage of
//  the behavior they mention. Each one asserts that a call site still exists
//  in the app's source. That is a weaker claim than "it works", and it is the
//  strongest claim available for the three cases below, all of which live
//  inside a SwiftUI `View` body or `Commands` block:
//
//    * `MainView.handleNewTabCommand()` — a method on a `View` needing
//      `terminals`, `selectedTabIndex` and a live tmux controller. Hosting a
//      `MainView` to drive ⌘T is not justified for one switch statement.
//    * `MenuToggleItem` — a `View` whose menu presence only materialises when
//      SwiftUI evaluates a `Commands` body, which a unit test does not do.
//    * `LocalShellSession`'s interpreter construction — the closure is passed
//      during session setup, behind a PTY and ios_system.
//
//  Each tripwire is written to survive a *refactor* and fail on a *removal*:
//  they search the whole app source rather than one file, so moving code
//  between files keeps them green. They are named `tripwire…` so a reader
//  scanning the runner output is never misled about what ran.
//
//  Where a real behavioral test exists elsewhere, it is named in the doc
//  comment so the pair can be read together.
//

import XCTest

@testable import Shell

final class CoherentRemovalTripwireTests: XCTestCase {

    private func appSource() throws -> String {
        try SourceTree.requireSources()
        let source = SourceTree.allAppSource()
        XCTAssertGreaterThan(source.count, 100_000, "Read almost no app source; the tripwires below would pass vacuously.")
        return source
    }

    // MARK: - ⌘T inside tmux

    /// The defect: `TmuxNewTabAction` and the `switch` that consulted it were
    /// deleted in one sweep. The build stayed green and ⌘T silently became
    /// "always open a local shell", ignoring a preference that was still
    /// syncing to the user's other devices.
    ///
    /// The setting half is covered behaviorally in
    /// `SettingsRegistryInventoryTests` (registration, config key, sync
    /// policy, and that `.current` really reads the store). This tripwire
    /// covers the half that has no runtime handle: that something still *asks*.
    func testTripwireNewTabCommandStillConsultsTheTmuxNewTabPreference() throws {
        let source = try appSource()

        XCTAssertTrue(
            source.contains("TmuxNewTabAction.current"),
            """
            Nothing reads TmuxNewTabAction.current any more. The preference is still \
            registered and still syncs, but ⌘T no longer consults it — which is \
            exactly the state this fork was already in once. See \
            shell/UI/Shell/MainView+TabManagement.swift (handleNewTabCommand).
            """
        )
    }

    /// Every case must lead somewhere distinct. `.tmuxTab` and `.ask` are the
    /// two a user has to change a setting to reach, so a `switch` quietly
    /// collapsed to "local shell" for both would still look correct in the
    /// settings UI and do nothing.
    ///
    /// Scoped to the switch statement itself rather than searching the whole
    /// app: `requestTmuxNewWindow` and `pendingTmuxNewTabTabID` are both used
    /// by other features (the tab bar's context menu, the confirmation sheet),
    /// so a whole-source search would stay green with every arm of this switch
    /// deleted — which is exactly the removal it is supposed to catch.
    func testTripwireEveryTmuxNewTabActionCaseHasItsOwnBranch() throws {
        let source = try appSource()

        guard let switchStart = source.range(of: "switch TmuxNewTabAction.current") else {
            return XCTFail("No `switch TmuxNewTabAction.current` remains; ⌘T no longer branches on the preference at all.")
        }
        // The whole switch comfortably fits; enough to span its three arms
        // without running into unrelated code.
        let body = String(source[switchStart.lowerBound...].prefix(700))

        let missing = ["case .localShell", "case .tmuxTab", "case .ask"].filter { !body.contains($0) }

        XCTAssertEqual(
            missing, [],
            """
            The ⌘T switch no longer handles every TmuxNewTabAction case. A case with no \
            branch of its own means the setting offers the user a choice that does \
            nothing. See shell/UI/Shell/MainView+TabManagement.swift (handleNewTabCommand).
            """
        )
    }

    // MARK: - Checkable menu items

    /// Eight menu items reflect live state with a checkmark. They are on the
    /// fork's keep-list: each replaced a plain `Button`, and reverting one to a
    /// button loses the checkmark without changing what the item *does*, so no
    /// behavioral test would notice.
    ///
    /// The dispatch half is checked at run time in
    /// `MenuCommandChainTests.testTerminalViewImplementsEveryResponderSideCommand`;
    /// this pins that the checkable items themselves still exist.
    func testTripwireAllEightCheckableMenuItemsAreStillInstalled() throws {
        let source = try appSource()

        let kinds = [
            "topTabBar", "groupMode", "transparency", "titleBar",
            "fullScreen", "splitZoom", "compose", "mouseCapture",
        ]
        let missing = kinds.filter { !source.contains("MenuToggleItem(kind: .\($0)") }

        XCTAssertEqual(
            missing, [],
            """
            These checkable menu items are no longer installed. If one was reverted to \
            a plain Button the command still works, so nothing else fails — the menu \
            just stops showing whether the thing is currently on. See \
            shell/App/AppCommands.swift.
            """
        )
        XCTAssertEqual(
            kinds.count, 8,
            "Update this list deliberately when adding or removing a checkable item."
        )
    }

    // MARK: - Local-shell pipeline staging

    /// The second coherent removal: `requiresOwnExternalPipelineStage` — the
    /// callback that keeps a command from being bundled with its neighbours
    /// into one `|`-joined argv — was deleted along with its only consumer.
    ///
    /// The mechanism is covered behaviorally at the interpreter level (a
    /// predicate that returns true really does force its own stage). What has
    /// no runtime handle is the *wiring*: that `LocalShellSession` still hands
    /// its predicate to the interpreter it builds. Without that, the mechanism
    /// works perfectly and is never invoked.
    ///
    /// Note the predicate currently returns a constant `false` in this fork
    /// ("Nothing this fork intercepts needs that"), so this tripwire protects
    /// the seam, not an active behavior. That is the honest scope: it ensures
    /// the hook is still connected for whoever next needs it.
    func testTripwireLocalShellStillSuppliesItsPipelineStagePredicate() throws {
        let source = try appSource()

        // ShellInterpreter passes the callback down its own recursion five
        // times and ShellJobs forwards it once, so searching every file would
        // stay green long after the only real supplier was deleted. Those two
        // implementation files are excluded, leaving genuine call sites.
        let callers = SourceTree.allAppSource(
            excludingFilesNamed: ["ShellInterpreter.swift", "ShellJobs.swift"]
        )

        XCTAssertTrue(
            callers.contains("requiresOwnExternalPipelineStage:"),
            """
            Nothing outside ShellInterpreter/ShellJobs passes \
            requiresOwnExternalPipelineStage any more. The interpreter may still honour \
            the callback, but no production code supplies one, so commands that must be \
            their own pipeline stage are silently bundled with their neighbours into a \
            single `|`-joined argv. See shell/Features/LocalShell/LocalShellSession+Shell.swift.
            """
        )
        XCTAssertTrue(
            source.contains("func requiresOwnExternalPipelineStage"),
            "LocalShellSession's predicate itself is gone; the interpreter parameter now has no production implementation."
        )
    }

    /// `ShellJobs` refuses to background a command that needs its own pipeline
    /// stage. That guard reads the same predicate and is easy to drop when
    /// simplifying the backgrounding path.
    func testTripwireBackgroundingStillRefusesCommandsNeedingTheirOwnStage() throws {
        let source = try appSource()

        XCTAssertTrue(
            source.contains("requiresOwnExternalPipelineStage?("),
            """
            ShellJobs no longer consults requiresOwnExternalPipelineStage before \
            backgrounding. A command that must be its own stage would be sent to the \
            background path that cannot give it one. See shell/Core/Shell/ShellJobs.swift.
            """
        )
    }
}
