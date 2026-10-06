//
//  ShellKeyboardTests.swift
//  ShellTests
//
//  The Shell replacement keyboard (docs/specs/keyboard-replacement.md):
//  layout inventory, the shared modifier model, dispatch semantics against a
//  recording terminal, presentation policy, migration, and privacy.
//

import Foundation
import Testing
import UIKit

@testable import Shell

// MARK: - Layout (K02, K15)

@MainActor
@Suite
struct ShellKeyboardLayoutTests {

    @Test func allPrintableASCIIIsReachable() {
        let ascii = Set((0x20...0x7E).map { Character(UnicodeScalar(UInt8($0))) })
        #expect(ascii.count == 95)
        let reachable = ShellKeyboardLayout.reachableCharacters
        #expect(ascii.subtracting(reachable).isEmpty, "unreachable: \(ascii.subtracting(reachable).sorted())")
        // No look-alike Unicode substitutes.
        #expect(reachable.allSatisfy { $0.isASCII })
    }

    @Test func everyPageHasFiveRowsAndSystemKey() {
        for page in ShellKeyboardPage.allCases {
            let rows = ShellKeyboardLayout.rows(for: page)
            #expect(rows.count == ShellKeyboardLayout.rowCount)
            #expect(rows.flatMap(\.keys).contains { $0.kind == .local(.system) }, "\(page) lacks System")
            // Persistent number row.
            #expect(rows[0].keys.map(\.id) == "1234567890".map { "digit.\($0)" })
        }
    }

    @Test func noFunctionKeysOrArrowCluster() {
        let ids = ShellKeyboardPage.allCases.flatMap { ShellKeyboardLayout.rows(for: $0).flatMap(\.keys) }.map(\.id)
        #expect(!ids.contains { $0.lowercased().contains("arrow") })
        #expect(!ids.contains { $0.range(of: #"^f\d+$"#, options: .regularExpression) != nil })
        #expect(!ShellKeyboardNamedKey.allCases.map(\.keyCode).contains { [.up, .down, .left, .right, .f1].contains($0) })
    }

    @Test func navigationPageMatchesSpec() {
        let rows = ShellKeyboardLayout.rows(for: .navigation)
        #expect(rows[1].keys.map(\.kind) == [.named(.home), .named(.end), .named(.pageUp), .named(.pageDown), .named(.forwardDelete)])
        #expect(rows[2].keys.map(\.kind) == [.named(.tab), .named(.backtab), .named(.escape), .paste])
        #expect(rows[3].keys.map(\.kind) == [.local(.shift), .local(.clearModifiers), .named(.backspace)])
    }

    @Test func literalSymbolsInsertTheirLabelEvenWithShift() {
        for key in ShellKeyboardLayout.rows(for: .symbols).flatMap(\.keys) {
            guard case .literal(let symbol) = key.kind else { continue }
            #expect(key.character(shifted: false)?.text == symbol)
            #expect(key.character(shifted: true)?.text == symbol)
        }
    }

    @Test func baseKeysFollowUSShiftPairs() {
        let key = ShellKeyboardKey("digit.1", .character("1"))
        #expect(key.character(shifted: true)?.text == "!")
        #expect(ShellKeyboardKey("x", .character("/")).character(shifted: true)?.text == "?")
        #expect(ShellKeyboardKey("x", .character(".")).character(shifted: true)?.text == ">")
        #expect(ShellKeyboardKey("x", .character("8")).character(shifted: true)?.text == "*")
        #expect(ShellKeyboardKey("x", .character("q")).character(shifted: true)?.text == "Q")
    }

    @Test func literalIdentityUsesUSBaseKey() {
        let brace = ShellKeyboardLayout.usIdentity(of: "{")
        #expect(brace.baseKey == "[")
        #expect(brace.impliesShift)
        #expect(brace.keyCode == .leftBracket)
        let minus = ShellKeyboardLayout.usIdentity(of: "-")
        #expect(minus.baseKey == "-")
        #expect(!minus.impliesShift)
    }

