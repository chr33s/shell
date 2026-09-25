//
//  ControlWatchGateway.swift
//  shell
//
//  The iPhone as network gateway for its paired Watch. Live Watch requests
//  are relayed to the Mac over this iPhone's own Tailscale session; the
//  Watch's decisions stay signed by the Watch's key, and nothing the Watch
//  asks for is ever held for later (docs/specs/control-protocol.md sections 10.1-10.4).
//

import Foundation
import Observation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@MainActor
@Observable
final class ControlWatchGateway {
    static let shared = ControlWatchGateway(gateway: ControlCompanion.shared.gateway)

    /// The Watch this iPhone gateways for, as last reported by the Mac.
    private(set) var boundWatch: WatchReviewerStatus?

    @ObservationIgnored let router: WatchGatewayRouter
    @ObservationIgnored private let binding: any WatchBindingStore

    init(gateway: ControlGatewaySession, binding: any WatchBindingStore = KeychainWatchBindingStore()) {
        self.binding = binding
        self.router = WatchGatewayRouter(
            client: { try await gateway.authenticatedClient() },
            binding: binding,
            recover: { await gateway.recover(from: $0) }
        )
        boundWatch = try? binding.loadBoundWatch()
    }

    /// Handles one interactive `sendMessageData` request.
    nonisolated func handle(_ data: Data) async -> Data {
        let reply = await router.handle(data)
        await MainActor.run { self.boundWatch = try? self.binding.loadBoundWatch() }
        return reply
    }

    /// Forgets the Watch binding locally; re-binding needs Mac confirmation.
    func forgetWatch() {
        try? binding.storeBoundWatch(nil)
        boundWatch = nil
    }

    /// Stale-tolerant state for the Watch's inbox badge and freshness line.
    /// It never contains an approval command.
    func context(pending: [ApprovalRecord], refreshedAt: ControlTimestamp?, macReachable: Bool, refreshRequested: Bool) -> WatchGatewayContext {
        WatchGatewayContext(
            pendingCount: pending.count,
            requestIDs: pending.map(\.spec.requestID),
            refreshedAt: refreshedAt,
            refreshRequested: refreshRequested,
            macReachable: macReachable,
            reviewer: boundWatch
        )
    }
}
