//
//  ControlNotifications.swift
//  shell
//
//  Notification categories for the optional control companion.
//
//  The iPhone registers the same `SHELL_APPROVAL_V1` category as the Watch, and
//  Review is first and foreground so a notification opened here launches a
//  native review flow rather than authorizing anything from its payload
//  (spec.watch.md section 6).
//

import Foundation
import UserNotifications
import ShellControlProtocol

enum ControlNotifications {
    /// Registered early in `application(_:didFinishLaunchingWithOptions:)`, so
    /// a notification that arrives before any scene exists still has its
    /// actions available.
    static func registerCategories(on center: UNUserNotificationCenter = .current()) {
        let review = UNNotificationAction(
            identifier: PushCategory.Action.review.rawValue,
            title: String(localized: "Review"),
            options: [.foreground]
        )
        let approve = UNNotificationAction(
            identifier: PushCategory.Action.approve.rawValue,
            title: String(localized: "Approve once"),
            // Foreground and authentication-gated: the shortcut selects an
            // intent, and the app still fetches and reviews before submitting.
            options: [.foreground, .authenticationRequired]
        )
        let reject = UNNotificationAction(
            identifier: PushCategory.Action.reject.rawValue,
            title: String(localized: "Reject"),
            options: [.foreground]
        )
        let approval = UNNotificationCategory(
            identifier: PushCategory.approval,
            actions: [review, approve, reject],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: String(localized: "A command needs your review."),
            options: []
        )
        let informational = UNNotificationCategory(
            identifier: PushCategory.informational,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([approval, informational])
    }

    /// What the user asked to look at. Only identifiers are read from the
    /// payload; everything shown is fetched and verified from the service.
    enum ReviewIntent: Equatable {
        case review(requestID: ControlID)
        case proposeApprove(requestID: ControlID)
        case proposeReject(requestID: ControlID)

        var requestID: ControlID {
            switch self {
            case .review(let id), .proposeApprove(let id), .proposeReject(let id): return id
            }
        }
    }

    static func intent(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> ReviewIntent? {
        guard let raw = userInfo["request_id"] as? String, let requestID = ControlID(raw) else { return nil }
        switch actionIdentifier {
        case PushCategory.Action.approve.rawValue: return .proposeApprove(requestID: requestID)
        case PushCategory.Action.reject.rawValue: return .proposeReject(requestID: requestID)
        default: return .review(requestID: requestID)
        }
    }

    /// The request a notification response asked to open. A scene reads and
    /// clears it; it is never treated as a decision.
    @MainActor static var pendingIntent: ReviewIntent?

    /// A terminal-sourced informational alert.
    ///
    /// OSC 9 / OSC 777 text is program output: it is shown locally and never
    /// becomes a signed host claim or a permission request
    /// (spec.watch.md sections 2 and 14).
    static func postLocalTerminalAlert(title: String?, body: String?) {
        let content = UNMutableNotificationContent()
        content.title = DisplaySanitizer.sanitize(title ?? String(localized: "Terminal"), maxScalars: 120).text
        content.body = DisplaySanitizer.sanitize(body ?? "", maxScalars: 300).text
        content.categoryIdentifier = PushCategory.informational
        // Deliberately carries no request identity: nothing here can open a
        // review, let alone authorize one.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
