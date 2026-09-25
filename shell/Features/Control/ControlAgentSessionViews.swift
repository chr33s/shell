//
//  ControlAgentSessionViews.swift
//  shell
//
//  Managed agent sessions on the iPhone: identity, compatibility evidence,
//  turn state, and terminal location as text; and, only where both the
//  session and this iPhone's grants allow it, a new instruction or steering
//  message and turn interruption — each shown exactly on a final
//  confirmation screen before this iPhone signs it. There is no terminal
//  keystroke fallback (docs/specs/agent-relay.md sections 12.1, 13.1, and 15).
//

import SwiftUI
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

// MARK: - Row

/// Provider and build as the Mac registered them, and the turn state.
struct ControlAgentSessionRow: View {
    let session: AgentSessionProjection

    var body: some View {
        let registration = session.registration
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(ControlAgentText.provider(registration.provider)).font(.subheadline.weight(.semibold))
                Text(verbatim: "·").font(.caption)
                Text(verbatim: DisplaySanitizer.sanitize(registration.providerBuild, maxScalars: 64).text).font(.caption)
            }
            Text(session.state == .ended ? String(localized: "Session ended") : ControlAgentText.turn(session))
                .font(.caption)
            Text(ControlAgentText.evidence(registration.evidence))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Detail

/// One managed session. The session is refetched on open; every command is
/// built from it exactly as shown when the user taps review, and a session
/// that moved before recording is reviewed again rather than retargeted.
struct ControlAgentSessionView: View {
    let companion: ControlCompanion
    let sessionID: ControlID

    @State private var draft = AgentMessageDraft()
    @State private var confirming: AgentSessionProposal?
    @State private var failure: String?

    /// Following a command's outcome never polls faster than this.
    static let followInterval: TimeInterval = max(5, ControlAgentCenter.minimumInterval)

    var body: some View {
        Group {
            if let session = companion.agent.inbox.session(sessionID) {
                form(session)
            } else if let failure {
                ContentUnavailableView(
                    String(localized: "Cannot show session"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure)
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(String(localized: "Agent session"))
        .task { await load() }
        .task(id: isFollowing) {
            while isFollowing, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.followInterval))
                if Task.isCancelled { break }
                await companion.followSessionCommands(sessionID)
            }
        }
        .sheet(item: $confirming) { proposal in
            NavigationStack {
                ControlAgentSessionConfirmation(proposal: proposal) {
                    confirming = nil
                    Task {
                        await companion.sendSessionCommand(proposal)
                        // Kept after a refusal, so the user can review again.
                        if proposal.text != nil, companion.agent.sessionProblems[sessionID] == nil { draft = AgentMessageDraft() }
                    }
                } cancel: {
                    confirming = nil
                }
            }
        }
    }

    private var isFollowing: Bool {
        companion.agent.sendingSessions.contains(sessionID) || !companion.agent.pendingSessionCommands(sessionID).isEmpty
    }

    private func load() async {
        do { _ = try await companion.fetchAgentSession(sessionID) } catch { failure = String(describing: error) }
    }

