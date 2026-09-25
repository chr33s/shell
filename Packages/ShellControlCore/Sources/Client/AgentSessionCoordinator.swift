import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// The calls a session command needs.
public protocol AgentSessionService: Sendable {
    func agentSession(_ id: ControlID) async throws -> AgentSessionProjection
    func agentReviewChallenge(_ request: AgentReviewChallengeRequest) async throws -> AgentReviewChallenge
    func submitAgent(signedCommand: String, commandID: ControlID) async throws -> AgentCommandResult
    func agentCommandResult(_ commandID: ControlID) async throws -> AgentCommandResult
}

extension ControlAPIClient: AgentSessionService {}

/// New instructions, steering, and cancellation for an opt-in managed
/// session (docs/specs/agent-relay.md section 15). The exact action — text, mode,
/// and the turn it targets — is digested into the challenge before signing;
/// a moved session is refused, never retargeted or queued.
public actor AgentSessionCoordinator {
    public enum CoordinatorError: Error, Sendable, Equatable {
        case missingGrant(DeviceGrant)
        case notOffered
        case sessionChanged
        case invalid(String)
    }

    private let client: any AgentSessionService
    private let journal: CommandJournal
    private let key: any DeviceSigningKey
    private let signer: SignerIdentity
    private let now: @Sendable () -> Date

    public init(service: any AgentSessionService, journal: CommandJournal, key: any DeviceSigningKey, signer: SignerIdentity,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = service
        self.journal = journal
        self.key = key
        self.signer = signer
        self.now = now
    }

    private var timestamp: ControlTimestamp { ControlTimestamp(now()) }

    /// The action for sending `text` to `session` as it was reviewed: a new
    /// turn when idle, steering the exact active turn otherwise.
    public static func messageAction(_ text: String, session: AgentSessionProjection) throws -> AgentSessionAction {
        let action: AgentSessionAction
        switch session.turnState {
        case .idle:
            action = .message(agentSessionID: session.registration.agentSessionID, runID: session.registration.runID,
                              expectedSessionVersion: session.sessionVersion, mode: .newTurn, expectedTurnID: nil, text: text)
        case .active:
            action = .message(agentSessionID: session.registration.agentSessionID, runID: session.registration.runID,
                              expectedSessionVersion: session.sessionVersion, mode: .steer, expectedTurnID: session.activeTurnID, text: text)
        case nil:
            throw CoordinatorError.notOffered
        }
        try action.validate()
        return action
    }

    public static func cancelAction(session: AgentSessionProjection) throws -> AgentSessionAction {
        guard session.turnState == .active, let turnID = session.activeTurnID else { throw CoordinatorError.notOffered }
        return .cancel(agentSessionID: session.registration.agentSessionID, runID: session.registration.runID,
                       expectedSessionVersion: session.sessionVersion, turnID: turnID)
    }

    /// Signs and submits `action` after confirming the session still has the
    /// exact state it was built from.
    public func send(_ action: AgentSessionAction) async throws -> AgentSubmissionState {
        let grant: DeviceGrant = action.commandType == .turnCancel ? .agentTurnsCancel : .agentMessagesSend
        guard signer.grants.contains(grant) else { throw CoordinatorError.missingGrant(grant) }
        do { try action.validate() } catch { throw CoordinatorError.invalid(String(describing: error)) }
        let current = try await client.agentSession(action.agentSessionID)
        let feature = action.commandType == .turnCancel ? AgentFeature.turnCancel : AgentFeature.messages
        guard current.offers(feature) else { throw CoordinatorError.notOffered }
        guard current.sessionVersion == action.expectedSessionVersion, current.registration.runID == action.runID else {
            throw CoordinatorError.sessionChanged
        }
        switch action {
        case .message(_, _, _, .newTurn, _, _):
            guard current.turnState == .idle else { throw CoordinatorError.sessionChanged }
        case .message(_, _, _, .steer, let turn, _):
            guard current.turnState == .active, current.activeTurnID == turn else { throw CoordinatorError.sessionChanged }
        case .cancel(_, _, _, let turn):
            guard current.turnState == .active, current.activeTurnID == turn else { throw CoordinatorError.sessionChanged }
        }
        let challenge = try await client.agentReviewChallenge(try AgentReviewChallengeRequest(sessionAction: action))
        let commandID = ControlID.random()
        let command = try AgentSessionCommand(
            envelope: try AgentCommandEnvelope(type: action.commandType, commandID: commandID, deviceID: signer.deviceID,
                                               audience: signer.audience, issuedAt: timestamp, notAfter: challenge.expiresAt),
            action: action,
            challengeID: challenge.challengeID
        )
        let jws = try ControlJWS.sign(payload: command.json, deviceID: signer.deviceID, key: key)
        try await journal.record(PendingCommand(commandID: commandID, signedCommand: jws, agentType: action.commandType,
                                                targetID: action.agentSessionID, notAfter: challenge.expiresAt))
        do {
            let result = try await client.submitAgent(signedCommand: jws, commandID: commandID)
            try? await journal.update(commandID, status: .decisionRecorded)
            return .fromResult(result)
        } catch let error as ControlError where error.provesCommandNotRecorded {
            try? await journal.resolve(commandID)
            throw error
        } catch let error as ControlError where !error.retryable && error.code.clientAction == .showRecordedState {
            try? await journal.update(commandID, status: .decisionRecorded)
            throw error
        } catch {
            try? await journal.update(commandID, status: .outcomeUnknown)
            return .outcomeUnknown(commandID: commandID, reason: String(describing: error))
        }
    }

    public func refresh(_ commandID: ControlID) async throws -> AgentSubmissionState {
        .fromResult(try await client.agentCommandResult(commandID))
    }
}
