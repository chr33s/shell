import UIKit
import Foundation
import Testing

@testable import Shell

@MainActor
@Suite
final class ModTapStateTests {
    private func commandControl() -> ModTapState {
        ModTapState(sourceKey: .keyboardLeftGUI, holdModifier: .control, startedAt: 10, threshold: 0.2)
    }

    @Test
    func testOlderKeyReleaseDoesNotConsumePendingTap() throws {
        for source: UIKeyboardHIDUsage in [.keyboardCapsLock, .keyboardLeftGUI] {
            let state = ModTapState(sourceKey: source, holdModifier: .control, startedAt: 10, threshold: 0.2)
            // C was already down when the source was pressed. Only its
            // release is delivered while the mod-tap source is pending.
            #expect((state.resolution(onRelease: .keyboardC)) == nil)
            #expect(state.phase == .pending)
            #expect(state.resolution(onRelease: source) == .tap)
        }
    }

    @Test
    func testChordResolvesHoldOnceAndSuppressesTap() throws {
        var state = commandControl()
        let used = state.useInChord()
        let usedAgain = state.useInChord()
        let advanced = state.advance(to: 11)
        #expect(used)
        #expect(!usedAgain)
        #expect(!advanced)
        #expect(state.resolution(onRelease: .keyboardLeftGUI) == .hold)
    }

    @Test
    func testRepeatDoesNotRestartThresholdOrResolveHoldTwice() throws {
        var state = commandControl()
        let early = state.advance(to: 10.1)
        let crossed = state.advance(to: 10.21)
        let later = state.advance(to: 10.3)
        #expect(!early)
        #expect(state.phase == .pending)
        #expect(crossed)
        #expect(!later)
        #expect(state.resolution(onRelease: .keyboardLeftGUI) == .hold)
    }

