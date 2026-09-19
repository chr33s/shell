import Foundation
import CryptoKit
import ShellControlProtocol

/// How the iPhone reaches an origin. A route is never an authorization
/// identifier (spec.iphone-gateway.md section 7.2).
public struct OriginRoute: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// `https://<mac>.<tailnet>.ts.net` through Tailscale Serve.
        case tailscaleHTTPS = "tailscale_https"
        /// `http://127.0.0.1:<port>` for a development broker on the same host
        /// as the simulator. Never a physical-device route.
        case loopbackHTTP = "loopback_http"
    }

    public let kind: Kind
    public let url: URL

    /// Validates `url` against the route policy and normalises it to scheme,
    /// host, and port only.
    public init(kind: Kind? = nil, url: URL) throws {
        guard let normalized = OriginRoute.normalize(url) else {
            throw ValidationError.invalid("route", "must be an origin with no credentials, path, query, or fragment")
        }
        let inferred: Kind = normalized.scheme == "https" ? .tailscaleHTTPS : .loopbackHTTP
        let kind = kind ?? inferred
        switch kind {
        case .tailscaleHTTPS:
            guard normalized.scheme == "https", let host = normalized.host, OriginRoute.isTailnetHost(host) else {
                throw ValidationError.invalid("route", "a tailscale_https route must be https://<name>.ts.net")
            }
        case .loopbackHTTP:
            guard normalized.scheme == "http", let host = normalized.host, OriginRoute.isLoopbackHost(host) else {
                throw ValidationError.invalid("route", "a loopback_http route must be http on a loopback host")
            }
        }
        self.kind = kind
        self.url = normalized
    }

    public init(_ text: String) throws {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ValidationError.invalid("route", "not a URL")
        }
        try self.init(url: url)
    }

    public var json: JSONValue {
        .object(["kind": .string(kind.rawValue), "url": .string(url.absoluteString)])
    }

    public init(json: JSONValue) throws {
        if let text = json.stringValue {
            try self.init(text)
            return
        }
        var reader = try JSONReader(json)
        let kindText = try reader.string("kind", maxLength: 32)
        guard let kind = Kind(rawValue: kindText) else { throw ValidationError.unsupported("route kind \(kindText)") }
        let urlText = try reader.string("url", maxLength: 512)
        try reader.rejectUnknownMembers()
        guard let url = URL(string: urlText) else { throw ValidationError.invalid("route", "not a URL") }
        try self.init(kind: kind, url: url)
        guard self.url.absoluteString == urlText else {
            throw ValidationError.invalid("route", "must already be normalised")
        }
    }

    /// MagicDNS machine names and Tailscale Service names both live under
    /// `ts.net`; a route outside the tailnet is never accepted.
    public static func isTailnetHost(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host.hasSuffix(".ts.net"), host.count > ".ts.net".count else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 3 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                && label.first != "-" && label.last != "-"
        }
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        var hostname = host.lowercased()
        if hostname.hasPrefix("["), hostname.hasSuffix("]") { hostname = String(hostname.dropFirst().dropLast()) }
        return hostname == "localhost" || hostname == "127.0.0.1" || hostname == "::1"
    }

    static func normalize(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/"
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        let hostname = host.lowercased()
        components.host = hostname.contains(":") && !hostname.hasPrefix("[") ? "[\(hostname)]" : hostname
        if let port = url.port, !(scheme == "https" && port == 443) { components.port = port }
        return components.url
    }
}

/// An origin-signed route update. Accepting one changes routing only: it is
/// never re-enrollment and never a new trust decision
/// (spec.iphone-gateway.md sections 7.4 and 24).
public struct OriginRouteUpdate: Sendable, Hashable {
    public static let type = "shell-control.route-update"

    public let originID: ControlID
    public let route: OriginRoute
    public let issuedAt: ControlTimestamp
    public let nonce: String
    /// The exact signed document, kept so it can be re-verified or re-shown.
    public let document: JSONValue

    public static func sign(
        originID: ControlID,
        route: OriginRoute,
        issuedAt: ControlTimestamp,
        nonce: String = Base64URL.encode(Data((0..<16).map { _ in UInt8.random(in: 0...255) })),
        key: some DeviceSigningKey
    ) throws -> OriginRouteUpdate {
        let document = try SignedDocument.sign([
            "v": 1,
            "type": .string(type),
            "origin_id": JSONValue(originID),
            "route": route.json,
            "issued_at": JSONValue(issuedAt),
            "nonce": .string(nonce)
        ], key: key)
        return try OriginRouteUpdate(unverified: document)
    }

