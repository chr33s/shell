import Foundation
import ShellControlProtocol
import ShellControlSecurity
import Synchronization

/// What the iPhone pins at pairing: the origin identity, plus cached routes.
///
/// Routes are an ordered cache; changing them never touches the device
/// enrollment, the Watch reviewer, signing keys, or grants
/// (spec.iphone-gateway.md section 7.3).
public struct PinnedOrigin: Sendable, Hashable {
    public static let maximumRoutes = 8

    public let origin: OriginIdentity
    /// Most recently confirmed first.
    public private(set) var routes: [OriginRoute]
    public let pairedAt: ControlTimestamp

    public init(origin: OriginIdentity, routes: [OriginRoute], pairedAt: ControlTimestamp) {
        self.origin = origin
        self.routes = []
        self.pairedAt = pairedAt
        for route in routes.reversed() { prefer(route) }
    }

    /// Moves `route` to the front, deduplicating by URL.
    public mutating func prefer(_ route: OriginRoute) {
        routes.removeAll { $0.url == route.url }
        routes.insert(route, at: 0)
        if routes.count > Self.maximumRoutes { routes.removeLast(routes.count - Self.maximumRoutes) }
    }

    public var json: JSONValue {
        .object([
            "v": 1,
            "origin_id": JSONValue(origin.originID),
            "origin_public_jwk": origin.publicJWK.json,
            "routes": .array(routes.map(\.json)),
            "paired_at": JSONValue(pairedAt)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard try reader.integer("v") == 1 else { throw ValidationError.unsupported("pinned origin version") }
        let origin = OriginIdentity(
            originID: try reader.id("origin_id"),
            publicJWK: try DeviceJWK(json: try reader.value("origin_public_jwk"))
        )
        let routes = try (try reader.value("routes").arrayValue ?? []).map(OriginRoute.init(json:))
        let pairedAt = try reader.timestamp("paired_at")
        try reader.rejectUnknownMembers()
        self.init(origin: origin, routes: routes, pairedAt: pairedAt)
    }
}

public protocol PinnedOriginStore: Sendable {
    func load() throws -> PinnedOrigin?
    func store(_ origin: PinnedOrigin) throws
    func remove() throws
}

public final class InMemoryPinnedOriginStore: PinnedOriginStore, Sendable {
    private let origin: Mutex<PinnedOrigin?>

    public init(_ origin: PinnedOrigin? = nil) { self.origin = Mutex(origin) }

    public func load() throws -> PinnedOrigin? {
        origin.withLock { $0 }
    }

    public func store(_ origin: PinnedOrigin) throws {
        self.origin.withLock { $0 = origin }
    }

    public func remove() throws {
        origin.withLock { $0 = nil }
    }
}

/// Trust decisions. The origin key is identity; the Tailscale URL is routing,
/// and changing routing must never silently become changing trust
/// (spec.iphone-gateway.md section 35).
public enum OriginTrust {
    public enum Assessment: Sendable, Equatable {
        /// Nothing pinned yet: a normal first pairing.
        case firstPairing
        /// Same origin ID and key: at most a route change. Existing Shell
        /// credentials remain valid.
        case sameOrigin
        /// A different key or origin ID: an explicit new trust decision that
        /// replaces the old identity.
        case differentOrigin
    }

    public static func assess(_ invitation: PairingInvitation, against pinned: PinnedOrigin?) -> Assessment {
        guard let pinned else { return .firstPairing }
        return pinned.origin == invitation.origin ? .sameOrigin : .differentOrigin
    }

    /// Verifies a route update against the pinned key (and origin ID) and, if
    /// it verifies, returns the pin with that route preferred. Nothing about
    /// device enrollment changes.
    public static func apply(_ update: OriginRouteUpdate, to pinned: PinnedOrigin) throws -> PinnedOrigin {
        try update.verify(pinned: pinned.origin)
        var next = pinned
        next.prefer(update.route)
        return next
    }
}

/// Finds a working route to the pinned origin in the order of
/// spec.iphone-gateway.md section 24: the last known route, then every other
/// previously signed route. Every candidate must prove it holds the pinned
/// origin key; reachability alone is never enough. Failure leaves local
/// credentials untouched.
public struct OriginRouteResolver: Sendable {
    public typealias ClientFactory = @Sendable (URL) -> ControlAPIClient

    public enum ResolutionError: Error, Sendable, Equatable, CustomStringConvertible {
        /// No route answered. Tailscale may be off, or the Mac may be offline.
        case unreachable
        /// A route answered but did not hold the pinned key.
        case originMismatch

        public var description: String {
            switch self {
            case .unreachable: return "the private Mac route is unavailable"
            case .originMismatch: return "the endpoint does not hold the paired Shell origin key"
            }
        }
    }

    private let makeClient: ClientFactory

    public init(makeClient: @escaping ClientFactory) {
        self.makeClient = makeClient
    }

    public func resolve(_ pinned: PinnedOrigin) async throws -> (route: OriginRoute, client: ControlAPIClient) {
        var sawMismatch = false
        for route in pinned.routes {
            let client = makeClient(route.url)
            do {
                try await client.verifyOrigin(pinned.origin)
                return (route, client)
            } catch let error as ControlError where error.code == .notAuthorized {
                sawMismatch = true
            } catch {
                continue
            }
        }
        throw sawMismatch ? ResolutionError.originMismatch : ResolutionError.unreachable
    }

    /// Adopts a signed route update only after the new endpoint proves
    /// possession of the same origin key (spec.iphone-gateway.md section 7.4).
    public func adopt(_ update: OriginRouteUpdate, into pinned: PinnedOrigin) async throws -> PinnedOrigin {
        let next = try OriginTrust.apply(update, to: pinned)
        try await makeClient(update.route.url).verifyOrigin(pinned.origin)
        return next
    }
}