    @Test(arguments: [CGFloat(320), 375, 390, 430, 744, 1024, 1366])
    func cellsTileEveryRowWithoutOverlap(width: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: width, height: 44)
        for page in ShellKeyboardPage.allCases {
            for row in ShellKeyboardLayout.rows(for: page) {
                #expect(row.totalUnits <= ShellKeyboardLayout.rowUnits + 0.001)
                let cells = ShellKeyboardLayout.cellFrames(for: row, in: rect)
                #expect(cells.count == row.keys.count)
                #expect(abs(cells.first!.minX - rect.minX) < 0.001)
                #expect(abs(cells.last!.maxX - rect.maxX) < 0.001)
                for (a, b) in zip(cells, cells.dropFirst()) {
                    #expect(abs(a.maxX - b.minX) < 0.001)
                    #expect(a.width > 0)
                }
                // System and the principal mode keys reach 44pt where the row permits.
                if width >= 375 {
                    for (key, cell) in zip(row.keys, cells) where Self.isPrincipalControl(key) {
                        #expect(cell.width >= 44, "\(key.id) is \(cell.width)pt at \(width)")
                    }
                }
            }
        }
    }

    private static func isPrincipalControl(_ key: ShellKeyboardKey) -> Bool {
        switch key.kind {
        case .local(.system), .local(.page), .named(.enter): true
        default: false
        }
    }

    @Test func compactHeightKeepsAllRows() {
        let compact = UITraitCollection(verticalSizeClass: .compact)
        let regular = UITraitCollection(verticalSizeClass: .regular)
        #expect(ShellKeyboardLayout.rowHeight(for: regular) == 44)
        #expect((36...40).contains(ShellKeyboardLayout.rowHeight(for: compact)))
        #expect(ShellKeyboardLayout.contentHeight(for: compact) == 5 * ShellKeyboardLayout.rowHeight(for: compact) + 8)
    }
}

// MARK: - Shared modifiers (K04)

@MainActor
@Suite
struct SoftwareModifierModelTests {

    @Test func singleTapIsOneShotConsumedByNextKey() {
        let model = SoftwareModifierModel()
        #expect(model.tap(.control, now: 10) == .oneShot)
        #expect(model.active == .control)
        model.consumeOneShots()
        #expect(model.active.isEmpty)
    }

    @Test func quickDoubleTapLocksAndSurvivesKeys() {
        let model = SoftwareModifierModel()
        model.tap(.shift, now: 10)
        #expect(model.tap(.shift, now: 10.3) == .locked)
        model.consumeOneShots()
        model.consumeOneShots()
        #expect(model.state(for: .shift) == .locked)
        #expect(model.tap(.shift, now: 20) == .inactive)
    }

    @Test func slowSecondTapTurnsOff() {
        let model = SoftwareModifierModel()
        model.tap(.alt, now: 10)
        #expect(model.tap(.alt, now: 10.6) == .inactive)
    }

    @Test func quickRetapAfterConsumedOneShotLocks() {
        let model = SoftwareModifierModel()
        model.tap(.control, now: 10)
        model.consumeOneShots()
        #expect(model.tap(.control, now: 10.2) == .locked)
    }

    @Test func clearAllResetsStatesAndTapHistory() {
        let model = SoftwareModifierModel()
        model.tap(.control, now: 10)
        model.tap(.command, now: 10)
        model.clearAll()
        #expect(model.active.isEmpty)
        // No stale tap history: a tap right after clearing is a one-shot.
        #expect(model.tap(.control, now: 10.1) == .oneShot)
    }

    @Test func accessibilitySetNeedsNoTiming() {
        let model = SoftwareModifierModel()
        model.set(.locked, for: .control)
        #expect(model.state(for: .control) == .locked)
        model.set(.inactive, for: .control)
        #expect(model.active.isEmpty)
    }

    @Test func toolbarAndBodyShareOneState() {
        let model = SoftwareModifierModel()
        let toolbar = KeyboardToolbarView(sizes: .iPhonePortrait)
        toolbar.modifierModel = model
        var reported: [KeyModifiers] = []
        toolbar.onModifiersChanged = { reported.append($0) }
        model.tap(.shift, now: 1)            // body Shift
        #expect(reported.last == .shift)     // toolbar sees it
        toolbar.clearOneShotModifiers()      // toolbar consumes it
        #expect(model.active.isEmpty)
    }

