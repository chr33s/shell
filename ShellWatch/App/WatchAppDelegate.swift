import Foundation
import WatchKit
import UserNotifications
import ShellControlProtocol

/// Registers the notification categories early and turns a notification
/// response into a review intent. The Watch has no APNs registration of its
/// own: approval hints go to the iPhone and the system mirrors them here
/// (spec.iphone-gateway.md section 16.4).
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    var session: ControlSession?
    /// The request a notification asked the user to look at. The UI opens
    /// review; it never approves from the payload.
    @MainActor static var pendingIntent: ShellNotificationCategories.ReviewIntent?

    func applicationDidFinishLaunching() {
        ShellNotificationCategories.register()
        UNUserNotificationCenter.current().delegate = self
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
        // Opening a notification starts a live fetch through the iPhone; the
        // notification itself is never the ledger.
        await session?.refresh()
    }
}
