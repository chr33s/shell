import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// What the UI shows for an agent response. Each is distinct: a recorded
/// response is not agent acceptance, and acceptance is not task completion
/// (docs/specs/agent-relay.md section 12.1).
public enum AgentSubmissionState: Sendable, Hashable {
    case sending
    case responseRecorded(AgentCommandResult)
    case waitingForAgent(AgentCommandResult)
    /// Bytes reached the agent's native wait; its acceptance is not
    /// observable through this integration.
    case deliveredToAgent(AgentCommandResult)
    case agentAccepted(AgentCommandResult)
    case notApplied(AgentCommandResult)
    case outcomeUnknown(commandID: ControlID, reason: String)

    public static func fromResult(_ result: AgentCommandResult) -> AgentSubmissionState {
        switch result.dispatch ?? .none {
        case .none, .awaitingOrigin: return .responseRecorded(result)
        case .claimed, .dispatchStarted: return .waitingForAgent(result)
        case .nativeResponseWritten: return .deliveredToAgent(result)
        case .accepted: return .agentAccepted(result)
        case .notApplied: return .notApplied(result)
        case .unknown: return .outcomeUnknown(commandID: result.commandID, reason: "the agent's outcome is unknown")
        }
    }
}

/// The calls an agent response needs. The iPhone reaches the Mac directly;
/// the Watch reaches it through its iPhone. The signed command is the only
/// authority either way.
public protocol AgentInputService: Sendable {
    func input(_ requestID: ControlID) async throws -> InputRecord
    func agentReviewChallenge(_ request: AgentReviewChallengeRequest) async throws -> AgentReviewChallenge
    func submitAgent(signedCommand: String, commandID: ControlID) async throws -> AgentCommandResult
    func agentCommandResult(_ commandID: ControlID) async throws -> AgentCommandResult
}

extension ControlAPIClient: AgentInputService {}

/// Drives review → challenge → signature → submission for one typed answer,
/// with the same fetch-before-sign, exact-hash, and no-replacement rules as a
/// decision (docs/specs/agent-relay.md section 7.2).
public actor AgentInputCoordinator {
    public enum CoordinatorError: Error, Sendable, Equatable {
        case notAnswerableHere(WatchApprovability.Reason)
        case requestChangedDuringReview
        case missingGrant(DeviceGrant)
        case invalidResponse(String)
    }

    private let client: any AgentInputService
    private let journal: CommandJournal
    private let key: any DeviceSigningKey
    private let signer: SignerIdentity
    private let now: @Sendable () -> Date
    public nonisolated let review: MinimumReview

    public init(
        service: any AgentInputService,
        journal: CommandJournal,
        key: any DeviceSigningKey,
        signer: SignerIdentity,
        review: MinimumReview? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = service
        self.journal = journal
        self.key = key
        self.signer = signer
        self.review = review ?? DecisionCoordinator.defaultReview(for: signer)
        self.now = now
    }

    private var timestamp: ControlTimestamp { ControlTimestamp(now()) }

    /// Answers or declines `reviewed` after confirming the broker still holds
    /// exactly what the user looked at. The response is validated against the
    /// committed spec before anything is signed.
    public func respond(
        _ response: InputResponse,
        reviewed: InputRecord,
        supportedFeatures: Set<String> = ControlFeature.supported
    ) async throws -> AgentSubmissionState {
        guard signer.grants.contains(.agentInputsRespond) else { throw CoordinatorError.missingGrant(.agentInputsRespond) }
        do {
            try response.validate(against: reviewed.spec)
        } catch {
            throw CoordinatorError.invalidResponse(String(describing: error))
        }
        let current = try await client.input(reviewed.spec.requestID)
        guard ContentDigest.matches(current.requestHash, reviewed.requestHash),
              current.projection.stateVersion == reviewed.projection.stateVersion,
              current.projection.policyVersion == reviewed.projection.policyVersion else {
            throw CoordinatorError.requestChangedDuringReview
        }
        switch current.answerability(at: timestamp, review: review, supportedFeatures: supportedFeatures) {
        case .approvable:
            break
        case .reviewElsewhere(let reason):
            // A decline, like a reject, does not need the live source.
            guard response == .decline, reason == .sourceNotPresent else { throw CoordinatorError.notAnswerableHere(reason) }
        }

        let challenge = try await client.agentReviewChallenge(try AgentReviewChallengeRequest(
            requestID: current.spec.requestID,
            requestHash: current.requestHash,
            expectedStateVersion: current.projection.stateVersion,
            policyVersion: current.projection.policyVersion
        ))
        let commandID = ControlID.random()
        let notAfter = min(challenge.expiresAt, current.spec.expiresAt)
        let command = try InputRespondCommand(
            envelope: try AgentCommandEnvelope(
                type: .inputRespond, commandID: commandID, deviceID: signer.deviceID,
                audience: signer.audience, issuedAt: timestamp, notAfter: notAfter
            ),
            requestID: current.spec.requestID,
            requestHash: current.requestHash,
            expectedStateVersion: current.projection.stateVersion,
            policyVersion: current.projection.policyVersion,
            challengeID: challenge.challengeID,
            response: response
        )
        let jws = try ControlJWS.sign(payload: command.json, deviceID: signer.deviceID, key: key)
        // Recorded before the first network send, so an ambiguous
        // submission can be queried by the same command ID.
        try await journal.record(PendingCommand(
            commandID: commandID, signedCommand: jws, agentType: .inputRespond,
            targetID: current.spec.requestID, notAfter: notAfter
        ))
        return try await submit(commandID: commandID, jws: jws)
    }

    private func submit(commandID: ControlID, jws: String) async throws -> AgentSubmissionState {
        do {
            let result = try await client.submitAgent(signedCommand: jws, commandID: commandID)
            try? await journal.update(commandID, status: .decisionRecorded)
            return .fromResult(result)
        } catch let error as ControlError where !error.retryable && error.code.clientAction == .showRecordedState {
            try? await journal.update(commandID, status: .decisionRecorded)
            throw error
        } catch let error as ControlError where error.provesCommandNotRecorded {
            try? await journal.resolve(commandID)
            throw error
        } catch {
            try? await journal.update(commandID, status: .outcomeUnknown)
            return .outcomeUnknown(commandID: commandID, reason: String(describing: error))
        }
    }

    /// Queries a journalled agent command by its ID. Only the identical JWS
    /// may be resent, and only while it is still valid; nothing is re-signed.
    public func reconcile(_ pending: PendingCommand) async throws -> AgentSubmissionState {
        // Session commands reconcile through the same command endpoint.
        guard pending.isAgentCommand else {
            return .outcomeUnknown(commandID: pending.commandID, reason: "reconciled by the decision coordinator")
        }
        do {
            let result = try await client.agentCommandResult(pending.commandID)
            try await journal.resolve(pending.commandID)
            return .fromResult(result)
        } catch let error as ControlError where error.code == .notFound {
            if pending.isRetryable(at: timestamp) {
                return try await submit(commandID: pending.commandID, jws: pending.signedCommand)
            }
            try await journal.resolve(pending.commandID)
            throw error
        }
    }

    /// Follows a recorded response's delivery without resubmitting anything.
    public func refresh(_ commandID: ControlID) async throws -> AgentSubmissionState {
        .fromResult(try await client.agentCommandResult(commandID))
    }
}
