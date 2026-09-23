//
//  ControlReviewView.swift
//  shell
//
//  The phone's larger review surface. A request whose `minimum_review` is
//  `full` can only be completed here or on another enrolled full-review
//  client; until one exists it stays unapproved or expires
//  (spec.watch.md section 6).
//

import SwiftUI
import UIKit
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

struct ControlReviewView: View {
    let companion: ControlCompanion
    let requestID: ControlID

    @State private var record: ApprovalRecord?
    @State private var failure: String?
    @State private var confirming: ControlDecision?

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
        .navigationTitle(String(localized: "Review request"))
        .task {
            do { record = try await companion.fetch(requestID) } catch { failure = String(describing: error) }
        }
    }

    @ViewBuilder
    private func form(_ record: ApprovalRecord) -> some View {
        let now = ControlTimestamp(Date())
        Form {
            Section {
                Text(DisplaySanitizer.sanitize(record.spec.summary, maxScalars: 200).text)
                    .font(.headline)
                LabeledContent(String(localized: "Origin"), value: record.spec.originID.rawValue)
                LabeledContent(String(localized: "Run"), value: record.spec.runID.rawValue)
                LabeledContent(String(localized: "Expires"), value: record.spec.expiresAt.rfc3339)
                LabeledContent(String(localized: "Digest"), value: record.requestHash)
                    .font(.footnote.monospaced())
            }
            if case .exec(let operation) = record.spec.operation {
                Section(String(localized: "Command")) {
                    LabeledContent(String(localized: "Working directory"), value: DisplaySanitizer.sanitize(operation.cwd, maxScalars: 1024).text)
                    // Full arguments, never silently truncated.
                    ForEach(Array(DisplaySanitizer.argumentLines(operation.argv, maxScalars: 4096).enumerated()), id: \.offset) { index, line in
                        LabeledContent("argv[\(index)]") {
                            Text(line.text).font(.footnote.monospaced())
                        }
                    }
                    LabeledContent(String(localized: "Context"), value: operation.contextSHA256)
                        .font(.footnote.monospaced())
                }
            } else {
                Section {
                    Label(
                        String(localized: "Unsupported operation schema: \(record.spec.operation.schema)"),
                        systemImage: "questionmark.square.dashed"
                    )
                }
            }
            Section {
                // The same gate the decision coordinator applies for a
                // full-review client, so Approve is never offered for a
                // request the submission would refuse.
                Button(String(localized: "Approve once")) { confirming = .approve }
                    .disabled(!record.canApprove(at: now, review: ControlCompanion.review))
                if record.spec.allowedDecisions.contains(.approve),
                   case .reviewElsewhere(let reason) = record.approvability(at: now, review: ControlCompanion.review) {
                    Text(ControlCompanion.reviewElsewhereText(reason))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(String(localized: "Reject"), role: .destructive) { confirming = .reject }
                    .disabled(!record.canReject(at: now))
            } footer: {
                Text(String(localized: "A recorded decision does not mean the host has applied it."))
            }
            if let status = companion.statusMessage {
                Section(String(localized: "Status")) { Text(status) }
            }
        }
        .confirmationDialog(
            String(localized: "Confirm this decision"),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            if let decision = confirming {
                Button(decision == .approve ? String(localized: "Approve once") : String(localized: "Reject")) {
                    Task {
                        await companion.decide(decision, on: record)
                        // Always show the request as it now stands: after a
                        // refusal this is the fresh review the user decides from.
                        if let current = try? await companion.fetch(requestID) { self.record = current }
                    }
                    confirming = nil
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { confirming = nil }
        }
    }
}

/// Pairing with the Mac over Tailscale, route updates, and the Watch this
/// iPhone gateways for. Private keys never leave the device that made them
/// (spec.iphone-gateway.md sections 9, 10, and 24).
struct ControlSetupView: View {
    let companion: ControlCompanion

    @State private var pastedText = ""
    @State private var showScanner = false
    @State private var confirmForget = false

    var body: some View {
        List {
            macSection
            pairingSection
            if companion.phase != .notConfigured {
                actionsSection
            }
            watchSection
        }
        .themedList()
        .navigationTitle(String(localized: "Control"))
        .task { await companion.start() }
        .refreshable { await companion.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .controlPairingReceived)) { _ in
            Task { await companion.start() }
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showScanner) {
            ControlPairingScannerSheet { payload in
                Task { await companion.handleScanned(payload) }
            }
        }
        #endif
        .confirmationDialog(
            String(localized: "Forget this Mac?"),
            isPresented: $confirmForget
        ) {
            Button(String(localized: "Forget Mac"), role: .destructive) {
                Task { await companion.forgetMac() }
            }
        } message: {
            Text(String(localized: "This iPhone and its Watch will need to pair again."))
        }
    }

    private var phaseTitle: String {
        switch companion.phase {
        case .notConfigured: String(localized: "Not paired")
        case .needsEnrollment: String(localized: "Needs pairing")
        case .ready: String(localized: "Ready")
        }
    }

    @ViewBuilder
    private var macSection: some View {
        Section {
            LabeledContent(String(localized: "Status"), value: phaseTitle)
                .themedRow()
            if let fingerprint = companion.originFingerprint {
                LabeledContent(String(localized: "Shell origin")) {
                    Text(fingerprint).font(.footnote.monospaced())
                }
                .themedRow()
            }
            if let route = companion.currentRoute {
                LabeledContent(String(localized: "Route"), value: URL(string: route)?.host ?? route)
                    .themedRow()
            }
            switch companion.routeState {
            case .unknown:
                EmptyView()
            case .reachable:
                LabeledContent(String(localized: "Private route"), value: String(localized: "Reachable"))
                    .themedRow()
            case .unavailable(let reason):
                Label(reason, systemImage: "network.slash")
                    .font(.footnote)
                    .themedRow()
            }
            if let status = companion.statusMessage {
                Text(status).font(.footnote).themedRow()
            }
        } header: {
            Text(String(localized: "Mac"))
        } footer: {
            Text(String(localized: "Shell reaches your Mac privately over Tailscale. Keep Tailscale connected on this iPhone; VPN On Demand is recommended. A changed Tailscale address never requires pairing again."))
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        Section {
            #if os(iOS) && !targetEnvironment(macCatalyst)
            Button(String(localized: "Scan QR")) { showScanner = true }
                .disabled(companion.isPairing)
                .themedRow()
            #endif
            TextField(String(localized: "shell-control://pair… or shell-control://route…"), text: $pastedText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
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
        } header: {
            Text(String(localized: "Pair or update route"))
        } footer: {
            Text(String(localized: "Run shell-control setup (or pair) on your Mac and scan its QR. A route QR from shell-control route only updates how this iPhone reaches the Mac; it is not a new pairing."))
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button(String(localized: "Refresh")) { Task { await companion.refresh() } }
                .themedRow()
            if companion.phase == .ready {
                Button(String(localized: "Sign out"), role: .destructive) { Task { await companion.signOut() } }
                    .themedRow()
            }
            Button(String(localized: "Forget Mac"), role: .destructive) { confirmForget = true }
                .themedRow()
        }
    }

    @ViewBuilder
    private var watchSection: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let session = ControlPairingSession.shared
        let gateway = ControlWatchGateway.shared
        Section {
            LabeledContent(String(localized: "Watch app"), value: session.isWatchAppInstalled
                ? String(localized: "Installed")
                : String(localized: "Not installed"))
                .themedRow()
            if session.isWatchAppInstalled {
                LabeledContent(String(localized: "Reachable"), value: session.isReachable
                    ? String(localized: "Yes")
                    : String(localized: "No"))
                    .themedRow()
            }
            if let watch = gateway.boundWatch {
                LabeledContent(String(localized: "Reviewer"), value: watchStateTitle(watch.state))
                    .themedRow()
                LabeledContent(String(localized: "Watch key")) {
                    Text(watch.fingerprint).font(.footnote.monospaced())
                }
                .themedRow()
                if let code = watch.userCode {
                    LabeledContent(String(localized: "Watch code"), value: code)
                        .font(.body.monospaced())
                        .themedRow()
                    Text(String(localized: "Confirm this code on the Mac running shell-control setup."))
                        .font(.footnote)
                        .themedRow()
                }
                Button(String(localized: "Forget Watch on this iPhone"), role: .destructive) { gateway.forgetWatch() }
                    .themedRow()
            }
        } header: {
            Text(String(localized: "Apple Watch"))
        } footer: {
            Text(String(localized: "Open Shell on the Watch to set it up. The Watch signs its own decisions with its own key; this iPhone only carries them to the Mac, live, and cannot approve on its behalf."))
        }
        #endif
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

/// What the user compares with the Mac while pairing: the code and both
/// fingerprints, or a spinner until they arrive.
struct ControlPairingProgressRows: View {
    let companion: ControlCompanion

    var body: some View {
        if let progress = companion.pairingProgress {
            if progress.replacesOrigin {
                Label(String(localized: "This QR is from a different Shell origin. Confirming replaces the Mac this iPhone trusts."), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .themedRow()
            }
            LabeledContent(String(localized: "Code"), value: progress.userCode)
                .font(.body.monospaced())
                .themedRow()
            LabeledContent(String(localized: "This iPhone's key")) {
                Text(progress.deviceFingerprint).font(.footnote.monospaced())
            }
            .themedRow()
            LabeledContent(String(localized: "Mac origin")) {
                Text(progress.originFingerprint).font(.footnote.monospaced())
            }
            .themedRow()
            Text(String(localized: "Confirm this code and fingerprint on the Mac running shell-control setup."))
                .font(.footnote)
                .themedRow()
        } else if companion.isPairing {
            ProgressView().themedRow()
        }
    }
}

/// The explicit trust decision before pairing: which Mac key will be
/// pinned, reached where, and whether it replaces the Mac already trusted.
struct ControlPairingConfirmation: View {
    let companion: ControlCompanion
    let pending: ControlCompanion.PendingPairing
    @State private var confirmReplace = false

    var body: some View {
        Group {
            Text(title)
                .font(.headline)
                .themedRow()
            LabeledContent(String(localized: "Mac origin")) {
                Text(pending.invitation.origin.fingerprint).font(.footnote.monospaced())
            }
            .themedRow()
            LabeledContent(String(localized: "Route"), value: pending.invitation.route.url.host ?? pending.invitation.route.url.absoluteString)
                .themedRow()
            if pending.fromLink {
                Label(String(localized: "This came from a link. Pair only if you just ran shell-control on your own Mac."), systemImage: "link")
                    .font(.footnote)
                    .themedRow()
            }
            if pending.assessment == .differentOrigin {
                Label(String(localized: "This is a different Mac key. Pairing replaces the Mac this iPhone trusts and its Watch must be set up again."), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .themedRow()
                Button(String(localized: "Replace trusted Mac"), role: .destructive) { confirmReplace = true }
                    .themedRow()
            } else {
                Button(String(localized: "Pair with this Mac")) {
                    Task { await companion.confirmPendingPairing() }
                }
                .themedRow()
            }
            Button(String(localized: "Cancel"), role: .cancel) { companion.cancelPendingPairing() }
                .themedRow()
        }
        .confirmationDialog(
            String(localized: "Replace the trusted Mac?"),
            isPresented: $confirmReplace
        ) {
            Button(String(localized: "Replace trusted Mac"), role: .destructive) {
                Task { await companion.confirmPendingPairing() }
            }
        } message: {
            Text(String(localized: "The current Mac will no longer be trusted by this iPhone or its Watch."))
        }
    }

    private var title: String {
        switch pending.assessment {
        case .firstPairing: String(localized: "Pair with this Mac?")
        case .sameOrigin: String(localized: "Pair again with your Mac?")
        case .differentOrigin: String(localized: "Pair with a different Mac?")
        }
    }
}

/// Presents a staged pairing that arrived as a link, wherever the user is, so
/// it is confirmed or cancelled rather than silently waiting. After the yes
/// the sheet stays up with the code and fingerprints to compare on the Mac,
/// and the outcome, until the user dismisses it.
struct ControlPairingLinkModifier: ViewModifier {
    @State private var companion = ControlCompanion.shared
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: companion.pendingPairing?.fromLink == true, initial: true) { _, fromLink in
                if fromLink {
                    isPresented = true
                } else if !companion.isPairing, companion.pairingProgress == nil {
                    // Cancelled rather than confirmed: nothing to show.
                    isPresented = false
                }
            }
            .sheet(isPresented: $isPresented, onDismiss: {
                if companion.pendingPairing?.fromLink == true { companion.cancelPendingPairing() }
            }) {
                NavigationStack {
                    List {
                        if let pending = companion.pendingPairing {
                            ControlPairingConfirmation(companion: companion, pending: pending)
                        } else {
                            ControlPairingProgressRows(companion: companion)
                            if !companion.isPairing, let status = companion.statusMessage {
                                Text(status).font(.footnote).themedRow()
                            }
                        }
                    }
                    .themedList()
                    .navigationTitle(String(localized: "Pair with Mac"))
                    .toolbar {
                        if companion.pendingPairing == nil {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "Done")) { isPresented = false }
                            }
                        }
                    }
                }
            }
    }
}

/// Presents the phone review surface when a notification response selected an
/// intent. The payload never authorizes anything.
struct ControlReviewPresentationModifier: ViewModifier {
    @State private var requestID: ControlID?

    func body(content: Content) -> some View {
        content
            .modifier(ControlPairingLinkModifier())
            .sheet(isPresented: Binding(
                get: { requestID != nil },
                set: { if !$0 { requestID = nil } }
            )) {
                if let requestID {
                    NavigationStack {
                        ControlReviewView(companion: .shared, requestID: requestID)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(String(localized: "Close")) { self.requestID = nil }
                                }
                            }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ControlNotifications.reviewRequested)) { notification in
                if let raw = notification.userInfo?["request_id"] as? String {
                    requestID = ControlID(raw)
                    ControlNotifications.pendingIntent = nil
                }
            }
            .task {
                // A tap that LAUNCHES the app delivers its response before this
                // scene installs the receiver above, so the post lands on
                // nobody. The intent is parked for exactly that case.
                if let intent = ControlNotifications.pendingIntent {
                    ControlNotifications.pendingIntent = nil
                    requestID = intent.requestID
                }
                await ControlCompanion.shared.start()
            }
    }
}