    @Test func observationEndsWithToken() {
        let model = SoftwareModifierModel()
        var count = 0
        var token: SoftwareModifierObservation? = model.observe { _ in count += 1 }
        model.tap(.alt, now: 1)
        token = nil
        _ = token
        model.tap(.alt, now: 5)
        #expect(count == 1)
    }
}

// MARK: - Dispatch (K03, K04, K06, K09, K10, K11, K12)

@MainActor
private final class RecordingTarget: TerminalKeyboardDispatchTarget {
    enum Event: Equatable {
        case printable(String, KeyModifiers)
        case named(ShellKeyboardNamedKey, KeyModifiers)
        case paste
        case unassigned
    }

    var identity: TerminalKeyboardTargetIdentity? = TerminalKeyboardTargetIdentity(
        terminal: ObjectIdentifier(NSObject.self), session: nil, surface: 1
    )
    var accepting = true
    var claimed: Set<KeyTrigger> = []
    private(set) var events: [Event] = []
    private(set) var triggers: [KeyTrigger] = []

    var keyboardTargetIdentity: TerminalKeyboardTargetIdentity? { identity }
    var keyboardTargetIsAcceptingInput: Bool { accepting }

    func keyboardDispatchBinding(_ trigger: KeyTrigger) -> Bool {
        triggers.append(trigger)
        return claimed.contains(trigger)
    }
    func keyboardSendPrintable(_ key: String, modifiers: KeyModifiers) { events.append(.printable(key, modifiers)) }
    func keyboardSendNamedKey(_ key: ShellKeyboardNamedKey, modifiers: KeyModifiers) { events.append(.named(key, modifiers)) }
    func keyboardPaste() { events.append(.paste) }
    func keyboardReportUnassignedShortcut() { events.append(.unassigned) }
}

@MainActor
@Suite
struct TerminalKeyboardDispatcherTests {
    private let target = RecordingTarget()
    private let model = SoftwareModifierModel()
    private var dispatcher: TerminalKeyboardDispatcher { TerminalKeyboardDispatcher(target: target, modifiers: model) }

    private func press(_ key: ShellKeyboardKey, _ dispatcher: TerminalKeyboardDispatcher) -> TerminalKeyboardDispatchResult {
        let identity = dispatcher.beginInteraction()
        let character = key.character(shifted: model.state(for: .shift) != .inactive)!
        return dispatcher.perform(.character(character), on: identity)
    }

    @Test func plainTypingIsByteExactAndSingle() {
        let dispatcher = dispatcher
        for symbol in "ls -la | grep '~/x' > \"o\";" {
            let key = ShellKeyboardLayout.usBaseCharacters.contains(symbol)
                ? ShellKeyboardKey("k", .character(symbol)) : ShellKeyboardKey("k", .literal(symbol))
            #expect(press(key, dispatcher) == .delivered)
        }
        let typed = target.events.map { event -> String in
            guard case .printable(let text, let mods) = event, mods.isEmpty else { return "\u{FFFD}" }
            return text
        }.joined()
        #expect(typed == "ls -la | grep '~/x' > \"o\";")
    }

    @Test func shiftOneEmitsOneExclamation() {
        let dispatcher = dispatcher
        model.tap(.shift, now: 1)
        _ = press(ShellKeyboardKey("digit.1", .character("1")), dispatcher)
        #expect(target.events == [.printable("!", [])])
        #expect(model.active.isEmpty)
        _ = press(ShellKeyboardKey("digit.1", .character("1")), dispatcher)
        #expect(target.events.last == .printable("1", []))
    }

    @Test func shiftDoesNotChangeLiteralSymbol() {
        let dispatcher = dispatcher
        model.set(.locked, for: .shift)
        _ = press(ShellKeyboardKey("symbol.leftBracket", .literal("[")), dispatcher)
        #expect(target.events == [.printable("[", [])])
    }

