//
//  ControlAgentSessionModel.swift
//  shell
//
//  Plain, testable logic for managed-session commands on the phone: which
//  controls a session and this iPhone's grants allow, the new-instruction
//  draft, the exact action a confirmation screen shows before signing, and
//  the distinct outcome of each command. The action is always built from the
//  session exactly as the user reviewed it; a session that moved is refused
//  and reviewed again, never retargeted (docs/specs/agent-relay.md section 15).
//

import Foundation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

// MARK: - Controls

/// What the session screen may offer. Every control needs its own grant and
/// the session's own negotiated feature; nothing falls back to typing into a
/// terminal (docs/specs/agent-relay.md sections 13.1 and 15).
struct AgentSessionControls: Equatable {
    /// The session may be shown at all.
    let canRead: Bool
    /// The compose field and its confirmation.
    let canCompose: Bool
    /// "Interrupt turn" and its confirmation.
    let canInterrupt: Bool
    /// The session offers messages, but this iPhone was not granted them.
    let messagesNeedGrant: Bool
    /// A turn is running that this iPhone could interrupt with the grant.
    let cancelNeedsGrant: Bool

    init(session: AgentSessionProjection, grants: Set<DeviceGrant>) {
        let readable = grants.contains(.agentSessionsRead) && session.registration.profile == .managed
        let offersMessages = readable && session.offers(AgentFeature.messages) && session.turnState != nil
        let turnRunning = session.turnState == .active && !(session.activeTurnID ?? "").isEmpty
        let offersCancel = readable && session.offers(AgentFeature.turnCancel) && turnRunning
        canRead = readable
        canCompose = offersMessages && grants.contains(.agentMessagesSend)
        canInterrupt = offersCancel && grants.contains(.agentTurnsCancel)
        messagesNeedGrant = offersMessages && !grants.contains(.agentMessagesSend)
        cancelNeedsGrant = offersCancel && !grants.contains(.agentTurnsCancel)
    }

