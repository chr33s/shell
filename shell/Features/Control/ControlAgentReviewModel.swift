//
//  ControlAgentReviewModel.swift
//  shell
//
//  Plain, testable review logic for agent requests on the phone: the exact
//  operation as display lines and the words for every delivery state (the
//  typed-answer draft is Core's `InputAnswerDraft`). Everything
//  agent-supplied is untrusted text and is sanitized before display
//  (spec.agent-relay.md sections 6.3, 7, 13.1, 17.2).
//

import Foundation
import ShellControlProtocol
import ShellControlClient

// MARK: - Exact operation

/// The exact `agent.tool.v1` operation as the review screen shows it. If any
/// authorization-relevant field would not fit, `isTruncated` is set and
/// approval must be refused here in favour of native review on the Mac
/// (spec.agent-relay.md sections 13.1 and 17.2).
struct AgentOperationDisplay: Equatable {
    struct Option: Equatable {
        let name: String
        let value: DisplaySanitizer.Result
    }

    struct FileChange: Equatable {
        let path: DisplaySanitizer.Result
        let change: AgentFileChange.Change
        let baseSHA256: String?
        /// One sanitized line per diff line, so a control character can never
        /// hide inside a line or fake a line break.
        let diffLines: [DisplaySanitizer.Result]
    }

    /// A committed operation is at most 32 KiB, so this budget shows every
    /// supported operation in full; exceeding it is a stop, not a trim.
    static let maximumScalars = AgentPolicy.maximumOperationBytes

    let kind: AgentToolKind
    let toolName: DisplaySanitizer.Result
    let cwd: DisplaySanitizer.Result?
    /// A command string, split only at its real line breaks.
    let commandLines: [DisplaySanitizer.Result]
    /// A true argument vector, one line per argument.
    let argv: [DisplaySanitizer.Result]
    let shellIdentity: DisplaySanitizer.Result?
    let options: [Option]
    let fileChanges: [FileChange]
    /// The provider's own explanation: shown, labelled as agent-provided.
    let reason: DisplaySanitizer.Result?
    let permissionScope: String
    let unavailable: [String]

    init(_ operation: AgentToolOperation) {
        let budget = Self.maximumScalars
        kind = operation.kind
        toolName = DisplaySanitizer.sanitize(operation.toolName, maxScalars: 128)
        cwd = operation.cwd.map { DisplaySanitizer.sanitize($0, maxScalars: 4096) }
        let shell = operation.shellRequest
        commandLines = shell?.command.map { command in
            command.split(separator: "\n", omittingEmptySubsequences: false)
                .map { DisplaySanitizer.sanitize(String($0), maxScalars: budget) }
        } ?? []
        argv = shell?.argv.map { DisplaySanitizer.argumentLines($0, maxScalars: budget) } ?? []
        shellIdentity = shell?.shellIdentity.map { DisplaySanitizer.sanitize($0, maxScalars: 1024) }
        options = (shell?.options ?? [:]).sorted { $0.key < $1.key }.map { name, value in
            Option(name: name, value: DisplaySanitizer.sanitize(value.displayText, maxScalars: 1024))
        }
        fileChanges = (operation.fileChanges ?? []).map { change in
            FileChange(
                path: DisplaySanitizer.sanitize(change.path, maxScalars: 4096),
                change: change.change,
                baseSHA256: change.baseSHA256,
                diffLines: change.diff.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { DisplaySanitizer.sanitize(String($0), maxScalars: budget) }
            )
        }
        reason = operation.reason.map { DisplaySanitizer.sanitize($0, maxScalars: 2048) }
        permissionScope = operation.permissionScope
        unavailable = operation.unavailable
    }

    /// Whether anything authorization-relevant could not be shown in full.
    var isTruncated: Bool {
        let results: [DisplaySanitizer.Result] = [toolName] + [cwd, shellIdentity].compactMap { $0 }
            + commandLines + argv + options.map(\.value)
            + fileChanges.flatMap { [$0.path] + $0.diffLines }
        return results.contains { $0.isTruncated }
    }

    /// Whether any shown value had characters escaped.
    var didEscape: Bool {
        (commandLines + argv + fileChanges.flatMap { [$0.path] + $0.diffLines } + [cwd].compactMap { $0 })
            .contains { $0.didEscape }
    }

    /// The command string exactly, line breaks kept, escapes visible.
    var commandText: String { commandLines.map(\.text).joined(separator: "\n") }
}

// MARK: - Words

