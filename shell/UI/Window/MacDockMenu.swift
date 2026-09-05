#if targetEnvironment(macCatalyst)
import UIKit
import os

/// The Dock tile menu: New Window, New Local Shell, and the most recently used
/// SSH profiles.
///
/// The Dock can be clicked while the app has no window at all, and every action
/// here except New Window is delivered as a notification that only a live
/// `MainView` observes. So when nothing is connected the action is parked and a
/// window is requested; `MainView.handleOnAppear` drains it once its observers
/// are registered. That is deterministic — no timer waiting for the window to
/// come up.
@MainActor
enum MacDockMenu {
    private static let logger = Logger(subsystem: "dev.chr33s.shell", category: "MacDockMenu")
    private static let maxRecentProfiles = 5
    private static var pendingAction: (() -> Void)?

    static func install() {
        guard let bridge = MacSupport.bridge else { return }
        if !bridge.installDockMenu({ MainActor.assumeIsolated { entries() } }) {
            logger.warning("Dock menu could not be installed")
        }
    }

    /// Run whatever a Dock menu click parked while no window was open. Called
    /// from `MainView.handleOnAppear`, after its notification observers exist.
    static func drainPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
    }

    private static func entries() -> [any MacMenuEntry] {
        var items: [any MacMenuEntry] = [
            CatalystMenuEntry(title: String(localized: "New Window")) {
                UIApplication.shared.requestSceneSessionActivation(
                    nil, userActivity: nil, options: nil, errorHandler: nil)
            },
            CatalystMenuEntry(title: String(localized: "New Local Shell")) {
                inFocusedWindow { UIApplication.shared.menuCreateLocalShell(nil) }
            }
        ]
        let recents = ConnectionProfileManager.shared.profiles
            .compactMap { profile in profile.lastUsedAt.map { (profile, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(maxRecentProfiles)
            .map(\.0)
        if !recents.isEmpty {
            items.append(CatalystMenuEntry(separator: true))
            for profile in recents {
                items.append(CatalystMenuEntry(title: profile.name) {
                    inFocusedWindow { UIApplication.shared.menuOpenRecentProfile(profile.id) }
                })
            }
        }
        return items
    }

    /// Perform `action` against a window, opening one first if none is connected.
    private static func inFocusedWindow(_ action: @escaping () -> Void) {
        guard CatalystSceneDelegate.preferredRegularScene() == nil else {
            action()
            return
        }
        pendingAction = action
        UIApplication.shared.requestSceneSessionActivation(
            nil, userActivity: nil, options: nil,
            errorHandler: { error in
                logger.error("Dock menu could not open a window: \(error.localizedDescription)")
                pendingAction = nil
            })
    }
}
#endif
