import UserNotifications
import XCTest
import ShellControlProtocol
import ShellControlClient

@testable import ShellWatch

/// Notification handling on the Watch (spec.watch.md section 6).
final class NotificationRoutingTests: XCTestCase {
    func testReviewIsFirstAndEveryActionIsForeground() throws {
        let category = ShellNotificationCategories.makeApprovalCategory()
        XCTAssertEqual(category.identifier, PushCategory.approval)
        // Apple invokes the first nondestructive action for Double Tap, so
        // Review must be first — and it must open the app rather than run a
        // background action on the phone.
        let first = try XCTUnwrap(category.actions.first)
        XCTAssertEqual(first.identifier, PushCategory.Action.review.rawValue)
        for action in category.actions {
            XCTAssertTrue(action.options.contains(.foreground), "\(action.identifier) must be foreground")
            XCTAssertFalse(action.options.contains(.destructive), "\(action.identifier) must not be destructive")
        }
    }

    func testAnActionOnlySelectsAnIntent() throws {
        let requestID = try XCTUnwrap(ControlID("10000000-0000-4000-8000-000000000001"))
        let payload: [AnyHashable: Any] = ["request_id": requestID.rawValue, "event_id": "ignored"]
        XCTAssertEqual(
            ShellNotificationCategories.intent(actionIdentifier: PushCategory.Action.review.rawValue, userInfo: payload),
            .review(requestID: requestID)
        )
        // The approve shortcut is a proposal; the app still fetches and reviews.
        XCTAssertEqual(
            ShellNotificationCategories.intent(actionIdentifier: PushCategory.Action.approve.rawValue, userInfo: payload),
            .proposeApprove(requestID: requestID)
        )
        XCTAssertEqual(
            ShellNotificationCategories.intent(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: payload),
            .review(requestID: requestID)
        )
    }

    func testAPayloadWithoutAUsableRequestIDProducesNoIntent() {
        XCTAssertNil(ShellNotificationCategories.intent(
            actionIdentifier: PushCategory.Action.approve.rawValue,
            userInfo: [:]
        ))
        // A terminal surface pointer is not an authorization identifier.
        XCTAssertNil(ShellNotificationCategories.intent(
            actionIdentifier: PushCategory.Action.review.rawValue,
            userInfo: ["request_id": "surface-0x600001234"]
        ))
    }

    /// A tapped notification's intent waits in an observable router until
    /// the inbox takes it — on a cold launch the inbox does not exist yet —
    /// and opens review exactly once.
    @MainActor
    func testTheRouterHoldsAnIntentUntilTheInboxTakesItOnce() throws {
        let requestID = try XCTUnwrap(ControlID("10000000-0000-4000-8000-000000000001"))
        let router = WatchNotificationRouter()
        router.receive(nil)
        XCTAssertNil(router.pendingIntent, "a payload without a request id selects nothing")
        router.receive(.proposeApprove(requestID: requestID))
        XCTAssertEqual(router.pendingIntent, .proposeApprove(requestID: requestID))
        XCTAssertEqual(router.consume(), .proposeApprove(requestID: requestID))
        XCTAssertNil(router.consume())
    }

    /// Only a command whose fate is genuinely unknown is labelled so; one the
    /// broker recorded shows as recorded while it awaits reconciliation.
    func testActivityLabelsFollowTheJournalState() {
        XCTAssertTrue(PendingCommandLabel.isAmbiguous(.outcomeUnknown))
        XCTAssertTrue(PendingCommandLabel.isAmbiguous(.sending))
        XCTAssertFalse(PendingCommandLabel.isAmbiguous(.decisionRecorded))
        XCTAssertNotEqual(PendingCommandLabel.text(.decisionRecorded), PendingCommandLabel.text(.outcomeUnknown))
    }

    /// The Watch has no route of its own: no broker URL is baked into it and
    /// none can be configured (spec.iphone-gateway.md section 4.6).
    func testTheWatchBundleCarriesNoBrokerAddress() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SHELLControlBrokerURL"))
    }
}
