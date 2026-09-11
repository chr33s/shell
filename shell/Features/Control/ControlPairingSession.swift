//
//  ControlPairingSession.swift
//  shell
//
//  Phone-side WatchConnectivity for setup assistance. It never carries private
//  keys, session tokens, or approval commands (spec.watch.md sections 5 and 7).
//

import Foundation
import Observation
import ShellControlClient

enum ControlPairingSupport {
    @MainActor
    static func activate() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        ControlPairingSession.shared.activate()
        #endif
    }

    @MainActor
    static func publishBroker(brokerURL: URL, startEnrollment: Bool) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        ControlPairingSession.shared.publishBrokerContext(brokerURL: brokerURL, startEnrollment: startEnrollment)
        #endif
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
import WatchConnectivity

@MainActor
@Observable
final class ControlPairingSession: NSObject, WCSessionDelegate {
    static let shared = ControlPairingSession()

    private(set) var isWatchAppInstalled = false
    private(set) var isReachable = false
    private(set) var inboundEnrollment: ControlPairingMessage.EnrollmentReference?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        refreshState(from: session)
        if let inbound = ControlPairingMessage(applicationContext: session.receivedApplicationContext) {
            adopt(inbound)
        }
        if let brokerURL = ControlCompanion.shared.resolvedBrokerURL {
            publishBrokerContext(brokerURL: brokerURL, startEnrollment: false)
        }
    }

    /// Ask the Watch to begin independent enrollment. The Watch still generates
    /// its own key; this only delivers a hint (spec.watch.md section 5).
    func requestWatchEnrollment() {
        guard let brokerURL = ControlCompanion.shared.resolvedBrokerURL else { return }
        publishBrokerContext(brokerURL: brokerURL, startEnrollment: true)
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(
            ["type": ControlPairingMessage.messageType, "start_enrollment": true],
            replyHandler: nil,
            errorHandler: nil
        )
    }

    func publishBrokerContext(brokerURL: URL, startEnrollment: Bool) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let message = ControlPairingMessage(brokerURL: brokerURL, startEnrollment: startEnrollment)
        guard let context = try? message.applicationContext() else { return }
        try? WCSession.default.updateApplicationContext(context)
    }

    private func refreshState(from session: WCSession) {
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }

    private func adopt(_ message: ControlPairingMessage) {
        if let enrollment = message.enrollment, !enrollment.isExpired() {
            inboundEnrollment = enrollment
        } else {
            inboundEnrollment = nil
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor in
            refreshState(from: session)
            if activationState == .activated, let brokerURL = ControlCompanion.shared.resolvedBrokerURL {
                publishBrokerContext(brokerURL: brokerURL, startEnrollment: false)
            }
            if let inbound = ControlPairingMessage(applicationContext: session.receivedApplicationContext) {
                adopt(inbound)
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in refreshState(from: session) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in refreshState(from: session) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            if let inbound = ControlPairingMessage(applicationContext: applicationContext) {
                adopt(inbound)
            }
        }
    }
}
#endif