/// Words for agent state, so nothing depends on color. Each delivery state is
/// distinct: a recorded response is not agent acceptance, and acceptance is
/// not task completion (spec.agent-relay.md 13.1).
enum ControlAgentText {
    static func submission(_ state: AgentSubmissionState) -> String {
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

    /// The broker's detailed delivery dimension after a response exists.
    static func dispatch(_ dispatch: AgentDispatch) -> String {
        switch dispatch {
        case .none, .awaitingOrigin: String(localized: "Response recorded")
        case .claimed, .dispatchStarted: String(localized: "Waiting for agent")
        case .nativeResponseWritten: String(localized: "Delivered to agent")
        case .accepted: String(localized: "Agent accepted")
        case .notApplied: String(localized: "Not applied")
        case .unknown: String(localized: "Outcome unknown")
        }
    }

    static func resolution(_ projection: InputProjection) -> String {
        switch projection.resolution {
        case .pending: String(localized: "Waiting for your answer")
        case .answered, .declined: dispatch(projection.dispatch)
        case .expired: String(localized: "Expired")
        case .withdrawn: String(localized: "Withdrawn by the agent")
        }
    }

    /// The agent's own task, reported separately from delivery.
    static func operation(_ state: AgentOperationState) -> String? {
        switch state {
        case .notObserved: nil
        case .running: String(localized: "Task running")
        case .completed: String(localized: "Task completed")
        case .failed: String(localized: "Task failed")
        case .cancelled: String(localized: "Task cancelled")
        case .unknown: String(localized: "Task outcome unknown")
        }
    }

    static func provider(_ raw: String) -> String {
        switch raw {
        case "claude_code": "Claude Code"
        case "codex": "Codex"
        default: DisplaySanitizer.sanitize(raw, maxScalars: 64).text
        }
    }

    static func kind(_ kind: AgentToolKind) -> String {
        switch kind {
        case .shell: String(localized: "Shell command")
        case .fileChange: String(localized: "File change")
        case .toolCall: String(localized: "Tool call")
        case .unknown(let raw): String(localized: "Unsupported kind: \(DisplaySanitizer.sanitize(raw, maxScalars: 32).text)")
        }
    }

    static func change(_ change: AgentFileChange.Change) -> String {
        switch change {
        case .create: String(localized: "Create")
        case .modify: String(localized: "Modify")
        case .delete: String(localized: "Delete")
        }
    }

    static func review(_ minimum: MinimumReview) -> String {
        minimum == .watch
            ? String(localized: "Watch or iPhone review")
            : String(localized: "Full review (iPhone or Mac)")
    }

    static func evidence(_ evidence: AgentCompatibilityEvidence) -> String {
        switch evidence {
        case .none: String(localized: "No compatibility evidence")
        case .documented: String(localized: "Documented only")
        case .userAttested: String(localized: "Untested build allowed by you")
        case .contractTested: String(localized: "Contract tested")
        case .deviceValidated: String(localized: "Device validated")
        }
    }

    static func profile(_ profile: AgentIntegrationProfile) -> String {
        switch profile {
        case .hook: String(localized: "Native hook")
        case .managed: String(localized: "Managed session (experimental)")
        case .informational: String(localized: "Informational only")
        }
    }

    /// Whether the waiting agent is present, and how recently that was seen.
    static func freshness(_ presence: SourcePresence, now: ControlTimestamp) -> String {
        if presence.isFresh(at: now) { return String(localized: "Agent is waiting") }
        if let seen = presence.lastSeenAt {
            return String(localized: "Agent last seen \(seen.date.formatted(date: .omitted, time: .standard))")
        }
        return String(localized: "Agent not seen waiting")
    }

    /// Where to look on the Mac. Navigation text only: Shell never sends
    /// keystrokes to the pane (spec.agent-relay.md section 14.1).
    static func terminal(_ location: TerminalLocation) -> String {
        String(localized: "tmux session \(location.sessionID), window \(location.windowID), pane \(location.paneID)")
    }

    static func reviewElsewhere(_ reason: WatchApprovability.Reason) -> String {
        switch reason {
        case .unknownOperationSchema, .unsupportedRequiredFeature:
            String(localized: "This question is not supported on this iPhone. Answer it on the Mac.")
        case .policyRequiresFullReview:
            String(localized: "Policy requires review on another device")
        case .alreadyResolved:
            String(localized: "Already resolved")
        case .expired:
            String(localized: "Expired")
        case .sourceNotPresent:
            String(localized: "The agent is not waiting right now")
        }
    }

    static func coordinatorError(_ error: AgentInputCoordinator.CoordinatorError) -> String {
        switch error {
        case .notAnswerableHere(let reason): reviewElsewhere(reason)
        case .requestChangedDuringReview: String(localized: "This question changed while you were reviewing it. Review it again.")
        case .missingGrant: String(localized: "Answering agent questions is not enabled for this iPhone. On the Mac: shell-control agent grant")
        case .invalidResponse(let reason): String(localized: "The answer does not fit the question: \(reason)")
        }
    }
}
