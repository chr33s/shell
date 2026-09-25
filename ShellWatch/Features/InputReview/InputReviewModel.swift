import Foundation
import ShellControlProtocol
import ShellControlClient

/// Whether this Watch may answer a typed question right now, and if not,
/// why. Only a narrow question — at most two questions, four choices each,
/// or short explicitly permitted text — that was fetched live through a
/// reachable iPhone can be answered here (spec.agent-relay.md section 13.2).
enum WatchInputEligibility: Equatable {
    case answerable
    /// The question itself needs the iPhone or Mac: too complex, full review,
    /// expired, resolved, unsupported, or the agent is not waiting.
    case reviewOnIPhone(WatchApprovability.Reason)
    /// The iPhone is not reachable. Cached details stay readable; nothing
    /// can be signed or queued.
    case iPhoneUnavailable
    /// Shown from the cache and not yet confirmed live: stale, readable only.
    case stale

    static func evaluate(
        _ record: InputRecord,
        now: ControlTimestamp,
        gatewayReachable: Bool,
        fetchedLive: Bool
    ) -> WatchInputEligibility {
        if case .reviewElsewhere(let reason) = record.answerability(at: now, review: .watch) {
            return .reviewOnIPhone(reason)
        }
        guard gatewayReachable else { return .iPhoneUnavailable }
        guard fetchedLive else { return .stale }
        return .answerable
    }

    var permitsSubmission: Bool { self == .answerable }

    /// A decline, like a reject, does not need the agent's live presence, but
    /// it still needs the offered decline, a live fetch, and the iPhone.
    static func permitsDecline(
        _ record: InputRecord,
        now: ControlTimestamp,
        gatewayReachable: Bool,
        fetchedLive: Bool
    ) -> Bool {
        guard record.spec.allowedResponses.contains(.decline), gatewayReachable, fetchedLive else { return false }
        switch record.answerability(at: now, review: .watch) {
        case .approvable, .reviewElsewhere(reason: .sourceNotPresent): return true
        default: return false
        }
    }
}

/// The Watch's in-progress answer: Core's `InputAnswerDraft` plus the
/// user's confirmation. Dictated or scribbled text is only ever a draft:
/// nothing can be signed until the user has confirmed the exact response on
/// the final screen, and any later edit withdraws that confirmation
/// (spec.agent-relay.md sections 7.3 and 13.2).
struct WatchAnswerDraft: Equatable {
    /// Selections and draft text, as dictation or Scribble produced it.
    private(set) var answers = InputAnswerDraft()
    /// Exactly what the user confirmed; nil until then.
    private(set) var confirmed: InputResponse?

    /// Single choice replaces; multi choice toggles and stops at the
    /// committed maximum. Any tap on a choice withdraws the confirmation.
    mutating func select(_ choiceID: String, in question: InputQuestion) {
        guard question.kind.choices.contains(where: { $0.id == choiceID }) else { return }
        answers.select(choiceID, in: question)
        confirmed = nil
    }

    /// A dictation or Scribble result. It replaces the draft and withdraws
    /// any earlier confirmation.
    mutating func setDraftText(_ text: String, for question: InputQuestion) {
        guard case .text = question.kind else { return }
        answers.setText(text, for: question)
        confirmed = nil
    }

    /// The deterministic response for the confirmation screen. Nil when
    /// incomplete or invalid.
    func proposedResponse(for spec: InputSpec) -> InputResponse? {
        try? answers.response(for: spec)
    }

    /// Records the user's explicit yes to `shown`, which must be exactly the
    /// current draft's response.
    @discardableResult
    mutating func confirm(_ shown: InputResponse, for spec: InputSpec) -> Bool {
        guard let proposed = proposedResponse(for: spec), proposed == shown else { return false }
        confirmed = shown
        return true
    }

    /// The only response the Watch may sign: confirmed, and unchanged since.
    func confirmedResponse(for spec: InputSpec) -> InputResponse? {
        guard let confirmed, confirmed == proposedResponse(for: spec) else { return nil }
        return confirmed
    }
}

/// Words for agent answer states, each distinct: recorded is not accepted,
/// and accepted is not task completion (spec.agent-relay.md 13.1).
enum AgentSubmissionLabel {
    static func text(_ state: AgentSubmissionState) -> String {
        switch state {
        case .sending: String(localized: "Sending")
        case .responseRecorded: String(localized: "Response recorded")
        case .waitingForAgent: String(localized: "Waiting for agent")
        case .deliveredToAgent: String(localized: "Delivered to agent")
        case .agentAccepted: String(localized: "Agent accepted")
        case .notApplied: String(localized: "Not applied")
        case .outcomeUnknown: String(localized: "Outcome unknown")
        }
    }

    static func resolution(_ projection: InputProjection) -> String {
        switch projection.resolution {
        case .pending: return String(localized: "Waiting for an answer")
        case .expired: return String(localized: "Expired")
        case .withdrawn: return String(localized: "Withdrawn")
        case .answered, .declined:
            switch projection.dispatch {
            case .none, .awaitingOrigin: return String(localized: "Response recorded")
            case .claimed, .dispatchStarted: return String(localized: "Waiting for agent")
            case .nativeResponseWritten: return String(localized: "Delivered to agent")
            case .accepted: return String(localized: "Agent accepted")
            case .notApplied: return String(localized: "Not applied")
            case .unknown: return String(localized: "Outcome unknown")
            }
        }
    }

    static func provider(_ raw: String) -> String {
        switch raw {
        case "claude_code": "Claude Code"
        case "codex": "Codex"
        default: DisplaySanitizer.sanitize(raw, maxScalars: 32).text
        }
    }

    static func reviewOnIPhone(_ reason: WatchApprovability.Reason) -> String {
        switch reason {
        case .alreadyResolved: String(localized: "Already resolved")
        case .expired: String(localized: "Expired")
        case .sourceNotPresent: String(localized: "The agent is not waiting right now")
        case .unknownOperationSchema, .unsupportedRequiredFeature, .policyRequiresFullReview:
            String(localized: "Review on iPhone")
        }
    }
}
