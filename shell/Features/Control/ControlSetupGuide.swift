//
//  ControlSetupGuide.swift
//  shell
//
//  Guided Control companion setup and evidence-based status on the iPhone:
//  Prepare Mac → Pair iPhone → Test review → Done, with Apple Watch and
//  remote alerts as optional sections. Every status names what was observed
//  and when; what this app cannot observe is labelled unknown
//  (docs/specs/control-setup.md sections 5-9).
//

import SwiftUI
import UIKit
import ShellControlProtocol
import ShellControlClient
import ShellControlSecurity

// MARK: - Status text

/// Words for every state, so nothing depends on color.
enum ControlStatusText {
    static let vpnOnDemandURL = URL(string: "https://tailscale.com/docs/features/client/ios-vpn-on-demand")!

    /// The newest evidence wins: a diagnostic pass older than the last
    /// refresh does not override what the refresh observed, and vice versa.
    static func newestDiagnostics(_ companion: ControlCompanion) -> DiagnosticReport? {
        guard let report = companion.diagnostics else { return nil }
        if let checked = companion.routeCheckedAt, checked > report.generatedAt.date { return nil }
        return report
    }

    static func review(_ companion: ControlCompanion) -> String {
        switch companion.phase {
        case .notConfigured, .needsEnrollment: return String(localized: "Not paired")
        case .ready:
            if let report = newestDiagnostics(companion) {
                switch report.readiness(for: .iphoneReview) {
                case .pass: return String(localized: "Ready")
                case .notConfigured: return String(localized: "Not paired")
                default: return String(localized: "Unavailable")
                }
            }
            if case .unavailable = companion.routeState { return String(localized: "Unavailable") }
            if case .reachable = companion.routeState { return String(localized: "Ready") }
            return String(localized: "Not checked")
        }
    }

    static func route(_ companion: ControlCompanion) -> String {
        switch companion.routeState {
        case .reachable: String(localized: "Reachable")
        case .unavailable: String(localized: "Unreachable")
        case .unknown: String(localized: "Not checked")
        }
    }

    static func origin(_ companion: ControlCompanion) -> String {
        guard let check = newestDiagnostics(companion)?.check("origin_identity") else {
            if case .reachable = companion.routeState { return String(localized: "Verified") }
            return String(localized: "Not checked")
        }
        switch check.code {
        case .originVerified: return String(localized: "Verified")
        case .originKeyMismatch: return String(localized: "Mismatch")
        default: return String(localized: "Not checked")
        }
    }

    static func watch(_ watch: WatchReviewerStatus?, installed: Bool) -> String {
        switch watch?.state {
        case .active?: String(localized: "Ready")
        case .pending?: String(localized: "Pending")
        case .revoked?: String(localized: "Unavailable")
        default: String(localized: "Not configured")
        }
    }

    static func alerts(_ policy: RemoteAlertPolicy?) -> String {
        switch policy?.displayState ?? .off {
        case .off: String(localized: "Off")
        case .configured: String(localized: "Configured")
        case .degraded: String(localized: "Degraded")
        case .disablePending, .disableNeedsHostUpdate: String(localized: "Disable pending")
        }
    }

    static func symbol(_ state: DiagnosticState) -> String {
        switch state {
        case .pass: "checkmark.circle"
        case .warn: "exclamationmark.triangle"
        case .fail: "xmark.octagon"
        case .unknown: "questionmark.circle"
        case .notConfigured: "circle.dashed"
        case .disabled: "minus.circle"
        }
    }

    static func stateWord(_ state: DiagnosticState) -> String {
        switch state {
        case .pass: String(localized: "OK")
        case .warn: String(localized: "Warning")
        case .fail: String(localized: "Problem")
        case .unknown: String(localized: "Unknown")
        case .notConfigured: String(localized: "Not configured")
        case .disabled: String(localized: "Off")
        }
    }

