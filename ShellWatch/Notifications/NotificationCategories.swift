import Foundation
import UserNotifications
import ShellControlProtocol

/// The `SHELL_APPROVAL_V1` category, registered identically on Watch and
/// iPhone.
///
/// Review is first and `.foreground` because Apple invokes the first
/// nondestructive action for Double Tap, and foreground actions run on the
/// device where they were selected — so a forwarded notification launches the
/// native Watch review flow. A notification action never authorizes from its
/// embedded payload (spec.watch.md section 6).
public enum ShellNotificationCategories {
    public static func makeApprovalCategory() -> UNNotificationCategory {
        let review = UNNotificationAction(
            identifier: PushCategory.Action.review.rawValue,
            title: String(localized: "Review"),
            options: [.foreground]
        )
        let approve = UNNotificationAction(
            identifier: PushCategory.Action.approve.rawValue,
            title: String(localized: "Approve once"),
            // Foreground: the shortcut only selects an intent; the app still
            // fetches and reviews the request before submitting anything.
            options: [.foreground, .authenticationRequired]
        )
        let reject = UNNotificationAction(
            identifier: PushCategory.Action.reject.rawValue,
            title: String(localized: "Reject"),
            options: [.foreground]
        )
        // The static long-look fallback is the notification's own generic text,
        // which works without a network fetch (spec.watch.md section 18).
        return UNNotificationCategory(
            identifier: PushCategory.approval,
            actions: [review, approve, reject],
            intentIdentifiers: [],
            options: []
        )
    }

    public static func makeInformationalCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: PushCategory.informational,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
    }

    public static func register(on center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories([makeApprovalCategory(), makeInformationalCategory()])
    }

    /// What a tapped action asks the app to do. It is an intent, never an
    /// authorization.
    public enum ReviewIntent: Sendable, Equatable {
        case review(requestID: ControlID)
        case proposeApprove(requestID: ControlID)
        case proposeReject(requestID: ControlID)

        public var requestID: ControlID {
            switch self {
            case .review(let id), .proposeApprove(let id), .proposeReject(let id): return id
            }
        }
    }

    /// Reads only identifiers out of the payload; everything else is fetched
    /// and verified from the server.
    public static func intent(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> ReviewIntent? {
        guard let raw = userInfo["request_id"] as? String, let requestID = ControlID(raw) else { return nil }
        switch actionIdentifier {
        case PushCategory.Action.approve.rawValue: return .proposeApprove(requestID: requestID)
        case PushCategory.Action.reject.rawValue: return .proposeReject(requestID: requestID)
        default: return .review(requestID: requestID)
        }
    }
}
