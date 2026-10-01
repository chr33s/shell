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

/// Settings window state: the sidebar selection and the detail stack. Lives on
/// the scene delegate so a deep link into an already open window re-targets it
/// instead of rebuilding the hosting controller.
@Observable
final class MacSettingsModel {
    private(set) var selection: SettingsSection? = .terminal
    var path = NavigationPath()

    /// A sidebar pick starts the section at its root.
    func select(_ section: SettingsSection?) {
        guard section != selection else { return }
        selection = section
        path = NavigationPath()
    }

    func open(_ destination: SettingsDestination) {
        selection = destination.section
        path = NavigationPath([destination])
    }
}

/// Settings as a Mac window: a sidebar of sections beside the selected one,
/// rather than the sheet's single drill-down column. No Done button; the
/// window closes like any other. Theming is deliberately not applied, so the
/// sidebar and lists keep the system materials and follow the system
/// appearance instead of the terminal theme.
///
/// The columns are hosted in a UIKit split view rather than SwiftUI's
/// `NavigationSplitView`: on macOS the sidebar only gets Liquid Glass behind
/// it when the split view controller's `primaryBackgroundStyle` is `.sidebar`
/// (Apple, "Optimizing your iPad app for Mac"), and SwiftUI exposes no
/// equivalent on Catalyst, so its sidebar rendered as an opaque grey column.
final class MacSettingsSplitViewController: UISplitViewController {
    init(model: MacSettingsModel) {
        super.init(style: .doubleColumn)
        primaryBackgroundStyle = .sidebar
        preferredDisplayMode = .oneBesideSecondary
        presentsWithGesture = false
        minimumPrimaryColumnWidth = 170
        preferredPrimaryColumnWidth = 190
        maximumPrimaryColumnWidth = 260

        // The hosting view defaults to an opaque system background, which
        // would sit between the glass and the list and hide the effect.
        let sidebar = UIHostingController(rootView: MacSettingsSidebar(model: model))
        sidebar.view.backgroundColor = .clear
        setViewController(sidebar, for: .primary)
        setViewController(UIHostingController(rootView: MacSettingsDetail(model: model)), for: .secondary)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// The section list. Sidebar style with the scroll background hidden so the
/// split view's glass shows through; the list itself paints nothing.
struct MacSettingsSidebar: View {
    @Bindable var model: MacSettingsModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            ForEach(SettingsSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

/// The selected section's navigation stack.
struct MacSettingsDetail: View {
    @Bindable var model: MacSettingsModel

    var body: some View {
        NavigationStack(path: $model.path) {
            if let section = model.selection {
                section.content
                    .id(section)
                    .navigationDestination(for: SettingsDestination.self) { $0.content }
            }
        }
    }
}

final class MacSettingsSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private let model = MacSettingsModel()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        MacSettingsWindow.didConnect()
        scene.title = "Settings"
        scene.sizeRestrictions?.minimumSize = CGSize(width: 640, height: 450)
        scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 160, y: 160, width: 760, height: 560)))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = MacSettingsSplitViewController(model: model)
        self.window = window
        present(activity: options.userActivities.first)
        window.makeKeyAndVisible()
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) { present(activity: userActivity) }

    private func present(activity: NSUserActivity?) {
        guard let destination = (activity?.userInfo?["destination"] as? String)
            .flatMap(SettingsDestination.init(rawValue:)) else { return }
        model.open(destination)
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
