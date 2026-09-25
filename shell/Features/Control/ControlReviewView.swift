//
//  ControlReviewView.swift
//  shell
//
//  The phone's larger review surface. A request whose `minimum_review` is
//  `full` can only be completed here or on another enrolled full-review
//  client; until one exists it stays unapproved or expires
//  (docs/specs/control-protocol.md section 11.2). A request ID that names an agent question
//  rather than an approval opens the question review instead
//  (docs/specs/agent-relay.md section 11.3).
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
    @State private var input: InputRecord?
    @State private var failure: String?
    @State private var confirming: ControlDecision?

    var body: some View {
        Group {
            if let input {
                ControlAgentInputView(companion: companion, requestID: requestID, initial: input)
            } else if let record {
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
            do {
                switch try await companion.lookup(requestID) {
                case .approval(let found): record = found
                case .input(let found): input = found
                }
            } catch {
                failure = String(describing: error)
            }
        }
    }

    @ViewBuilder
    private func form(_ record: ApprovalRecord) -> some View {
        let now = ControlTimestamp(Date())
        Form {
            Section {
                if SetupTestFixture.isWatchTest(record.spec) {
                    // A label only: approving here is this iPhone's decision,
                    // which does not test the Watch.
                    Label(String(localized: "This setup test is for your Apple Watch. Approve it on the Watch to test the Watch."),
                          systemImage: "applewatch")
                        .font(.footnote)
                }
                if case .agentTool = record.spec.operation {
                    // Adapter-supplied text, attributed as such.
                    ControlAgentSuppliedText(text: record.spec.summary, maxScalars: 200, font: .headline)
                } else {
                    Text(DisplaySanitizer.sanitize(record.spec.summary, maxScalars: 200).text)
                        .font(.headline)
                }
                LabeledContent(String(localized: "Origin"), value: record.spec.originID.rawValue)
                LabeledContent(String(localized: "Run"), value: record.spec.runID.rawValue)
                LabeledContent(String(localized: "Expires"), value: record.spec.expiresAt.rfc3339)
                LabeledContent(String(localized: "Digest"), value: record.requestHash)
                    .font(.footnote.monospaced())
            }
            if case .agentTool(let operation) = record.spec.operation {
                agentSections(record, operation: operation, now: now)
            } else if case .exec(let operation) = record.spec.operation {
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
                    .disabled(!record.canApprove(at: now, review: ControlCompanion.review) || Self.hidesContent(record))
                if record.spec.allowedDecisions.contains(.approve),
                   case .reviewElsewhere(let reason) = record.approvability(at: now, review: ControlCompanion.review) {
                    Text(ControlCompanion.reviewElsewhereText(reason))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if Self.hidesContent(record) {
                    // Hidden or truncated authorization-relevant content
                    // prevents confirmation (docs/specs/agent-relay.md 12.1).
                    Text(String(localized: "Review on Mac: this operation is too large to show in full here."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if case .agentTool = record.spec.operation {
                    Text(String(localized: "Approve once answers this one native permission gate. It does not promise a single subprocess, network request, or file write."))
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

    /// Whether any authorization-relevant part of an agent operation could
    /// not be shown in full here.
    static func hidesContent(_ record: ApprovalRecord) -> Bool {
        guard case .agentTool(let operation) = record.spec.operation else { return false }
        return AgentOperationDisplay(operation).isTruncated
    }

    /// Provider/session context, the exact operation, and — once decided —
    /// detailed delivery, which is distinct from the base dispatch.
    @ViewBuilder
    private func agentSections(_ record: ApprovalRecord, operation: AgentToolOperation, now: ControlTimestamp) -> some View {
        let agent = companion.agent
        Section {
            LabeledContent(String(localized: "Freshness"), value: ControlAgentText.freshness(record.projection.presence, now: now))
            LabeledContent(String(localized: "Review"), value: ControlAgentText.review(record.spec.minimumReview))
            if let reference = agent.inbox.approvals[record.spec.requestID], record.projection.resolution != .pending {
                LabeledContent(String(localized: "Delivery"), value: ControlAgentText.dispatch(reference.dispatch))
                if let task = ControlAgentText.operation(reference.operation) {
                    LabeledContent(String(localized: "Task"), value: task)
                }
            }
        }
        ControlAgentSessionSection(
            provider: operation.provider,
            providerBuild: operation.providerBuild,
            session: agent.inbox.session(operation.agentSessionID)
        )
        ControlAgentOperationSections(operation: operation)
    }
}

/// Settings → Control: evidence-based status, the requests waiting on this
/// iPhone, and the entry to guided setup. Private keys never leave the device
/// that made them (docs/specs/control-protocol.md sections 5.2, 5.3, and 4.5;
/// docs/specs/control-setup.md section 5).
struct ControlSetupView: View {
    let companion: ControlCompanion

    @State private var pastedText = ""
    @State private var showScanner = false

    var body: some View {
        List {
            #if targetEnvironment(macCatalyst)
            // This Mac as the bundled Control host (docs/specs/agent-relay.md 18.4).
            ControlHostEntrySection(lifecycle: .shared)
            #endif
            if companion.phase == .notConfigured {
                invitationSection
            } else {
                ControlStatusSection(companion: companion)
                ControlActionsSection(companion: companion)
                if companion.phase == .ready {
                    ControlRequestsSection(companion: companion)
                    ControlAgentSection(companion: companion)
                    ControlRemoteAlertsSection(companion: companion)
                }
            }
            pairingSection
            watchSection
            if companion.phase != .notConfigured {
                Section {
                    NavigationLink(String(localized: "Sign out or forget Mac…")) {
                        ControlRecoveryView(companion: companion)
                    }
                    .themedRow()
                } footer: {
                    Text(String(localized: "Recovery actions remove trust or credentials and are kept apart from everyday controls."))
                }
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Control"))
        .task { await companion.start() }
        .refreshable { await companion.refresh(forceAgent: true) }
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
    }

    /// Never configured: a neutral invitation, not a warning.
    @ViewBuilder
    private var invitationSection: some View {
        Section {
            Text(String(localized: "Review permission requests from your Mac on this iPhone, privately over Tailscale. An Apple Watch and remote alerts are optional."))
                .themedRow()
            NavigationLink(String(localized: "Set up Control")) {
                ControlSetupGuideView(companion: companion)
            }
            .themedRow()
        } footer: {
            Text(String(localized: "Terminal, SSH, and tmux never need Control."))
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
                .accessibilityLabel(String(localized: "Pairing or route link"))
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
            if companion.phase == .notConfigured, let status = companion.statusMessage {
                Text(status).font(.footnote).themedRow()
            }
        } header: {
            Text(String(localized: "Pair or update route"))
        } footer: {
            Text(String(localized: "Run shell-control setup --guided (or pair) on your Mac and scan its QR. A route QR from shell-control route only updates how this iPhone reaches the Mac; it is not a new pairing."))
        }
    }

    @ViewBuilder
    private var watchSection: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if companion.phase == .ready {
            Section {
                NavigationLink {
                    ControlWatchSetupView(companion: companion)
                } label: {
                    LabeledContent(String(localized: "Apple Watch"), value: ControlStatusText.watch(ControlWatchGateway.shared.boundWatch, installed: ControlPairingSession.shared.isWatchAppInstalled))
                }
                .themedRow()
            } header: {
                Text(String(localized: "Apple Watch (optional)"))
            } footer: {
                Text(String(localized: "The Watch signs its own decisions with its own key; this iPhone only carries them to the Mac, live, and cannot approve on its behalf."))
            }
        }
        #endif
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
