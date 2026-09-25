import SwiftUI
import ShellControlProtocol
import ShellControlClient

/// The review screen. It fetches the current request live through the iPhone
/// before enabling any decision, shows the exact argument vector and working directory, escapes
/// control and bidi characters, and never silently truncates an
/// authorization-relevant argument (docs/specs/control-protocol.md section 11.2). A request ID
/// that names an agent question instead opens question review
/// (docs/specs/agent-relay.md section 11.3).
struct ApprovalReviewView: View {
    @Environment(ControlSession.self) private var session
    let requestID: ControlID

    @State private var record: ApprovalRecord?
    @State private var input: InputRecord?
    @State private var loadError: String?
    @State private var confirming: ControlDecision?

    var body: some View {
        Group {
            if let input {
                InputReviewView(requestID: requestID, initial: input)
            } else if let record {
                content(record)
            } else if let loadError {
                ContentUnavailableView(
                    String(localized: "Cannot review"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(String(localized: "Review"))
        .task { await load() }
    }

    private func load() async {
        do {
            record = try await session.fetchForReview(requestID)
        } catch let error as ControlError where error.code == .notFound && input == nil {
            // Questions reuse the approval hint: try the agent extension.
            if let found = try? await session.fetchInputForReview(requestID) {
                input = found
            } else {
                loadError = String(describing: error)
            }
        } catch {
            loadError = String(describing: error)
        }
    }

    @ViewBuilder
    private func content(_ record: ApprovalRecord) -> some View {
        let now = ControlTimestamp(session.currentDate)
        let approvability = record.watchApprovability(at: now)
        List {
            Section {
                if SetupTestFixture.matches(record.spec) {
                    // A label only: the decision is still this Watch's own
                    // signed, live decision (docs/specs/control-setup.md 8).
                    Label(String(localized: "Setup test — nothing will run"), systemImage: "checkmark.shield")
                        .font(.caption)
                }
                Text(DisplaySanitizer.sanitize(record.spec.summary, maxScalars: 200).text)
                    .font(.headline)
                LabeledContent(String(localized: "Origin"), value: shortID(record.spec.originID))
                LabeledContent(String(localized: "Job"), value: shortID(record.spec.jobID))
                LabeledContent(String(localized: "Run"), value: shortID(record.spec.runID))
                ExpiryLabel(expiresAt: record.spec.expiresAt)
            }

            Section(String(localized: "Operation")) {
                switch record.spec.operation {
                case .exec(let operation):
                    LabeledContent(String(localized: "Working directory")) {
                        Text(DisplaySanitizer.sanitize(operation.cwd, maxScalars: 512).text)
                            .font(.system(.caption, design: .monospaced))
                    }
                    // One line per argument, so a space inside an argument can
                    // never look like an argument boundary.
                    ForEach(Array(DisplaySanitizer.argumentLines(operation.argv).enumerated()), id: \.offset) { index, line in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("argv[\(index)]")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                            if line.didEscape {
                                Label(String(localized: "Contains escaped characters"), systemImage: "eye.trianglebadge.exclamationmark")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if line.isTruncated {
                                Label(String(localized: "Too long to show fully — review elsewhere"), systemImage: "text.append")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                case .agentTool(let operation):
                    AgentOperationRows(operation: operation)
                case .unknown(let schema, _):
                    Label(
                        String(localized: "Unsupported operation: \(schema)"),
                        systemImage: "questionmark.square.dashed"
                    )
                }
            }

            Section(String(localized: "Status")) {
                Text(ResolutionLabel.text(record.projection))
                if let state = session.submissions[record.spec.requestID] {
                    Text(SubmissionLabel.text(state))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !record.projection.presence.isFresh(at: now) {
                    Label(String(localized: "The waiting host is not currently present"), systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.caption2)
                }
            }

            Section {
                switch approvability {
                case .approvable where AgentOperationRows.hidesContent(record.spec.operation):
                    // Hidden or truncated content prevents confirmation.
                    Label(String(localized: "Review on another device: too long to show here"), systemImage: "iphone.and.arrow.forward")
                        .font(.caption2)
                case .approvable:
                    Button(String(localized: "Approve once")) { confirming = .approve }
                        .disabled(!session.isGatewayReachable)
                case .reviewElsewhere(let reason):
                    // No approval path: the Watch says so instead of degrading
                    // to a weaker check.
                    Label(reviewElsewhereText(reason), systemImage: "iphone.and.arrow.forward")
                        .font(.caption2)
                }
                if record.canReject(at: now) {
                    Button(String(localized: "Reject"), role: .destructive) { confirming = .reject }
                        .disabled(!session.isGatewayReachable)
                }
                if !session.isGatewayReachable {
                    // Decisions need a live iPhone round trip; nothing is
                    // queued for later (docs/specs/control-protocol.md 10.2).
                    Text(String(localized: "iPhone unavailable — no decision is queued"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let problem = session.gatewayProblem {
                    Text(problem)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let problem = session.decisionProblems[record.spec.requestID] {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                }
            }
        }
        // An explicit confirmation for every decision. There is no "approve
        // all", no long-lived grant, and no approval from a complication.
        .confirmationDialog(
            confirming == .approve
                ? String(localized: "Approve this one request?")
                : String(localized: "Reject this request?"),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            if let decision = confirming {
                Button(decision == .approve ? String(localized: "Approve once") : String(localized: "Reject")) {
                    Task {
                        await session.decide(decision, on: record)
                        await load()
                    }
                    confirming = nil
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { confirming = nil }
        }
    }

    private func reviewElsewhereText(_ reason: WatchApprovability.Reason) -> String {
        switch reason {
        case .unknownOperationSchema, .unsupportedRequiredFeature:
            return String(localized: "Review on another device: this operation is not supported here")
        case .policyRequiresFullReview:
            return String(localized: "Review on another device: fuller review required")
        case .alreadyResolved:
            return String(localized: "Already resolved")
        case .expired:
            return String(localized: "Expired")
        case .sourceNotPresent:
            return String(localized: "The host is not waiting right now")
        }
    }

    private func shortID(_ id: ControlID) -> String {
        String(id.rawValue.prefix(8))
    }
}

enum SubmissionLabel {
    static func text(_ state: SubmissionState) -> String {
        switch state {
        case .sending: return String(localized: "Sending")
        case .decisionRecorded: return String(localized: "Decision recorded")
        case .waitingForHost: return String(localized: "Waiting for host")
        case .hostAccepted: return String(localized: "Host accepted")
        case .notApplied: return String(localized: "Not applied")
        case .outcomeUnknown: return String(localized: "Outcome unknown")
        }
    }
}

/// The exact `agent.tool.v1` shell request: the command string as sent (or
/// one line per argument), the working directory, and every option, escaped
/// visibly. Other kinds are shown by kind only; the approvability check
/// already sends them to the iPhone (docs/specs/agent-relay.md sections 5.3 and
/// 13.2).
struct AgentOperationRows: View {
    struct Option {
        let name: DisplaySanitizer.Result
        let value: DisplaySanitizer.Result
    }

    let operation: AgentToolOperation

    /// Watch-eligible shell commands are at most 160 bytes, so this budget
    /// never trims one; anything that would be trimmed is not approvable here.
    static let maximumScalars = 512

    static func hidesContent(_ operation: ControlOperation) -> Bool {
        guard case .agentTool(let agent) = operation else { return false }
        return lines(agent).contains { $0.isTruncated }
            || options(agent).contains { $0.name.isTruncated || $0.value.isTruncated }
            || agent.cwd.map { DisplaySanitizer.sanitize($0, maxScalars: maximumScalars).isTruncated } ?? false
    }

    /// Every shell option, by name. The Watch cannot approve a request with
    /// options, but its review still shows them all before a reject.
    static func options(_ operation: AgentToolOperation) -> [Option] {
        (operation.shellRequest?.options ?? [:]).sorted { $0.key < $1.key }.map { name, value in
            Option(
                name: DisplaySanitizer.sanitize(name, maxScalars: maximumScalars),
                value: DisplaySanitizer.sanitize(value.displayText, maxScalars: maximumScalars)
            )
        }
    }

    static func lines(_ operation: AgentToolOperation) -> [DisplaySanitizer.Result] {
        guard let shell = operation.shellRequest else { return [] }
        if let command = shell.command { return [DisplaySanitizer.sanitize(command, maxScalars: maximumScalars)] }
        return DisplaySanitizer.argumentLines(shell.argv ?? [], maxScalars: maximumScalars)
    }

    var body: some View {
        Text(verbatim: AgentSubmissionLabel.provider(operation.provider) + " · " + operation.kind.rawValue)
            .font(.caption2)
            .foregroundStyle(.secondary)
        if case .shell = operation.kind, let shell = operation.shellRequest {
            if let cwd = operation.cwd {
                LabeledContent(String(localized: "Working directory")) {
                    Text(verbatim: DisplaySanitizer.sanitize(cwd, maxScalars: Self.maximumScalars).text)
                        .font(.system(.caption, design: .monospaced))
                }
            }
            let lines = Self.lines(operation)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: shell.representation == .argv ? "argv[\(index)]" : String(localized: "Command"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(verbatim: line.text)
                        .font(.system(.caption, design: .monospaced))
                    if line.didEscape {
                        Label(String(localized: "Contains escaped characters"), systemImage: "eye.trianglebadge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            ForEach(Array(Self.options(operation).enumerated()), id: \.offset) { _, option in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: option.name.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(verbatim: option.value.text)
                        .font(.system(.caption, design: .monospaced))
                    if option.name.didEscape || option.value.didEscape {
                        Label(String(localized: "Contains escaped characters"), systemImage: "eye.trianglebadge.exclamationmark")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if let reason = operation.reason {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "Reason (agent)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "“" + DisplaySanitizer.sanitize(reason, maxScalars: 2048).text + "”")
                        .font(.caption2)
                }
            }
        } else {
            Label(String(localized: "Review on iPhone"), systemImage: "iphone.and.arrow.forward")
                .font(.caption2)
        }
    }
}
