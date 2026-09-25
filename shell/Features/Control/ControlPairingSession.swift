//
//  ControlPairingSession.swift
//  shell
//
//  Phone-side WatchConnectivity: the required transport of the
//  `shell-watch-gateway/1` profile. Interactive Watch requests arrive as
//  `sendMessageData` and are answered from a live Mac round trip; background
//  channels carry only stale-tolerant context out, and nothing they deliver
//  in is acted on (docs/specs/control-protocol.md section 10.1).
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

    /// Sends the Watch its stale-tolerant inbox summary.
    @MainActor
    static func publish(_ context: WatchGatewayContext) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        ControlPairingSession.shared.publish(context)
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
    private(set) var isPaired = false

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        refreshState(from: session)
    }

    func publish(_ context: WatchGatewayContext) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled,
              let payload = try? context.applicationContext()
        else { return }
        try? WCSession.default.updateApplicationContext(payload)
    }

    private func refreshState(from session: WCSession) {
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor in refreshState(from: session) }
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

    /// The interactive channel: every Watch read, challenge, and decision
    /// arrives here and is answered only after a live Mac round trip.
    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let reply = UncheckedReply(replyHandler)
        Task {
            let gateway = await ControlWatchGateway.shared
            reply.send(await gateway.handle(messageData))
        }
    }

    /// Queued delivery never authorizes: a Watch command that arrives this way
    /// is dropped, not deferred (docs/specs/control-protocol.md section 10.2).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        _ = WatchGatewayRouter.refusesBackground(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        _ = WatchGatewayRouter.refusesBackground(applicationContext)
    }

    /// A reply-less message is not the interactive channel either.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        _ = WatchGatewayRouter.refusesBackground(message)
    }
}

/// `WCSession` reply handlers are not `Sendable`; each is called exactly once.
private nonisolated struct UncheckedReply: @unchecked Sendable {
    let handler: (Data) -> Void
    init(_ handler: @escaping (Data) -> Void) { self.handler = handler }
    func send(_ data: Data) { handler(data) }
}
#endif
