import Foundation
import WatchKit
import UserNotifications
import ShellControlProtocol

/// Registers the notification categories early and turns a notification
/// response into a review intent. The Watch has no APNs registration of its
/// own: approval hints go to the iPhone and the system mirrors them here
/// (docs/specs/control-protocol.md section 12.4).
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    var session: ControlSession?

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
        // The request the notification asked the user to look at. The inbox
        // opens review; it never approves from the payload.
        await MainActor.run { WatchNotificationRouter.shared.receive(intent) }
        // Opening a notification starts a live fetch through the iPhone; the
        // notification itself is never the ledger.
        await session?.refresh()
    }
}
