import UserNotifications
import XCTest
import ShellControlProtocol

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

    func testConfigurationTreatsThePlaceholderBrokerAsUnconfigured() {
        // The shipped placeholder must read as "not set up" rather than being
        // dialled during enrollment.
        XCTAssertEqual(ShellWatchConfiguration.unconfiguredHost, "control.invalid")
    }

    /// A Debug build must carry a usable broker address, or every developer
    /// running from Xcode lands on "no control service configured" — which is
    /// exactly what happened before the Debug configuration set one.
    func testDebugBuildsCarryAUsableBrokerAddress() throws {
        #if DEBUG
        let url = try XCTUnwrap(
            ShellWatchConfiguration.brokerURL,
            "the Debug configuration must set SHELL_CONTROL_BROKER_URL"
        )
        XCTAssertNotEqual(url.host, ShellWatchConfiguration.unconfiguredHost)
        // Loopback is the one case the client accepts without TLS.
        if url.scheme != "https" {
            XCTAssertEqual(url.host, "localhost", "a non-HTTPS broker is only accepted on loopback")
        }
        #endif
    }
}
