import Foundation
import Observation
import WatchConnectivity
import ShellControlClient

/// The Watch's only transport: WatchConnectivity to its paired iPhone, which
/// reaches the Mac over Tailscale. The Watch has no URL, no Tailscale session,
/// and no network credential of its own (docs/specs/control-protocol.md sections 2.5
/// and 11).
@MainActor
@Observable
final class WatchConnectivityGateway: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityGateway()

    /// `WCSession.isReachable`: decisions are enabled only while this is true.
    private(set) var isReachable = false
    /// The latest stale-tolerant summary the iPhone pushed in the background.
    private(set) var context: WatchGatewayContext?
    @ObservationIgnored var onContext: ((WatchGatewayContext) -> Void)?
    @ObservationIgnored var onReachabilityChange: ((Bool) -> Void)?

    private override init() {
        super.init()
    }

    nonisolated var link: any WatchGatewayLink { WCSessionGatewayLink() }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        isReachable = session.activationState == .activated && session.isReachable
        adopt(WatchGatewayContext(applicationContext: session.receivedApplicationContext))
    }

    private func adopt(_ context: WatchGatewayContext?) {
        guard let context else { return }
        self.context = context
        onContext?(context)
    }

    private func updateReachability(_ session: WCSession) {
        applyReachability(session.activationState == .activated && session.isReachable)
    }

    private func applyReachability(_ reachable: Bool) {
        guard reachable != isReachable else { return }
        isReachable = reachable
        onReachabilityChange?(reachable)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let context = WatchGatewayContext(applicationContext: session.receivedApplicationContext)
        let reachable = activationState == .activated && session.isReachable
        Task { @MainActor in
            applyReachability(reachable)
            adopt(context)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.activationState == .activated && session.isReachable
        Task { @MainActor in applyReachability(reachable) }
    }

    /// Background context is display state only: a pending count, request
    /// IDs, and freshness. Anything that does not parse as exactly that —
    /// including a decision-like object — is dropped.
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let context = WatchGatewayContext(applicationContext: applicationContext)
        Task { @MainActor in adopt(context) }
    }

    /// Queued user-info transfers carry no authority and are ignored.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {}
}

/// `sendMessageData` with a reply: the only way a Watch request leaves the
/// Watch, and only while the iPhone is reachable.
struct WCSessionGatewayLink: WatchGatewayLink {
    func isReachable() async -> Bool {
        await MainActor.run {
            WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
        }
    }

    func send(_ data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessageData(
                data,
                replyHandler: { continuation.resume(returning: $0) },
                // Any WatchConnectivity failure means the iPhone did not
                // answer: typed here so callers never guess from the error.
                errorHandler: { _ in continuation.resume(throwing: WatchGatewayError.iPhoneUnreachable) }
            )
        }
    }
}
