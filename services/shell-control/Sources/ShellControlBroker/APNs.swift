import Foundation
import CryptoKit
import ShellControlProtocol
import ShellControlSecurity

/// Delivers alerts to APNs.
///
/// Provider credentials live only in the broker, never on the Watch, the
/// iPhone, or a job host (spec.watch.md section 3).
public protocol PushSender: Sendable {
    func send(_ entry: OutboxEntry) async throws
}

public struct APNsClient: PushSender {
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
    private let tokenCache = ProviderTokenCache()

    public init(credentials: Credentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    /// APNs rejects a provider that regenerates its token more often than
    /// roughly once every 20 minutes, so the token is reused until it is old
    /// enough to be worth refreshing but still well inside the one-hour limit.
    actor ProviderTokenCache {
        private var token: String?
        private var issuedAt: Date?
        static let refreshInterval: TimeInterval = 45 * 60

        func token(now: Date, make: (Date) throws -> String) throws -> String {
            if let token, let issuedAt, now.timeIntervalSince(issuedAt) < Self.refreshInterval {
                return token
            }
            let fresh = try make(now)
            token = fresh
            issuedAt = now
            return fresh
        }
    }

    public enum PushError: Error, Sendable {
        case status(Int, String)
        case badCredentials
    }

    public func send(_ entry: OutboxEntry) async throws {
        let host = entry.environment == .production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(entry.token)") else { throw PushError.badCredentials }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = entry.payload
        let now = Date()
        let bearer = try await tokenCache.token(now: now) { try providerToken(now: $0) }
        request.setValue("bearer \(bearer)", forHTTPHeaderField: "authorization")
        for (name, value) in entry.headers.headerFields {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PushError.status(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw PushError.status(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    /// A short-lived ES256 provider token, as APNs requires.
    func providerToken(now: Date = Date()) throws -> String {
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM) else {
            throw PushError.badCredentials
        }
        let header = try JSONCanonicalization.canonicalize(.object([
            "alg": "ES256",
            "kid": .string(credentials.keyID),
        ]))
        let claims = try JSONCanonicalization.canonicalize(.object([
            "iss": .string(credentials.teamID),
            "iat": .number(.int(Int64(now.timeIntervalSince1970))),
        ]))
        let signingInput = "\(Base64URL.encode(header)).\(Base64URL.encode(claims))"
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return "\(signingInput).\(Base64URL.encode(signature))"
    }
}

/// Records what would have been sent. Useful for tests and for running the
/// broker without APNs credentials.
public actor RecordingPushSender: PushSender {
    private var sent: [OutboxEntry] = []

    public init() {}

    public func send(_ entry: OutboxEntry) async throws {
        sent.append(entry)
    }

    public var delivered: [OutboxEntry] { sent }
}

/// Drains the outbox. A failed push is dropped rather than retried forever:
/// push is a hint, and the client reconciles from the change stream
/// (spec.watch.md section 14).
public struct OutboxWorker: Sendable {
    let store: BrokerStore
    let sender: any PushSender

    public init(store: BrokerStore, sender: any PushSender) {
        self.store = store
        self.sender = sender
    }

    public func drainOnce() async {
        for entry in await store.drainOutbox() {
            try? await sender.send(entry)
        }
    }

    public func run(interval: TimeInterval = 1) async {
        while !Task.isCancelled {
            await drainOnce()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}