    /// Parses without verifying. Callers must use ``verify(pinned:)`` before
    /// acting on it.
    public init(unverified document: JSONValue) throws {
        var reader = try JSONReader(document)
        guard try reader.integer("v") == 1 else { throw ValidationError.unsupported("route update version") }
        guard try reader.string("type", maxLength: 64) == Self.type else {
            throw ValidationError.unsupported("not a route update")
        }
        originID = try reader.id("origin_id")
        route = try OriginRoute(json: try reader.value("route"))
        issuedAt = try reader.timestamp("issued_at")
        nonce = try reader.string("nonce", maxLength: 64)
        _ = try reader.string(SignedDocument.signatureMember, maxLength: 128)
        try reader.rejectUnknownMembers()
        self.document = document
    }

    /// Accepts the update only if it names the pinned origin and verifies under
    /// the pinned key. Another origin's key is rejected outright.
    public func verify(pinned: OriginIdentity) throws {
        guard originID == pinned.originID else {
            throw ControlError(code: .notAuthorized, message: "route update names a different origin")
        }
        do {
            try SignedDocument.verify(document, type: Self.type, publicKey: pinned.publicJWK)
        } catch {
            throw ControlError(code: .notAuthorized, message: "route update is not signed by the pinned origin key")
        }
    }

    /// `shell-control://route?update=<base64url canonical JSON>`, the payload
    /// of the route-only QR.
    public func link() throws -> URL {
        var components = URLComponents()
        components.scheme = ControlLinks.scheme
        components.host = "route"
        components.queryItems = [URLQueryItem(
            name: "update",
            value: Base64URL.encode(try JSONCanonicalization.canonicalize(document))
        )]
        guard let url = components.url else { throw ValidationError.invalid("route", "cannot build link") }
        return url
    }

    public init(link: URL) throws {
        guard link.scheme?.lowercased() == ControlLinks.scheme, link.host?.lowercased() == "route",
              let payload = ControlLinks.query(link, "update")
        else { throw ValidationError.invalid("link", "not a route update link") }
        try self.init(unverified: try ControlLinks.decodeDocument(payload))
    }
}

/// The setup QR. It carries bootstrap material only: the pairing secret is
/// random, one use, short lived, and not an origin credential
/// (spec.iphone-gateway.md section 9.1).
public struct PairingInvitation: Sendable, Hashable {
    public static let type = "shell-control.pairing"

    public let origin: OriginIdentity
    public let route: OriginRoute
    public let pairingID: ControlID
    public let pairingSecret: String
    public let expiresAt: ControlTimestamp

    public init(origin: OriginIdentity, route: OriginRoute, pairingID: ControlID, pairingSecret: String, expiresAt: ControlTimestamp) throws {
        guard let secret = Base64URL.decode(pairingSecret), secret.count >= 16 else {
            throw ValidationError.invalid("pairing_secret", "must be at least 128 bits of base64url")
        }
        self.origin = origin
        self.route = route
        self.pairingID = pairingID
        self.pairingSecret = pairingSecret
        self.expiresAt = expiresAt
    }

