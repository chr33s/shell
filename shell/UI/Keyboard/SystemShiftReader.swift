//
//  SystemShiftReader.swift
//  shell
//
//  Reads the system keyboard's live Shift state so on-screen toolbar keys
//  (Tab, arrows, symbols) can honor it, matching what the user sees latched
//  on the software keyboard or held on a hardware keyboard.
//
//  Layered strategies, all public API:
//  1. Hardware: GCKeyboard live left/right Shift state.
//  2. Touch event modifier flags noted at button touch-down (also carries
//     hardware caps lock via .alphaShift).
//  3. Software keyboard: the stock keyboard is hosted in-process (in
//     UIRemoteKeyboardWindow, found via the toolbar's own window or window
//     visibility tracking). The active keyplane view's description embeds
//     the keyplane name, which encodes the case state ("..._Capital-Letters"
//     while shift or caps lock is active). The view is found once per
//     keyboard appearance and cached; a read is one description string.
//
//  Any strategy that can't produce a signal returns .unknown and behavior
//  degrades to the toolbar's own sticky modifiers only.
//

import UIKit
import GameController
import os

@MainActor
final class SystemShiftReader {
    static let shared = SystemShiftReader()

    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SystemShift")

    enum Reading {
        case shifted
        case notShifted
        case unknown
    }

    // MARK: - Touch event flags (strategy 2)

    /// Modifier flags of the most recent toolbar button touch. Every toolbar
    /// dispatch path notes its touch before firing, so this is always fresh
    /// for the press being evaluated. TTL is hygiene against leaks into
    /// unrelated later presses.
    private var lastTouchModifierFlags: UIKeyModifierFlags = []
    private var lastTouchNoteTime: CFAbsoluteTime = 0
    private static let touchFlagsTTL: CFAbsoluteTime = 10

    // MARK: - Keyplane cache (strategy 3)

    /// The system keyboard's keyplane view (TUIKeyplaneView). Its
    /// description embeds the active keyplane name, which encodes the
    /// case state. Weak: never keeps a dismissed keyboard alive.
    private weak var cachedKeyplaneView: UIView?
    private var needsDiagnosticDump = true

    /// Keyboard-hosting windows (UIRemoteKeyboardWindow etc.) are not
    /// returned by UIWindowScene.windows, so track them as they appear.
    /// Weak so we never keep a dismissed keyboard window alive.
    private let trackedKeyboardWindows = NSHashTable<UIWindow>.weakObjects()