    @Test
    func testOriginalBindingsWinBeforeAndAfterThreshold() throws {
        for useTimer in [false, true] {
            var state = commandControl()
            if useTimer { state.advance(to: 11) } else { state.useInChord() }
            // Cmd+T, Cmd+1 and Cmd+C all remain Command shortcuts; selection
            // availability never changes this decision. Cmd+Shift+V is intact.
            for hardware: UIKeyModifierFlags in [.command, [.command, .shift]] {
                #expect(state.modifiers(hardware: hardware, originalShortcutIsBound: true,
                    heldKeys: [.keyboardLeftGUI]) == hardware)
            }
            #expect(state.resolution(onRelease: .keyboardLeftGUI) == .hold)
        }
    }

    @Test
    func testUnboundChordReplacesCommandAndPreservesShift() throws {
        var state = commandControl()
        state.useInChord()
        #expect(state.modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI]) == .control)
        #expect(state.modifiers(hardware: [.command, .shift], originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI, .keyboardLeftShift]) == [.control, .shift])
    }

    @Test
    func testMovingCopyBindingOnlyChangesWhichChordWins() throws {
        var state = commandControl()
        state.useInChord()
        // Test configuration only: Copy on Cmd+Shift+C, Cmd+C unbound.
        #expect(state.modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI]) == .control)
        #expect(state.modifiers(hardware: [.command, .shift], originalShortcutIsBound: true,
            heldKeys: [.keyboardLeftGUI, .keyboardLeftShift]) == [.command, .shift])
    }

    @Test
    func testShortcutThenUnboundKeyDuringSameHold() throws {
        var state = commandControl()
        state.useInChord() // A UIKeyCommand/menu action without a raw key-down.
        #expect(state.modifiers(hardware: .command, originalShortcutIsBound: true,
            heldKeys: [.keyboardLeftGUI]) == .command)
        #expect(state.modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI]) == .control)
        #expect(state.resolution(onRelease: .keyboardLeftGUI) == .hold)
    }

    @Test
    func testIndependentOppositeSideModifierIsPreserved() throws {
        var state = commandControl()
        state.useInChord()
        #expect(state.modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI, .keyboardRightGUI]) == [.command, .control])
        #expect(state.modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI]) == .control)
    }

    @Test
    func testAllModifierSourcesAndNonModifierSources() throws {
        let sources: [(UIKeyboardHIDUsage, UIKeyModifierFlags)] = [
            (.keyboardLeftGUI, .command), (.keyboardRightGUI, .command),
            (.keyboardLeftControl, .control), (.keyboardRightControl, .control),
            (.keyboardLeftAlt, .alternate), (.keyboardRightAlt, .alternate),
            (.keyboardLeftShift, .shift), (.keyboardRightShift, .shift)
        ]
        for (source, flag) in sources {
            var state = ModTapState(sourceKey: source, holdModifier: .control, startedAt: 0, threshold: 0.2)
            state.useInChord()
            #expect(state.modifiers(hardware: flag, originalShortcutIsBound: false,
                heldKeys: [source]) == .control)
        }
        for source: UIKeyboardHIDUsage in [.keyboardCapsLock, .keyboardEscape, .keyboardTab, .keyboardA] {
            var state = ModTapState(sourceKey: source, holdModifier: .control, startedAt: 0, threshold: 0.2)
            state.useInChord()
            #expect(state.modifiers(hardware: .shift, originalShortcutIsBound: false,
                heldKeys: [.keyboardLeftShift]) == [.control, .shift])
        }
    }

    @Test
    func testPendingSourceDoesNotChangeModifiers() throws {
        #expect(commandControl().modifiers(hardware: .command, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftGUI]) == .command)
    }

    @Test
    func testTrackedOptionPrintableSubstitutesEveryHoldModifierAndCombination() throws {
        for hold: UIKeyModifierFlags in [.shift, .control, .command, .alternate] {
            for extra: UIKeyModifierFlags in [[], .shift, .control, [.control, .shift]] {
                var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: hold, startedAt: 0, threshold: 0.2)
                state.useInChord()
                let chord = try #require(ModifierPrintableChord(
                    hardware: extra.union(.alternate), state: state, originalShortcutIsBound: false,
                    heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
                ))
                #expect(chord.modifiers == extra.union(hold))
                #expect(state.resolution(onRelease: .keyboardLeftAlt) == .hold)
            }
        }
    }

    @Test
    func testTrackedBoundOptionShortcutYieldsToUIKit() throws {
        var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .shift, startedAt: 0, threshold: 0.2)
        state.useInChord()
        for extra: UIKeyModifierFlags in [[], .shift, .control, [.control, .shift]] {
            #expect((ModifierPrintableChord(
                hardware: extra.union(.alternate), state: state, originalShortcutIsBound: true,
                heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
            )) == nil)
        }
    }

    @Test
    func testTrackedOptionTextPolicyUsesEffectiveModifiers() throws {
        #expect((ModifierPrintableChord(
            hardware: .alternate, state: nil, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: false
        )) == nil)
        #expect(ModifierPrintableChord(
            hardware: [.alternate, .control], state: nil, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
        )?.modifiers == [.alternate, .control])

        var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .shift, startedAt: 0, threshold: 0.2)
        state.useInChord()
        // A consumed Option must not fall back to UIKit's composed character.
        #expect(ModifierPrintableChord(
            hardware: .alternate, state: state, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: false
        )?.modifiers == .shift)
        // Independently held right Option still contributes Alt.
        #expect(ModifierPrintableChord(
            hardware: .alternate, state: state, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt, .keyboardRightAlt], optionActsAsAlt: true
        )?.modifiers == [.alternate, .shift])
    }

    @Test
    func testOriginalOptionControlActionIsHandledWithAndWithoutModTap() throws {
        var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .shift, startedAt: 0, threshold: 0.2)
        state.useInChord()
        for activeState in [nil, state] {
            for optionActsAsAlt in [false, true] {
                for extra: UIKeyModifierFlags in [[], .control, .shift, [.control, .shift]] {
                    let hardware = extra.union(.alternate)
                    let chord = try #require(ModifierPrintableChord(
                        hardware: hardware, state: activeState, originalShortcutIsBound: true,
                        heldKeys: [.keyboardLeftAlt], optionActsAsAlt: optionActsAsAlt,
                        originalControlCharacter: 4,
                        effectiveControlCharacter: { _ in Issue.record("Original binding must win"); return 1 }
                    ))
                    #expect(chord.modifiers == hardware)
                    #expect(chord.controlCharacter == 4)
                }
            }
        }
    }

    @Test
    func testSubstitutedControlActionUsesBoundByteRatherThanPhysicalLetter() throws {
        var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .control, startedAt: 0, threshold: 0.2)
        state.useInChord()
        let chord = try #require(ModifierPrintableChord(
            hardware: .alternate, state: state, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: false,
            effectiveControlCharacter: {
                #expect($0 == .control)
                return 1 // For example, Ctrl+D explicitly rebound to ctrl_a.
            }
        ))
        #expect(chord.controlCharacter == 1)
        #expect(chord.modifiers == .control)
    }

    @Test
    func testUnboundOptionChordStillUsesGhosttyEncoding() throws {
        let chord = try #require(ModifierPrintableChord(
            hardware: [.alternate, .shift], state: nil, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
        ))
        #expect((chord.controlCharacter) == nil)
        #expect(chord.modifiers == [.alternate, .shift])
    }

    @Test
    func testGCPrintableCapsLockReachesLayoutTranslationOnPressAndRepeat() throws {
        // The GC route supplies modifier flags, not a UIKit-translated UIKey.
        // Model a US layout at the translation boundary used by the encoder.
        let letterLayout: [Int: String] = [
            0: "a", UIKeyModifierFlags.shift.rawValue: "A", UIKeyModifierFlags.alphaShift.rawValue: "A",
            UIKeyModifierFlags([.shift, .alphaShift]).rawValue: "a"
        ]
        for capsLock in [false, true] {
            for extra: UIKeyModifierFlags in [[], .control, .shift, [.control, .shift]] {
                var hardware = extra.union(.alternate)
                if capsLock { hardware.insert(.alphaShift) }
                var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .shift, startedAt: 0, threshold: 0.2)
                state.useInChord()
                let chord = try #require(ModifierPrintableChord(
                    hardware: hardware, state: state, originalShortcutIsBound: false,
                    heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
                ))
                #expect(chord.modifiers == hardware.subtracting(.alternate).union(.shift))

                // Repeat retains the press's resolved modifiers even after the
                // pending mod-tap state is no longer used for translation.
                let repeatModifiers = chord.modifiers
                let expectedLayoutModifiers: UIKeyModifierFlags = capsLock ? [.shift, .alphaShift] : .shift
                var translations = 0
                for modifiers in [chord.modifiers, repeatModifiers, repeatModifiers] {
                    let text = HardwareKeyboardText.printableText(modifiers: modifiers, fallbackCharacter: "a") {
                        translations += 1
                        #expect($0 == expectedLayoutModifiers)
                        return letterLayout[$0.rawValue]
                    }
                    #expect(text == (capsLock ? "a" : "A"))
                }
                #expect(translations == 3)
            }
        }
    }

    @Test
    func testGCPrintableCapsLockFallbackPreservesShiftedSymbols() throws {
        var state = ModTapState(sourceKey: .keyboardLeftAlt, holdModifier: .shift, startedAt: 0, threshold: 0.2)
        state.useInChord()
        let chord = try #require(ModifierPrintableChord(
            hardware: [.alternate, .alphaShift], state: state, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
        ))
        for (base, expected): (Character, String) in [("a", "a"), ("1", "!"), ("[", "{")] {
            #expect(HardwareKeyboardText.printableText(
                modifiers: chord.modifiers, fallbackCharacter: base, translate: { _ in nil }
            ) == expected)
        }
    }

    @Test
    func testGCPrintableUnsubstitutedCapsLockAndCommandLayout() throws {
        let chord = try #require(ModifierPrintableChord(
            hardware: [.alternate, .alphaShift], state: nil, originalShortcutIsBound: false,
            heldKeys: [.keyboardLeftAlt], optionActsAsAlt: true
        ))
        #expect(HardwareKeyboardText.printableText(
            modifiers: chord.modifiers, fallbackCharacter: "a", translate: { _ in nil }
        ) == "A")

        // Control/Alt are encoded by Ghostty; Command/Caps affect the layout.
        let text = HardwareKeyboardText.printableText(
            modifiers: [.command, .control, .alternate, .alphaShift], fallbackCharacter: "a"
        ) {
            #expect($0 == [.command, .alphaShift])
            return "LAYOUT"
        }
        #expect(text == "LAYOUT")
    }
}