    static func action(_ action: DiagnosticAction) -> String? {
        switch action {
        case .checkConnection: String(localized: "Check connection again.")
        case .checkTailscaleOnIPhone: String(localized: "Open Tailscale on this iPhone and check it is connected to your tailnet.")
        case .pairIPhone, .pairAgain: String(localized: "Pair again using the QR from shell-control pair on your Mac.")
        case .addWatch, .openWatchApp: String(localized: "Open Shell on your Apple Watch.")
        case .confirmEnrollment: String(localized: "Confirm the code on your Mac.")
        case .retryAlertDisable: String(localized: "This retries automatically when the Mac is reachable.")
        case .updateHost: String(localized: "Update the Shell Control tools on your Mac.")
        case .openNotificationSettings: String(localized: "Allow notifications for Shell in Settings.")
        default: action.macCommand.map { String(localized: "On your Mac: \($0)") }
        }
    }

    static func lastChecked(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never") }
        return date.formatted(date: .omitted, time: .standard)
    }
}

// MARK: - Status

/// The six independent dimensions, never collapsed into one success flag.
struct ControlStatusSection: View {
    let companion: ControlCompanion

    var body: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let watch = ControlStatusText.watch(ControlWatchGateway.shared.boundWatch, installed: ControlPairingSession.shared.isWatchAppInstalled)
        #else
        let watch = String(localized: "Not configured")
        #endif
        Section {
            LabeledContent(String(localized: "Control review"), value: ControlStatusText.review(companion)).themedRow()
            LabeledContent(String(localized: "Mac route"), value: ControlStatusText.route(companion)).themedRow()
            LabeledContent(String(localized: "Origin identity"), value: ControlStatusText.origin(companion)).themedRow()
            LabeledContent(String(localized: "Apple Watch"), value: watch).themedRow()
            LabeledContent(String(localized: "Remote alerts"), value: ControlStatusText.alerts(companion.alertPolicy)).themedRow()
            LabeledContent(String(localized: "Last checked"), value: ControlStatusText.lastChecked(lastObservation)).themedRow()
            if let fingerprint = companion.originFingerprint {
                LabeledContent(String(localized: "Shell origin")) {
                    Text(fingerprint).font(.footnote.monospaced())
                }
                .themedRow()
            }
            if let route = companion.currentRoute {
                LabeledContent(String(localized: "Route"), value: URL(string: route)?.host ?? route).themedRow()
            }
            if let status = companion.statusMessage {
                Text(status).font(.footnote).themedRow()
            }
        } header: {
            Text(String(localized: "Status"))
        } footer: {
            if let observed = lastObservation, Date().timeIntervalSince(observed) > DiagnosticCheck.freshness {
                Text(String(localized: "These results are from \(ControlStatusText.lastChecked(observed)). Check connection for current evidence."))
            } else {
                Text(String(localized: "Shell reaches your Mac privately over Tailscale. A changed Tailscale address never requires pairing again."))
            }
        }
    }

    private var lastObservation: Date? {
        [companion.diagnostics?.generatedAt.date, companion.routeCheckedAt].compactMap { $0 }.max()
    }
}

struct ControlActionsSection: View {
    let companion: ControlCompanion
    @State private var showTest = false
    @State private var showExport = false

    var body: some View {
        Section {
            Button {
                Task { await companion.checkConnection() }
            } label: {
                HStack {
                    Text(String(localized: "Check connection"))
                    if companion.isCheckingConnection { Spacer(); ProgressView() }
                }
            }
            .disabled(companion.isCheckingConnection)
            .themedRow()
            if companion.phase == .ready {
                Button(String(localized: "Test review")) { showTest = true }.themedRow()
                #if os(iOS) && !targetEnvironment(macCatalyst)
                if ControlWatchGateway.shared.boundWatch == nil {
                    NavigationLink(String(localized: "Add Apple Watch")) { ControlWatchSetupView(companion: companion) }
                        .themedRow()
                }
                #endif
            }
            Button(String(localized: "Export diagnostics")) {
                Task {
                    if companion.diagnostics == nil { await companion.checkConnection() }
                    showExport = true
                }
            }
            .themedRow()
            if let report = companion.diagnostics {
                ForEach(report.checks.filter { $0.state != .pass }) { check in
                    ControlDiagnosticRow(check: check)
                }
            }
        } header: {
            Text(String(localized: "Diagnostics"))
        } footer: {
            Text(String(localized: "Checks run only when you ask. A passing check is evidence, not permission: every decision still makes its own live checks."))
        }
        .sheet(isPresented: $showTest) {
            NavigationStack { ControlTestReviewView(companion: companion) }
        }
        .sheet(isPresented: $showExport) {
            NavigationStack { ControlDiagnosticsExportView(companion: companion) }
        }
    }
}

