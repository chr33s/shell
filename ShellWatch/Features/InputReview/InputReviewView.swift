import SwiftUI
import ShellControlProtocol
import ShellControlClient

/// Reviews and answers one narrow agent question on the Watch. The question
/// is fetched live through the iPhone before any control is enabled; cached
/// details stay readable, marked stale, and cannot be answered. Dictated or
/// scribbled text is a draft until the final screen confirms it exactly
/// (docs/specs/agent-relay.md section 12.2).
struct InputReviewView: View {
    @Environment(ControlSession.self) private var session
    let requestID: ControlID
    var initial: InputRecord?

    @State private var record: InputRecord?
    @State private var fetchedLive = false
    @State private var loadError: String?
    @State private var draft = WatchAnswerDraft()
    @State private var confirmingDecline = false

    var body: some View {
        Group {
            if let record {
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
        .navigationTitle(String(localized: "Question"))
        .task { await load() }
    }

    private func load() async {
        if let initial, record == nil {
            record = initial
            fetchedLive = true
            return
        }
        do {
            record = try await session.fetchInputForReview(requestID)
            fetchedLive = true
        } catch {
            // Readable from the cache, marked stale; never answerable.
            if let cached = session.agentInputs[requestID] {
                record = cached
                fetchedLive = false
            } else {
                loadError = String(describing: error)
            }
        }
    }

    @ViewBuilder
    private func content(_ record: InputRecord) -> some View {
        let now = ControlTimestamp(session.currentDate)
        let eligibility = WatchInputEligibility.evaluate(
            record, now: now, gatewayReachable: session.isGatewayReachable, fetchedLive: fetchedLive
        )
        let editable = eligibility.permitsSubmission
        List {
            Section {
                // Agent-supplied text, sanitized and attributed.
                Text(verbatim: "“" + DisplaySanitizer.sanitize(record.spec.summary, maxScalars: 200).text + "”")
                    .font(.headline)
                Text(AgentSubmissionLabel.provider(record.spec.source.provider))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ExpiryLabel(expiresAt: record.spec.expiresAt)
            }
            if !fetchedLive {
                Label(String(localized: "Cached — not confirmed with your Mac"), systemImage: "clock.badge.exclamationmark")
                    .font(.caption2)
            }
            ForEach(record.spec.questions, id: \.id) { question in
                Section {
                    Text(verbatim: DisplaySanitizer.sanitize(question.prompt, maxScalars: AgentPolicy.maximumPromptBytes).text)
                        .font(.footnote)
                    questionControls(question, editable: editable)
                } header: {
                    Text(question.required ? String(localized: "Required") : String(localized: "Optional"))
                }
            }
            Section(String(localized: "Status")) {
                Text(AgentSubmissionLabel.resolution(record.projection))
                if let state = session.agentSubmissions[requestID] {
                    Text(AgentSubmissionLabel.text(state))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                switch eligibility {
                case .answerable:
                    if let proposed = draft.proposedResponse(for: record.spec) {
                        NavigationLink(String(localized: "Review answer")) {
                            AnswerConfirmationView(spec: record.spec, response: proposed) {
                                // The user's explicit yes to exactly this
                                // response; any later edit withdraws it.
                                guard draft.confirm(proposed, for: record.spec) else { return }
                                let confirmed = draft
                                Task {
                                    await session.respond(with: confirmed, to: record)
                                    await reload()
                                }
                            }
                        }
                    } else {
                        Text(String(localized: "Answer the required questions"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .reviewOnIPhone(let reason):
                    Label(AgentSubmissionLabel.reviewOnIPhone(reason), systemImage: "iphone.and.arrow.forward")
                        .font(.caption2)
                case .iPhoneUnavailable:
                    // Nothing is queued for later (docs/specs/agent-relay.md 12.2).
                    Text(String(localized: "iPhone unavailable — no answer is queued"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .stale:
                    Button(String(localized: "Refresh")) { Task { await reload() } }
                }
                if record.spec.allowedResponses.contains(.decline) {
                    Button(String(localized: "Decline"), role: .destructive) { confirmingDecline = true }
                        .disabled(!WatchInputEligibility.permitsDecline(
                            record, now: now, gatewayReachable: session.isGatewayReachable, fetchedLive: fetchedLive
                        ))
                }
                if let problem = session.agentProblems[requestID] {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                }
            }
        }
        .confirmationDialog(String(localized: "Decline this question?"), isPresented: $confirmingDecline) {
            Button(String(localized: "Decline"), role: .destructive) {
                Task {
                    await session.decline(record)
                    await reload()
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private func questionControls(_ question: InputQuestion, editable: Bool) -> some View {
        switch question.kind {
        case .singleChoice(let choices), .multiChoice(let choices, _, _):
            if case .multiChoice(_, let minimum, let maximum) = question.kind {
                Text(String(localized: "Choose \(minimum)–\(maximum)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(choices, id: \.id) { choice in
                let selected = draft.answers.isSelected(choice.id, in: question)
                Button {
                    draft.select(choice.id, in: question)
                } label: {
                    Label {
                        Text(verbatim: DisplaySanitizer.sanitize(choice.label, maxScalars: AgentPolicy.maximumLabelBytes).text)
                    } icon: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    }
                }
                .disabled(!editable)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        case .text(let maximumBytes, _):
            // Dictation, Scribble, or the keyboard fill a draft only.
            TextField(String(localized: "Dictate or scribble"), text: Binding(
                get: { draft.answers.text(for: question) },
                set: { draft.setDraftText($0, for: question) }
            ))
            .disabled(!editable)
            let bytes = draft.answers.byteCount(for: question)
            Text(String(localized: "\(bytes)/\(maximumBytes) bytes"))
                .font(.caption2)
                .foregroundStyle(bytes > maximumBytes ? .red : .secondary)
        }
    }

    private func reload() async {
        if let current = try? await session.fetchInputForReview(requestID) {
            record = current
            fetchedLive = true
        }
        draft = WatchAnswerDraft()
    }
}

/// The final screen: exactly what will be signed by this Watch, text shown
/// verbatim with escapes visible and its size in bytes.
struct AnswerConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let spec: InputSpec
    let response: InputResponse
    let confirm: () -> Void

    var body: some View {
        List {
            ForEach(response.answers, id: \.questionID) { answer in
                Section {
                    switch answer {
                    case .singleChoice(let questionID, let choiceID):
                        Text(verbatim: label(choiceID, in: questionID))
                    case .multiChoice(let questionID, let choiceIDs):
                        ForEach(choiceIDs, id: \.self) { Text(verbatim: label($0, in: questionID)) }
                    case .text(_, let text):
                        Text(verbatim: DisplaySanitizer.sanitize(text, maxScalars: AgentPolicy.watchMaximumTextBytes).text)
                            .font(.system(.footnote, design: .monospaced))
                        Text(String(localized: "\(text.utf8.count) bytes, sent exactly as shown"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(verbatim: spec.question(answer.questionID).map {
                        DisplaySanitizer.sanitize($0.prompt, maxScalars: 60).text
                    } ?? answer.questionID)
                }
            }
            Section {
                Button(String(localized: "Sign and send")) {
                    confirm()
                    dismiss()
                }
                Button(String(localized: "Edit"), role: .cancel) { dismiss() }
            }
        }
        .navigationTitle(String(localized: "Confirm"))
    }

    private func label(_ choiceID: String, in questionID: String) -> String {
        let choice = spec.question(questionID)?.kind.choices.first { $0.id == choiceID }
        return choice.map { DisplaySanitizer.sanitize($0.label, maxScalars: AgentPolicy.maximumLabelBytes).text } ?? choiceID
    }
}
