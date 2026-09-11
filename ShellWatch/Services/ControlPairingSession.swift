import Foundation
import Observation
import WatchConnectivity
import ShellControlClient

/// Watch-side WatchConnectivity for setup assistance. The Watch still owns its
/// key and talks HTTPS to the broker; this only receives a start hint, a
/// runtime broker URL, and publishes an enrollment reference
/// (spec.watch.md sections 5 and 7).
@MainActor
@Observable
final class ControlPairingSession: NSObject, WCSessionDelegate {
    static let shared = ControlPairingSession()

    private(set) var startEnrollmentRequested = false
    private(set) var isReachable = false
    private(set) var inboundBrokerURL: URL?
    var onBrokerURL: ((URL) -> Void)?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        isReachable = session.isReachable
        if let inbound = ControlPairingMessage(applicationContext: session.receivedApplicationContext) {
            adopt(inbound)
        }
    }

    func consumeStartEnrollmentRequest() -> Bool {
        let requested = startEnrollmentRequested
        startEnrollmentRequested = false
        return requested
    }

    /// Wait for the phone to deliver a broker URL, without blocking forever if
    /// this Watch is enrolling independently.
    func waitForBrokerURL(timeout: TimeInterval) async -> URL? {
        if let inboundBrokerURL { return inboundBrokerURL }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let inboundBrokerURL { return inboundBrokerURL }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return inboundBrokerURL
    }

    func publishEnrollment(_ enrollment: ControlPairingMessage.EnrollmentReference, brokerURL: URL) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let message = ControlPairingMessage(brokerURL: brokerURL, startEnrollment: false, enrollment: enrollment)
        guard let context = try? message.applicationContext() else { return }
        try? WCSession.default.updateApplicationContext(context)
    }

    private func adopt(_ message: ControlPairingMessage) {
        inboundBrokerURL = message.brokerURL
        onBrokerURL?(message.brokerURL)
        if message.startEnrollment {
            startEnrollmentRequested = true
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor in
            isReachable = session.isReachable
            if let inbound = ControlPairingMessage(applicationContext: session.receivedApplicationContext) {
                adopt(inbound)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in isReachable = session.isReachable }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            guard let inbound = ControlPairingMessage(applicationContext: applicationContext) else { return }
            adopt(inbound)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if message["start_enrollment"] as? Bool == true {
                startEnrollmentRequested = true
            }
        }
    }
}
