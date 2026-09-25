import Foundation
import CryptoKit
import ShellControlProtocol
import ShellControlSecurity
import ShellControlHTTPServer

/// One APNs delivery the relay built itself.
public struct RelayDelivery: Sendable, Hashable {
    public let token: String
    public let topic: String
    public let environment: PushRegistration.Environment
    public let collapseID: String
    public let expiration: ControlTimestamp
    public let payload: Data
}

public protocol RelayAPNsSending: Sendable {
    func send(_ delivery: RelayDelivery) async throws
}

/// The stateless Shell Push Relay.
///
/// It stores and decides nothing: no approvals, decisions, consumes, receipts,
/// jobs, run state, origin presence, or terminal data. It mints signed push
/// capabilities for iPhones and turns an origin's hint into one generic APNs
/// alert for the token inside that capability (spec.iphone-gateway.md 4.7, 16).
public struct RelayService: Sendable {
    public struct Configuration: Sendable {
        public var allowedTopics: Set<String>
        /// The header a trusted TLS front end sets to the client's address
        /// (for example `x-forwarded-for`). Without one, the connected peer is
        /// the client.
        public var clientAddressHeader: String?
        public init(allowedTopics: Set<String>, clientAddressHeader: String? = nil) {
            self.allowedTopics = allowedTopics
            self.clientAddressHeader = clientAddressHeader?.lowercased()
        }
    }

    private let key: OriginSigningKey
    private let configuration: Configuration
    private let sender: any RelayAPNsSending
    private let limiter: RelayRateLimiter
    private let now: @Sendable () -> Date

    public init(
        key: OriginSigningKey,
        configuration: Configuration,
        sender: any RelayAPNsSending,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.key = key
        self.configuration = configuration
        self.sender = sender
        self.limiter = RelayRateLimiter()
        self.now = now
    }

    public static let approvalEvent = "approval.created"
    /// A typed agent question is waiting (spec.agent-relay.md section 12.3).
    /// Same generic, identifier-only hint; opening it fetches current state.
    public static let inputEvent = "input.created"

