//
//  KeyboardGeometryMonitor.swift
//  shell
//
//  Tracks the software keyboard's frame, docked state, and height so terminal
//  layout can avoid it. Extracted from the upstream effect manager: the shader
//  and background-effect machinery is not part of this fork, but the keyboard
//  geometry it happened to own drives terminal insets and the keyboard toolbar.
//

import Combine
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class KeyboardGeometryMonitor {
    static let shared = KeyboardGeometryMonitor()

    // With `@Observable`, SwiftUI tracks per-property reads inside view bodies,
    // so a write to `keyboardFrame` only invalidates views that actually read
    // `keyboardFrame` — not every view that holds a reference to this monitor.

    /// Current keyboard height, after docking and hardware-keyboard filtering.
    private(set) var keyboardHeight: CGFloat = 0

    /// The keyboard's last reported frame, in screen coordinates.
    private(set) var keyboardFrame: CGRect = .zero

    /// Whether the keyboard is docked at the bottom of the screen (iPad only).
    /// When false, the keyboard is floating/undocked and we skip avoidance.
    private(set) var isKeyboardDocked: Bool = false

    /// Increments on keyboard state changes to force SwiftUI re-render.
    private(set) var keyboardStateVersion: Int = 0 {
        didSet {
            // `@Observable` doesn't expose a Combine publisher per property,
            // so bridge to a PassthroughSubject for the Combine consumer in
            // `TerminalView` that wants debounced keyboard-state notifications.
            keyboardStateDidChange.send()
        }
    }

    /// Increments when a surface's cell size changes, so SwiftUI re-evaluates
    /// layout that depends on grid metrics (the terminal's top grid-alignment
    /// padding). Deliberately separate from `keyboardStateVersion`: that one
    /// also feeds `keyboardStateDidChange`, which reloads input views in every
    /// accessory controller — churn a pinch-zoom's stream of cell-size changes
    /// must not drive.
    private(set) var gridMetricsVersion: Int = 0

    /// Emits when `keyboardStateVersion` increments.
    @ObservationIgnored let keyboardStateDidChange = PassthroughSubject<Void, Never>()

    @ObservationIgnored private var hardwareKeyboardTask: Task<Void, Never>?
    @ObservationIgnored private var softwareKeyboardVisibilityTask: Task<Void, Never>?

    fileprivate static let softwareKeyboardHeightThreshold: CGFloat = 120
    private static let dockTolerance: CGFloat = 50

    private init() {
        #if !targetEnvironment(macCatalyst)
        setupKeyboardObserver()

        // Reset the tracked height when a hardware keyboard attaches/detaches.
        hardwareKeyboardTask = Task { @MainActor [weak self] in
            for await isHardware in KeyboardTracker.shared.hardwareKeyboardStateDidChangeStream() {
                guard let self else { continue }
                self.keyboardStateVersion += 1
                if isHardware {
                    if self.keyboardHeight != 0 { self.keyboardHeight = 0 }
                } else {
                    self.applyKeyboardFrame(KeyboardTracker.shared.keyboardFrame)
                }
            }
        }

        softwareKeyboardVisibilityTask = Task { @MainActor [weak self] in
            for await _ in KeyboardTracker.shared.softwareKeyboardVisibilityDidChangeStream() {
                guard let self else { continue }
                self.keyboardStateVersion += 1
            }
        }
        #endif
    }

    // MARK: - Change notifications

    func notifyKeyboardToolbarLayoutChanged() {
        keyboardStateVersion += 1
    }

    func notifyGridMetricsChanged() {
        gridMetricsVersion += 1
    }

    func clearPreservedKeyboardLayout() {
        var changed = false
        if keyboardHeight != 0 {
            keyboardHeight = 0
            changed = true
        }
        if keyboardFrame != .zero {
            keyboardFrame = .zero
            changed = true
        }
        if changed {
            keyboardStateVersion += 1
        }
    }

    // MARK: - Observation

    private func setupKeyboardObserver() {
        // Synchronous (matching TerminalView's observers) rather than hopping
        // through `Task { @MainActor }`: the hop drained a turn later, so the
        // preservation gate was read after every KeyboardTracker observer had
        // run. A frame enqueued with a hidden frame could drain just after the
        // latch released and zero the geometry driving terminalBottomPadding,
        // turning a latch drop into a second bounce.
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated {
                self?.handleKeyboardFrameChange(keyboardFrame)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            MainActor.assumeIsolated {
                self?.handleKeyboardFrameChange(keyboardFrame)
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !KeyboardTracker.shared.isPreservingSoftwareKeyboardLayout else { return }
                if self.keyboardHeight != 0 { self.keyboardHeight = 0 }
                if self.keyboardFrame != .zero { self.keyboardFrame = .zero }
            }
        }
    }

    private func handleKeyboardFrameChange(_ keyboardFrame: CGRect?) {
        guard let keyboardFrame else { return }
        if KeyboardTracker.shared.isPreservingSoftwareKeyboardLayout,
           !isMeaningfulKeyboardFrame(keyboardFrame) {
            return
        }
        applyKeyboardFrame(keyboardFrame)
    }

    private func applyKeyboardFrame(_ keyboardFrame: CGRect) {
        if self.keyboardFrame != keyboardFrame {
            self.keyboardFrame = keyboardFrame
        }

        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let newDockedState = isKeyboardFrameDocked(keyboardFrame)
        if newDockedState != isKeyboardDocked {
            isKeyboardDocked = newDockedState
            keyboardStateVersion += 1
        }
        #endif

        let newHeight = adjustedKeyboardHeight(for: keyboardFrame)
        if keyboardHeight != newHeight {
            keyboardHeight = newHeight
        }
    }

    // MARK: - Geometry

    private func isMeaningfulKeyboardFrame(_ keyboardFrame: CGRect) -> Bool {
        guard !keyboardFrame.isNull, !keyboardFrame.isEmpty else { return false }
        #if os(visionOS)
        return keyboardFrame.height > Self.softwareKeyboardHeightThreshold
        #else
        // `UIScreen.main` is deprecated; `activeWindowFrame` already resolves
        // this app's own window/screen. With nothing connected, measuring the
        // keyboard against itself matches the visionOS branch above.
        let screenBounds = activeWindowFrame() ?? keyboardFrame
        let intersection = screenBounds.intersection(keyboardFrame)
        if intersection.isNull || intersection.isEmpty {
            return false
        }
        return intersection.height > Self.softwareKeyboardHeightThreshold
        #endif
    }

    private func isKeyboardFrameDocked(_ keyboardFrame: CGRect) -> Bool {
        // No window and no screen means nothing for the keyboard to be docked
        // against. (`UIScreen.main` used to stand in here; it is deprecated and
        // on a multi-display setup is not necessarily this window's screen.)
        guard let windowFrame = activeWindowFrame() else { return false }
        let screenHeight = windowFrame.height

        let keyboardBottom = keyboardFrame.origin.y + keyboardFrame.height

        // Keyboard is docked if its bottom edge is at or near the screen bottom
        // and it has meaningful height (not just the suggestion bar)
        let touchesBottom = abs(keyboardBottom - screenHeight) < Self.dockTolerance
        let hasMeaningfulHeight = keyboardFrame.height > 100
        // A docked keyboard spans the window. Narrow bottom HUDs — the
        // minimized-keyboard pill a pencil tap summons, the floating
        // mini keyboard — must never register as docked coverage.
        let spansWindowWidth = keyboardFrame.width >= windowFrame.width - Self.dockTolerance

        return touchesBottom && hasMeaningfulHeight && spansWindowWidth
    }

    private func adjustedKeyboardHeight(for keyboardFrame: CGRect) -> CGFloat {
        // On iPad, skip keyboard height if keyboard is undocked/floating
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if !isKeyboardDocked {
            return 0
        }
        #endif

        let height = keyboardIntersectionHeight(for: keyboardFrame)
        guard height > 0 else { return 0 }

        if KeyboardTracker.shared.isHardwareKeyboard && height < Self.softwareKeyboardHeightThreshold {
            // Ignore accessory-only frames while hardware keyboard is attached.
            return 0
        }

        return height
    }

    private func keyboardIntersectionHeight(for keyboardFrame: CGRect) -> CGFloat {
        // visionOS has no UIScreen - use the keyboard frame directly
        #if os(visionOS)
        let screenBounds = keyboardFrame
        #else
        let screenBounds = activeWindowFrame() ?? keyboardFrame
        #endif

        let keyboardIntersection = screenBounds.intersection(keyboardFrame)
        if keyboardIntersection.isNull || keyboardIntersection.isEmpty {
            return 0
        }
        return keyboardIntersection.height
    }

    private func activeWindowFrame() -> CGRect? {
        #if os(visionOS)
        return nil
        #else
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let foregroundScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let windowScene = foregroundScene else {
            return nil
        }

        if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
            return keyWindow.frame
        }

        if let window = windowScene.windows.first {
            return window.frame
        }

        // A connected scene with no window yet still names the screen it is on.
        // This is the contextual replacement for the deprecated `UIScreen.main`.
        return windowScene.screen.bounds
        #endif
    }
}

extension KeyboardGeometryMonitor {
    /// How much of `viewFrame` the keyboard currently covers.
    func keyboardOverlapHeight(in viewFrame: CGRect) -> CGFloat {
        keyboardOverlapHeight(in: viewFrame, keyboardFrame: keyboardFrame)
    }

    func keyboardOverlapHeight(in viewFrame: CGRect, keyboardFrame: CGRect) -> CGFloat {
        if keyboardFrame.isNull || keyboardFrame.isEmpty {
            return 0
        }

        // On iPad, skip keyboard avoidance if keyboard is undocked/floating
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        if !isKeyboardDocked {
            return 0
        }
        #endif

        let intersection = viewFrame.intersection(keyboardFrame)
        if intersection.isNull || intersection.isEmpty {
            return 0
        }

        let height = intersection.height
        if KeyboardTracker.shared.isHardwareKeyboard && height < Self.softwareKeyboardHeightThreshold {
            return 0
        }

        return height
    }
}