    @Test func ctrlOneShotAppliesToNextKeyOnly() {
        let dispatcher = dispatcher
        model.tap(.control, now: 1)
        _ = press(ShellKeyboardKey("letter.c", .character("c")), dispatcher)
        _ = press(ShellKeyboardKey("letter.c", .character("c")), dispatcher)
        #expect(target.events == [.printable("c", [.control]), .printable("c", [])])
        #expect(target.triggers.first == KeyTrigger(key: .c, modifiers: .control))
    }

    @Test func lockedCtrlAppliesToEveryKey() {
        let dispatcher = dispatcher
        model.set(.locked, for: .control)
        _ = press(ShellKeyboardKey("letter.a", .character("a")), dispatcher)
        _ = press(ShellKeyboardKey("letter.e", .character("e")), dispatcher)
        #expect(target.events == [.printable("a", [.control]), .printable("e", [.control])])
    }

    @Test func ctrlWithShiftedLiteralEncodesBaseKey() {
        let dispatcher = dispatcher
        model.tap(.control, now: 1)
        _ = press(ShellKeyboardKey("symbol.underscore", .literal("_")), dispatcher)
        #expect(target.events == [.printable("-", [.control, .shift])])
    }

    @Test func bindingsRunOnceAndConsumeOneShot() {
        let dispatcher = dispatcher
        target.claimed = [KeyTrigger(key: .a, modifiers: .control)]
        model.tap(.control, now: 1)
        #expect(press(ShellKeyboardKey("letter.a", .character("a")), dispatcher) == .delivered)
        #expect(target.events.isEmpty)
        #expect(target.triggers.count == 1)
        #expect(model.active.isEmpty)
    }

    @Test func sequenceSecondKeyReachesBindings() {
        let dispatcher = dispatcher
        target.claimed = [KeyTrigger(key: .n)]
        _ = press(ShellKeyboardKey("letter.n", .character("n")), dispatcher)
        #expect(target.events.isEmpty)
    }

    @Test func unclaimedCommandChordIsConsumedWithoutText() {
        let dispatcher = dispatcher
        model.tap(.command, now: 1)
        #expect(press(ShellKeyboardKey("letter.k", .character("k")), dispatcher) == .unassignedShortcut)
        #expect(target.events == [.unassigned])
        #expect(model.active.isEmpty)
    }

    @Test func claimedCommandShortcutRuns() {
        let dispatcher = dispatcher
        target.claimed = [KeyTrigger(key: .k, modifiers: .command)]
        model.tap(.command, now: 1)
        #expect(press(ShellKeyboardKey("letter.k", .character("k")), dispatcher) == .delivered)
        #expect(target.events.isEmpty)
    }

    @Test func backtabIsTabWithShift() {
        let dispatcher = dispatcher
        let identity = dispatcher.beginInteraction()
        dispatcher.perform(.named(.backtab), on: identity)
        #expect(target.events == [.named(.tab, .shift)])
        #expect(target.triggers == [KeyTrigger(key: .tab, modifiers: .shift)])
    }

    @Test func namedKeysCarryModifiers() {
        let dispatcher = dispatcher
        model.tap(.control, now: 1)
        dispatcher.perform(.named(.home), on: dispatcher.beginInteraction())
        dispatcher.perform(.named(.pageDown), on: dispatcher.beginInteraction())
        #expect(target.events == [.named(.home, .control), .named(.pageDown, [])])
    }

    @Test func retiredTargetReceivesNothing() {
        let dispatcher = dispatcher
        let identity = dispatcher.beginInteraction()
        model.set(.locked, for: .control)
        // The pane's connection was replaced while the key was held.
        target.identity = TerminalKeyboardTargetIdentity(
            terminal: ObjectIdentifier(NSObject.self), session: ObjectIdentifier(NSString.self), surface: 1
        )
        #expect(dispatcher.perform(.named(.backspace), on: identity) == .targetUnavailable)
        #expect(!dispatcher.canContinue(identity))
        #expect(target.events.isEmpty)
        #expect(model.active.isEmpty)
    }

