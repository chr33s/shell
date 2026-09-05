#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

@MainActor
enum MacSettingsWindow {
    // nonisolated: the scene-configuration and scene-classification paths that
    // read these are not main-actor isolated.
    nonisolated static let activityType = "dev.chr33s.shell.settings"
    nonisolated static let configurationName = "Shell Settings"
    private static var opening = false

    static func show(destination: SettingsDestination? = nil) {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = "Settings"
        if let destination { activity.userInfo = ["destination": destination.rawValue] }
        let session = UIApplication.shared.connectedScenes.first {
            $0.session.configuration.name == configurationName
        }?.session
        guard session != nil || !opening else { return }
        opening = session == nil
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: activity, options: nil) { _ in
            opening = false
        }
    }

    static func didConnect() { opening = false }
}

final class MacSettingsSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private var currentDestination: SettingsDestination?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        MacSettingsWindow.didConnect()
        scene.title = "Settings"
        scene.sizeRestrictions?.minimumSize = CGSize(width: 500, height: 450)
        scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 160, y: 160, width: 650, height: 650)))
        let window = UIWindow(windowScene: scene)
        self.window = window
        present(activity: options.userActivities.first)
        window.makeKeyAndVisible()
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) { present(activity: userActivity) }

    private func present(activity: NSUserActivity?) {
        let destination = (activity?.userInfo?["destination"] as? String).flatMap(SettingsDestination.init(rawValue:))
        if window?.rootViewController != nil, destination == nil { return }
        currentDestination = destination
        let view = SettingsView(initialDestination: destination, onClose: { [weak self] in
            guard let session = self?.window?.windowScene?.session else { return }
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        })
        window?.rootViewController = UIHostingController(rootView: view)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        WindowFocusRegistry.shared.update(sceneSessionId: scene.session.persistentIdentifier, isKey: true)
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        WindowFocusRegistry.shared.remove(sceneSessionId: scene.session.persistentIdentifier)
        window = nil
    }
}
#endif