    public func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        do {
            switch (request.method, request.path) {
            case ("GET", "/healthz"):
                return json(200, .object(["state": "ready"]))
            case ("POST", "/v1/capabilities"):
                // Per client where the client is known: a single caller must
                // not be able to lock every iPhone out of registering. Behind
                // a proxy with no configured header every request looks like
                // the proxy, so that one shared bucket keeps the wider limit.
                if let client = clientAddress(request) {
                    try await limiter.check(bucket: "capabilities:\(client)", limit: 20, now: now())
                } else {
                    try await limiter.check(bucket: "capabilities", limit: 120, now: now())
                }
                return json(201, try issueCapability(try body(request)))
            case ("POST", "/v1/push"):
                // Before the capability is opened, not after: verifying its
                // signature costs a P-256 check, so an unauthenticated caller
                // must not be able to ask for an unbounded number of them.
                // The per-capability limit below still bounds real senders.
                if let client = clientAddress(request) {
                    try await limiter.check(bucket: "push:\(client)", limit: 600, now: now())
                } else {
                    try await limiter.check(bucket: "push", limit: 3000, now: now())
                }
                return json(202, try await push(try body(request)))
            default:
                throw ControlError(code: .notFound, message: "no such endpoint")
            }
        } catch let error as ControlError {
            return json(error.code.httpStatus, error.json)
        } catch {
            return json(400, ControlError(code: .invalidPayload, message: String(describing: error).prefix(200).description).json)
        }
    }

    /// The client's address, or nil when it cannot be told apart from the
    /// proxy. With a configured header it is the *last* entry: front ends
    /// append the peer they saw, and anything before it is client-supplied and
    /// spoofable. Without one it is the connected peer, unless that is
    /// loopback — a local TLS front end, not a client.
    func clientAddress(_ request: HTTPServer.Request) -> String? {
        if let header = configuration.clientAddressHeader {
            guard let value = request.header(header)?.split(separator: ",").last?.trimmingCharacters(in: .whitespaces),
                  !value.isEmpty else { return nil }
            return value
        }
        guard let peer = request.peerAddress, !Self.isLoopback(peer) else { return nil }
        return peer
    }

    static func isLoopback(_ address: String) -> Bool {
        address == "::1" || address.hasPrefix("127.") || address.hasPrefix("::ffff:127.")
    }

    /// `POST /v1/capabilities`: the iPhone trades its current APNs token for a
    /// signed capability. Only configured app topics are accepted.
    func issueCapability(_ value: JSONValue) throws -> JSONValue {
        var reader = try JSONReader(value)
        let token = try reader.string("apns_token", maxLength: 200)
        let topic = try reader.string("topic", maxLength: 200)
        let environmentText = try reader.string("environment", maxLength: 16)
        try reader.rejectUnknownMembers()
        guard let environment = PushRegistration.Environment(rawValue: environmentText) else {
            throw ControlError(code: .invalidPayload, message: "unknown environment")
        }
        guard configuration.allowedTopics.contains(topic) else {
            throw ControlError(code: .notAuthorized, message: "topic is not served by this relay")
        }
        // An APNs device token is lowercase hex. Checking the shape here keeps
        // a sealed capability from naming something APNs will never accept.
        guard token.count >= 64, token.count <= 200,
              token.allSatisfy({ $0.isHexDigit && $0.isASCII && !$0.isUppercase })
        else {
            throw ControlError(code: .invalidPayload, message: "apns_token is malformed")
        }
        let capability = try PushCapability(
            apnsToken: token,
            topic: topic,
            environment: environment,
            expiresAt: ControlTimestamp(now()).adding(PushCapability.lifetime)
        )
        return .object([
            "capability": .string(try capability.sealed(with: key)),
            "capability_id": JSONValue(capability.capabilityID),
            "expires_at": JSONValue(capability.expiresAt)
        ])
    }

    /// `POST /v1/push`: verify, rate-limit, build the payload here, and send
    /// only to the token and topic sealed in the capability. There is no
    /// caller-supplied topic or alert text.
    func push(_ value: JSONValue) async throws -> JSONValue {
        var reader = try JSONReader(value)
        let sealed = try reader.string("capability", maxLength: 4096)
        let event = try reader.string("event", maxLength: 64)
        let requestID = try reader.id("request_id")
        let originID = try reader.id("origin_id")
        let collapseID = try reader.string("collapse_id", maxLength: 64)
        let presentation = try reader.string("presentation_class", maxLength: 32)
        try reader.rejectUnknownMembers()

        let capability: PushCapability
        do {
            capability = try PushCapability.open(sealed, publicKey: key.publicJWK, now: now())
        } catch PushCapability.OpenError.expired {
            throw ControlError(code: .requestExpired, message: "push capability expired; the iPhone must refresh it")
        } catch {
            throw ControlError(code: .notAuthorized, message: "push capability rejected")
        }
        let allowed = (event == Self.approvalEvent && presentation == "approval") || (event == Self.inputEvent && presentation == "input")
        guard allowed, capability.schema == PushCapability.approvalSchema else {
            throw ControlError(code: .unsupportedCommand, message: "event is not allowed by this capability")
        }
        guard !collapseID.isEmpty, collapseID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw ControlError(code: .invalidPayload, message: "collapse_id is malformed")
        }
        try await limiter.check(bucket: "cap:\(capability.capabilityID.rawValue)", limit: capability.rateClass.perMinute, now: now())

        let delivery = RelayDelivery(
            token: capability.apnsToken,
            topic: capability.topic,
            environment: capability.environment,
            collapseID: collapseID,
            // A hint that arrives after the longest possible approval is noise.
            expiration: ControlTimestamp(now()).adding(ApprovalPolicy.maximumLifetime),
            payload: event == Self.inputEvent
                ? try Self.inputPayload(originID: originID, requestID: requestID)
                : try Self.approvalPayload(originID: originID, requestID: requestID)
        )
        do {
            try await sender.send(delivery)
        } catch {
            // A dropped hint is not an error for correctness; the origin just
            // learns the relay could not deliver it.
            throw ControlError(code: .temporarilyUnavailable, message: "APNs delivery failed")
        }
        return .object(["accepted": true])
    }

    /// The default approval push of spec.iphone-gateway.md section 16.3. It is
    /// generic on purpose: no command, argument, or host text leaves the Mac.
    public static func approvalPayload(originID: ControlID, requestID: ControlID) throws -> Data {
        try JSONCanonicalization.canonicalize(.object([
            "aps": .object([
                "alert": .object([
                    "title": "Approval needed",
                    "body": "A Shell request is waiting for review"
                ]),
                "category": .string(PushCategory.approval),
                "content-available": 1
            ]),
            "v": 1,
            "event": .string(approvalEvent),
            "origin_id": JSONValue(originID),
            "request_id": JSONValue(requestID)
        ]))
    }

    /// The question hint: as generic as the approval hint. No question,
    /// choice, or answer text leaves the Mac (spec.agent-relay.md 12.3).
    public static func inputPayload(originID: ControlID, requestID: ControlID) throws -> Data {
        try JSONCanonicalization.canonicalize(.object([
            "aps": .object([
                "alert": .object([
                    "title": "Question from an agent",
                    "body": "An agent is waiting for an answer"
                ]),
                "category": .string(PushCategory.approval),
                "content-available": 1
            ]),
            "v": 1,
            "event": .string(inputEvent),
            "origin_id": JSONValue(originID),
            "request_id": JSONValue(requestID)
        ]))
    }

    private func body(_ request: HTTPServer.Request) throws -> JSONValue {
        guard request.body.count <= 8192 else { throw ControlError(code: .invalidPayload, message: "body too large") }
        do { return try JSONValue.parse(request.body, limits: JSONLimits(maxDocumentBytes: 8192)) } catch {
            throw ControlError(code: .invalidPayload, message: "\(error)")
        }
    }

    private func json(_ status: Int, _ value: JSONValue) -> HTTPServer.Response {
        HTTPServer.Response(
            status: status,
            headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
            body: (try? JSONCanonicalization.canonicalize(value)) ?? Data("{}".utf8)
        )
    }
}

