//
//  ControlGatewaySession.swift
//  shell
//
//  The iPhone's own authenticated session with its Mac: pinned origin,
//  device key and tokens, and a route verified against the pinned key. Both
//  the phone's review UI and the Watch gateway draw clients from here
//  (spec.iphone-gateway.md sections 13 and 24).
//

import Foundation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

actor ControlGatewaySession {
    enum SessionError: Error, CustomStringConvertible {
        case notPaired
        /// The Mac revoked this iPhone or its session lapsed. Only this —
        /// never a route or Tailscale failure — requires pairing again.
        case pairingRequired(String)

        var description: String {
            switch self {
            case .notPaired: return String(localized: "Not paired with a Mac.")
            case .pairingRequired(let reason): return reason
            }
        }
    }

    private let credentials: any DeviceCredentialStore
    private let origins: any PinnedOriginStore
    private let transport: any ControlHTTPTransport
    private let now: @Sendable () -> Date
    private var resolved: (route: OriginRoute, client: ControlAPIClient, verifiedAt: Date)?
    private var refreshTask: Task<DeviceSession, any Error>?
    /// A refreshed session the Keychain refused (the phone was locked). The
    /// broker has already spent the old refresh token, so this copy is the
    /// only valid one; it is used, and saved again, until a write succeeds.
    private var unsavedSession: DeviceSession?
    /// A verified route is re-proved after this long, so a changed endpoint is
    /// noticed without proving on every request.
    private static let routeReverifyInterval: TimeInterval = 120

    init(
        credentials: any DeviceCredentialStore,
        origins: any PinnedOriginStore,
        transport: any ControlHTTPTransport = ControlTailnetTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.origins = origins
        self.transport = transport
        self.now = now
    }

    var pinnedOrigin: PinnedOrigin? { try? origins.load() }
    var deviceSession: DeviceSession? { unsavedSession ?? (try? credentials.loadSession()) }
    var currentRoute: OriginRoute? { resolved?.route }

    func signingMaterial() -> (key: any DeviceSigningKey, signer: SignerIdentity)? {
        guard let session = deviceSession, let key = try? credentials.loadSigningKey() else { return nil }
        return (key, SignerIdentity(session: session))
    }

    func makeClient(_ url: URL, credential: ControlCredential = .none) -> ControlAPIClient {
        ControlAPIClient(baseURL: url, transport: transport, credential: credential)
    }

    // MARK: Routes

    /// Finds a route that proves the pinned origin key. Failure never touches
    /// credentials: the next call simply tries again.
    func verifiedRoute() async throws -> (route: OriginRoute, client: ControlAPIClient) {
        guard let pinned = try origins.load() else { throw SessionError.notPaired }
        if let resolved, now().timeIntervalSince(resolved.verifiedAt) < Self.routeReverifyInterval {
            return (resolved.route, resolved.client)
        }
        let resolver = OriginRouteResolver { [transport] url in ControlAPIClient(baseURL: url, transport: transport) }
        let found = try await resolver.resolve(pinned)
        resolved = (found.route, found.client, now())
        if pinned.routes.first != found.route {
            var preferred = pinned
            preferred.prefer(found.route)
            try? origins.store(preferred)
        }
        return (found.route, found.client)
    }

    /// Drops the verified route so the next request re-resolves; called after
    /// a transport failure.
    func invalidateRoute() { resolved = nil }

    /// Adopts an origin-signed route update. It verifies under the pinned key
    /// and the new endpoint must prove the same key; trust is unchanged.
    func adopt(_ update: OriginRouteUpdate) async throws -> PinnedOrigin {
        guard let pinned = try origins.load() else { throw SessionError.notPaired }
        let resolver = OriginRouteResolver { [transport] url in ControlAPIClient(baseURL: url, transport: transport) }
        let next = try await resolver.adopt(update, into: pinned)
        try origins.store(next)
        resolved = nil
        return next
    }

    // MARK: Pairing state

    func pin(_ origin: PinnedOrigin) throws {
        try origins.store(origin)
        resolved = nil
    }

    func store(session: DeviceSession, key: InMemoryDeviceKey) throws {
        unsavedSession = nil
        try credentials.storeSigningKey(key)
        try credentials.storeSession(session)
    }

    /// Removes this iPhone's Shell credentials. The pinned origin stays unless
    /// `forgetOrigin` asks otherwise, so re-pairing the same Mac is a
    /// same-origin pairing, not a new trust decision.
    func signOut(forgetOrigin: Bool) {
        unsavedSession = nil
        try? credentials.removeAll()
        if forgetOrigin { try? origins.remove() }
        resolved = nil
    }

    // MARK: Authenticated access

    /// A client for the verified route carrying a fresh access token.
    func authenticatedClient() async throws -> ControlAPIClient {
        let route = try await verifiedRoute()
        let session = try await freshSession(route: route.route)
        return makeClient(route.route.url, credential: .device(session.accessToken))
    }

    /// Access tokens last ten minutes; concurrent callers share one refresh.
    private func freshSession(route: OriginRoute) async throws -> DeviceSession {
        if let unsaved = unsavedSession, (try? credentials.storeSession(unsaved)) != nil { unsavedSession = nil }
        guard let session = try unsavedSession ?? credentials.loadSession() else { throw SessionError.notPaired }
        if session.isAccessTokenFresh(at: ControlTimestamp(now())) { return session }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { [transport, now] () throws -> DeviceSession in
            try await EnrollmentCoordinator(baseURL: route.url, transport: transport, now: now).refresh(session: session)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let renewed = try await task.value
            do {
                try credentials.storeSession(renewed)
                unsavedSession = nil
            } catch {
                unsavedSession = renewed
            }
            return renewed
        } catch let error as ControlError where error.code == .deviceRevoked || error.code == .invalidToken {
            // A revoked device, or a refresh token that is spent: this is the
            // one path back to pairing. The pinned origin is kept.
            unsavedSession = nil
            try? credentials.removeAll()
            throw SessionError.pairingRequired(error.code == .deviceRevoked
                ? String(localized: "This iPhone was revoked on the Mac. Pair again.")
                : String(localized: "This iPhone's Shell session expired. Pair again."))
        }
    }
}
