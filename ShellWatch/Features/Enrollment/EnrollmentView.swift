import SwiftUI
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// Independent setup: a short code on the Watch, confirmed in an authenticated
/// browser on any suitable device. No iPhone app is required
/// (spec.watch.md section 5).
struct EnrollmentView: View {
    @Environment(ControlSession.self) private var session

    @State private var userCode: String?
    @State private var verificationURI: String?
    @State private var fingerprint: String?
    @State private var status: String = String(localized: "Ready to set up")
    @State private var isRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Set up Shell Watch"))
                    .font(.headline)
                if let userCode {
                    Text(userCode)
                        .font(.system(.title2, design: .monospaced))
                }
                if let verificationURI {
                    Text(String(localized: "Sign in at \(verificationURI) and confirm this code."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let fingerprint {
                    // The same fingerprint is shown on the confirmation page.
                    Text(String(localized: "Key fingerprint \(fingerprint)"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(status)
                    .font(.caption)
                if !isRunning {
                    Button(String(localized: "Start setup")) {
                        Task { await enroll() }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .task(id: ControlPairingSession.shared.startEnrollmentRequested) {
            guard ControlPairingSession.shared.consumeStartEnrollmentRequest() else { return }
            guard !isRunning else { return }
            await enroll()
        }
    }

    private func enroll() async {
        isRunning = true
        defer { isRunning = false }
        do {
            // A new P-256 key is generated locally; only its public half leaves.
            let key = InMemoryDeviceKey()
            let store = KeychainCredentialStore(
                service: "dev.chr33s.shell.control",
                accessGroup: ShellWatchConfiguration.keychainAccessGroup
            )
            try store.storeSigningKey(key)
            let coordinator = EnrollmentCoordinator(baseURL: session.brokerURL)
            let started = try await coordinator.start(key: key, platform: .watchOS, label: WKInterfaceDeviceLabel.current)
            userCode = started.authorization.userCode
            verificationURI = started.authorization.verificationURI
            fingerprint = started.fingerprint
            status = String(localized: "Waiting for confirmation…")
            ControlPairingSession.shared.publishEnrollment(
                .init(
                    userCode: started.authorization.userCode,
                    verificationURI: started.authorization.verificationURI,
                    verificationURIComplete: started.authorization.verificationURIComplete,
                    fingerprint: started.fingerprint,
                    expiresAt: started.authorization.expiresAt,
                    platform: "watchOS",
                    label: WKInterfaceDeviceLabel.current
                ),
                brokerURL: session.brokerURL
            )

            var interval = started.authorization.interval
            while Date() < started.authorization.expiresAt.date {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                do {
                    let token = try await coordinator.poll(deviceCode: started.authorization.deviceCode)
                    let deviceSession = try await coordinator.complete(
                        enrollmentID: started.enrollmentID,
                        enrollmentToken: token,
                        challenge: started.challenge,
                        key: key
                    )
                    try store.storeSession(deviceSession)
                    status = String(localized: "Enrolled")
                    await session.adopt(session: deviceSession, key: key)
                    return
                } catch EnrollmentError.authorizationPending {
                    continue
                } catch EnrollmentError.slowDown {
                    // RFC 8628: widen the interval rather than hammering.
                    interval += 5
                } catch EnrollmentError.accessDenied {
                    status = String(localized: "Setup was declined")
                    return
                } catch EnrollmentError.expired {
                    status = String(localized: "The code expired — start again")
                    return
                }
            }
            status = String(localized: "The code expired — start again")
        } catch {
            status = String(describing: error)
        }
    }
}

/// A display label for the enrolling device, shown on the confirmation page.
enum WKInterfaceDeviceLabel {
    static var current: String {
        #if canImport(WatchKit)
        return "Apple Watch"
        #else
        return "Watch"
        #endif
    }
}