/// Per-bucket fixed windows, in memory only. Losing it on restart loses
/// nothing a relay is allowed to know.
actor RelayRateLimiter {
    private var counters: [String: (start: Date, count: Int)] = [:]

    func check(bucket: String, limit: Int, now: Date, window: TimeInterval = 60) throws {
        if counters.count > 10_000 { counters = counters.filter { now.timeIntervalSince($0.value.start) <= window } }
        var entry = counters[bucket] ?? (now, 0)
        if now.timeIntervalSince(entry.start) > window { entry = (now, 0) }
        entry.count += 1
        counters[bucket] = entry
        guard entry.count <= limit else { throw ControlError(code: .rateLimited, message: "too many pushes") }
    }
}

/// APNs over HTTP/2 with a cached ES256 provider token.
public struct RelayAPNsClient: RelayAPNsSending {
    public struct Credentials: Sendable {
        public let keyID: String
        public let teamID: String
        public let privateKeyPEM: String
        public init(keyID: String, teamID: String, privateKeyPEM: String) {
            self.keyID = keyID
            self.teamID = teamID
            self.privateKeyPEM = privateKeyPEM
        }
    }

    private let credentials: Credentials
    private let session: URLSession
    private let cache = TokenCache()

    public init(credentials: Credentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    actor TokenCache {
        private var token: (value: String, issuedAt: Date)?
        func token(now: Date, make: (Date) throws -> String) throws -> String {
            if let token, now.timeIntervalSince(token.issuedAt) < 45 * 60 { return token.value }
            let value = try make(now)
            token = (value, now)
            return value
        }
    }

    public func send(_ delivery: RelayDelivery) async throws {
        let host = delivery.environment == .production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(delivery.token)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = delivery.payload
        let bearer = try await cache.token(now: Date()) { try providerToken(now: $0) }
        request.setValue("bearer \(bearer)", forHTTPHeaderField: "authorization")
        for (name, value) in APNsRequestHeaders(topic: delivery.topic, expiresAt: delivery.expiration, collapseID: delivery.collapseID).headerFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    func providerToken(now: Date) throws -> String {
        let key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM)
        let header = try JSONCanonicalization.canonicalize(.object(["alg": "ES256", "kid": .string(credentials.keyID)]))
        let claims = try JSONCanonicalization.canonicalize(.object([
            "iss": .string(credentials.teamID),
            "iat": .number(.int(Int64(now.timeIntervalSince1970)))
        ]))
        let input = "\(Base64URL.encode(header)).\(Base64URL.encode(claims))"
        return "\(input).\(Base64URL.encode(try key.signature(for: Data(input.utf8)).rawRepresentation))"
    }
}

public actor RecordingRelayAPNs: RelayAPNsSending {
    public private(set) var deliveries: [RelayDelivery] = []
    public init() {}
    public func send(_ delivery: RelayDelivery) async throws { deliveries.append(delivery) }
}
