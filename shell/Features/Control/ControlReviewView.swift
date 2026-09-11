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
                Button(String(localized: "Approve once")) { confirming = .approve }
                    .disabled(!record.spec.allowedDecisions.contains(.approve) || record.projection.resolution != .pending)
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
                    Task { await companion.decide(decision, on: record) }
                    confirming = nil
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) { confirming = nil }
        }
    }
}

/// Optional phone setup: the same device-authorization flow the Watch uses,
/// confirmed in Safari on this device. It never copies private keys or
/// long-lived credentials between devices (spec.watch.md section 5).
struct ControlSetupView: View {
    let companion: ControlCompanion

    @State private var userCode: String?
    @State private var fingerprint: String?
    @State private var status = String(localized: "Not set up")
    @State private var isEnrolling = false
    @State private var pairingText = ""
    @State private var showScanner = false

    var body: some View {
        List {
            Section {
                LabeledContent(String(localized: "Status"), value: phaseTitle)
                    .themedRow()
                if let host = companion.resolvedBrokerURL?.host {
                    LabeledContent(String(localized: "Broker"), value: host)
                        .themedRow()
                }
            } footer: {
                Text(footerText)
            }

            pairingSection

            if companion.phase == .notConfigured {
                Section {
                    Text(String(localized: "Run npx @chr33s/shell on your Mac, then scan the QR or paste the broker URL."))
                        .foregroundStyle(.secondary)
                        .themedRow()
                }
            } else {
                thisDeviceSection
                watchSection
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Control"))
        .task { await companion.start() }
        .onAppear { refreshStatusFromPhase() }
        .onChange(of: companion.phase) { _, _ in refreshStatusFromPhase() }
        .onReceive(NotificationCenter.default.publisher(for: .controlPairingReceived)) { _ in
            Task { await companion.start(); refreshStatusFromPhase() }
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showScanner) {
            ControlPairingScannerSheet { url in
                Task { _ = await companion.applyPairedBroker(url) }
            }
        }
        #endif
    }

    private var phaseTitle: String {
        switch companion.phase {
        case .notConfigured: String(localized: "Not configured")
        case .needsEnrollment: String(localized: "Needs setup")
        case .ready: String(localized: "Ready")
        }
    }

    private var footerText: String {
        String(localized: "On your Mac run npx @chr33s/shell, then scan the QR. This device and Apple Watch each enrol with their own key. The CLI confirms them; credentials are never copied.")
    }

    @ViewBuilder
    private var pairingSection: some View {
        Section {
            TextField(String(localized: "https://… or shell-control://pair"), text: $pairingText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .themedRow()
            Button(String(localized: "Use this broker")) {
                Task { await submitPairingText() }
            }
            .disabled(pairingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .themedRow()
            #if os(iOS) && !targetEnvironment(macCatalyst)
            Button(String(localized: "Scan QR")) { showScanner = true }
                .themedRow()
            #endif
            if let token = companion.pairingToken {
                LabeledContent(String(localized: "Pairing code"), value: token)
                    .font(.body.monospaced())
                    .themedRow()
            }
            if companion.isRuntimePaired {
                Button(String(localized: "Forget paired broker"), role: .destructive) {
                    Task { await companion.forgetPairedBroker() }
                }
                .themedRow()
            }
        } header: {
            Text(String(localized: "Pair with Mac"))
        } footer: {
            Text(String(localized: "Paste the URL printed by npx @chr33s/shell, or scan its QR. Changing broker signs this device out."))
        }
    }

    private func submitPairingText() async {
        let trimmed = pairingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ControlBrokerAddress.parsePairing(url) != nil else {
            status = String(localized: "That is not an acceptable broker URL.")
            return
        }
        _ = await companion.applyPairedBroker(url)
        pairingText = ""
    }

    @ViewBuilder
    private var thisDeviceSection: some View {
        Section {
            if let userCode {
                LabeledContent(String(localized: "Code"), value: userCode)
                    .font(.body.monospaced())
                    .themedRow()
            }
            if let fingerprint {
                LabeledContent(String(localized: "Key fingerprint"), value: fingerprint)
                    .font(.footnote.monospaced())
                    .themedRow()
            }
            Text(status)
                .font(.footnote)
                .themedRow()
            Button(String(localized: "Start setup")) { Task { await enroll() } }
                .disabled(isEnrolling || companion.phase == .notConfigured)
                .themedRow()
            if companion.phase == .ready {
                Button(String(localized: "Sign out"), role: .destructive) {
                    companion.signOut()
                    userCode = nil
                    fingerprint = nil
                    status = String(localized: "Not set up")
                }
                .themedRow()
            }
        } header: {
            Text(String(localized: "This device"))
        }
    }

    @ViewBuilder
    private var watchSection: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let pairing = ControlPairingSession.shared
        Section {
            LabeledContent(String(localized: "Watch app"), value: pairing.isWatchAppInstalled
                ? String(localized: "Installed")
                : String(localized: "Not installed"))
                .themedRow()
            if pairing.isWatchAppInstalled {
                LabeledContent(String(localized: "Reachable"), value: pairing.isReachable
                    ? String(localized: "Yes")
                    : String(localized: "No"))
                    .themedRow()
            }
            if let enrollment = pairing.inboundEnrollment, !enrollment.isExpired() {
                LabeledContent(String(localized: "Watch code"), value: enrollment.userCode)
                    .font(.body.monospaced())
                    .themedRow()
                LabeledContent(String(localized: "Watch fingerprint"), value: enrollment.fingerprint)
                    .font(.footnote.monospaced())
                    .themedRow()
                Text(String(localized: "Confirm this code on the Mac running npx @chr33s/shell."))
                    .font(.footnote)
                    .themedRow()
            }
            Button(String(localized: "Set up Apple Watch")) {
                pairing.requestWatchEnrollment()
            }
            .disabled(!pairing.isWatchAppInstalled)
            .themedRow()
        } header: {
            Text(String(localized: "Apple Watch"))
        } footer: {
            Text(String(localized: "The Watch generates its own key. Confirming here only approves that enrollment."))
        }
        #endif
    }

    private func refreshStatusFromPhase() {
        guard !isEnrolling else { return }
        switch companion.phase {
        case .notConfigured: status = String(localized: "Not configured")
        case .needsEnrollment: status = String(localized: "Not set up")
        case .ready: status = String(localized: "Enrolled")
        }
    }

    private var deviceLabel: String {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #elseif os(visionOS)
        return "Vision"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    private func enroll() async {
        guard let brokerURL = companion.resolvedBrokerURL else { return }
        isEnrolling = true
        defer { isEnrolling = false }
        do {
            let key = InMemoryDeviceKey()
            let store = KeychainCredentialStore(service: "dev.chr33s.shell.control")
            try store.storeSigningKey(key)
            let coordinator = EnrollmentCoordinator(baseURL: brokerURL)
            let started = try await coordinator.start(key: key, platform: .iOS, label: deviceLabel)
            userCode = started.authorization.userCode
            fingerprint = started.fingerprint
            status = String(localized: "Waiting for confirmation on your Mac…")
            var interval = started.authorization.interval
            while Date() < started.authorization.expiresAt.date {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                do {
                    let token = try await coordinator.poll(deviceCode: started.authorization.deviceCode)
                    let session = try await coordinator.complete(
                        enrollmentID: started.enrollmentID,
                        enrollmentToken: token,
                        challenge: started.challenge,
                        key: key
                    )
                    try store.storeSession(session)
                    status = String(localized: "Enrolled")
                    await companion.start()
                    return
                } catch EnrollmentError.authorizationPending {
                    continue
                } catch EnrollmentError.slowDown {
                    interval += 5
                } catch EnrollmentError.accessDenied {
                    status = String(localized: "Setup was declined")
                    return
                }
            }
            status = String(localized: "The code expired — start again")
        } catch {
            status = String(describing: error)
        }
    }
}

/// Presents the phone review surface when a notification response selected an
/// intent. The payload never authorizes anything.
struct ControlReviewPresentationModifier: ViewModifier {
    @State private var requestID: ControlID?

    func body(content: Content) -> some View {
        content
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