    public var json: JSONValue {
        .object([
            "v": 1,
            "type": .string(Self.type),
            "origin_id": JSONValue(origin.originID),
            "origin_public_jwk": origin.publicJWK.json,
            "route": .string(route.url.absoluteString),
            "pairing_id": JSONValue(pairingID),
            "pairing_secret": .string(pairingSecret),
            "expires_at": JSONValue(expiresAt)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        guard try reader.integer("v") == 1 else { throw ValidationError.unsupported("pairing version") }
        guard try reader.string("type", maxLength: 64) == Self.type else {
            throw ValidationError.unsupported("not a pairing invitation")
        }
        let origin = OriginIdentity(
            originID: try reader.id("origin_id"),
            publicJWK: try DeviceJWK(json: try reader.value("origin_public_jwk"))
        )
        let route = try OriginRoute(try reader.string("route", maxLength: 512))
        let pairingID = try reader.id("pairing_id")
        let secret = try reader.string("pairing_secret", maxLength: 128)
        let expiresAt = try reader.timestamp("expires_at")
        try reader.rejectUnknownMembers()
        try self.init(origin: origin, route: route, pairingID: pairingID, pairingSecret: secret, expiresAt: expiresAt)
    }

    public func isExpired(at now: Date = Date()) -> Bool { expiresAt.date <= now }

    /// `shell-control://pair?invite=<base64url canonical JSON>`.
    public func link() throws -> URL {
        var components = URLComponents()
        components.scheme = ControlLinks.scheme
        components.host = "pair"
        components.queryItems = [URLQueryItem(
            name: "invite",
            value: Base64URL.encode(try JSONCanonicalization.canonicalize(json))
        )]
        guard let url = components.url else { throw ValidationError.invalid("invite", "cannot build link") }
        return url
    }

    /// Accepts the `shell-control://pair?invite=` link or the raw JSON a user
    /// pasted from the terminal.
    public init(scanned text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            try self.init(json: try JSONValue.parse(trimmed))
            return
        }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == ControlLinks.scheme,
              url.host?.lowercased() == "pair", let payload = ControlLinks.query(url, "invite")
        else { throw ValidationError.invalid("invite", "not a pairing invitation") }
        try self.init(json: try ControlLinks.decodeDocument(payload))
    }

    /// The claim proof: HMAC-SHA256 under the pairing secret over the
    /// canonical claim binding, so the secret itself is never sent.
    public static func claimBinding(pairingID: ControlID, publicJWK: DeviceJWK, nonce: String) throws -> Data {
        try JSONCanonicalization.canonicalize(.object([
            "type": "shell-control.pairing-claim",
            "pairing_id": JSONValue(pairingID),
            "public_jwk": publicJWK.json,
            "nonce": .string(nonce)
        ]))
    }
}

/// Proof that the endpoint reached over a route holds the pinned origin key
/// (spec.iphone-gateway.md sections 7.4 and 9.2).
public struct OriginProof: Sendable, Hashable {
    public static let type = "shell-control.origin-proof"

    public let originID: ControlID
    public let nonce: String
    public let issuedAt: ControlTimestamp
    public let document: JSONValue

    public static func sign(originID: ControlID, nonce: String, issuedAt: ControlTimestamp, key: some DeviceSigningKey) throws -> OriginProof {
        try OriginProof(unverified: try SignedDocument.sign([
            "v": 1,
            "type": .string(type),
            "origin_id": JSONValue(originID),
            "nonce": .string(nonce),
            "issued_at": JSONValue(issuedAt)
        ], key: key))
    }

    public init(unverified document: JSONValue) throws {
        var reader = try JSONReader(document)
        guard try reader.integer("v") == 1 else { throw ValidationError.unsupported("origin proof version") }
        guard try reader.string("type", maxLength: 64) == Self.type else {
            throw ValidationError.unsupported("not an origin proof")
        }
        originID = try reader.id("origin_id")
        nonce = try reader.string("nonce", maxLength: 64)
        issuedAt = try reader.timestamp("issued_at")
        _ = try reader.string(SignedDocument.signatureMember, maxLength: 128)
        try reader.rejectUnknownMembers()
        self.document = document
    }

    /// The endpoint answered our nonce with a signature under the expected key.
    public func verify(expected: OriginIdentity, nonce expectedNonce: String) throws {
        guard originID == expected.originID, nonce == expectedNonce else {
            throw ControlError(code: .notAuthorized, message: "origin proof does not answer this challenge")
        }
        do {
            try SignedDocument.verify(document, type: Self.type, publicKey: expected.publicJWK)
        } catch {
            throw ControlError(code: .notAuthorized, message: "endpoint does not hold the pinned origin key")
        }
    }

    public static func freshNonce() -> String {
        Base64URL.encode(Data((0..<24).map { _ in UInt8.random(in: 0...255) }))
    }
}

/// `shell-control://` link helpers shared by pairing and route QRs.
public enum ControlLinks {
    public static let scheme = "shell-control"

    static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    static func decodeDocument(_ payload: String) throws -> JSONValue {
        guard payload.count <= 8192, let data = Base64URL.decode(payload) else {
            throw ValidationError.invalid("link", "payload is not base64url")
        }
        return try JSONValue.parse(data, limits: JSONLimits(maxDocumentBytes: 8192))
    }
}

/// HMAC-SHA256 proof of the one-use pairing secret.
public enum PairingProof {
    public static func mac(secret: Data, binding: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: binding, using: SymmetricKey(data: secret)))
    }

    public static func isValid(_ proof: Data, secret: Data, binding: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: binding, using: SymmetricKey(data: secret))
    }
}