struct ControlDiagnosticRow: View {
    let check: DiagnosticCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(check.summary)
            } icon: {
                Image(systemName: ControlStatusText.symbol(check.state))
            }
            .accessibilityLabel("\(ControlStatusText.stateWord(check.state)): \(check.summary)")
            if let action = check.action, let text = ControlStatusText.action(action) {
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            if check.action == .checkTailscaleOnIPhone {
                Link(String(localized: "Tailscale VPN On Demand"), destination: ControlStatusText.vpnOnDemandURL)
                    .font(.footnote)
            }
        }
        .themedRow()
    }
}

// MARK: - Requests

/// With remote alerts off, this is where requests are found: open Control
/// and refresh.
struct ControlRequestsSection: View {
    let companion: ControlCompanion

    var body: some View {
        Section {
            // Agent approvals are listed under Agents, with their context.
            if companion.basePending.isEmpty {
                Text(String(localized: "No requests are waiting.")).foregroundStyle(.secondary).themedRow()
            }
            ForEach(companion.basePending, id: \.spec.requestID) { record in
                NavigationLink {
                    ControlReviewView(companion: companion, requestID: record.spec.requestID)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        if SetupTestFixture.isWatchTest(record.spec) {
                            Label(String(localized: "Apple Watch setup test — approve it on the Watch"), systemImage: "applewatch")
                                .font(.caption)
                        } else if SetupTestFixture.matches(record.spec) {
                            Label(String(localized: "Setup test"), systemImage: "checkmark.shield")
                                .font(.caption)
                        }
                        Text(DisplaySanitizer.sanitize(record.spec.summary, maxScalars: 120).text)
                        Text(String(localized: "Expires \(record.spec.expiresAt.date.formatted(date: .omitted, time: .shortened))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()
            }
            Button(String(localized: "Refresh")) { Task { await companion.refresh() } }.themedRow()
        } header: {
            Text(String(localized: "Requests"))
        } footer: {
            if let refreshed = companion.lastRefreshedAt {
                Text(String(localized: "Updated \(refreshed.date.formatted(date: .omitted, time: .standard))."))
            }
        }
    }
}

// MARK: - Remote alerts

struct ControlRemoteAlertsSection: View {
    let companion: ControlCompanion

    var body: some View {
        let policy = companion.alertPolicy
        let relayAvailable = ControlPushCapability.relayURL != nil
        Section {
            if policy?.needsChoice == true {
                Text(String(localized: "Remote alerts can tell you about new requests while Shell is closed. They are off until you choose."))
                    .themedRow()
                Button(String(localized: "Keep remote alerts off")) { Task { await companion.setRemoteAlerts(.off) } }.themedRow()
                Button(String(localized: "Turn on remote alerts")) { Task { await companion.setRemoteAlerts(.configured) } }.themedRow()
            } else {
                Toggle(String(localized: "Remote alerts"), isOn: Binding(
                    get: { policy?.choice == .configured },
                    set: { on in Task { await companion.setRemoteAlerts(on ? .configured : .off) } }
                ))
                .disabled(!relayAvailable && policy?.choice != .configured)
                .themedRow()
            }
            Text(statusText(policy)).font(.footnote).themedRow()
        } header: {
            Text(String(localized: "Remote alerts (optional)"))
        } footer: {
            Text(relayAvailable
                ? String(localized: "Applies only to Control alerts for this Mac on this iPhone. Alerts already sent may still appear. Turning alerts off never affects pairing or pending requests.")
                : String(localized: "This build has no push relay, so remote alerts are unavailable. Review works without them."))
        }
    }

    private func statusText(_ policy: RemoteAlertPolicy?) -> String {
        switch policy?.displayState ?? .off {
        case .off: ControlCompanion.alertsOffText
        case .configured: companion.notificationsDenied
            ? String(localized: "Notifications are turned off for Shell in Settings.")
            : String(localized: "Registered. Registration does not prove an alert will be shown.")
        case .degraded(let failure): ControlCompanion.describe(failure)
        case .disablePending: String(localized: "Off on this iPhone; Mac update pending.")
        case .disableNeedsHostUpdate: String(localized: "Update host to finish disabling alerts.")
        }
    }
}

// MARK: - Guided setup

/// Prepare Mac → Pair iPhone → Test review → Done. The Watch and remote
/// alerts follow as optional sections and never block completion.
struct ControlSetupGuideView: View {
    let companion: ControlCompanion
    @State private var pastedText = ""
    @State private var showScanner = false

    var body: some View {
        List {
            Section {
                Text(String(localized: "On your Mac, install Tailscale and sign in. Then run:")).themedRow()
                ControlCommandRow(command: "shell-control setup --guided")
                Text(String(localized: "Install Tailscale on this iPhone and sign in to the same tailnet. Shell cannot see or change Tailscale's settings; VPN On Demand can connect it for *.ts.net automatically."))
                    .font(.footnote)
                    .themedRow()
                Link(String(localized: "Tailscale VPN On Demand"), destination: ControlStatusText.vpnOnDemandURL).themedRow()
            } header: {
                stepHeader(1, String(localized: "Prepare Mac"), done: companion.phase != .notConfigured)
            }

            Section {
                if companion.phase == .ready {
                    Label(String(localized: "Paired"), systemImage: "checkmark.circle").themedRow()
                } else {
                    #if os(iOS) && !targetEnvironment(macCatalyst)
                    Button(String(localized: "Scan QR")) { showScanner = true }
                        .disabled(companion.isPairing)
                        .themedRow()
                    #endif
                    TextField(String(localized: "Or paste the shell-control://pair link"), text: $pastedText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel(String(localized: "Pairing link"))
                        .themedRow()
                    Button(String(localized: "Use pasted code")) {
                        let text = pastedText
                        pastedText = ""
                        Task { await companion.handleScanned(text) }
                    }
                    .disabled(pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || companion.isPairing)
                    .themedRow()
                    if let pending = companion.pendingPairing {
                        ControlPairingConfirmation(companion: companion, pending: pending)
                    }
                    ControlPairingProgressRows(companion: companion)
                    if let status = companion.statusMessage { Text(status).font(.footnote).themedRow() }
                }
            } header: {
                stepHeader(2, String(localized: "Pair iPhone"), done: companion.phase == .ready)
            } footer: {
                Text(String(localized: "You confirm the Mac's key on this iPhone and this iPhone's code on the Mac. Nothing is trusted automatically."))
            }

            if companion.phase == .ready {
                Section {
                    ControlTestReviewRows(companion: companion)
                } header: {
                    stepHeader(3, String(localized: "Test review"), done: companion.setupTestPassed)
                }

                Section {
                    Text(companion.setupTestPassed
                        ? String(localized: "Control is ready on this iPhone. The Apple Watch and remote alerts below are optional.")
                        : String(localized: "Finish the review test to complete setup."))
                        .themedRow()
                } header: {
                    stepHeader(4, String(localized: "Done"), done: companion.setupTestPassed)
                }

                #if os(iOS) && !targetEnvironment(macCatalyst)
                Section {
                    NavigationLink(String(localized: "Add Apple Watch")) { ControlWatchSetupView(companion: companion) }.themedRow()
                } header: {
                    Text(String(localized: "Optional: Apple Watch"))
                }
                #endif
                ControlRemoteAlertsSection(companion: companion)
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Set up Control"))
        .task { await companion.start() }
        .refreshable { await companion.refresh() }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showScanner) {
            ControlPairingScannerSheet { payload in
                Task { await companion.handleScanned(payload) }
            }
        }
        #endif
    }

    private func stepHeader(_ number: Int, _ title: String, done: Bool) -> some View {
        Label("\(number). \(title)", systemImage: done ? "checkmark.circle" : "circle")
            .accessibilityLabel(done ? String(localized: "Step \(number), \(title), done") : String(localized: "Step \(number), \(title)"))
    }
}

/// A command to run on the Mac, copyable.
struct ControlCommandRow: View {
    let command: String

    var body: some View {
        HStack {
            Text(command).font(.footnote.monospaced()).textSelection(.enabled)
            Spacer()
            Button {
                UIPasteboard.general.string = command
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel(String(localized: "Copy command"))
            .buttonStyle(.borderless)
        }
        .themedRow()
    }
}

// MARK: - Review test

/// The iPhone cannot publish a request; the Mac sends the fixed setup test
/// and this iPhone reviews it like any other request.
struct ControlTestReviewRows: View {
    let companion: ControlCompanion

    var body: some View {
        Text(String(localized: "The Mac's guided setup sends a harmless setup test. You can also send one on the Mac with:"))
            .themedRow()
        ControlCommandRow(command: "shell-control test-review --reviewer iphone --device-id \(companion.deviceID?.rawValue ?? "<ID>")")
        if let test = companion.pending.first(where: { SetupTestFixture.isIPhoneTest($0.spec) }) {
            NavigationLink {
                ControlReviewView(companion: companion, requestID: test.spec.requestID)
            } label: {
                Label(String(localized: "Review the setup test"), systemImage: "checkmark.shield")
            }
            .themedRow()
        } else if companion.setupTestPassed {
            Label(String(localized: "Setup test passed: approved here and recorded by the Mac."), systemImage: "checkmark.circle")
                .themedRow()
        } else if let test = companion.latestSetupTest {
            Label(outcome(test), systemImage: "info.circle").themedRow()
        }
        Button(String(localized: "Refresh")) { Task { await companion.refresh() } }.themedRow()
    }

    private func outcome(_ test: ApprovalRecord) -> String {
        switch test.projection.resolution {
        case .rejected: String(localized: "The last setup test was rejected. Send another to finish.")
        case .expired: String(localized: "The last setup test expired. Send another to finish.")
        case .approved: String(localized: "Approved; waiting for the Mac to record the receipt.")
        default: String(localized: "The last setup test did not complete.")
        }
    }
}

struct ControlTestReviewView: View {
    let companion: ControlCompanion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List { ControlTestReviewRows(companion: companion) }
            .themedList()
            .navigationTitle(String(localized: "Test review"))
            .task { await companion.refresh() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
            }
    }
}

// MARK: - Apple Watch

#if os(iOS) && !targetEnvironment(macCatalyst)
/// Optional Watch enrollment through this iPhone. Leaving this screen is
/// "skip for now": it never revokes an enrolled Watch.
struct ControlWatchSetupView: View {
    let companion: ControlCompanion

    var body: some View {
        let session = ControlPairingSession.shared
        let gateway = ControlWatchGateway.shared
        List {
            Section {
                LabeledContent(String(localized: "Watch app"), value: session.isWatchAppInstalled
                    ? String(localized: "Installed") : String(localized: "Not installed"))
                    .themedRow()
                LabeledContent(String(localized: "Reviewer"), value: gateway.boundWatch.map { watchStateTitle($0.state) } ?? String(localized: "Not enrolled"))
                    .themedRow()
                LabeledContent(String(localized: "Reachable from this iPhone"), value: session.isReachable
                    ? String(localized: "Yes") : String(localized: "No"))
                    .themedRow()
            } footer: {
                Text(String(localized: "Installed, enrolled, and reachable are separate. Reachable here does not by itself mean the Watch can reach the Mac."))
            }
            Section {
                Text(String(localized: "1. Install Shell on your Apple Watch.")).themedRow()
                Text(String(localized: "2. Open Shell on the Watch. It makes its own key and asks this iPhone to enroll it.")).themedRow()
                Text(String(localized: "3. Confirm the Watch's code on your Mac (the guided setup shows it, or run shell-control pair --watch).")).themedRow()
                if let watch = gateway.boundWatch {
                    if let code = watch.userCode {
                        LabeledContent(String(localized: "Watch code"), value: code).font(.body.monospaced()).themedRow()
                    }
                    LabeledContent(String(localized: "Watch key")) { Text(watch.fingerprint).font(.footnote.monospaced()) }.themedRow()
                    if watch.state == .active {
                        Text(String(localized: "4. Test it from the Mac:")).themedRow()
                        ControlCommandRow(command: "shell-control test-review --reviewer watch --device-id \(watch.watchDeviceID.rawValue)")
                    }
                }
            } header: {
                Text(String(localized: "Steps"))
            } footer: {
                Text(String(localized: "The Watch gets no Mac network credential. Its decisions are signed by the Watch and carried live by this iPhone; nothing is queued for later."))
            }
            if gateway.boundWatch != nil {
                Section {
                    Button(String(localized: "Forget Watch on this iPhone"), role: .destructive) { gateway.forgetWatch() }.themedRow()
                } footer: {
                    Text(String(localized: "Revoking the Watch on the Mac is separate: shell-control revoke <DEVICE-ID>."))
                }
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Apple Watch"))
    }

    private func watchStateTitle(_ state: WatchReviewerStatus.State) -> String {
        switch state {
        case .pending: String(localized: "Waiting for Mac confirmation")
        case .active: String(localized: "Enrolled via this iPhone")
        case .denied: String(localized: "Declined")
        case .expired: String(localized: "Expired")
        case .revoked: String(localized: "Revoked")
        }
    }
}
#endif

// MARK: - Recovery

/// Destructive recovery, kept on its own clearly labelled screen.
struct ControlRecoveryView: View {
    let companion: ControlCompanion
    @State private var confirmForget = false
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section {
                if companion.phase == .ready {
                    Button(String(localized: "Sign out"), role: .destructive) { confirmSignOut = true }.themedRow()
                }
                Button(String(localized: "Forget Mac"), role: .destructive) { confirmForget = true }.themedRow()
            } footer: {
                Text(String(localized: "Sign out removes this iPhone's Shell credentials; the Mac stays trusted. Forget Mac removes the trusted Mac key, and this iPhone and its Watch must pair again."))
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Recovery"))
        .confirmationDialog(String(localized: "Sign out of this Mac?"), isPresented: $confirmSignOut) {
            Button(String(localized: "Sign out"), role: .destructive) { Task { await companion.signOut() } }
        }
        .confirmationDialog(String(localized: "Forget this Mac?"), isPresented: $confirmForget) {
            Button(String(localized: "Forget Mac"), role: .destructive) { Task { await companion.forgetMac() } }
        } message: {
            Text(String(localized: "This iPhone and its Watch will need to pair again."))
        }
    }
}

// MARK: - Export

/// Shows the redacted report before the user chooses where to send it.
struct ControlDiagnosticsExportView: View {
    let companion: ControlCompanion
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?

    var body: some View {
        Group {
            if let data = companion.diagnosticExport() {
                ScrollView {
                    Text(String(decoding: data, as: UTF8.self))
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if let file {
                            ShareLink(item: file) { Label(String(localized: "Share"), systemImage: "square.and.arrow.up") }
                        }
                    }
                }
                .task { file = write(data) }
            } else {
                ContentUnavailableView(String(localized: "No diagnostics yet"), systemImage: "stethoscope",
                                       description: Text(String(localized: "Check connection first.")))
            }
        }
        .navigationTitle(String(localized: "Diagnostics"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Close")) { dismiss() } }
        }
    }

    /// A local file for the share sheet; nothing is uploaded automatically.
    private func write(_ data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shell-control-diagnostics.json")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }
}
