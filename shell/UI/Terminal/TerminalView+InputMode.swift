//
//  TerminalView+InputMode.swift
//  shell
//
//  Overrides `textInputMode` so a preferred primary language nudges the
//  hardware-keyboard input source. The switch is realized by briefly
//  handing first-responder to a parked text field and then taking it back,
//  which is the standard iOS pattern for refreshing the active input mode
//  without dismissing the keyboard window.
//

import UIKit
import os

extension Ghostty.TerminalView {

    override var textInputMode: UITextInputMode? {
        // Emoji search is owned by UIKit even when the terminal remains the
        // text-input responder. A saved language must not mask that mode.
        if isSystemEmojiInputActive { return super.textInputMode }
        guard let target = preferredInputLanguage else { return super.textInputMode }

        if let exact = UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage == target }) {
            return exact
        }
        if let prefix = UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage?.hasPrefix(target) == true }) {
            return prefix
        }
        return super.textInputMode
    }

    /// Read the system mode, not our preferred-language override. Hardware
    /// search keys belong to the emoji keyboard; only its committed text
    /// should reach insertText and the terminal session.
    var isSystemEmojiInputActive: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return super.textInputMode?.primaryLanguage == "emoji"
        #endif
    }

    /// iPad's hardware emoji popover keeps the terminal as first responder and
    /// reports the normal language (for example en-US), even during search.
    /// Yield only while its search field is visible. This compatibility check
    /// uses an observed UIKit class name; recheck it when updating iPadOS.
    var shouldYieldHardwareInputToEmojiUI: Bool {
        if isSystemEmojiInputActive { return true }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard isFirstResponder, let hostWindow = window,
              let scene = hostWindow.windowScene,
              scene.activationState == .foregroundActive else { return false }

        func containsVisibleEmojiSearch(_ view: UIView) -> Bool {
            guard !view.isHidden, view.alpha > 0 else { return false }
            if NSStringFromClass(type(of: view)) == "TUIEmojiSearchTextField" {
                return !view.bounds.isEmpty
            }
            return view.subviews.contains(where: containsVisibleEmojiSearch)
        }

        var windows = scene.windows
        // UIKit's auxiliary text-effects window may only be in the legacy
        // inventory. Restrict it to this scene so other windows cannot divert
        // this terminal's keys. Never retain the result across events.
        for candidate in UIApplication.shared.windows
            where candidate.windowScene === scene && !windows.contains(where: { $0 === candidate }) {
            windows.append(candidate)
        }
        return windows.contains { candidate in
            candidate !== hostWindow
                && candidate.windowLevel > hostWindow.windowLevel
                && containsVisibleEmojiSearch(candidate)
        }
        #else
        return false
        #endif
    }

    /// Switch the hardware-keyboard input source for this terminal.
    ///
    /// iPad / visionOS: set `preferredInputLanguage` and refresh the responder
    /// via a parked text field so the keyboard accessory bar and candidate
    /// strip aren't torn down by a bare `resignFirstResponder()`.
    /// Mac Catalyst: dispatch via Carbon TIS — the UIKit textInputMode override
    /// is not honored by AppKit's input-source machinery on Catalyst.
    func applyInputLanguageSwitch(toPrimaryLanguage target: String) {
        invalidateInputDocument()
        #if targetEnvironment(macCatalyst)
        // Catalyst's TIS call triggers the native macOS input-source HUD,
        // so no in-app overlay is needed here.
        InputSourceCatalog.catalystSwitch(toPrimaryLanguage: target)
        #else
        // This preference (and our textInputMode override) reflects a request,
        // not the source UIKit selected through Globe or its language picker.
        // Reapply explicit requests even when the stored preference matches.
        preferredInputLanguage = target
        showInputModeOverlay(displayName(forPrimaryLanguage: target))

        // If we're not currently first responder, the override applies next time
        // we become first responder — nothing else to do.
        guard isFirstResponder else { return }

        let parking = ensureSwapParkingField()
        // Order: park grabs first responder, then we take it back on the next
        // runloop turn so UIKit has actually surfaced the override.
        //
        // The park can legitimately fail (our own resignFirstResponder() blocks
        // during the software-keyboard app transition and while the secure-draw
        // latch is armed), and the result used to be discarded with `_ =`: the
        // terminal then never resigned, so the deferred re-take was a no-op on a
        // view that was already first responder and the input source never
        // changed. Bail out loudly instead of pretending the switch happened.
        guard parking.becomeFirstResponder() else {
            Ghostty.logger.warning(
                "input-source swap: parking field could not take first responder; textInputMode override not refreshed"
            )
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.becomeFirstResponder() {
                // becomeFirstResponder() is heavily gated (overlay owns the
                // keyboard, not logically focused, inactive window, secure
                // draw). If it refuses we must not strand the keyboard on the
                // invisible parking field, or keystrokes would vanish into it
                // until the user taps the terminal.
                _ = parking.resignFirstResponder()
            }
        }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    /// Resolve a friendly name for the overlay. Prefer the active input mode's
    /// localized identifier (so a system-installed mode picks up its full name)
    /// and fall back to a plain locale-string lookup on the language code.
    private func displayName(forPrimaryLanguage lang: String) -> String {
        if let mode = UITextInputMode.activeInputModes.first(where: { $0.primaryLanguage == lang }),
           let primary = mode.primaryLanguage,
           let localized = Locale.current.localizedString(forIdentifier: primary) {
            return localized
        }
        return Locale.current.localizedString(forIdentifier: lang) ?? lang
    }
    #endif

    /// Advance the hardware-keyboard input source to the next installed one,
    /// wrapping around — the in-app analogue of the system Ctrl+Space input
    /// cycle. The live input-source set and the current source are both re-read
    /// on every call (no cross-invocation state), so a keyboard added/removed
    /// while the app is running is reflected on the very next press.
    func cycleInputSource() {
        let sources = InputSourceCatalog.available()
        guard sources.count > 1 else {
            // 0 or 1 installed source: nothing to cycle.
            #if !targetEnvironment(macCatalyst)
            if let only = sources.first {
                showInputModeOverlay(only.displayName)
            }
            #endif
            return
        }

        let currentID = currentInputSourceIdentifier()
        let currentIndex = currentID.flatMap { id in
            sources.firstIndex { $0.primaryLanguage == id }
        } ?? -1
        // -1 (not found) -> 0; last index -> 0 (wrap).
        let nextIndex = (currentIndex + 1) % sources.count
        applyInputLanguageSwitch(toPrimaryLanguage: sources[nextIndex].primaryLanguage)
    }

    /// The currently-effective input source identifier, in the same namespace as
    /// `InputSourceCatalog.available()` (UITextInputMode primaryLanguage on
    /// iPad/visionOS, raw TIS source ID on Mac Catalyst).
    private func currentInputSourceIdentifier() -> String? {
        #if targetEnvironment(macCatalyst)
        return InputSourceCatalog.currentSourceID()
        #else
        // textInputMode reflects our preferredInputLanguage override when set,
        // else the system's active mode — both are the correct "current" to
        // advance from.
        return textInputMode?.primaryLanguage
        #endif
    }

    /// Drop the preferred-language override so a subsequent system input-source
    /// cycle (e.g. user-pressed Ctrl+Space) is not snapped back by our override.
    /// Called from the existing Ctrl+Space pass-through paths in pressesBegan
    /// / processKeyPress so the system HUD behaves normally.
    func yieldInputLanguageOverrideForSystemCycle() {
        preferredInputLanguage = nil
    }

    private func ensureSwapParkingField() -> UITextField {
        if let existing = inputLanguageSwapParkingField {
            return existing
        }
        // Parked off-screen at 1x1 rather than hidden: UIKit refuses first
        // responder to a hidden (or fully transparent) view, so `isHidden = true`
        // here made every park fail and the input-source swap a no-op. The
        // off-screen frame is what keeps the field invisible — do not "clean up"
        // by hiding it or setting alpha to 0.
        let field = UITextField(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
        field.backgroundColor = .clear
        // No caret blink from the parked field during the swap.
        field.tintColor = .clear
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        // Adding to self keeps the field in the responder chain even if our
        // superview changes (split panes, tab swaps).
        addSubview(field)
        inputLanguageSwapParkingField = field
        return field
    }
}
