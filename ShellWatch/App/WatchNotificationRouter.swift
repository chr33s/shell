import Foundation
import Observation

/// Carries a tapped notification's review intent to the inbox.
///
/// Observable, so the inbox navigates whether the tap arrives while it is on
/// screen or before it exists (a cold launch from the notification): the
/// intent waits here until the inbox takes it. It only ever opens review;
/// it never decides.
@MainActor
@Observable
final class WatchNotificationRouter {
    static let shared = WatchNotificationRouter()

    private(set) var pendingIntent: ShellNotificationCategories.ReviewIntent?

    func receive(_ intent: ShellNotificationCategories.ReviewIntent?) {
        guard let intent else { return }
        pendingIntent = intent
    }

    /// Takes the pending intent, so it opens review once.
    func consume() -> ShellNotificationCategories.ReviewIntent? {
        defer { pendingIntent = nil }
        return pendingIntent
    }
}
