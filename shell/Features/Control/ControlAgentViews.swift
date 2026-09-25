//
//  ControlAgentViews.swift
//  shell
//
//  The phone's unified agent view: agent approvals, typed questions, and
//  recent outcomes. Every item keeps the trusted host identity apart from
//  agent-supplied text, and every detail renders the exact operation or
//  question rather than a friendly summary (docs/specs/agent-relay.md sections
//  13.1 and 17.2).
//

import SwiftUI
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

// MARK: - Section

/// Settings → Control → Agents. Hidden entirely when the Mac has no agent
/// extension and nothing agent-shaped is pending.
struct ControlAgentSection: View {
    let companion: ControlCompanion

    var body: some View {
        let agent = companion.agent
        let approvals = companion.agentPending
        let questions = agent.inbox.pendingInputs
        if agent.availability != .unsupported || !approvals.isEmpty || !companion.agentApprovalOutcomes.isEmpty {
            Section {
                if agent.availability == .notEnabled {
                    Text(String(localized: "Agent questions are not enabled for this iPhone. To enable them, run shell-control agent grant on the Mac."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .themedRow()
                }
                if approvals.isEmpty && questions.isEmpty && agent.inbox.unsupportedInputs.isEmpty {
                    Text(String(localized: "No agent is waiting.")).foregroundStyle(.secondary).themedRow()
                }
                ForEach(approvals, id: \.spec.requestID) { record in
                    NavigationLink {
                        ControlReviewView(companion: companion, requestID: record.spec.requestID)
                    } label: {
                        ControlAgentApprovalRow(companion: companion, record: record)
                    }
                    .themedRow()
                }
                ForEach(questions, id: \.spec.requestID) { record in
                    NavigationLink {
                        ControlAgentInputView(companion: companion, requestID: record.spec.requestID)
                    } label: {
                        ControlAgentInputRow(companion: companion, record: record)
                    }
                    .themedRow()
                }
                // Managed sessions only; a hook session has nothing to send.
                ForEach(agent.managedSessions, id: \.registration.agentSessionID) { session in
                    NavigationLink {
                        ControlAgentSessionView(companion: companion, sessionID: session.registration.agentSessionID)
                    } label: {
                        ControlAgentSessionRow(session: session)
                    }
                    .themedRow()
                }
                if !agent.inbox.unsupportedInputs.isEmpty {
                    // Never answerable here, and never silently dropped.
                    Label(String(localized: "\(agent.inbox.unsupportedInputs.count) questions need review on the Mac"),
                          systemImage: "desktopcomputer")
                        .font(.footnote)
                        .themedRow()
                }
                NavigationLink(String(localized: "Recent agent outcomes")) {
                    ControlAgentOutcomesView(companion: companion)
                }
                .themedRow()
                if agent.inbox.omitsOlderOutcomes {
                    Text(String(localized: "Too much agent history to list in full. Pending requests are shown; older outcomes are omitted."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .themedRow()
                }
                if let problem = agent.problem {
                    Text(problem).font(.footnote).foregroundStyle(.secondary).themedRow()
                }
            } header: {
                Text(String(localized: "Agents"))
            } footer: {
                if let refreshed = agent.inbox.lastRefreshedAt {
                    Text(String(localized: "Agent state updated \(refreshed.date.formatted(date: .omitted, time: .standard)). A recorded response is not agent acceptance."))
                } else {
                    Text(String(localized: "Claude Code and Codex requests from your Mac. A recorded response is not agent acceptance."))
                }
            }
        }
    }
}

// MARK: - Rows

/// Trusted identity first, then the agent's own words, clearly attributed.
struct ControlAgentApprovalRow: View {
    let companion: ControlCompanion
    let record: ApprovalRecord

    var body: some View {
        let now = ControlTimestamp(Date())
        VStack(alignment: .leading, spacing: 2) {
            if case .agentTool(let operation) = record.spec.operation {
                ControlAgentContextLine(
                    kind: ControlAgentText.kind(operation.kind),
                    provider: operation.provider,
                    session: companion.agent.inbox.session(operation.agentSessionID)
                )
            }
            ControlAgentSuppliedText(text: record.spec.summary, maxScalars: 120)
            ControlAgentItemFooter(
                expiresAt: record.spec.expiresAt,
                review: record.spec.minimumReview,
                freshness: ControlAgentText.freshness(record.projection.presence, now: now)
            )
        }
    }
}

struct ControlAgentInputRow: View {
    let companion: ControlCompanion
    let record: InputRecord

    var body: some View {
        let now = ControlTimestamp(Date())
        VStack(alignment: .leading, spacing: 2) {
            ControlAgentContextLine(
                kind: String(localized: "Question"),
                provider: record.spec.source.provider,
                session: companion.agent.inbox.session(record.spec.source.agentSessionID)
            )
            ControlAgentSuppliedText(text: record.spec.summary, maxScalars: 120)
            ControlAgentItemFooter(
                expiresAt: record.spec.expiresAt,
                review: record.spec.minimumReview,
                freshness: ControlAgentText.freshness(record.projection.presence, now: now)
            )
        }
    }
}

/// Request kind and provider/session context. Provider names come from the
/// broker's registration, not from the agent's text.
struct ControlAgentContextLine: View {
    let kind: String
    let provider: String
    let session: AgentSessionProjection?

    var body: some View {
        HStack(spacing: 4) {
            Text(kind).font(.caption.weight(.semibold))
            Text(verbatim: "·").font(.caption)
            Text(ControlAgentText.provider(provider)).font(.caption)
            if let session, session.state == .ended {
                Text(String(localized: "(session ended)")).font(.caption)
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// Agent-supplied text: sanitized, quoted, and labelled as coming from the
/// agent, so it cannot pass for Shell's own words (docs/specs/agent-relay.md 16.2).
struct ControlAgentSuppliedText: View {
    let text: String
    var maxScalars = 200
    var font: Font = .body

    var body: some View {
        let sanitized = DisplaySanitizer.sanitize(text, maxScalars: maxScalars)
        // Verbatim: agent text is never a localization key.
        Text(verbatim: "“" + sanitized.text + (sanitized.isTruncated ? "…" : "") + "”")
            .font(font)
            .accessibilityLabel(String(localized: "Agent says: \(sanitized.text)"))
    }
}

struct ControlAgentItemFooter: View {
    let expiresAt: ControlTimestamp
    let review: MinimumReview
    let freshness: String

    var body: some View {
        Text(String(localized: "Expires \(expiresAt.date.formatted(date: .omitted, time: .shortened)) · \(ControlAgentText.review(review)) · \(freshness)"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Shared detail sections

/// The trusted side of a request: the paired Mac's key and the broker's
/// own identifiers. Nothing here came from the agent.
struct ControlAgentTrustedHostSection: View {
    let companion: ControlCompanion
    let originID: ControlID
    let runID: ControlID
    let expiresAt: ControlTimestamp
    let review: MinimumReview
    let freshness: String
    let digest: String

    var body: some View {
        Section {
            if let fingerprint = companion.originFingerprint {
                LabeledContent(String(localized: "Paired Mac")) {
                    Text(fingerprint).font(.footnote.monospaced())
                }
            }
            LabeledContent(String(localized: "Origin"), value: originID.rawValue)
                .font(.footnote)
            LabeledContent(String(localized: "Run"), value: runID.rawValue)
                .font(.footnote)
            LabeledContent(String(localized: "Expires"), value: expiresAt.date.formatted(date: .omitted, time: .standard))
            LabeledContent(String(localized: "Review"), value: ControlAgentText.review(review))
            LabeledContent(String(localized: "Freshness"), value: freshness)
            LabeledContent(String(localized: "Digest")) {
                Text(digest).font(.footnote.monospaced())
            }
        } header: {
            Text(String(localized: "Trusted host"))
        } footer: {
            Text(String(localized: "Verified by your paired Mac. Everything quoted below comes from the agent and is untrusted."))
        }
    }
}

/// Provider and session as the Mac registered them, plus where the agent's
/// terminal was last seen. The location is navigation text only: Shell sends
/// no keystrokes to it (docs/specs/agent-relay.md section 13.1).
struct ControlAgentSessionSection: View {
    let provider: String
    let providerBuild: String
    let session: AgentSessionProjection?

    var body: some View {
        Section {
            LabeledContent(String(localized: "Provider"), value: ControlAgentText.provider(provider))
            LabeledContent(String(localized: "Build"), value: DisplaySanitizer.sanitize(providerBuild, maxScalars: 64).text)
            if let session {
                LabeledContent(String(localized: "Integration"), value: ControlAgentText.profile(session.registration.profile))
                LabeledContent(String(localized: "Compatibility"), value: ControlAgentText.evidence(session.registration.evidence))
                LabeledContent(String(localized: "Session"), value: session.state == .active ? String(localized: "Active") : String(localized: "Ended"))
                if let status = session.status {
                    LabeledContent(String(localized: "Agent status")) {
                        ControlAgentSuppliedText(text: status, maxScalars: 200, font: .footnote)
                    }
                }
                if let location = session.registration.terminalLocation {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Open terminal")).font(.subheadline)
                        Text(ControlAgentText.terminal(location)).font(.footnote.monospaced())
                        Text(String(localized: "On your Mac, as seen \(location.observedAt.date.formatted(date: .omitted, time: .shortened)). Navigation only: nothing is typed into it."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(String(localized: "Agent"))
        }
    }
}

/// The exact `agent.tool.v1` operation. Shell commands show the exact
/// command string (or true argv), working directory, options, scope, and
/// what the adapter could not observe; file changes show every path, change
/// kind, and the complete diff (docs/specs/agent-relay.md section 5.3).
struct ControlAgentOperationSections: View {
    let operation: AgentToolOperation

    var body: some View {
        let display = AgentOperationDisplay(operation)
        Section {
            LabeledContent(String(localized: "Kind"), value: ControlAgentText.kind(operation.kind))
            LabeledContent(String(localized: "Tool"), value: display.toolName.text)
            if let cwd = display.cwd {
                LabeledContent(String(localized: "Working directory")) {
                    Text(cwd.text).font(.footnote.monospaced())
                }
            }
            switch operation.kind {
            case .shell:
                if !display.commandLines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Command (exact string)")).font(.caption).foregroundStyle(.secondary)
                        Text(display.commandText)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        if display.commandLines.count > 1 {
                            Text(String(localized: "\(display.commandLines.count) lines")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                // A true argument vector: one line per argument.
                ForEach(Array(display.argv.enumerated()), id: \.offset) { index, line in
                    LabeledContent("argv[\(index)]") {
                        Text(line.text).font(.footnote.monospaced())
                    }
                }
                LabeledContent(String(localized: "Shell"), value: display.shellIdentity?.text ?? String(localized: "Not identified by the adapter"))
                ForEach(display.options, id: \.name) { option in
                    LabeledContent(option.name) {
                        Text(option.value.text).font(.footnote.monospaced())
                    }
                }
            case .fileChange:
                EmptyView()
            case .toolCall, .unknown:
                Label(String(localized: "This kind of operation cannot be reviewed on this iPhone. Review it on the Mac."),
                      systemImage: "desktopcomputer")
            }
            LabeledContent(String(localized: "Scope"), value: operation.permissionScope == AgentPermissionScope.singleNativeGate
                ? String(localized: "One native permission gate")
                : DisplaySanitizer.sanitize(operation.permissionScope, maxScalars: 64).text)
            if !display.unavailable.isEmpty {
                LabeledContent(String(localized: "Not observable")) {
                    Text(display.unavailable.joined(separator: ", ")).font(.footnote.monospaced())
                }
            }
            if display.didEscape {
                Label(String(localized: "Contains escaped characters"), systemImage: "eye.trianglebadge.exclamationmark")
                    .font(.footnote)
            }
            if display.isTruncated {
                Label(String(localized: "Too large to show in full. Review it on the Mac."), systemImage: "desktopcomputer")
                    .font(.footnote)
            }
        } header: {
            Text(String(localized: "Operation"))
        }
        if case .fileChange = operation.kind {
            ForEach(Array(display.fileChanges.enumerated()), id: \.offset) { _, change in
                Section {
                    LabeledContent(String(localized: "Change"), value: ControlAgentText.change(change.change))
                    LabeledContent(String(localized: "Base SHA-256")) {
                        Text(change.baseSHA256 ?? String(localized: "None (new file)")).font(.caption2.monospaced())
                    }
                    ScrollView(.horizontal) {
                        Text(change.diffLines.map(\.text).joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } header: {
                    Text(change.path.text).font(.footnote.monospaced()).textCase(nil)
                }
            }
        }
        if let reason = operation.reason {
            Section {
                ControlAgentSuppliedText(text: reason, maxScalars: 2048, font: .footnote)
            } header: {
                Text(String(localized: "Reason (agent-provided)"))
            } footer: {
                Text(String(localized: "The agent's own words. They have no effect on what is authorized."))
            }
        }
    }
}

// MARK: - Question review

/// Reviews and answers one typed question. The exact question is fetched
/// live; the answer is shown in full on a confirmation screen before this
/// iPhone signs it (docs/specs/agent-relay.md sections 6, 7.2, and 12.1).
struct ControlAgentInputView: View {
    let companion: ControlCompanion
    let requestID: ControlID
    var initial: InputRecord?

    @State private var record: InputRecord?
    @State private var failure: String?
    @State private var draft = InputAnswerDraft()
    @State private var confirming: InputResponse?
    @State private var confirmingDecline = false

    var body: some View {
        Group {
            if let record {
                form(record)
            } else if let failure {
                ContentUnavailableView(
                    String(localized: "Cannot review"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure)
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(String(localized: "Agent question"))
        .task {
            if let initial, record == nil { record = initial } else { await load() }
        }
        .task(id: isFollowingDelivery) {
            // Follow delivery while an answer is in flight, no faster than
            // the poll floor; recorded is not accepted.
            while isFollowingDelivery, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ControlAgentCenter.minimumInterval))
                if Task.isCancelled { break }
                await companion.refresh()
                if let current = companion.agent.inbox.inputs[requestID] { record = current }
            }
        }
    }

    private var isFollowingDelivery: Bool {
        guard let state = companion.agent.submissions[requestID] else { return false }
        switch state {
        case .sending, .responseRecorded, .waitingForAgent, .deliveredToAgent, .outcomeUnknown: return true
        case .agentAccepted, .notApplied: return false
        }
    }

    private func load() async {
        do { record = try await companion.fetchInput(requestID) } catch { failure = String(describing: error) }
    }

    @ViewBuilder
    private func form(_ record: InputRecord) -> some View {
        let now = ControlTimestamp(Date())
        let answerability = record.answerability(at: now, review: ControlCompanion.review)
        let agent = companion.agent
        Form {
            Section {
                ControlAgentSuppliedText(text: record.spec.summary, maxScalars: 200, font: .headline)
            } header: {
                Text(String(localized: "Summary (agent-provided)"))
            }
            ControlAgentTrustedHostSection(
                companion: companion,
                originID: record.spec.originID,
                runID: record.spec.runID,
                expiresAt: record.spec.expiresAt,
                review: record.spec.minimumReview,
                freshness: ControlAgentText.freshness(record.projection.presence, now: now),
                digest: record.requestHash
            )
            ControlAgentSessionSection(
                provider: record.spec.source.provider,
                providerBuild: record.spec.source.providerBuild,
                session: agent.inbox.session(record.spec.source.agentSessionID)
            )
            ForEach(record.spec.questions, id: \.id) { question in
                ControlAgentQuestionSection(
                    question: question,
                    draft: $draft,
                    editable: record.projection.resolution == .pending
                )
            }
            Section(String(localized: "Status")) {
                Text(ControlAgentText.resolution(record.projection))
                if let state = agent.submissions[requestID] {
                    Text(ControlAgentText.submission(state)).font(.footnote).foregroundStyle(.secondary)
                }
                if let task = ControlAgentText.operation(record.projection.operation) {
                    Text(task).font(.footnote)
                }
                if let problem = agent.problems[requestID] {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.footnote)
                }
            }
            actions(record, answerability: answerability, now: now)
        }
        .sheet(isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let response = confirming {
                NavigationStack {
                    ControlAgentAnswerConfirmation(spec: record.spec, response: response) {
                        confirming = nil
                        Task { await send(response, to: record) }
                    } cancel: {
                        confirming = nil
                    }
                }
            }
        }
        .confirmationDialog(
            String(localized: "Decline this question?"),
            isPresented: $confirmingDecline
        ) {
            Button(String(localized: "Decline"), role: .destructive) {
                Task { await send(.decline, to: record) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "The agent receives a decline, not an answer."))
        }
    }

    @ViewBuilder
    private func actions(_ record: InputRecord, answerability: WatchApprovability, now: ControlTimestamp) -> some View {
        let agent = companion.agent
        let proposed = try? draft.response(for: record.spec)
        let promptsFit = ControlAgentQuestionSection.fitsDisplay(record.spec)
        Section {
            Button(String(localized: "Review answer…")) { confirming = proposed }
                .disabled(answerability != .approvable || !agent.canRespond || proposed == nil || !promptsFit)
            if !promptsFit {
                Text(String(localized: "Too large to show in full. Answer it on the Mac.")).font(.footnote)
            }
            if case .reviewElsewhere(let reason) = answerability {
                Text(ControlAgentText.reviewElsewhere(reason)).font(.footnote).foregroundStyle(.secondary)
            } else if !agent.canRespond {
                Text(String(localized: "Answering is not enabled for this iPhone. On the Mac: shell-control agent grant"))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if proposed == nil {
                let missing = draft.missingRequired(in: record.spec).count
                if missing > 0 {
                    Text(String(localized: "\(missing) required questions still need an answer.")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            // Offered only when the adapter has a tested native decline.
            if record.spec.allowedResponses.contains(.decline) {
                Button(String(localized: "Decline"), role: .destructive) { confirmingDecline = true }
                    .disabled(!Self.canDecline(answerability) || !agent.canRespond)
            }
        } footer: {
            Text(String(localized: "Your answer is signed by this iPhone and sent live to your Mac. A recorded response does not mean the agent accepted it."))
        }
    }

    /// Like a reject, a decline does not need the agent's live presence.
    static func canDecline(_ answerability: WatchApprovability) -> Bool {
        switch answerability {
        case .approvable, .reviewElsewhere(reason: .sourceNotPresent): return true
        default: return false
        }
    }

    private func send(_ response: InputResponse, to record: InputRecord) async {
        await companion.respond(response, to: record)
        // Show the question as it now stands: after a refusal this is the
        // fresh review the user answers from.
        if let current = try? await companion.fetchInput(requestID) { self.record = current }
    }
}

/// One question: its exact prompt and the constrained controls for its kind.
struct ControlAgentQuestionSection: View {
    let question: InputQuestion
    @Binding var draft: InputAnswerDraft
    let editable: Bool

    /// Every prompt, label, and description is shown in full or the answer
    /// is refused here.
    static func fitsDisplay(_ spec: InputSpec) -> Bool {
        spec.questions.allSatisfy { question in
            !DisplaySanitizer.sanitize(question.prompt, maxScalars: AgentPolicy.maximumPromptBytes).isTruncated
                && question.kind.choices.allSatisfy { choice in
                    !DisplaySanitizer.sanitize(choice.label, maxScalars: AgentPolicy.maximumLabelBytes).isTruncated
                        && !DisplaySanitizer.sanitize(choice.description ?? "", maxScalars: AgentPolicy.maximumDescriptionBytes).isTruncated
                }
        }
    }

    var body: some View {
        Section {
            ControlAgentSuppliedText(text: question.prompt, maxScalars: AgentPolicy.maximumPromptBytes)
            switch question.kind {
            case .singleChoice(let choices):
                ForEach(choices, id: \.id) { choice in
                    choiceButton(choice)
                }
            case .multiChoice(let choices, let minimum, let maximum):
                Text(String(localized: "Choose \(minimum) to \(maximum). \(draft.selectionCount(for: question)) chosen."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(choices, id: \.id) { choice in
                    choiceButton(choice)
                }
            case .text(let maximumBytes, let hint):
                if let hint {
                    ControlAgentSuppliedText(text: hint, maxScalars: AgentPolicy.maximumDescriptionBytes, font: .footnote)
                        .foregroundStyle(.secondary)
                }
                TextField(String(localized: "Answer"), text: Binding(
                    get: { draft.text(for: question) },
                    set: { draft.setText($0, for: question) }
                ), axis: .vertical)
                .lineLimit(3...10)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(!editable)
                let bytes = draft.byteCount(for: question)
                Text(String(localized: "\(bytes) of \(maximumBytes) bytes"))
                    .font(.caption)
                    .foregroundStyle(bytes > maximumBytes ? .red : .secondary)
                    .accessibilityLabel(bytes > maximumBytes
                        ? String(localized: "Too long: \(bytes) of \(maximumBytes) bytes")
                        : String(localized: "\(bytes) of \(maximumBytes) bytes"))
            }
        } header: {
            Text(question.required ? String(localized: "Question (required)") : String(localized: "Question (optional)"))
        }
    }

    private func choiceButton(_ choice: InputChoice) -> some View {
        let selected = draft.isSelected(choice.id, in: question)
        return Button {
            draft.select(choice.id, in: question)
        } label: {
            HStack(alignment: .top) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplaySanitizer.sanitize(choice.label, maxScalars: AgentPolicy.maximumLabelBytes).text)
                    if let description = choice.description {
                        Text(DisplaySanitizer.sanitize(description, maxScalars: AgentPolicy.maximumDescriptionBytes).text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(!editable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The final confirmation: the exact answer that will be signed, with text
/// shown byte for byte (escapes visible) and its size
/// (docs/specs/agent-relay.md sections 6.3 and 12.1).
struct ControlAgentAnswerConfirmation: View {
    let spec: InputSpec
    let response: InputResponse
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        Form {
            ForEach(response.answers, id: \.questionID) { answer in
                Section {
                    if let question = spec.question(answer.questionID) {
                        ControlAgentSuppliedText(text: question.prompt, maxScalars: AgentPolicy.maximumPromptBytes, font: .footnote)
                            .foregroundStyle(.secondary)
                    }
                    switch answer {
                    case .singleChoice(_, let choiceID):
                        Text(label(choiceID, in: answer.questionID))
                    case .multiChoice(_, let choiceIDs):
                        ForEach(choiceIDs, id: \.self) { Text(label($0, in: answer.questionID)) }
                    case .text(_, let text):
                        let shown = DisplaySanitizer.sanitize(text, maxScalars: AgentPolicy.maximumTextAnswerBytes)
                        Text(shown.text).font(.body.monospaced()).textSelection(.enabled)
                        Text(String(localized: "\(text.utf8.count) bytes, sent exactly as shown")).font(.caption).foregroundStyle(.secondary)
                        if shown.didEscape {
                            Label(String(localized: "Contains escaped characters"), systemImage: "eye.trianglebadge.exclamationmark")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text(answer.questionID).textCase(nil)
                }
            }
            Section {
                Button(String(localized: "Sign and send answer"), action: confirm)
                Button(String(localized: "Edit answer"), role: .cancel, action: cancel)
            } footer: {
                Text(String(localized: "Sent to the agent's native question, never typed into a terminal."))
            }
        }
        .navigationTitle(String(localized: "Confirm answer"))
    }

    private func label(_ choiceID: String, in questionID: String) -> String {
        let choice = spec.question(questionID)?.kind.choices.first { $0.id == choiceID }
        let text = choice.map { DisplaySanitizer.sanitize($0.label, maxScalars: AgentPolicy.maximumLabelBytes).text } ?? choiceID
        return "\(text) (\(choiceID))"
    }
}

// MARK: - Outcomes

/// Recent answers, agent-approval outcomes, and turn results. Delivery and
/// task completion are reported separately.
struct ControlAgentOutcomesView: View {
    let companion: ControlCompanion

    var body: some View {
        let inbox = companion.agent.inbox
        List {
            Section(String(localized: "Questions")) {
                if inbox.resolvedInputs.isEmpty {
                    Text(String(localized: "None yet")).foregroundStyle(.secondary).themedRow()
                }
                ForEach(inbox.resolvedInputs, id: \.spec.requestID) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        ControlAgentSuppliedText(text: record.spec.summary, maxScalars: 80, font: .subheadline)
                        Text(ControlAgentText.resolution(record.projection)).font(.caption).foregroundStyle(.secondary)
                        if let task = ControlAgentText.operation(record.projection.operation) {
                            Text(task).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .themedRow()
                }
            }
            Section(String(localized: "Approvals")) {
                if companion.agentApprovalOutcomes.isEmpty {
                    Text(String(localized: "None yet")).foregroundStyle(.secondary).themedRow()
                }
                ForEach(companion.agentApprovalOutcomes, id: \.spec.requestID) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        ControlAgentSuppliedText(text: record.spec.summary, maxScalars: 80, font: .subheadline)
                        Text(record.projection.resolution == .approved ? String(localized: "Approved") : String(localized: "Not approved"))
                            .font(.caption).foregroundStyle(.secondary)
                        if let reference = inbox.approvals[record.spec.requestID], reference.dispatch != .none {
                            Text(ControlAgentText.dispatch(reference.dispatch)).font(.caption).foregroundStyle(.secondary)
                            if let task = ControlAgentText.operation(reference.operation) {
                                Text(task).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .themedRow()
                }
            }
            if !inbox.turnEvents.isEmpty {
                Section {
                    ForEach(inbox.turnEvents, id: \.eventID) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.type == .turnCompleted ? String(localized: "Turn completed") : String(localized: "Turn failed"))
                                .font(.subheadline)
                            if let summary = event.summary {
                                ControlAgentSuppliedText(text: summary, maxScalars: 200, font: .caption)
                            }
                            Text(event.observedAt.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .themedRow()
                    }
                } header: {
                    Text(String(localized: "Agent turns"))
                } footer: {
                    Text(String(localized: "Reported by the agent. Informational only."))
                }
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Agent outcomes"))
        .refreshable { await companion.refresh(forceAgent: true) }
    }
}