    @Test func unfocusedTargetReceivesNothing() {
        let dispatcher = dispatcher
        target.identity = nil
        #expect(dispatcher.perform(.named(.enter), on: dispatcher.beginInteraction()) == .targetUnavailable)
        #expect(target.events.isEmpty)
    }

    @Test func rejectedInputStopsRepeatButKeepsLockedModifiers() {
        let dispatcher = dispatcher
        let identity = dispatcher.beginInteraction()
        model.set(.locked, for: .control)
        model.tap(.alt, now: 1)
        target.accepting = false
        #expect(dispatcher.perform(.named(.backspace), on: identity) == .rejected)
        #expect(!dispatcher.canContinue(identity))
        // The pending one-shot is gone; the user's explicit lock is not.
        #expect(model.active == .control)
    }

    @Test func pasteConsumesOneShot() {
        let dispatcher = dispatcher
        model.tap(.control, now: 1)
        dispatcher.perform(.paste, on: dispatcher.beginInteraction())
        #expect(target.events == [.paste])
        #expect(model.active.isEmpty)
        // Ctrl must not turn the next letter into a control character.
        _ = press(ShellKeyboardKey("letter.c", .character("c")), dispatcher)
        #expect(target.events.last == .printable("c", []))
    }

    @Test func shiftNeverChangesLiteralShortcutIdentity() {
        let dispatcher = dispatcher
        target.claimed = [KeyTrigger(key: .leftBracket, modifiers: .shift)]
        model.tap(.shift, now: 1)
        _ = press(ShellKeyboardKey("symbol.leftBracket", .literal("[")), dispatcher)
        #expect(target.triggers == [KeyTrigger(key: .leftBracket)])
        #expect(target.events == [.printable("[", [])])
    }

    @Test func ctrlShiftWithUnshiftedLiteralDropsShift() {
        let dispatcher = dispatcher
        model.tap(.control, now: 1)
        model.tap(.shift, now: 1)
        _ = press(ShellKeyboardKey("symbol.minus", .literal("-")), dispatcher)
        #expect(target.events == [.printable("-", [.control])])
    }
}

// MARK: - Presentation, toolbar, and migration (K05, K13, K18)

@MainActor
@Suite
struct SoftwareKeyboardPresentationTests {

    @Test func hideRemembersTheImplementationOnScreen() {
        typealias Policy = SoftwareKeyboardPresentationPolicy
        #expect(Policy.rememberedOnHide(presented: .shell, fallbackActive: false, requested: .shell) == .shell)
        #expect(Policy.rememberedOnHide(presented: .system, fallbackActive: false, requested: .system) == .system)
        // Hiding Apple's keyboard while the preference is Shell restores System…
        #expect(Policy.rememberedOnHide(presented: .system, fallbackActive: false, requested: .shell) == .system)
        // …unless System was only a transient fallback: keep the Shell intent.
        #expect(Policy.rememberedOnHide(presented: .system, fallbackActive: true, requested: .shell) == .shell)
    }

    @Test func rememberedModeWinsOverPreferenceUntilCleared() {
        typealias Policy = SoftwareKeyboardPresentationPolicy
        #expect(Policy.requested(restore: .system, preference: .shell) == .system)
        #expect(Policy.requested(restore: nil, preference: .shell) == .shell)
    }

    @Test func visibilityControlIsFirstWithoutRewritingLayout() {
        let saved: [KeySlot] = [.builtIn(.esc), .builtIn(.ctrl), .builtIn(.arrowDrawerToggle), .builtIn(.dismiss), .builtIn(.tab)]
        let presented = KeyboardToolbarManager.presentationOrder(saved)
        #expect(presented == [.builtIn(.dismiss), .builtIn(.esc), .builtIn(.ctrl), .builtIn(.arrowDrawerToggle), .builtIn(.tab)])
        // The single joystick stays; nothing is added or removed.
        #expect(presented.filter { $0 == .builtIn(.arrowDrawerToggle) }.count == 1)
        #expect(Set(presented) == Set(saved))
        let withoutDismiss: [KeySlot] = [.builtIn(.esc), .builtIn(.tab)]
        #expect(KeyboardToolbarManager.presentationOrder(withoutDismiss) == withoutDismiss)
    }

