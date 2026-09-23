//
//  ControlTailnetTransport.swift
//  shell
//
//  HTTPS to the Mac over the user's tailnet. Tailscale provides reachability,
//  not authorization: every request still carries Shell credentials, and
//  every route is checked against the pinned origin key
//  (spec.iphone-gateway.md sections 4.3 and 23).
//

import Foundation
import ShellControlClient

/// The private Mac route could not be reached. This is a connectivity state,
/// never a reason to clear Shell credentials (spec.iphone-gateway.md 28).
nonisolated struct TailnetUnavailable: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

nonisolated struct ControlTailnetTransport: ControlHTTPTransport {
    private let inner: URLSessionTransport

    init(inner: URLSessionTransport = URLSessionTransport()) {
        self.inner = inner
    }

    func send(_ request: ControlHTTPRequest, baseURL: URL) async throws -> ControlHTTPResponse {
        do {
            return try await inner.send(request, baseURL: baseURL)
        } catch TransportError.offline {
            throw TailnetUnavailable(reason: String(localized: "This iPhone is offline."))
        } catch let error as URLError where Self.meansRouteUnavailable(error.code) {
            // A `*.ts.net` name that does not resolve, or a host that does not
            // answer, is almost always Tailscale being off or the Mac asleep.
            throw TailnetUnavailable(reason: String(localized: "The private Mac route is unavailable. Check that Tailscale is connected on this iPhone and the Mac is online."))
        }
    }

    static func meansRouteUnavailable(_ code: URLError.Code) -> Bool {
        [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut,
         .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
         .dataNotAllowed, .secureConnectionFailed].contains(code)
    }
}
