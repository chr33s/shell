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

            if !session.pendingCommands.isEmpty {
                Section(String(localized: "Unresolved")) {
                    // A submitted decision whose outcome is unknown stays
                    // visible until the server is asked about it again.
                    ForEach(session.pendingCommands, id: \.commandID) { command in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(command.type.rawValue)
                                .font(.caption)
                            Text(String(localized: "Outcome unknown — will be reconciled by command id"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(String(localized: "Check now")) {
                        Task { await session.reconcilePendingCommands() }
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