    private init() {
        // The keyplane view can be recreated when the keyboard reloads
        // (show/hide, layout or input-mode changes).
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(invalidateCache),
            name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(invalidateCache),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(keyboardDidShow),
            name: UIResponder.keyboardDidShowNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeVisible(_:)),
            name: UIWindow.didBecomeVisibleNotification,
            object: nil
        )
    }

    /// Call once at launch so the window-visibility observer is registered
    /// before the first keyboard appearance.
    func activate() {}

    @objc private func invalidateCache() {
        cachedKeyplaneView = nil
    }

    @objc private func keyboardDidShow() {
        cachedKeyplaneView = nil
        needsDiagnosticDump = true
    }

    @objc private func windowDidBecomeVisible(_ notification: Notification) {
        guard let window = notification.object as? UIWindow else { return }
        if Self.isKeyboardWindowClassName(NSStringFromClass(type(of: window))) {
            trackedKeyboardWindows.add(window)
            cachedKeyplaneView = nil
        }
    }

    private static func isKeyboardWindowClassName(_ name: String) -> Bool {
        name.contains("Keyboard") || name.contains("TextEffects") || name.contains("InputSet")
    }

    // MARK: - Public API

    /// Record the UIEvent of a toolbar button touch-down. Called from every
    /// toolbar touch entry point so flags are fresh at dispatch time.
    func noteTouchEvent(_ event: UIEvent?) {
        guard let event else { return }
        noteModifierFlags(event.modifierFlags)
    }

    /// Gesture-recognizer variant (arrow cluster / joystick paths).
    func noteModifierFlags(_ flags: UIKeyModifierFlags) {
        lastTouchModifierFlags = flags
        lastTouchNoteTime = CFAbsoluteTimeGetCurrent()
    }

    /// The system keyboard's Shift state right now. Caps lock counts as
    /// shifted. `.unknown` means no signal was available — callers should
    /// change nothing. `hint` is a view near the keyboard (the toolbar):
    /// when the toolbar is the keyboard accessory its window IS the
    /// keyboard-hosting window, giving us a direct handle.
    func currentShift(near hint: UIView? = nil) -> Reading {
        // 1. Hardware keyboard: live GCKeyboard state.
        let hardwareShift = hardwareShiftPressed()

        // 2. Touch event flags (covers hardware caps lock, and the software
        //    latch if UIKit folds it into touch events).
        let flags = freshTouchFlags()

        // 3. Software keyboard: accessibility readout of the shift key.
        let softwareVisible = KeyboardTracker.shared.isSoftwareKeyboardVisible
        let softwareReading: Reading = softwareVisible ? softwareShiftReading(hint: hint) : .unknown

        let result: Reading
        if hardwareShift == true {
            result = .shifted
        } else if flags.contains(.shift) || flags.contains(.alphaShift) {
            result = .shifted
        } else {
            result = softwareReading
        }

        let hardwareText = hardwareShift.map(String.init) ?? "n/a"
        let flagsRaw = flags.rawValue
        let softwareText = String(describing: softwareReading)
        let resultText = String(describing: result)
        Self.logger.debug("SystemShift: hw=\(hardwareText, privacy: .public) touchFlags=\(flagsRaw) swVisible=\(softwareVisible) sw=\(softwareText, privacy: .public) → \(resultText, privacy: .public)")

        return result
    }

    // MARK: - Strategy 1: GCKeyboard

    private func hardwareShiftPressed() -> Bool? {
        #if os(visionOS)
        return nil
        #else
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return nil }
        let left = input.button(forKeyCode: .leftShift)?.isPressed ?? false
        let right = input.button(forKeyCode: .rightShift)?.isPressed ?? false
        return left || right
        #endif
    }

    // MARK: - Strategy 2: touch flags

    private func freshTouchFlags() -> UIKeyModifierFlags {
        guard CFAbsoluteTimeGetCurrent() - lastTouchNoteTime < Self.touchFlagsTTL else { return [] }
        return lastTouchModifierFlags
    }

    // MARK: - Strategy 3: keyplane readout

    private func softwareShiftReading(hint: UIView?) -> Reading {
        #if os(visionOS)
        // visionOS system keyboard is out of process — nothing to read.
        return .unknown
        #else
        if let cached = cachedKeyplaneView, cached.window != nil {
            return shiftState(fromKeyplane: cached)
        }
        cachedKeyplaneView = nil

        let windows = candidateKeyboardWindows(hint: hint)
        dumpDiagnosticsIfNeeded(windows: windows)

        for window in windows {
            if let keyplane = findKeyplaneView(in: window, depth: 0) {
                cachedKeyplaneView = keyplane
                return shiftState(fromKeyplane: keyplane)
            }
        }
        return .unknown
        #endif
    }

    /// The keyplane view's description embeds the active keyplane name,
    /// which encodes the case state — observed on-device:
    /// `name = Dynamic-QWERTY-British-Small_Capital-Letters` while shift or
    /// caps lock is active, `..._Small-Letters` otherwise, and each key
    /// describes itself as `Latin-Capital-Letter-Q` / `Latin-Small-Letter-q`.
    /// Reading a description is public NSObject API and fails safe: an
    /// unexpected format (symbols keyplane, caseless scripts) reads as not
    /// shifted, which leaves the key press unmodified.
    private func shiftState(fromKeyplane view: UIView) -> Reading {
        let description = String(describing: view)
        // Isolate the first "name = ...;" segment (the active keyplane) so
        // references to other keyplanes deeper in the description can't
        // false-positive. If the segment is absent the format assumption is
        // broken — report no signal rather than guess from the full string.
        guard let nameRange = description.range(of: "name = "),
              let end = description[nameRange.upperBound...].firstIndex(of: ";") else {
            return .unknown
        }
        let name = description[nameRange.upperBound..<end]
        return name.contains("Capital-Letter") ? .shifted : .notShifted
    }

    private func findKeyplaneView(in view: UIView, depth: Int) -> UIView? {
        guard depth <= 24 else { return nil }
        if NSStringFromClass(type(of: view)).contains("KeyplaneView") { return view }
        for subview in view.subviews {
            if let found = findKeyplaneView(in: subview, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Keyboard-hosting window candidates, most promising first. The
    /// keyboard's own window (UIRemoteKeyboardWindow) is not part of
    /// UIWindowScene.windows, so it comes from the toolbar hint (the
    /// accessory view lives inside it) or from visibility tracking.
    private func candidateKeyboardWindows(hint: UIView?) -> [UIWindow] {
        var result: [UIWindow] = []
        var seen = Set<ObjectIdentifier>()

        func add(_ window: UIWindow?) {
            guard let window, seen.insert(ObjectIdentifier(window)).inserted else { return }
            result.append(window)
        }

        if let hintWindow = hint?.window,
           Self.isKeyboardWindowClassName(NSStringFromClass(type(of: hintWindow))) {
            add(hintWindow)
        }
        for window in trackedKeyboardWindows.allObjects where window.isHidden == false {
            add(window)
        }
        let sceneWindows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        for window in sceneWindows
        where Self.isKeyboardWindowClassName(NSStringFromClass(type(of: window))) {
            add(window)
        }
        return result
    }

    // MARK: - Diagnostics (local debug builds only)

    /// One-time dump per keyboard appearance: keyboard window hierarchy with
    /// descriptions and shift-state probes. Compiled out of Release. Kept for
    /// re-diagnosis if a future iOS changes the keyplane description format —
    /// the shipping detector only depends on `shiftState(fromKeyplane:)`.
    private func dumpDiagnosticsIfNeeded(windows: [UIWindow]) {
        #if DEBUG
        guard needsDiagnosticDump else { return }
        needsDiagnosticDump = false

        let candidateClasses = windows.map { NSStringFromClass(type(of: $0)) }.joined(separator: ", ")
        let trackedCount = trackedKeyboardWindows.allObjects.count
        Self.logger.notice("SystemShift dump: candidates = [\(candidateClasses, privacy: .public)] tracked=\(trackedCount)")

        var lineBudget = 250
        for window in windows {
            let windowClass = NSStringFromClass(type(of: window))
            Self.logger.notice("SystemShift dump: --- window \(windowClass, privacy: .public) ---")
            dumpNode(window, depth: 0, lineBudget: &lineBudget)
        }
        Self.logger.notice("SystemShift dump: done (budget left \(lineBudget))")
        #endif
    }

    #if DEBUG
    private func dumpNode(_ node: NSObject, depth: Int, lineBudget: inout Int) {
        guard depth <= 24, lineBudget > 0 else { return }

        let label = node.accessibilityLabel
        let value = node.accessibilityValue
        let identifier = (node as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? nil
        let className = NSStringFromClass(type(of: node))
        // Log nodes carrying accessibility metadata, plus keyboard-ish view
        // classes so the hierarchy shape is visible even without metadata.
        let isInterestingClass = className.contains("Key") || className.contains("KB")
        if label != nil || value != nil || identifier != nil || isInterestingClass {
            lineBudget -= 1
            let traits = node.accessibilityTraits.rawValue
            let labelText = label ?? "-"
            let valueText = value ?? "-"
            let identifierText = identifier ?? "-"
            let indent = String(repeating: "  ", count: depth)
            Self.logger.notice("SystemShift dump: \(indent, privacy: .public)\(className, privacy: .public) label=\(labelText, privacy: .public) value=\(valueText, privacy: .public) id=\(identifierText, privacy: .public) traits=\(traits)")

            // Key views and keyboard controllers often carry key name/state
            // in their description override — public API, worth reading.
            let describesState = className.contains("KBKey") || className.contains("Keyplane")
                || className.hasPrefix("UIKeyboard") || className.hasPrefix("TUIKeyboard")
            if describesState {
                lineBudget -= 1
                let description = String(String(describing: node).prefix(240))
                Self.logger.notice("SystemShift dump: \(indent, privacy: .public)  desc: \(description, privacy: .public)")
            }

            // Ground-truth probe: read shift getters if they exist. The
            // responds(to:) check guarantees value(forKey:) cannot throw.
            if className == "UIKeyboardImpl" || className == "UIKeyboardLayoutStar" {
                for key in ["isShifted", "isShiftLocked", "shift", "shiftLockedByUser"] {
                    guard node.responds(to: NSSelectorFromString(key)) else { continue }
                    let probed = node.value(forKey: key)
                    let probedText = probed.map { String(describing: $0) } ?? "nil"
                    lineBudget -= 1
                    Self.logger.notice("SystemShift dump: \(indent, privacy: .public)  probe \(className, privacy: .public).\(key, privacy: .public) = \(probedText, privacy: .public)")
                }
            }
        }

        if let elements = node.accessibilityElements {
            for child in elements {
                guard let childObject = child as? NSObject else { continue }
                dumpNode(childObject, depth: depth + 1, lineBudget: &lineBudget)
            }
        } else {
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound, count < 200 {
                for index in 0..<count {
                    guard let childObject = node.accessibilityElement(at: index) as? NSObject else { continue }
                    dumpNode(childObject, depth: depth + 1, lineBudget: &lineBudget)
                }
            }
        }

        if let view = node as? UIView {
            for subview in view.subviews {
                dumpNode(subview, depth: depth + 1, lineBudget: &lineBudget)
            }
        }
    }
    #endif
}
