import UserNotifications
import Foundation
import Testing
import ShellControlProtocol
import ShellControlClient

@testable import ShellWatch

/// Notification handling on the Watch (docs/specs/control-protocol.md section 11.2).
@Suite
final class NotificationRoutingTests {
    @Test
    func testReviewIsFirstAndEveryActionIsForeground() throws {
        let category = ShellNotificationCategories.makeApprovalCategory()
        #expect(category.identifier == PushCategory.approval)
        // Apple invokes the first nondestructive action for Double Tap, so
        // Review must be first — and it must open the app rather than run a
        // background action on the phone.
        let first = try #require(category.actions.first)
        #expect(first.identifier == PushCategory.Action.review.rawValue)
        for action in category.actions {
            #expect(action.options.contains(.foreground), "\(action.identifier) must be foreground")
            #expect(!(action.options.contains(.destructive)), "\(action.identifier) must not be destructive")
        }
    }

    @Test
    func testAnActionOnlySelectsAnIntent() throws {
        let requestID = try #require(ControlID("10000000-0000-4000-8000-000000000001"))
        let payload: [AnyHashable: Any] = ["request_id": requestID.rawValue, "event_id": "ignored"]
        #expect(ShellNotificationCategories.intent(actionIdentifier: PushCategory.Action.review.rawValue, userInfo: payload) == .review(requestID: requestID))
        // The approve shortcut is a proposal; the app still fetches and reviews.
        #expect(ShellNotificationCategories.intent(actionIdentifier: PushCategory.Action.approve.rawValue, userInfo: payload) == .proposeApprove(requestID: requestID))
        #expect(ShellNotificationCategories.intent(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: payload) == .review(requestID: requestID))
    }

    @Test
    func testAPayloadWithoutAUsableRequestIDProducesNoIntent() throws {
        #expect((ShellNotificationCategories.intent(
            actionIdentifier: PushCategory.Action.approve.rawValue,
            userInfo: [:]
        )) == nil)
        // A terminal surface pointer is not an authorization identifier.
        #expect((ShellNotificationCategories.intent(
            actionIdentifier: PushCategory.Action.review.rawValue,
            userInfo: ["request_id": "surface-0x600001234"]
        )) == nil)
    }

    /// A tapped notification's intent waits in an observable router until
    /// the inbox takes it — on a cold launch the inbox does not exist yet —
    /// and opens review exactly once.
    @Test
    @MainActor
    func testTheRouterHoldsAnIntentUntilTheInboxTakesItOnce() throws {
        let requestID = try #require(ControlID("10000000-0000-4000-8000-000000000001"))
        let router = WatchNotificationRouter()
        router.receive(nil)
        #expect((router.pendingIntent) == nil, "a payload without a request id selects nothing")
        router.receive(.proposeApprove(requestID: requestID))
        #expect(router.pendingIntent == .proposeApprove(requestID: requestID))
        #expect(router.consume() == .proposeApprove(requestID: requestID))
        #expect((router.consume()) == nil)
    }

    /// Only a command whose fate is genuinely unknown is labelled so; one the
    /// broker recorded shows as recorded while it awaits reconciliation.
    @Test
    func testActivityLabelsFollowTheJournalState() throws {
        #expect(PendingCommandLabel.isAmbiguous(.outcomeUnknown))
        #expect(PendingCommandLabel.isAmbiguous(.sending))
        #expect(!(PendingCommandLabel.isAmbiguous(.decisionRecorded)))
        #expect(PendingCommandLabel.text(.decisionRecorded) != PendingCommandLabel.text(.outcomeUnknown))
    }

    /// The Watch has no route of its own: no broker URL is baked into it and
    /// none can be configured (docs/specs/control-protocol.md section 2.5).
    @Test
    func testTheWatchBundleCarriesNoBrokerAddress() throws {
        #expect((Bundle.main.object(forInfoDictionaryKey: "SHELLControlBrokerURL")) == nil)
    }
}
