import XCTest
@testable import ShellControlProtocol
@testable import ShellControlSecurity
@testable import ShellControlClient

/// Review capability and submission-outcome classification in the
/// coordinator (docs/specs/control-protocol.md sections 11.2, 13.1 and 14).
final class DecisionCoordinatorTests: XCTestCase {
    private let phoneGrants = DeviceGrant.watchDefault
    private let watchGrants = DeviceGrant.watchReviewerDefault

    private func record(minimumReview: MinimumReview, watchReviewAllowed: Bool = true) throws -> ApprovalRecord {
        let json = try JSONValue.parse(ApprovalSpecTests.specJSON)
        guard var members = json.objectValue else { throw ValidationError.invalid("spec", "not an object") }
        members["minimum_review"] = .string(minimumReview.rawValue)
        let spec = try ApprovalSpec(json: .object(members))
        return try ApprovalRecord(spec: spec, projection: ApprovalProjection(
            presence: SourcePresence(lastSeenAt: spec.createdAt, isWaiting: true),
            watchReviewAllowed: watchReviewAllowed
        ))
    }

    /// The fixture's dates are in the past; a journal on the real clock
    /// would prune its entries as past retention.
    private func journal(at record: ApprovalRecord) throws -> CommandJournal {
        let now = record.spec.createdAt.date
        return CommandJournal(now: { now })
    }

    private func coordinator(
        _ service: StubDecisionService,
        journal: CommandJournal,
        grants: Set<DeviceGrant>,
        review: MinimumReview? = nil,
        at record: ApprovalRecord
    ) -> DecisionCoordinator {
        let now = record.spec.createdAt.date
        return DecisionCoordinator(
            service: service,
            journal: journal,
            key: InMemoryDeviceKey(),
            signer: SignerIdentity(deviceID: .random(), audience: "shell-control:test", grants: grants),
            review: review,
            now: { now }
        )
    }

    // MARK: Review capability

    func testFullReviewRequestIsApprovableOnlyByAFullReviewClient() async throws {
        let full = try record(minimumReview: .full)
        XCTAssertEqual(full.watchApprovability(at: full.spec.createdAt), .reviewElsewhere(reason: .policyRequiresFullReview))
        XCTAssertEqual(full.approvability(at: full.spec.createdAt, review: .full), .approvable)
        XCTAssertTrue(full.canApprove(at: full.spec.createdAt, review: .full))
        XCTAssertFalse(full.canApprove(at: full.spec.createdAt))

        let service = StubDecisionService(record: full)
        let watchJournal = try journal(at: full)
        let watch = coordinator(service, journal: watchJournal, grants: watchGrants, review: .watch, at: full)
        do {
            _ = try await watch.decide(.approve, reviewed: full)
            XCTFail("a Watch approved a full-review request")
        } catch let error as DecisionCoordinator.CoordinatorError {
            XCTAssertEqual(error, .notApprovableOnWatch(.policyRequiresFullReview))
        }
        let watchPending = await watchJournal.pending
        XCTAssertTrue(watchPending.isEmpty)

        let phone = coordinator(service, journal: try journal(at: full), grants: phoneGrants, review: .full, at: full)
        let state = try await phone.decide(.approve, reviewed: full)
        guard case .decisionRecorded = state else { return XCTFail("unexpected \(state)") }
    }

    func testPolicyWithheldWatchReviewStillAllowsFullReview() throws {
        let withheld = try record(minimumReview: .watch, watchReviewAllowed: false)
        XCTAssertEqual(withheld.approvability(at: withheld.spec.createdAt, review: .watch), .reviewElsewhere(reason: .policyRequiresFullReview))
        XCTAssertEqual(withheld.approvability(at: withheld.spec.createdAt, review: .full), .approvable)
    }

    /// Everything but the review policy applies to a full-review client too.
    func testFullReviewStillRequiresPresence() throws {
        let full = try record(minimumReview: .full)
        let absent = try ApprovalRecord(spec: full.spec, projection: ApprovalProjection(presence: .absent))
        XCTAssertEqual(absent.approvability(at: full.spec.createdAt, review: .full), .reviewElsewhere(reason: .sourceNotPresent))
    }

    func testDefaultReviewTreatsAGatewayReviewerAsAWatch() {
        let reviewer = SignerIdentity(deviceID: .random(), audience: "a", grants: watchGrants)
        XCTAssertEqual(DecisionCoordinator.defaultReview(for: reviewer), .watch)
        let direct = SignerIdentity(deviceID: .random(), audience: "a", grants: phoneGrants)
        #if os(watchOS)
        XCTAssertEqual(DecisionCoordinator.defaultReview(for: direct), .watch)
        #else
        XCTAssertEqual(DecisionCoordinator.defaultReview(for: direct), .full)
        #endif
    }

    // MARK: Submission outcomes

