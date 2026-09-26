import UIKit

/// Owns the window/scene observations and the explicit active-window signal
/// used by a terminal. The terminal remains responsible for first responder.
@MainActor
final class TerminalWindowFocus {
    enum Event { case windowChanged, sceneActivated, sceneDeactivating }

    private weak var observedWindow: UIWindow?
    private var observers: [NSObjectProtocol] = []
    private var activeOverride: Bool?

    func setActive(_ active: Bool) -> Bool {
        // A cold-start false signal must not block UIKit focus recovery.
        guard active || activeOverride != nil else { return false }
        activeOverride = active
        return true
    }

    func isActive(for view: UIView) -> Bool {
        #if !targetEnvironment(macCatalyst)
        if let scene = view.window?.windowScene, scene.activationState != .foregroundActive {
            return false
        }
        #endif
        return activeOverride ?? genuineSignal(for: view)
    }

    /// Ground-truth "this window is the active/usable one" from live UIKit
    /// state, bypassing the override. Used as the override-nil fallback and by
    /// `reassertVisibleIfNeeded` to heal an override stuck `false`. Because it
    /// can heal a correct `false` and drive `focusDidChange(true)`, trusting
    /// `isKeyWindow` on iPadOS/visionOS would let an inactive window steal first
    /// responder; only Catalyst, where it is reliable, uses it.
    func genuineSignal(for view: UIView) -> Bool {
        guard let window = view.window else { return false }
        if let scene = window.windowScene, scene.activationState != .foregroundActive {
            return false
        }
        #if targetEnvironment(macCatalyst)
        return window.isKeyWindow
        #else
        // isKeyWindow can be true for several foreground iPad/vision windows.
        return view.traitCollection.activeAppearance == .active
        #endif
    }

    func observe(_ window: UIWindow, onChange: @escaping @MainActor (Event) -> Void) {
        guard observedWindow !== window else { return }
        stop()
        observedWindow = window
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { onChange(.windowChanged) }
        })
        observers.append(center.addObserver(forName: UIWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { onChange(.windowChanged) }
        })
        if let scene = window.windowScene {
            observers.append(center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { _ in
                MainActor.assumeIsolated { onChange(.sceneActivated) }
            })
            observers.append(center.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { _ in
                MainActor.assumeIsolated { onChange(.sceneDeactivating) }
            })
        }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        observedWindow = nil
    }
}