    @Test func minimumTerminalHeightIsInPoints() {
        // An 18pt font on a 3x screen: ~66px cells are 22pt, so two rows = 44pt.
        #expect(ShellKeyboardLayout.minimumTerminalHeight(cellPixelHeight: 66, scale: 3) == 44)
        #expect(ShellKeyboardLayout.minimumTerminalHeight(cellPixelHeight: 120, scale: 3) == 80)
        #expect(ShellKeyboardLayout.minimumTerminalHeight(cellPixelHeight: 40, scale: 2) == 44)
    }

    @Test func retiringTheTargetClearsLockedModifiers() {
        let host = FakeKeyboardHost()
        let controller = TerminalKeyboardAccessoryController(host: host)
        controller.keyboardState.modifiers.set(.locked, for: .control)
        controller.keyboardState.page = .symbols
        controller.retireKeyboardTarget()
        #expect(controller.keyboardState.modifiers.active.isEmpty)
        // A reconnect is not a focus change: the page stays.
        #expect(controller.keyboardState.page == .symbols)
    }

    @Test func visibilityControlUsesKeyboardGlyphs() {
        for (restore, pinned) in [(false, false), (true, false), (true, true)] {
            let name = KeyboardToolbarView.keyboardVisibilityIconName(showsRestore: restore, pinned: pinned)
            #expect(name.hasPrefix("keyboard"), "\(name)")
            #expect(UIImage(systemName: name) != nil)
        }
    }

    @Test func migrationDefaults() {
        typealias Migration = SoftwareKeyboardModeMigration
        // New install.
        #expect(Migration.decision(storeIsReady: true, alreadyDecided: false, detectedCorruption: false,
                                   hasDefaultsBackup: false, persistedSettingCount: 0) == .shell)
        // Upgrade: prior defaults or backup.
        #expect(Migration.decision(storeIsReady: true, alreadyDecided: false, detectedCorruption: false,
                                   hasDefaultsBackup: true, persistedSettingCount: 0) == .system)
        #expect(Migration.decision(storeIsReady: true, alreadyDecided: false, detectedCorruption: false,
                                   hasDefaultsBackup: false, persistedSettingCount: 3) == .system)
        // Uncertain: protected data / corruption / not bootstrapped → untouched.
        #expect(Migration.decision(storeIsReady: false, alreadyDecided: false, detectedCorruption: false,
                                   hasDefaultsBackup: false, persistedSettingCount: 0) == nil)
        #expect(Migration.decision(storeIsReady: true, alreadyDecided: false, detectedCorruption: true,
                                   hasDefaultsBackup: true, persistedSettingCount: 0) == nil)
        // Decided once; never re-run over a user choice.
        #expect(Migration.decision(storeIsReady: true, alreadyDecided: true, detectedCorruption: false,
                                   hasDefaultsBackup: false, persistedSettingCount: 0) == nil)
    }

    @Test func preferenceIsDeviceOnlyAndDefaultsToSystem() {
        let key = Settings.Keyboard.softwareKeyboardMode
        #expect(key.policy == .deviceOnly)
        #expect(key.defaultValue == .system)
        #expect(key.configKey == nil)
    }
}

@MainActor
private final class FakeKeyboardHost: TerminalKeyboardAccessoryHost {
    let keyboardHostView = UIView()
    var keyboardIsFirstResponder = false
    func keyboardBecomeFirstResponder() -> Bool { false }
    func keyboardResignFirstResponder() -> Bool { false }
    func keyboardSetSoftwareKeyboardRequested(_ requested: Bool) {}
    func keyboardReloadInputViews() {}
    func keyboardInvalidateKeyCommands() {}
    func keyboardDidFinishAnimationLayout() {}
    func keyboardUpdateAccessoryForTraitCollection() {}
    func keyboardPaste() {}
    func keyboardToggleCompose() {}
    func keyboardToggleMouseCapture() {}
}

