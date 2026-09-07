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

/// Optional phone setup: the same device-authorization flow the Watch uses.
/// It never copies private keys or long-lived credentials between devices
/// (spec.watch.md section 5).
struct ControlSetupView: View {
    let companion: ControlCompanion

    @State private var userCode: String?
    @State private var verificationURI: String?
    @State private var fingerprint: String?
    @State private var status = String(localized: "Not set up")

    var body: some View {
        Form {
            Section {
                if let userCode {
                    LabeledContent(String(localized: "Code"), value: userCode)
                        .font(.title3.monospaced())
                }
                if let verificationURI {
                    LabeledContent(String(localized: "Confirm at"), value: verificationURI)
                }
                if let fingerprint {
                    LabeledContent(String(localized: "Key fingerprint"), value: fingerprint)
                        .font(.footnote.monospaced())
                }
                Text(status).font(.footnote)
            }
            Section {
                Button(String(localized: "Start setup")) { Task { await enroll() } }
                    .disabled(ControlCompanion.brokerURL == nil)
            } footer: {
                Text(String(localized: "Setting up this iPhone is optional. Shell Watch enrols on its own and does not need this app."))
            }
        }
        .navigationTitle(String(localized: "Control companion"))
    }

    private func enroll() async {
        guard let brokerURL = ControlCompanion.brokerURL else { return }
        do {
            let key = InMemoryDeviceKey()
            let store = KeychainCredentialStore(service: "dev.chr33s.shell.control")
            try store.storeSigningKey(key)
            let coordinator = EnrollmentCoordinator(baseURL: brokerURL)
            let started = try await coordinator.start(key: key, platform: .iOS, label: "iPhone")
            userCode = started.authorization.userCode
            verificationURI = started.authorization.verificationURI
            fingerprint = started.fingerprint
            status = String(localized: "Waiting for confirmation…")
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