    @ViewBuilder
    private func form(_ session: AgentSessionProjection) -> some View {
        let agent = companion.agent
        let controls = agent.controls(for: session)
        let sending = agent.sendingSessions.contains(sessionID)
        Form {
            ControlAgentSessionSection(
                provider: session.registration.provider,
                providerBuild: session.registration.providerBuild,
                session: session
            )
            Section {
                LabeledContent(String(localized: "Turn"), value: ControlAgentText.turn(session))
                if session.turnState == .active, let turnID = session.activeTurnID {
                    LabeledContent(String(localized: "Turn ID")) {
                        Text(verbatim: ControlAgentText.turnID(turnID)).font(.footnote.monospaced())
                    }
                }
                LabeledContent(String(localized: "Session version"), value: String(session.sessionVersion))
                if sending {
                    Label(String(localized: "Sending"), systemImage: "arrow.up.circle")
                }
                if let problem = agent.sessionProblems[sessionID] {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.footnote)
                }
            } header: {
                Text(String(localized: "Turn"))
            } footer: {
                Text(String(localized: "Reported by the agent's managed connection on your Mac."))
            }
            if controls.canCompose {
                composeSection(session, disabled: sending)
            } else if controls.messagesNeedGrant {
                Section {
                    Text(String(localized: "Sending messages is not enabled for this iPhone. On the Mac: shell-control agent grant <device-id> --messages"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if controls.canInterrupt {
                Section {
                    Button(String(localized: "Interrupt turn…"), role: .destructive) {
                        confirming = try? AgentSessionProposal.interrupt(session)
                    }
                    .disabled(sending)
                } footer: {
                    Text(String(localized: "An acknowledgement is not proof that the agent's process stopped, and nothing already done is rolled back."))
                }
            } else if controls.cancelNeedsGrant {
                Section {
                    Text(String(localized: "Interrupting turns is not enabled for this iPhone. On the Mac: shell-control agent grant <device-id> --cancel"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            outcomesSection
        }
        .refreshable { await companion.followSessionCommands(sessionID) }
    }

    private func composeSection(_ session: AgentSessionProjection, disabled: Bool) -> some View {
        let bytes = draft.byteCount
        let limit = AgentMessageDraft.maximumBytes
        let problem = draft.problem.flatMap { ControlAgentText.draftProblem($0) }
        return Section {
            TextField(String(localized: "Message"), text: $draft.text, axis: .vertical)
                .lineLimit(3...10)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .disabled(disabled)
            Text(String(localized: "\(bytes) of \(limit) bytes"))
                .font(.caption)
                .foregroundStyle(bytes > limit ? .red : .secondary)
                .accessibilityLabel(bytes > limit
                    ? String(localized: "Too long: \(bytes) of \(limit) bytes")
                    : String(localized: "\(bytes) of \(limit) bytes"))
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote)
            }
            Button(session.turnState == .active ? String(localized: "Review steering message…") : String(localized: "Review new instruction…")) {
                confirming = try? draft.proposal(for: session)
            }
            .disabled(disabled || draft.problem != nil)
        } header: {
            Text(session.turnState == .active ? String(localized: "Steer the running turn") : String(localized: "New instruction"))
        } footer: {
            Text(String(localized: "Plain text only. You see the exact text, and whether it starts a new turn or steers the running one, before this iPhone signs it."))
        }
    }

    private var outcomesSection: some View {
        let outcomes = companion.agent.commandOutcomes(for: sessionID)
        return Section {
            if outcomes.isEmpty {
                Text(String(localized: "None yet")).foregroundStyle(.secondary)
            }
            ForEach(outcomes) { outcome in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ControlAgentText.sessionCommand(outcome.action)).font(.subheadline)
                    if case .message(_, _, _, _, _, let text)? = outcome.action {
                        let shown = DisplaySanitizer.sanitize(text, maxScalars: 120)
                        Text(verbatim: shown.text + (shown.isTruncated ? "…" : "")).font(.caption.monospaced())
                    }
                    Text(outcome.outcome.text).font(.caption.weight(.semibold))
                    if let evidence = outcome.evidence {
                        Text(verbatim: DisplaySanitizer.sanitize(evidence, maxScalars: 64).text)
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(outcome.at.date.formatted(date: .omitted, time: .standard))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "Commands"))
        } footer: {
            Text(String(localized: "Recorded is not agent acceptance, and acceptance is not proof the turn did anything."))
        }
    }
}

// MARK: - Confirmation

/// The final screen before signing: the exact text, byte for byte with
/// escapes visible, and whether it starts a new turn or steers or interrupts
/// a named turn (docs/specs/agent-relay.md sections 15.1 and 15.2).
struct ControlAgentSessionConfirmation: View {
    let proposal: AgentSessionProposal
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        let registration = proposal.reviewed.registration
        Form {
            Section {
                LabeledContent(String(localized: "Provider"), value: ControlAgentText.provider(registration.provider))
                LabeledContent(String(localized: "Session")) {
                    Text(verbatim: registration.agentSessionID.rawValue).font(.footnote.monospaced())
                }
                LabeledContent(String(localized: "Session version"), value: String(proposal.action.expectedSessionVersion))
                Text(ControlAgentText.target(proposal.target)).font(.headline)
            } header: {
                Text(String(localized: "Target"))
            }
            if let text = proposal.text {
                Section {
                    Text(verbatim: proposal.displayLines.map(\.text).joined(separator: "\n"))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    Text(String(localized: "\(text.utf8.count) bytes, sent exactly as shown")).font(.caption).foregroundStyle(.secondary)
                    if proposal.didEscape {
                        Label(String(localized: "Contains escaped characters"), systemImage: "eye.trianglebadge.exclamationmark")
                            .font(.caption)
                    }
                    if proposal.isTruncated {
                        Label(String(localized: "Too large to show in full. It cannot be sent from this iPhone."), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                    }
                } header: {
                    Text(String(localized: "Exact message"))
                }
            }
            if case .cancel = proposal.target {
                Section {
                    Text(String(localized: "The agent is asked to stop this turn. An acknowledgement is not proof that its process stopped, and anything it already did is not rolled back."))
                        .font(.footnote)
                }
            }
            Section {
                if case .cancel = proposal.target {
                    Button(String(localized: "Sign and interrupt"), role: .destructive, action: confirm)
                } else {
                    Button(String(localized: "Sign and send"), action: confirm)
                        .disabled(proposal.isTruncated)
                }
                Button(String(localized: "Cancel"), role: .cancel, action: cancel)
            } footer: {
                Text(String(localized: "Sent to the managed session by your Mac, never typed into a terminal. If the session changes first, nothing is sent and you review it again."))
            }
        }
        .navigationTitle(proposal.text == nil ? String(localized: "Confirm interrupt") : String(localized: "Confirm message"))
    }
}