    /// Managed sessions this iPhone may see, active ones first, newest first.
    static func visibleSessions(_ sessions: some Sequence<AgentSessionProjection>, grants: Set<DeviceGrant>,
                                limit: Int = 10) -> [AgentSessionProjection] {
        guard grants.contains(.agentSessionsRead) else { return [] }
        return sessions
            .filter { $0.registration.profile == .managed }
            .sorted { lhs, rhs in
                if (lhs.state == .active) != (rhs.state == .active) { return lhs.state == .active }
                return lhs.registration.startedAt > rhs.registration.startedAt
            }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Draft

/// The user's in-progress instruction. It never signs anything: it produces
/// the exact action the confirmation screen shows, from the session as it
/// was reviewed (docs/specs/agent-relay.md 15.1).
struct AgentMessageDraft: Equatable {
    enum DraftError: Error, Equatable {
        case empty
        case tooLong(bytes: Int)
        case controlCharacters
        /// The session offers no turn state to bind the message to.
        case notOffered
    }

    var text = ""

    static let maximumBytes = AgentSessionAction.maximumTextBytes

    /// Exact UTF-8 bytes, the unit the signed limit is expressed in.
    var byteCount: Int { text.utf8.count }
    var isOverLimit: Bool { byteCount > Self.maximumBytes }

    /// Plain text only: line breaks and tabs are allowed; every other control
    /// character (C0, DEL, C1) is refused rather than escaped into the text.
    static func check(_ text: String) -> DraftError? {
        if text.isEmpty { return .empty }
        if text.utf8.count > maximumBytes { return .tooLong(bytes: text.utf8.count) }
        let refused = text.unicodeScalars.contains { scalar in
            scalar != "\n" && scalar != "\t" && scalar.properties.generalCategory == .control
        }
        return refused ? .controlCharacters : nil
    }

    var problem: DraftError? { Self.check(text) }

    /// The exact message for `reviewed`: a new turn when it was idle, steering
    /// the exact active turn otherwise. Validated before return.
    func proposal(for reviewed: AgentSessionProjection) throws -> AgentSessionProposal {
        if let problem { throw problem }
        do {
            return AgentSessionProposal(action: try AgentSessionCoordinator.messageAction(text, session: reviewed), reviewed: reviewed)
        } catch {
            // The text already passed; what remains is the turn binding.
            throw DraftError.notOffered
        }
    }
}

// MARK: - Proposal

/// One action exactly as it will be signed, and the session state it was
/// built from. The confirmation screen shows only what is in here.
struct AgentSessionProposal: Equatable, Identifiable {
    enum Target: Equatable {
        case newTurn
        case steer(turnID: String)
        case cancel(turnID: String)
    }

    let action: AgentSessionAction
    let reviewed: AgentSessionProjection

    var id: String { action.digest }

    static func interrupt(_ reviewed: AgentSessionProjection) throws -> AgentSessionProposal {
        AgentSessionProposal(action: try AgentSessionCoordinator.cancelAction(session: reviewed), reviewed: reviewed)
    }

    var target: Target {
        switch action {
        case .message(_, _, _, .newTurn, _, _): .newTurn
        case .message(_, _, _, .steer, let turnID, _): .steer(turnID: turnID ?? "")
        case .cancel(_, _, _, let turnID): .cancel(turnID: turnID)
        }
    }

    /// The exact text of a message, nil for a cancellation.
    var text: String? {
        if case .message(_, _, _, _, _, let text) = action { return text }
        return nil
    }

    /// The text one sanitized line per real line break, so a control or bidi
    /// character is visible and cannot fake a line break.
    var displayLines: [DisplaySanitizer.Result] {
        guard let text else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { DisplaySanitizer.sanitize(String($0), maxScalars: AgentSessionAction.maximumTextBytes) }
    }

    /// Whether anything could not be shown in full. Confirmation is refused.
    var isTruncated: Bool { displayLines.contains { $0.isTruncated } }
    var didEscape: Bool { displayLines.contains { $0.didEscape } }
}

// MARK: - Outcomes

/// The distinct states of one session command. A recorded command is not
/// agent acceptance, and acceptance is not proof the turn did anything
/// (docs/specs/agent-relay.md sections 12.1 and 15.2).
enum AgentSessionOutcome: Equatable {
    case sending
    case recorded
    case waitingForAgent
    case agentAccepted
    case notApplied
    case outcomeUnknown

    init(_ state: AgentSubmissionState) {
        switch state {
        case .sending: self = .sending
        case .responseRecorded: self = .recorded
        case .waitingForAgent, .deliveredToAgent: self = .waitingForAgent
        case .agentAccepted: self = .agentAccepted
        case .notApplied: self = .notApplied
        case .outcomeUnknown: self = .outcomeUnknown
        }
    }

    init(_ dispatch: AgentDispatch) {
        switch dispatch {
        case .none, .awaitingOrigin: self = .recorded
        case .claimed, .dispatchStarted, .nativeResponseWritten: self = .waitingForAgent
        case .accepted: self = .agentAccepted
        case .notApplied: self = .notApplied
        case .unknown: self = .outcomeUnknown
        }
    }

    var text: String {
        switch self {
        case .sending: String(localized: "Sending")
        case .recorded: String(localized: "Recorded")
        case .waitingForAgent: String(localized: "Waiting for agent")
        case .agentAccepted: String(localized: "Agent accepted")
        case .notApplied: String(localized: "Not applied")
        case .outcomeUnknown: String(localized: "Outcome unknown")
        }
    }
}

/// One command's outcome as the session screen lists it.
struct AgentSessionCommandOutcome: Equatable, Identifiable {
    let commandID: ControlID
    let sessionID: ControlID
    /// Nil when only the command ID is known locally (a journalled command
    /// whose record has not arrived yet).
    let action: AgentSessionAction?
    let outcome: AgentSessionOutcome
    /// Settled outcomes are not followed any further.
    let isSettled: Bool
    let evidence: String?
    let at: ControlTimestamp

    var id: ControlID { commandID }

    /// Merges this iPhone's own submissions with the broker's records for one
    /// session, newest first. The further-along state wins, so a late local
    /// result never moves a command backwards.
    static func merge(sessionID: ControlID, local: [ControlID: AgentLocalSessionCommand],
                      records: [ControlID: AgentSessionCommandRecord]) -> [AgentSessionCommandOutcome] {
        var outcomes: [ControlID: AgentSessionCommandOutcome] = [:]
        for (id, record) in records where record.action.agentSessionID == sessionID {
            let outcome = AgentSessionOutcome(record.dispatch)
            outcomes[id] = AgentSessionCommandOutcome(
                commandID: id, sessionID: sessionID, action: record.action, outcome: outcome,
                // The broker's `unknown` is terminal until positive evidence.
                isSettled: record.dispatch.isTerminal, evidence: record.evidence, at: record.recordedAt
            )
        }
        for (id, entry) in local where entry.sessionID == sessionID {
            let mine = AgentSessionOutcome(entry.state)
            if let existing = outcomes[id] {
                guard rank(mine) > rank(existing.outcome) else { continue }
                outcomes[id] = AgentSessionCommandOutcome(
                    commandID: id, sessionID: sessionID, action: existing.action, outcome: mine,
                    isSettled: isSettled(mine), evidence: existing.evidence, at: existing.at
                )
            } else {
                outcomes[id] = AgentSessionCommandOutcome(
                    commandID: id, sessionID: sessionID, action: entry.action, outcome: mine,
                    isSettled: isSettled(mine), evidence: nil, at: entry.at
                )
            }
        }
        return outcomes.values.sorted { $0.at > $1.at }
    }

    /// A local "outcome unknown" is an ambiguous submission, still followed
    /// by its command ID.
    private static func isSettled(_ outcome: AgentSessionOutcome) -> Bool {
        outcome == .agentAccepted || outcome == .notApplied
    }

    private static func rank(_ outcome: AgentSessionOutcome) -> Int {
        switch outcome {
        case .sending: 0
        case .outcomeUnknown: 1
        case .recorded: 2
        case .waitingForAgent: 3
        case .agentAccepted, .notApplied: 4
        }
    }
}

/// A command this iPhone signed, by command ID.
struct AgentLocalSessionCommand: Equatable {
    let sessionID: ControlID
    let action: AgentSessionAction?
    var state: AgentSubmissionState
    let at: ControlTimestamp
}

// MARK: - Sending

/// Why a session command was not sent. Nothing is resent or retargeted: the
/// user reviews the session again (docs/specs/agent-relay.md 15.1).
enum AgentSessionSendFailure: Error, Equatable {
    case sessionChanged
    case missingGrant(DeviceGrant)
    case notOffered
    case invalid(String)
    case notRecorded(String)

    /// Only refusals that prove nothing was recorded are failures; anything
    /// ambiguous is left to the journal and reported as an outcome.
    init?(_ error: any Error) {
        switch error {
        case let error as AgentSessionCoordinator.CoordinatorError:
            switch error {
            case .sessionChanged: self = .sessionChanged
            case .missingGrant(let grant): self = .missingGrant(grant)
            case .notOffered: self = .notOffered
            case .invalid(let reason): self = .invalid(reason)
            }
        case let error as ControlError:
            switch error.code {
            case .staleVersion, .nativeContextChanged, .challengeExpired, .hashMismatch, .policyChanged:
                self = .sessionChanged
            case .deviceRevoked, .reviewerNotBound:
                // Handled as a session problem: pair again.
                return nil
            default:
                guard error.provesCommandNotRecorded else { return nil }
                self = .notRecorded(ControlCompanion.notRecordedText(error))
            }
        default:
            return nil
        }
    }

    var text: String {
        switch self {
        case .sessionChanged:
            String(localized: "The session changed — review again")
        case .missingGrant(.agentTurnsCancel):
            String(localized: "Interrupting turns is not enabled for this iPhone. On the Mac: shell-control agent grant <device-id> --cancel")
        case .missingGrant:
            String(localized: "Sending messages is not enabled for this iPhone. On the Mac: shell-control agent grant <device-id> --messages")
        case .notOffered:
            String(localized: "This session no longer offers that. Review it again.")
        case .invalid(let reason):
            String(localized: "The message cannot be sent: \(reason)")
        case .notRecorded(let reason):
            reason
        }
    }
}

enum AgentSessionSender {
    enum Result: Equatable {
        case submitted(AgentSubmissionState)
        case refused(AgentSessionSendFailure)
    }

    /// One signed submission of exactly `proposal`. A refusal is returned as
    /// is; the caller refreshes for a fresh review and never resends.
    static func send(_ proposal: AgentSessionProposal, with coordinator: AgentSessionCoordinator) async throws -> Result {
        do {
            return .submitted(try await coordinator.send(proposal.action))
        } catch {
            if let failure = AgentSessionSendFailure(error) { return .refused(failure) }
            throw error
        }
    }

    /// The command ID a recorded or ambiguous state names.
    static func commandID(of state: AgentSubmissionState) -> ControlID? {
        switch state {
        case .sending: nil
        case .responseRecorded(let result), .waitingForAgent(let result), .deliveredToAgent(let result),
             .agentAccepted(let result), .notApplied(let result):
            result.commandID
        case .outcomeUnknown(let commandID, _): commandID
        }
    }
}

// MARK: - Words

extension ControlAgentText {
    static func turn(_ session: AgentSessionProjection) -> String {
        switch session.turnState {
        case .idle?: String(localized: "Idle")
        case .active?: String(localized: "Turn running")
        case nil: String(localized: "Not reported")
        }
    }

    /// A provider turn ID is agent-supplied text.
    static func turnID(_ id: String) -> String {
        DisplaySanitizer.sanitize(id, maxScalars: 256).text
    }

    static func target(_ target: AgentSessionProposal.Target) -> String {
        switch target {
        case .newTurn: String(localized: "Starts a new turn")
        case .steer(let id): String(localized: "Steers turn \(turnID(id))")
        case .cancel(let id): String(localized: "Interrupts turn \(turnID(id))")
        }
    }

    static func sessionCommand(_ action: AgentSessionAction?) -> String {
        switch action {
        case .message(_, _, _, .newTurn, _, _)?: String(localized: "New instruction")
        case .message(_, _, _, .steer, let id, _)?: String(localized: "Steering turn \(turnID(id ?? ""))")
        case .cancel(_, _, _, let id)?: String(localized: "Interrupt turn \(turnID(id))")
        case nil: String(localized: "Session command")
        }
    }

    static func draftProblem(_ problem: AgentMessageDraft.DraftError) -> String? {
        switch problem {
        case .empty: nil
        case .tooLong(let bytes): String(localized: "Too long: \(bytes) of \(AgentMessageDraft.maximumBytes) bytes")
        case .controlCharacters: String(localized: "Plain text only: remove control characters.")
        case .notOffered: String(localized: "This session does not report its turn state, so a message cannot be bound to it.")
        }
    }
}