    func testFinalRejectionIsThrownAndDroppedFromTheJournal() async throws {
        let watchRecord = try record(minimumReview: .watch)
        for code in [ControlErrorCode.staleVersion, .challengeExpired, .originUnavailable, .notAuthorized, .fullReviewRequired] {
            let service = StubDecisionService(record: watchRecord, submitError: ControlError(code: code, message: "no"))
            let journal = try journal(at: watchRecord)
            let coordinator = coordinator(service, journal: journal, grants: phoneGrants, at: watchRecord)
            do {
                _ = try await coordinator.decide(.approve, reviewed: watchRecord)
                XCTFail("\(code) was not surfaced")
            } catch let error as ControlError {
                XCTAssertEqual(error.code, code)
                XCTAssertTrue(error.provesCommandNotRecorded)
            }
            let pending = await journal.pending
            XCTAssertTrue(pending.isEmpty, "\(code) left a command to be resent")
        }
    }

    func testAmbiguousFailuresStayJournalledAsOutcomeUnknown() async throws {
        let watchRecord = try record(minimumReview: .watch)
        let failures: [any Error] = [
            URLError(.timedOut),
            ControlError(code: .temporarilyUnavailable, message: "503"),
            ControlError(code: .rateLimited, message: "429"),
            ControlError(code: .invalidToken, message: "401"),
            // Also synthesized locally for an undecodable (maybe successful) response.
            ControlError(code: .invalidPayload, message: "unexpected HTTP 400"),
            // A normally-final code flagged retryable by the server is not final.
            ControlError(code: .staleVersion, message: "retry", retryable: true)
        ]
        for failure in failures {
            let service = StubDecisionService(record: watchRecord, submitError: failure)
            let journal = try journal(at: watchRecord)
            let coordinator = coordinator(service, journal: journal, grants: phoneGrants, at: watchRecord)
            let state = try await coordinator.decide(.approve, reviewed: watchRecord)
            guard case .outcomeUnknown(let commandID, _) = state else { return XCTFail("\(failure): unexpected \(state)") }
            let pending = await journal.pending
            XCTAssertEqual(pending.map(\.commandID), [commandID])
            XCTAssertEqual(pending.first?.status, .outcomeUnknown)
        }
    }

    func testReconcileDropsACommandTheBrokerRejectsOnResend() async throws {
        let watchRecord = try record(minimumReview: .watch)
        let service = StubDecisionService(record: watchRecord, submitError: URLError(.networkConnectionLost))
        let journal = try journal(at: watchRecord)
        let coordinator = coordinator(service, journal: journal, grants: phoneGrants, at: watchRecord)
        _ = try await coordinator.decide(.approve, reviewed: watchRecord)
        let journalled = await journal.pending
        let pending = try XCTUnwrap(journalled.first)

        await service.setSubmitError(ControlError(code: .originUnavailable, message: "not present"))
        do {
            _ = try await coordinator.reconcile(pending)
            XCTFail("expected the rejection")
        } catch let error as ControlError {
            XCTAssertEqual(error.code, .originUnavailable)
        }
        let remaining = await journal.pending
        XCTAssertTrue(remaining.isEmpty)
        let sends = await service.submissions
        XCTAssertEqual(sends, [pending.signedCommand, pending.signedCommand], "reconcile resends the identical JWS")
    }

    func testFinalRejectionClassification() {
        for code in ControlErrorCode.allCases where code.provesCommandNotRecorded {
            XCTAssertNotEqual(code.clientAction, .showRecordedState)
            XCTAssertFalse(code.isRetryable)
        }
        XCTAssertFalse(ControlErrorCode.notFound.provesCommandNotRecorded)
        XCTAssertFalse(ControlErrorCode.invalidPayload.provesCommandNotRecorded)
        XCTAssertFalse(ControlErrorCode.alreadyResolved.provesCommandNotRecorded)
    }
}

private actor StubDecisionService: ControlDecisionService {
    let record: ApprovalRecord
    private var submitError: (any Error)?
    private(set) var submissions: [String] = []

    init(record: ApprovalRecord, submitError: (any Error)? = nil) {
        self.record = record
        self.submitError = submitError
    }

    func setSubmitError(_ error: (any Error)?) { submitError = error }

    func approval(_ requestID: ControlID) async throws -> ApprovalRecord { record }

    func reviewChallenge(_ request: ReviewChallengeRequest) async throws -> ReviewChallenge {
        ReviewChallenge(challengeID: "challenge", deviceID: .random(), action: .approvalDecide, expiresAt: record.spec.createdAt.adding(60))
    }

    func submit(signedCommand: String, commandID: ControlID) async throws -> CommandResult {
        submissions.append(signedCommand)
        if let submitError { throw submitError }
        return CommandResult(recorded: true, commandID: commandID, serverTime: record.spec.createdAt)
    }

    func commandResult(_ commandID: ControlID) async throws -> CommandResult {
        throw ControlError(code: .notFound, message: "unknown command")
    }
}
