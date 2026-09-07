import Foundation
import WatchKit
import UserNotifications
import ShellControlProtocol

/// Registers the notification categories early, owns the Watch's own APNs
/// registration, and turns a notification response into a review intent
/// (spec.watch.md sections 6 and 14).
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    var session: ControlSession?
    /// The request a notification asked the user to look at. The UI opens
    /// review; it never approves from the payload.
    @MainActor static var pendingIntent: ShellNotificationCategories.ReviewIntent?

    func applicationDidFinishLaunching() {
        ShellNotificationCategories.register()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in WKApplication.shared().registerForRemoteNotifications() }
        }
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        Task { [session] in
            await session?.registerPushToken(
                deviceToken,
                topic: ShellWatchConfiguration.apnsTopic,
                environment: ShellWatchConfiguration.apnsEnvironment
            )
        }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: any Error) {
        // Push is a hint; the inbox still reconciles from the change stream.
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let intent = ShellNotificationCategories.intent(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        await MainActor.run { WatchAppDelegate.pendingIntent = intent }
        // Reconcile the inbox after opening any notification: the push is not
        // the ledger (spec.watch.md section 14).
        await session?.refresh()
    }
}
