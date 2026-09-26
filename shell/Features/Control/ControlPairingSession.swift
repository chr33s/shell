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
        refreshState(paired: session.isPaired, installed: session.isWatchAppInstalled, reachable: session.isReachable)
    }

    func publish(_ context: WatchGatewayContext) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled,
              let payload = try? context.applicationContext()
        else { return }
        try? WCSession.default.updateApplicationContext(payload)
    }

    private func refreshState(paired: Bool, installed: Bool, reachable: Bool) {
        isPaired = paired
        isWatchAppInstalled = installed
        isReachable = reachable
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        Task { @MainActor in refreshState(paired: paired, installed: installed, reachable: reachable) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        Task { @MainActor in refreshState(paired: paired, installed: installed, reachable: reachable) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        Task { @MainActor in refreshState(paired: paired, installed: installed, reachable: reachable) }
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
