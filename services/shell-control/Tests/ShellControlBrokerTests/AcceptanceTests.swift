import Foundation
import Testing
import ShellControlProtocol
import ShellControlSecurity
@testable import ShellControlBroker

/// The acceptance and failure table of docs/specs/control-protocol.md section 19, exercised
/// against the broker's state machines.
@Suite
final class AcceptanceTests {
    private func makeHarness() async throws -> (BrokerHarness, ControlID, ControlID) {
        let harness = BrokerHarness()
        try await harness.bootstrap()
        let runID = ControlID.random()
        let jobID = ControlID.random()
        try await harness.registerRun(runID: runID, jobID: jobID)
        return (harness, runID, jobID)
    }

    // MARK: Happy path

    @Test
    func testApproveConsumeAndReceipt() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)

        let outcome = try await harness.decide(.approve, device: device, record: current)
        #expect(outcome.result.recorded)
        #expect(!(outcome.isReplay))
        #expect(outcome.result.resolution == .approved)
        #expect(outcome.result.dispatch == .awaitingOrigin)

        let decisionID = try #require(outcome.result.decisionID)
        let consumeID = ControlID.random()
        let permit = try await harness.store.consumeApproval(
            principal: harness.originPrincipal,
            requestID: record.spec.requestID,
            request: ConsumeRequest(
                consumeID: consumeID,
                decisionID: decisionID,
                requestHash: record.requestHash,
                runID: runID
            )
        )
        #expect(permit.decision == .approve)
        #expect(!(permit.decisionJWS.isEmpty))
        // apply_before is at most ten seconds out and never past the deadline.
        #expect(permit.applyBefore.date <= record.spec.expiresAt.date)
        #expect(permit.applyBefore.date.timeIntervalSince(harness.clock.now) <= ApprovalPolicy.permitLifetime)
        // Retrying the same consume ID returns the same permit and deadline.
        let retried = try await harness.store.consumeApproval(
            principal: harness.originPrincipal,
            requestID: record.spec.requestID,
            request: ConsumeRequest(consumeID: consumeID, decisionID: decisionID, requestHash: record.requestHash, runID: runID)
        )
        #expect(retried.applyBefore == permit.applyBefore)

        try await harness.store.recordReceipt(principal: harness.originPrincipal, receipt: Receipt(
            receiptID: .random(),
            decisionID: decisionID,
            consumeID: consumeID,
            requestHash: record.requestHash,
            runID: runID,
            result: .applied,
            reasonCode: "adapter_applied",
            occurredAt: harness.timestamp
        ))
        let final = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        #expect(final.projection.dispatch == .applied)
        #expect(final.projection.resolution == .approved)
    }

    // MARK: Two devices approve/reject together

    @Test
    func testExactlyOneResolutionTransition() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let first = try await harness.enrollDevice()
        let second = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: first.principal)

        // Both devices hold a challenge against the same version.
        let firstChallenge = try await harness.store.createChallenge(
            principal: first.principal,
            request: try ReviewChallengeRequest(
                target: .approval(
                    requestID: current.spec.requestID,
                    requestHash: current.requestHash,
                    expectedStateVersion: current.projection.stateVersion,
                    policyVersion: current.projection.policyVersion
                ),
                action: .approvalDecide
            )
        )
        let secondChallenge = try await harness.store.createChallenge(
            principal: second.principal,
            request: try ReviewChallengeRequest(
                target: .approval(
                    requestID: current.spec.requestID,
                    requestHash: current.requestHash,
                    expectedStateVersion: current.projection.stateVersion,
                    policyVersion: current.projection.policyVersion
                ),
                action: .approvalDecide
            )
        )
        let winnerID = ControlID.random()
        _ = try await harness.store.submitCommand(
            principal: first.principal,
            signedCommand: try harness.signDecision(.approve, device: first, record: current, challengeID: firstChallenge.challengeID, commandID: winnerID),
            idempotencyKey: winnerID
        )
        let loserID = ControlID.random()
        // The loser sees the recorded decision, not a second transition.
        await assertControlError(.alreadyResolved) {
            _ = try await harness.store.submitCommand(
                principal: second.principal,
                signedCommand: try harness.signDecision(.reject, device: second, record: current, challengeID: secondChallenge.challengeID, commandID: loserID),
                idempotencyKey: loserID
            )
        }
        let final = try await harness.store.approval(record.spec.requestID, principal: first.principal)
        #expect(final.projection.resolution == .approved)
        #expect(final.projection.stateVersion == current.projection.stateVersion + 1)
    }

    // MARK: Idempotency

    @Test
    func testConnectionLostAfterCommitRetrievesTheSameResult() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let challenge = try await harness.store.createChallenge(
            principal: device.principal,
            request: try ReviewChallengeRequest(
                target: .approval(
                    requestID: current.spec.requestID,
                    requestHash: current.requestHash,
                    expectedStateVersion: current.projection.stateVersion,
                    policyVersion: current.projection.policyVersion
                ),
                action: .approvalDecide
            )
        )
        let commandID = ControlID.random()
        let jws = try harness.signDecision(.approve, device: device, record: current, challengeID: challenge.challengeID, commandID: commandID)
        let first = try await harness.store.submitCommand(principal: device.principal, signedCommand: jws, idempotencyKey: commandID)
        let replay = try await harness.store.submitCommand(principal: device.principal, signedCommand: jws, idempotencyKey: commandID)
        #expect(!(first.isReplay))
        #expect(replay.isReplay)
        #expect(first.result.decisionID == replay.result.decisionID)

        // The recorded result stays retrievable after the request expires.
        harness.clock.advance(ApprovalPolicy.defaultLifetime + 60)
        let afterExpiry = try await harness.store.submitCommand(principal: device.principal, signedCommand: jws, idempotencyKey: commandID)
        #expect(afterExpiry.isReplay)
        #expect(afterExpiry.result.decisionID == first.result.decisionID)
        let byID = try await harness.store.commandResult(commandID, principal: device.principal)
        #expect(byID.decisionID == first.result.decisionID)
    }

    @Test
    func testSameCommandIDWithChangedBodyConflicts() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let challenge = try await harness.store.createChallenge(
            principal: device.principal,
            request: try ReviewChallengeRequest(
                target: .approval(
                    requestID: current.spec.requestID,
                    requestHash: current.requestHash,
                    expectedStateVersion: current.projection.stateVersion,
                    policyVersion: current.projection.policyVersion
                ),
                action: .approvalDecide
            )
        )
        let commandID = ControlID.random()
        _ = try await harness.store.submitCommand(
            principal: device.principal,
            signedCommand: try harness.signDecision(.approve, device: device, record: current, challengeID: challenge.challengeID, commandID: commandID),
            idempotencyKey: commandID
        )
        await assertControlError(.idempotencyConflict) {
            _ = try await harness.store.submitCommand(
                principal: device.principal,
                signedCommand: try harness.signDecision(.reject, device: device, record: current, challengeID: challenge.challengeID, commandID: commandID),
                idempotencyKey: commandID
            )
        }
    }

    // MARK: Expiry, staleness, and policy

    @Test
    func testExpiredRequestCannotBeAuthorizedEvenWithAVisibleButton() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        harness.clock.advance(ApprovalPolicy.defaultLifetime + 1)
        await assertControlError(.alreadyResolved) {
            _ = try await harness.store.createChallenge(
                principal: device.principal,
                request: try ReviewChallengeRequest(
                    target: .approval(
                        requestID: current.spec.requestID,
                        requestHash: current.requestHash,
                        expectedStateVersion: current.projection.stateVersion,
                        policyVersion: current.projection.policyVersion
                    ),
                    action: .approvalDecide
                )
            )
        }
        let expired = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        #expect(expired.projection.resolution == .expired)
    }

    @Test
    func testChangedHashOrVersionRequiresFreshReview() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        await assertControlError(.hashMismatch) {
            _ = try await harness.store.createChallenge(
                principal: device.principal,
                request: try ReviewChallengeRequest(
                    target: .approval(
                        requestID: current.spec.requestID,
                        requestHash: "sha256:" + String(repeating: "1", count: 64),
                        expectedStateVersion: current.projection.stateVersion,
                        policyVersion: current.projection.policyVersion
                    ),
                    action: .approvalDecide
                )
            )
        }
        await assertControlError(.staleVersion) {
            _ = try await harness.store.createChallenge(
                principal: device.principal,
                request: try ReviewChallengeRequest(
                    target: .approval(
                        requestID: current.spec.requestID,
                        requestHash: current.requestHash,
                        expectedStateVersion: current.projection.stateVersion + 5,
                        policyVersion: current.projection.policyVersion
                    ),
                    action: .approvalDecide
                )
            )
        }
    }

    @Test
    func testPolicyChangeInvalidatesOutstandingChallenges() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let challenge = try await harness.store.createChallenge(
            principal: device.principal,
            request: try ReviewChallengeRequest(
                target: .approval(
                    requestID: current.spec.requestID,
                    requestHash: current.requestHash,
                    expectedStateVersion: current.projection.stateVersion,
                    policyVersion: current.projection.policyVersion
                ),
                action: .approvalDecide
            )
        )
        try await harness.store.bumpPolicyVersion()
        let commandID = ControlID.random()
        await assertControlError(.challengeExpired) {
            _ = try await harness.store.submitCommand(
                principal: device.principal,
                signedCommand: try harness.signDecision(.approve, device: device, record: current, challengeID: challenge.challengeID, commandID: commandID),
                idempotencyKey: commandID
            )
        }
    }

    @Test
    func testFullReviewRequestIsNotApprovableOnWatch() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID, minimumReview: .full))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let challenge = try await harness.store.createChallenge(
            principal: device.principal,
            request: try ReviewChallengeRequest(
                target: .approval(
                    requestID: current.spec.requestID,
                    requestHash: current.requestHash,
                    expectedStateVersion: current.projection.stateVersion,
                    policyVersion: current.projection.policyVersion
                ),
                action: .approvalDecide
            )
        )
        let commandID = ControlID.random()
        await assertControlError(.fullReviewRequired) {
            _ = try await harness.store.submitCommand(
                principal: device.principal,
                signedCommand: try harness.signDecision(.approve, device: device, record: current, challengeID: challenge.challengeID, commandID: commandID),
                idempotencyKey: commandID
            )
        }
    }

    // MARK: Presence

    @Test
    func testRejectWorksOfflineButApproveNeedsPresence() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let spec = try harness.makeSpec(runID: runID, jobID: jobID)
        let record = try await harness.publish(spec)
        harness.clock.advance(ApprovalPolicy.presenceStaleAfter + 5)
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        #expect(!(current.projection.presence.isFresh(at: harness.timestamp)))

        let approveID = ControlID.random()
        let approveChallenge = try await harness.store.createChallenge(
            principal: device.principal,
            request: try ReviewChallengeRequest(
                target: .approval(
                    requestID: current.spec.requestID,
                    requestHash: current.requestHash,
                    expectedStateVersion: current.projection.stateVersion,
                    policyVersion: current.projection.policyVersion
                ),
                action: .approvalDecide
            )
        )
        await assertControlError(.originUnavailable) {
            _ = try await harness.store.submitCommand(
                principal: device.principal,
                signedCommand: try harness.signDecision(.approve, device: device, record: current, challengeID: approveChallenge.challengeID, commandID: approveID),
                idempotencyKey: approveID
            )
        }
        let outcome = try await harness.decide(.reject, device: device, record: current)
        #expect(outcome.result.resolution == .rejected)
    }

    // MARK: Revocation

    @Test
    func testDeviceRevokedAfterDecisionCannotHaveItsGrantConsumed() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let outcome = try await harness.decide(.approve, device: device, record: current)
        try await harness.store.revokeDevice(device.id)
        await assertControlError(.deviceRevoked) {
            _ = try await harness.store.consumeApproval(
                principal: harness.originPrincipal,
                requestID: record.spec.requestID,
                request: ConsumeRequest(
                    consumeID: .random(),
                    decisionID: try #require(outcome.result.decisionID),
                    requestHash: record.requestHash,
                    runID: runID
                )
            )
        }
    }

    // MARK: Withdrawal and cancellation

    @Test
    func testWithdrawalAfterApprovalMarksUnconsumedDispatchNotApplied() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        _ = try await harness.decide(.approve, device: device, record: current)
        let withdrawn = try await harness.store.withdrawApproval(
            principal: harness.originPrincipal,
            requestID: record.spec.requestID,
            mutationID: .random(),
            runID: runID,
            requestHash: record.requestHash
        )
        // The historic approved resolution is preserved.
        #expect(withdrawn.projection.resolution == .approved)
        #expect(withdrawn.projection.dispatch == .notApplied)
    }

    @Test
    func testWithdrawalAfterClaimReportsAlreadyClaimed() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let outcome = try await harness.decide(.approve, device: device, record: current)
        _ = try await harness.store.consumeApproval(
            principal: harness.originPrincipal,
            requestID: record.spec.requestID,
            request: ConsumeRequest(
                consumeID: .random(),
                decisionID: try #require(outcome.result.decisionID),
                requestHash: record.requestHash,
                runID: runID
            )
        )
        await assertControlError(.alreadyClaimed) {
            _ = try await harness.store.withdrawApproval(
                principal: harness.originPrincipal,
                requestID: record.spec.requestID,
                mutationID: .random(),
                runID: runID,
                requestHash: record.requestHash
            )
        }
    }

    @Test
    func testJobCancellationRacesWithConsumeAndOnlyOneWins() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let outcome = try await harness.decide(.approve, device: device, record: current)

        // Cancellation lands first: the unconsumed grant is invalidated.
        let challenge = try await harness.store.createChallenge(
            principal: device.principal,
            request: try ReviewChallengeRequest(target: .job(jobID: jobID, runID: runID, expectedJobVersion: 1), action: .jobCancel)
        )
        let commandID = ControlID.random()
        let cancel = try JobCancelCommand(
            envelope: try ControlCommandEnvelope(
                type: .jobCancel,
                commandID: commandID,
                deviceID: device.id,
                audience: "shell-control:\(harness.accountID.rawValue)",
                issuedAt: harness.timestamp,
                notAfter: challenge.expiresAt
            ),
            jobID: jobID,
            runID: runID,
            expectedJobVersion: 1,
            challengeID: challenge.challengeID
        )
        _ = try await harness.store.submitCommand(
            principal: device.principal,
            signedCommand: try ControlJWS.sign(payload: cancel.json, deviceID: device.id, key: device.key),
            idempotencyKey: commandID
        )
        await assertControlError(.alreadyResolved) {
            _ = try await harness.store.consumeApproval(
                principal: harness.originPrincipal,
                requestID: record.spec.requestID,
                request: ConsumeRequest(
                    consumeID: .random(),
                    decisionID: try #require(outcome.result.decisionID),
                    requestHash: record.requestHash,
                    runID: runID
                )
            )
        }
        let final = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        #expect(final.projection.dispatch == .notApplied)
    }

    // MARK: Receipts

    @Test
    func testHostCrashReportsUnknownAndReconcilesOnlyWithEvidence() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let outcome = try await harness.decide(.approve, device: device, record: current)
        let decisionID = try #require(outcome.result.decisionID)
        let consumeID = ControlID.random()
        _ = try await harness.store.consumeApproval(
            principal: harness.originPrincipal,
            requestID: record.spec.requestID,
            request: ConsumeRequest(consumeID: consumeID, decisionID: decisionID, requestHash: record.requestHash, runID: runID)
        )
        try await harness.store.recordReceipt(principal: harness.originPrincipal, receipt: Receipt(
            receiptID: .random(),
            decisionID: decisionID,
            consumeID: consumeID,
            requestHash: record.requestHash,
            runID: runID,
            result: .unknown,
            reasonCode: "crashed_after_dispatch",
            occurredAt: harness.timestamp
        ))
        let afterCrash = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        #expect(afterCrash.projection.dispatch == .unknown)
        // Positive evidence may later reconcile unknown to applied.
        try await harness.store.recordReceipt(principal: harness.originPrincipal, receipt: Receipt(
            receiptID: .random(),
            decisionID: decisionID,
            consumeID: consumeID,
            requestHash: record.requestHash,
            runID: runID,
            result: .applied,
            reasonCode: "adapter_evidence",
            occurredAt: harness.timestamp
        ))
        let afterEvidence = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        #expect(afterEvidence.projection.dispatch == .applied)
    }

    @Test
    func testReceiptForAnotherRunIsRejected() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let otherRunID = ControlID.random()
        try await harness.registerRun(runID: otherRunID, jobID: jobID)
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let outcome = try await harness.decide(.approve, device: device, record: current)
        await assertControlError(.hashMismatch) {
            try await harness.store.recordReceipt(principal: harness.originPrincipal, receipt: Receipt(
                receiptID: .random(),
                decisionID: try #require(outcome.result.decisionID),
                consumeID: .random(),
                requestHash: record.requestHash,
                runID: otherRunID,
                result: .applied,
                reasonCode: "wrong_run",
                occurredAt: harness.timestamp
            ))
        }
    }

    // MARK: Isolation

    @Test
    func testAnotherAccountGuessingARequestIDLearnsNothing() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let stranger = Principal.device(deviceID: .random(), accountID: .random(), grants: DeviceGrant.watchDefault)
        await assertControlError(.notFound) {
            _ = try await harness.store.approval(record.spec.requestID, principal: stranger)
        }
    }

    @Test
    func testTmuxOrPIDReuseHasNoBearingOnAuthority() async throws {
        // Authority is bound to run and request IDs only; re-registering the
        // same job under a new run cannot answer the old waiter.
        let (harness, runID, jobID) = try await makeHarness()
        let device = try await harness.enrollDevice()
        let record = try await harness.publish(try harness.makeSpec(runID: runID, jobID: jobID))
        let current = try await harness.store.approval(record.spec.requestID, principal: device.principal)
        let outcome = try await harness.decide(.approve, device: device, record: current)
        let newRunID = ControlID.random()
        try await harness.registerRun(runID: newRunID, jobID: jobID)
        await assertControlError(.hashMismatch) {
            _ = try await harness.store.consumeApproval(
                principal: harness.originPrincipal,
                requestID: record.spec.requestID,
                request: ConsumeRequest(
                    consumeID: .random(),
                    decisionID: try #require(outcome.result.decisionID),
                    requestHash: record.requestHash,
                    runID: newRunID
                )
            )
        }
    }

    // MARK: Request creation

    @Test
    func testSameRequestIDWithADifferentSpecConflicts() async throws {
        let (harness, runID, jobID) = try await makeHarness()
        let requestID = ControlID.random()
        let spec = try harness.makeSpec(requestID: requestID, runID: runID, jobID: jobID)
        _ = try await harness.publish(spec)
        // Identical spec returns the existing record.
        let again = try await harness.store.createApproval(principal: harness.originPrincipal, spec: spec)
        #expect(again.requestHash == (try spec.requestHash()))
        let changed = try harness.makeSpec(requestID: requestID, runID: runID, jobID: jobID, argv: ["/usr/bin/git", "push", "--force"])
        await assertControlError(.idempotencyConflict) {
            _ = try await harness.store.createApproval(principal: harness.originPrincipal, spec: changed)
        }
    }
}
