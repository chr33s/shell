//
//  ControlOriginTrust.swift
//  shell
//
//  Pairing and route updates. The Shell origin key is identity; the
//  Tailscale URL is routing. A scanned setup QR pins the origin, a scanned
//  route QR only moves routing, and neither ever copies a private key
//  (spec.iphone-gateway.md sections 7, 9, and 24).
//

import Foundation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// What a scanned or pasted payload asks for.
enum ControlScannedPayload {
    case pairing(PairingInvitation)
    case routeUpdate(OriginRouteUpdate)

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invitation = try? PairingInvitation(scanned: trimmed) {
            self = .pairing(invitation)
        } else if let url = URL(string: trimmed), let update = try? OriginRouteUpdate(link: url) {
            self = .routeUpdate(update)
        } else if let value = try? JSONValue.parse(trimmed), let update = try? OriginRouteUpdate(unverified: value) {
            self = .routeUpdate(update)
        } else {
            return nil
        }
    }

    /// Deep links: `shell-control://pair?invite=…` and `shell-control://route?update=…`.
    static func isControlLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == ControlLinks.scheme && ["pair", "route"].contains(url.host?.lowercased() ?? "")
    }
}

/// One pairing in progress: the codes the user compares on the Mac.
struct ControlPairingProgress: Equatable {
    var userCode: String
    var deviceFingerprint: String
    var originFingerprint: String
    var route: String
    var replacesOrigin: Bool
}

/// The iPhone half of spec.iphone-gateway.md section 9.2.
struct ControlPairingFlow {
    enum FlowError: Error, CustomStringConvertible {
        case expired
        case declined
        case timedOut

        var description: String {
            switch self {
            case .expired: return String(localized: "This pairing QR expired. Run shell-control pair on the Mac for a new one.")
            case .declined: return String(localized: "Pairing was declined on the Mac.")
            case .timedOut: return String(localized: "The Mac did not confirm in time. Start again.")
            }
        }
    }

    let gateway: ControlGatewaySession
    let platformLabel: String

    /// Verifies the route policy and the origin's proof under the key in the
    /// QR, claims the one-use pairing with a fresh local key, waits for the
    /// explicit confirmation on the Mac, then pins the origin.
    func run(
        _ invitation: PairingInvitation,
        replacesOrigin: Bool,
        progress: @MainActor @escaping (ControlPairingProgress) -> Void
    ) async throws {
        guard !invitation.isExpired() else { throw FlowError.expired }
        // `PairingInvitation` already refused any route outside the tailnet.
        let client = await gateway.makeClient(invitation.route.url)
        try await client.verifyOrigin(invitation.origin)

        let key = InMemoryDeviceKey()
        let claim = try await client.claimPairing(invitation, key: key, platform: .iOS, label: platformLabel)
        progress(ControlPairingProgress(
            userCode: claim.authorization.userCode,
            deviceFingerprint: claim.fingerprint,
            originFingerprint: invitation.origin.fingerprint,
            route: invitation.route.url.absoluteString,
            replacesOrigin: replacesOrigin
        ))

        let enrollment = EnrollmentCoordinator(baseURL: invitation.route.url, transport: ControlTailnetTransport())
        var interval = claim.authorization.interval
        while Date() < claim.authorization.expiresAt.date {
            try await Task.sleep(for: .seconds(interval))
            do {
                let token = try await enrollment.poll(deviceCode: claim.authorization.deviceCode)
                let session = try await enrollment.complete(
                    enrollmentID: claim.enrollmentID,
                    enrollmentToken: token,
                    challenge: claim.challenge,
                    key: key
                )
                // A different origin key replaces the old trust entirely.
                if replacesOrigin { await gateway.signOut(forgetOrigin: true) }
                var pinned = await gateway.pinnedOrigin
                if pinned?.origin != invitation.origin {
                    pinned = PinnedOrigin(origin: invitation.origin, routes: [], pairedAt: ControlTimestamp(Date()))
                }
                pinned?.prefer(invitation.route)
                try await gateway.pin(pinned!)
                try await gateway.store(session: session, key: key)
                return
            } catch EnrollmentError.authorizationPending {
                continue
            } catch EnrollmentError.slowDown {
                interval += 5
            } catch EnrollmentError.accessDenied {
                throw FlowError.declined
            } catch EnrollmentError.expired {
                throw FlowError.expired
            }
        }
        throw FlowError.timedOut
    }
}
