import SwiftUI
import ShellControlProtocol
import ShellControlClient

/// Pending requests first, then recent notifications and outcomes.
///
/// Cached data says when it was last refreshed, and a local tap never paints a
/// green success state (spec.watch.md section 6).
struct InboxView: View {
    @Environment(ControlSession.self) private var session
    @State private var reviewing: ControlID?

    var body: some View {
        NavigationStack {
            List {
                if session.isOffline {
                    Label(String(localized: "Offline — showing cached state"), systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                Section(String(localized: "Pending")) {
                    if session.inbox.pendingApprovals.isEmpty {
                        Text(String(localized: "Nothing waiting"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.inbox.pendingApprovals, id: \.spec.requestID) { record in
                        Button {
                            reviewing = record.spec.requestID
                        } label: {
                            ApprovalRow(record: record)
                        }
                    }
                }
                Section(String(localized: "Recent")) {
                    ForEach(session.inbox.unacknowledgedNotifications, id: \.eventID) { event in
                        NotificationRow(event: event)
                    }
                    ForEach(session.inbox.recentOutcomes.prefix(10), id: \.spec.requestID) { record in
                        OutcomeRow(record: record)
                    }
                }
                Section {
                    NavigationLink(String(localized: "Activity")) { ActivityView() }
                    FreshnessFooter(lastRefreshedAt: session.lastRefreshedAt)
                }
            }
            .navigationTitle(String(localized: "Shell"))
            .refreshable { await session.refresh() }
            .navigationDestination(item: $reviewing) { requestID in
                ApprovalReviewView(requestID: requestID)
            }
        }
        // Polling runs only while a relevant screen is visible.
        .onAppear { session.startPolling() }
        .onDisappear { session.stopPolling() }
        .task(id: WatchAppDelegate.pendingIntent) {
            // A notification action opens review; it never decides.
            if let intent = WatchAppDelegate.pendingIntent {
                reviewing = intent.requestID
                WatchAppDelegate.pendingIntent = nil
            }
        }
    }
}

struct ApprovalRow: View {
    let record: ApprovalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // A program-supplied label is rendered distinctly from enrolled
            // identity, and is always sanitized.
            Text(DisplaySanitizer.sanitize(record.spec.summary, maxScalars: 80).text)
                .font(.headline)
                .lineLimit(2)
            Text(record.spec.operation.schema)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ExpiryLabel(expiresAt: record.spec.expiresAt)
        }
    }
}

struct OutcomeRow: View {
    let record: ApprovalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DisplaySanitizer.sanitize(record.spec.summary, maxScalars: 60).text)
                .font(.subheadline)
                .lineLimit(1)
            Text(ResolutionLabel.text(record.projection))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct NotificationRow: View {
    @Environment(ControlSession.self) private var session
    let event: InformationalEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DisplaySanitizer.sanitize(event.title, maxScalars: 80).text)
                .font(.subheadline)
            if !event.body.isEmpty {
                Text(DisplaySanitizer.sanitize(event.body, maxScalars: 160).text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Reading is not acknowledging.
            Button(String(localized: "Acknowledge")) {
                Task { await session.acknowledge(event) }
            }
            .font(.caption2)
        }
    }
}

struct ExpiryLabel: View {
    let expiresAt: ControlTimestamp

    var body: some View {
        Text(expiresAt.date, style: .relative)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

struct FreshnessFooter: View {
    let lastRefreshedAt: ControlTimestamp?

    var body: some View {
        if let lastRefreshedAt {
            Text(String(localized: "Last verified \(lastRefreshedAt.date.formatted(date: .omitted, time: .standard))"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text(String(localized: "Never verified with the service"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

enum ResolutionLabel {
    /// Distinguishes decision from dispatch: a recorded decision does not mean
    /// the host applied it (spec.watch.md section 6).
    static func text(_ projection: ApprovalProjection) -> String {
        switch (projection.resolution, projection.dispatch) {
        case (.pending, _): return String(localized: "Pending")
        case (.expired, _): return String(localized: "Expired")
        case (.cancelled, _): return String(localized: "Cancelled")
        case (_, .applied): return String(localized: "Host accepted")
        case (_, .notApplied): return String(localized: "Not applied")
        case (_, .unknown): return String(localized: "Outcome unknown")
        case (.approved, .claimed), (.rejected, .claimed): return String(localized: "Waiting for host")
        case (.approved, _): return String(localized: "Approved — decision recorded")
        case (.rejected, _): return String(localized: "Rejected — decision recorded")
        }
    }
}
