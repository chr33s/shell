import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// What the UI shows after a submission. These are distinct states: a recorded
/// decision does not mean the host applied it, and an unknown outcome is not a
/// failure to decide (spec.watch.md section 6).
public enum SubmissionState: Sendable, Hashable {
    case sending
    case decisionRecorded(CommandResult)
    case waitingForHost(CommandResult)
    case hostAccepted(CommandResult)
    case notApplied(CommandResult)
    case outcomeUnknown(commandID: ControlID, reason: String)

    public static func fromResult(_ result: CommandResult) -> SubmissionState {
        guard let dispatch = result.dispatch else { return .decisionRecorded(result) }
        switch dispatch {
        case .applied: return .hostAccepted(result)
        case .notApplied: return .notApplied(result)
        case .unknown: return .outcomeUnknown(commandID: result.commandID, reason: "host reported unknown")
        case .claimed, .awaitingOrigin: return .waitingForHost(result)
        case .none: return .decisionRecorded(result)
        }
    }
}

/// The four calls a decision needs. The iPhone reaches the Mac directly; the
/// Watch reaches it through the iPhone gateway. Either way the signed command
/// is the only authority (spec.iphone-gateway.md section 13).
public protocol ControlDecisionService: Sendable {
    func approval(_ requestID: ControlID) async throws -> ApprovalRecord
    func reviewChallenge(_ request: ReviewChallengeRequest) async throws -> ReviewChallenge
    func submit(signedCommand: String, commandID: ControlID) async throws -> CommandResult
    func commandResult(_ commandID: ControlID) async throws -> CommandResult
}

extension ControlAPIClient: ControlDecisionService {}

/// Who signs: the device ID in the JWS `kid`, the audience it commits to, and
/// the grants the device believes it holds.
public struct SignerIdentity: Sendable, Hashable {
    public let deviceID: ControlID
    public let audience: String
    public let grants: Set<DeviceGrant>

    public init(deviceID: ControlID, audience: String, grants: Set<DeviceGrant>) {
        self.deviceID = deviceID
        self.audience = audience
        self.grants = grants
    }

    public init(session: DeviceSession) {
        self.init(deviceID: session.deviceID, audience: session.audience, grants: session.grants)
    }
}