// MARK: - Privacy (K19) — source-text tripwire

@MainActor
@Suite(.enabled(if: SourceTree.isAvailable))
struct ShellKeyboardPrivacyTripwireTests {

    /// Lint, not behavior: logging calls on the replacement typing path must
    /// not interpolate key or text content.
    @Test func typingPathLogsNoContent() throws {
        try SourceTree.requireSources()
        let files = [
            "UI/Keyboard/KeyboardToolbarView.swift",
            "UI/Keyboard/ShellKeyboardInputView.swift",
            "UI/Keyboard/ShellKeyboardKeyView.swift",
            "UI/Keyboard/SoftwareKeyboardState.swift",
            "UI/Terminal/TerminalKeyboardDispatcher.swift"
        ]
        for file in files {
            let source = try String(contentsOf: SourceTree.appSources.appendingPathComponent(file), encoding: .utf8)
            for line in source.split(separator: "\n") where line.contains("logger.") {
                for forbidden in ["\\(key", "\\(text", "\\(character", "hexDescription", "\\(data)"] {
                    #expect(!line.contains(forbidden), "\(file): \(line)")
                }
            }
        }
        let terminal = try String(
            contentsOf: SourceTree.appSources.appendingPathComponent("UI/Terminal/TerminalView.swift"), encoding: .utf8
        )
        #expect(!terminal.contains("TerminalView.keyPressed: key=\\("))
        #expect(!terminal.contains("Sending sequence bytes: \\(data.hexDescription)"))
        #expect(!terminal.contains("to '\\(text)'"))
    }
}

// MARK: - Arrow control characterization (K05) — source-text tripwire

@MainActor
@Suite(.enabled(if: SourceTree.isAvailable))
struct ArrowJoystickCharacterizationTests {

    /// The single arrow control's gesture feel is the compatibility contract.
    /// Its constants are private, so pin them by source text.
    @Test func joystickTimingAndThresholdsAreUnchanged() throws {
        try SourceTree.requireSources()
        let source = try String(
            contentsOf: SourceTree.appSources.appendingPathComponent("UI/Keyboard/KeyboardArrowJoystickButton.swift"),
            encoding: .utf8
        )
        for constant in [
            "longPressDuration: TimeInterval = 1.5",
            "longPressCancelDistance: CGFloat = 8",
            "deadZone: CGFloat = 18",
            "autoRepeatDelay: TimeInterval = 0.5",
            "autoRepeatInterval: TimeInterval = 0.1",
            "abs(dx) > abs(dy)"
        ] {
            #expect(source.contains(constant), "missing \(constant)")
        }
    }

    /// A disconnect or replaced session must retire the keyboard target.
    @Test func sessionChangeRetiresKeyboardTarget() throws {
        try SourceTree.requireSources()
        let source = try String(
            contentsOf: SourceTree.appSources.appendingPathComponent("UI/Terminal/TerminalView+SessionHost.swift"),
            encoding: .utf8
        )
        let hook = try #require(source.range(of: "func terminalSessionWillChange()"))
        let body = source[hook.upperBound...].prefix(400)
        #expect(body.contains("retireKeyboardTarget()"))
    }

    @Test func shellBackspaceRepeatPolicy() {
        #expect(ShellKeyboardInputView.repeatDelay == 0.4)
        #expect(ShellKeyboardInputView.repeatInterval == 0.08)
        #expect(ShellKeyboardNamedKey.allCases.filter(\.repeats) == [.backspace, .forwardDelete])
    }

    @Test func toolbarKeepsOneArrowControl() {
        // The Shell body adds no arrows; the toolbar keeps .arrowDrawerToggle.
        let bodyKinds = ShellKeyboardPage.allCases.flatMap { ShellKeyboardLayout.rows(for: $0).flatMap(\.keys) }.map(\.kind)
        #expect(!bodyKinds.contains { kind in
            if case .named(let key) = kind { return [.up, .down, .left, .right].contains(key.keyCode) }
            return false
        })
        #expect(KeyID.arrowDrawerToggle.rawValue.isEmpty == false)
    }
}
