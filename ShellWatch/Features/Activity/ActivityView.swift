import SwiftUI
import ShellControlProtocol
import ShellControlClient

/// Recent outcomes, unresolved local commands, and host connectivity.
struct ActivityView: View {
    @Environment(ControlSession.self) private var session

    var body: some View {
        List {
            Section(String(localized: "Connectivity")) {
                LabeledContent(String(localized: "iPhone")) {
                    Text(session.isGatewayReachable ? String(localized: "Reachable") : String(localized: "Unavailable"))
                }
                if let problem = session.gatewayProblem {
                    Text(problem)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                FreshnessFooter(lastRefreshedAt: session.lastRefreshedAt)
            }

            let unresolved = session.pendingCommands.filter { PendingCommandLabel.isAmbiguous($0.status) }
            let recorded = session.pendingCommands.filter { !PendingCommandLabel.isAmbiguous($0.status) }
            if !unresolved.isEmpty {
                Section(String(localized: "Unresolved")) {
                    // A submitted decision whose outcome is unknown stays
                    // visible until the server is asked about it again.
                    ForEach(unresolved, id: \.commandID) { command in
                        PendingCommandRow(command: command)
                    }
                    Button(String(localized: "Check now")) {
                        Task { await session.reconcilePendingCommands() }
                    }
                }
            }
            if !recorded.isEmpty {
                Section(String(localized: "Recorded")) {
                    // The broker recorded these; they stay journalled only
                    // until the next reconcile confirms the final outcome.
                    ForEach(recorded, id: \.commandID) { command in
                        PendingCommandRow(command: command)
                    }
                }
            }

            Section(String(localized: "Outcomes")) {
                ForEach(session.inbox.recentOutcomes.prefix(20), id: \.spec.requestID) { record in
                    OutcomeRow(record: record)
                }
            }

            Section {
                Button(String(localized: "Sign out"), role: .destructive) { session.signOut() }
            } footer: {
                Text(String(localized: "Signing out removes this Watch's key and cache. Revoke it on the Mac with shell-control revoke."))
            }
        }
        .navigationTitle(String(localized: "Activity"))
    }
}

struct PendingCommandRow: View {
    let command: PendingCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(command.type.rawValue)
                .font(.caption)
            Text(PendingCommandLabel.text(command.status))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// What a journalled command's state means to the user. Only a command whose
/// fate the Watch genuinely does not know is "Outcome unknown"; one the
/// broker recorded is shown as recorded while it waits to be reconciled.
enum PendingCommandLabel {
    /// `.sending` counts as ambiguous: the journal is only read after a send
    /// returns, so a command still marked sending was interrupted mid-send.
    static func isAmbiguous(_ status: PendingCommand.Status) -> Bool {
        switch status {
        case .sending, .outcomeUnknown: return true
        case .decisionRecorded: return false
        }
    }

    static func text(_ status: PendingCommand.Status) -> String {
        switch status {
        case .sending, .outcomeUnknown:
            return String(localized: "Outcome unknown — will be reconciled by command id")
        case .decisionRecorded:
            return String(localized: "Decision recorded — confirming outcome")
        }
    }
}