/// Drives review → challenge → signature → submission for one device.
///
/// Every step re-fetches: the request is fetched before a decision is enabled,
/// the challenge binds the exact hash and versions, and the signed payload is
/// the only authority the broker accepts (spec.watch.md sections 6 and 11).
public actor DecisionCoordinator {
    public enum CoordinatorError: Error, Sendable, Equatable {
        /// This device may not approve the request; review it elsewhere. On a
        /// full-review client only `policyRequiresFullReview` never occurs.
        case notApprovableOnWatch(WatchApprovability.Reason)
        case decisionNotAllowed
        case requestChangedDuringReview
        case missingGrant(DeviceGrant)
        case noSession
    }

    private let client: any ControlDecisionService
    private let journal: CommandJournal
    private let key: any DeviceSigningKey
    private let session: SignerIdentity
    private let now: @Sendable () -> Date
    /// The review this device provides. Only a full-review client may approve
    /// a `minimum_review: full` request (spec.watch.md section 6); the broker
    /// enforces the same rule from its own device registration.
    public nonisolated let review: MinimumReview

    /// `review` defaults to ``defaultReview(for:)``.
    public init(
        client: ControlAPIClient,
        journal: CommandJournal,
        key: any DeviceSigningKey,
        session: DeviceSession,
        review: MinimumReview? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(service: client, journal: journal, key: key, signer: SignerIdentity(session: session), review: review, now: now)
    }

    /// `review` defaults to ``defaultReview(for:)``.
    public init(
        service: any ControlDecisionService,
        journal: CommandJournal,
        key: any DeviceSigningKey,
        signer: SignerIdentity,
        review: MinimumReview? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = service
        self.journal = journal
        self.key = key
        self.session = signer
        self.review = review ?? Self.defaultReview(for: signer)
        self.now = now
    }

    /// A Watch reviewer, identified by its gateway-only read grants, is a
    /// Watch whatever it runs on; otherwise the build's platform decides:
    /// Watch-sized review on watchOS, full review elsewhere (the iPhone).
    public static func defaultReview(for signer: SignerIdentity) -> MinimumReview {
        let gatewayOnly: Set<DeviceGrant> = [.requestsReadViaGateway, .notificationsReadViaGateway]
        guard signer.grants.isDisjoint(with: gatewayOnly) else { return .watch }
        return .providedByThisPlatform
    }

    private var timestamp: ControlTimestamp { ControlTimestamp(now()) }

    /// Approves or rejects `reviewed`, after confirming the server still holds
    /// the exact request the user looked at.
    public func decide(
        _ decision: ControlDecision,
        reviewed: ApprovalRecord,
        supportedFeatures: Set<String> = ControlFeature.supported
    ) async throws -> SubmissionState {
        guard session.grants.contains(.approvalsDecide) else { throw CoordinatorError.missingGrant(.approvalsDecide) }
        guard reviewed.spec.allowedDecisions.contains(decision) else { throw CoordinatorError.decisionNotAllowed }

        // Fetch the current request before enabling the decision: the app must
        // never silently accept a different request after confirmation.
        let current = try await client.approval(reviewed.spec.requestID)
        guard ContentDigest.matches(current.requestHash, reviewed.requestHash),
              current.projection.stateVersion == reviewed.projection.stateVersion,
              current.projection.policyVersion == reviewed.projection.policyVersion
        else {
            throw CoordinatorError.requestChangedDuringReview
        }
        if decision == .approve {
            switch current.approvability(at: timestamp, review: review, supportedFeatures: supportedFeatures) {
            case .approvable: break
            case .reviewElsewhere(let reason): throw CoordinatorError.notApprovableOnWatch(reason)
            }
        } else {
            guard current.canReject(at: timestamp) else {
                throw CoordinatorError.notApprovableOnWatch(.alreadyResolved)
            }
        }

        let challenge = try await client.reviewChallenge(
            try ReviewChallengeRequest(
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
        // The command never outlives its challenge or the request deadline.
        let notAfter = min(challenge.expiresAt, current.spec.expiresAt)
        let command = try ApprovalDecideCommand(
            envelope: try ControlCommandEnvelope(
                type: .approvalDecide,
                commandID: commandID,
                deviceID: session.deviceID,
                audience: session.audience,
                issuedAt: timestamp,
                notAfter: notAfter
            ),
            requestID: current.spec.requestID,
            requestHash: current.requestHash,
            expectedStateVersion: current.projection.stateVersion,
            policyVersion: current.projection.policyVersion,
            decision: decision,
            challengeID: challenge.challengeID
        )
        let jws = try ControlJWS.sign(payload: command.json, deviceID: session.deviceID, key: key)
        try await journal.record(PendingCommand(
            commandID: commandID,
            signedCommand: jws,
            type: .approvalDecide,
            targetID: current.spec.requestID,
            notAfter: notAfter
        ))
        return try await submit(commandID: commandID, jws: jws)
    }

    /// Acknowledging is not approving, and needs no review challenge
    /// (spec.watch.md section 13).
    public func acknowledge(notification: InformationalEvent) async throws -> SubmissionState {
        guard session.grants.contains(.notificationsAck) else { throw CoordinatorError.missingGrant(.notificationsAck) }
        let commandID = ControlID.random()
        let notAfter = timestamp.adding(ApprovalPolicy.challengeLifetime)
        let command = try NotificationAckCommand(
            envelope: try ControlCommandEnvelope(
                type: .notificationAck,
                commandID: commandID,
                deviceID: session.deviceID,
                audience: session.audience,
                issuedAt: timestamp,
                notAfter: notAfter
            ),
            notificationID: notification.eventID
        )
        let jws = try ControlJWS.sign(payload: command.json, deviceID: session.deviceID, key: key)
        try await journal.record(PendingCommand(
            commandID: commandID,
            signedCommand: jws,
            type: .notificationAck,
            targetID: notification.eventID,
            notAfter: notAfter
        ))
        return try await submit(commandID: commandID, jws: jws)
    }

    /// Cooperative cancellation. The Watch shows "Cancellation requested" until
    /// an origin confirms (spec.watch.md section 13).
    public func cancelJob(jobID: ControlID, runID: ControlID, expectedJobVersion: Int64) async throws -> SubmissionState {
        guard session.grants.contains(.jobsCancel) else { throw CoordinatorError.missingGrant(.jobsCancel) }
        let challenge = try await client.reviewChallenge(
            try ReviewChallengeRequest(
                target: .job(jobID: jobID, runID: runID, expectedJobVersion: expectedJobVersion),
                action: .jobCancel
            )
        )
        let commandID = ControlID.random()
        let command = try JobCancelCommand(
            envelope: try ControlCommandEnvelope(
                type: .jobCancel,
                commandID: commandID,
                deviceID: session.deviceID,
                audience: session.audience,
                issuedAt: timestamp,
                notAfter: challenge.expiresAt
            ),
            jobID: jobID,
            runID: runID,
            expectedJobVersion: expectedJobVersion,
            mode: .cooperative,
            challengeID: challenge.challengeID
        )
        let jws = try ControlJWS.sign(payload: command.json, deviceID: session.deviceID, key: key)
        try await journal.record(PendingCommand(
            commandID: commandID,
            signedCommand: jws,
            type: .jobCancel,
            targetID: jobID,
            notAfter: challenge.expiresAt
        ))
        return try await submit(commandID: commandID, jws: jws)
    }

    /// Sends, and on an ambiguous failure leaves the journal entry so the
    /// outcome can be queried later by the same command ID.
    ///
    /// Throws the broker's `ControlError` for a final rejection
    /// (``ControlError/provesCommandNotRecorded``): nothing was recorded, so
    /// the entry is dropped and reconciliation never resends that JWS.
    private func submit(commandID: ControlID, jws: String) async throws -> SubmissionState {
        // Journal status writes after the send are best effort: the entry was
        // recorded before sending, so a failed update leaves it pending and it
        // is reconciled by command ID. It must never mask what the send did.
        do {
            let result = try await client.submit(signedCommand: jws, commandID: commandID)
            try? await journal.update(commandID, status: .decisionRecorded)
            return SubmissionState.fromResult(result)
        } catch let error as ControlError where !error.retryable && error.code.clientAction == .showRecordedState {
            // Already resolved or an idempotency conflict: surface the recorded
            // state, never create a replacement command.
            try? await journal.update(commandID, status: .decisionRecorded)
            throw error
        } catch let error as ControlError where error.provesCommandNotRecorded {
            // The broker refused the command outright (stale version, expired
            // challenge, origin not present, not authorized...). The outcome
            // is known — not recorded — so it is not left for reconciliation.
            try? await journal.resolve(commandID)
            throw error
        } catch {
            try? await journal.update(commandID, status: .outcomeUnknown)
            return .outcomeUnknown(commandID: commandID, reason: String(describing: error))
        }
    }

    /// Reconciles one journalled command on reconnection. After expiry it can
    /// still retrieve status, but never creates a new decision
    /// (spec.watch.md section 15).
    public func reconcile(_ pending: PendingCommand) async throws -> SubmissionState {
        // An agent command is reconciled only through the agent endpoints;
        // the base endpoint would never find it, and resending it there
        // would be refused (spec.agent-relay.md section 8.1).
        guard !pending.isAgentCommand else {
            return .outcomeUnknown(commandID: pending.commandID, reason: "reconciled by the agent coordinator")
        }
        do {
            let result = try await client.commandResult(pending.commandID)
            try await journal.resolve(pending.commandID)
            return SubmissionState.fromResult(result)
        } catch let error as ControlError where error.code == .notFound {
            if pending.isRetryable(at: timestamp) {
                // The identical signed command may be retried while valid.
                return try await submit(commandID: pending.commandID, jws: pending.signedCommand)
            }
            try await journal.resolve(pending.commandID)
            throw error
        }
    }
}
