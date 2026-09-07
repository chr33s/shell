import SwiftUI
import ShellControlProtocol
import ShellControlClient

/// The review screen. It fetches the current request before enabling any
/// decision, shows the exact argument vector and working directory, escapes
/// control and bidi characters, and never silently truncates an
/// authorization-relevant argument (spec.watch.md section 6).
struct ApprovalReviewView: View {
    @Environment(ControlSession.self) private var session
    let requestID: ControlID

    @State private var record: ApprovalRecord?
    @State private var loadError: String?
    @State private var confirming: ControlDecision?

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
        .navigationTitle(String(localized: "Review"))
        .task { await load() }
    }

    private func load() async {
        do {
            record = try await session.fetchForReview(requestID)
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
                case .approvable:
                    Button(String(localized: "Approve once")) { confirming = .approve }
                        .disabled(session.isOffline)
                case .reviewElsewhere(let reason):
                    // No approval path: the Watch says so instead of degrading
                    // to a weaker check.
                    Label(reviewElsewhereText(reason), systemImage: "iphone.and.arrow.forward")
                        .font(.caption2)
                }
                if record.canReject(at: now) {
                    Button(String(localized: "Reject"), role: .destructive) { confirming = .reject }
                        .disabled(session.isOffline)
                }
                if session.isOffline {
                    Text(String(localized: "Offline — no new control command is queued"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
