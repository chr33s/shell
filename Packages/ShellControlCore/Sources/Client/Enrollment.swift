import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// Independent setup over OAuth device authorization (RFC 8628), confirmed in
/// an authenticated browser on any suitable device — not necessarily the paired
/// iPhone, and never requiring the Shell iPhone app
/// (spec.watch.md section 5).
public struct DeviceAuthorization: Sendable, Hashable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: String
    public let verificationURIComplete: String?
    public let expiresAt: ControlTimestamp
    public var interval: TimeInterval

    public init(json: JSONValue, now: ControlTimestamp) throws {
        var reader = try JSONReader(json)
        deviceCode = try reader.string("device_code", maxLength: 512)
        userCode = try reader.string("user_code", maxLength: 32)
        verificationURI = try reader.string("verification_uri", maxLength: 512)
        verificationURIComplete = try reader.optionalString("verification_uri_complete", maxLength: 512)
        let expiresIn = try reader.integer("expires_in")
        expiresAt = now.adding(TimeInterval(expiresIn))
        interval = TimeInterval(try reader.optionalInteger("interval") ?? 5)
        try reader.rejectUnknownMembers(allowing: ["server_time"])
    }
}

public enum EnrollmentError: Error, Sendable, Equatable {
    case authorizationPending
    case slowDown
    case accessDenied
    case expired
    case challengeMismatch
    case server(String)
}

/// Runs the enrollment sequence of spec.watch.md section 5.
///
/// The key is generated locally and only its public half ever leaves the
/// device; the enrollment is one-use and grants no control authority until it
/// completes.
public actor EnrollmentCoordinator {
    private let baseURL: URL
    private let transport: any ControlHTTPTransport
    private let now: @Sendable () -> Date

    public init(baseURL: URL, transport: any ControlHTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.transport = transport
        self.now = now
    }

    private var timestamp: ControlTimestamp { ControlTimestamp(now()) }

    public struct StartedEnrollment: Sendable {
        public let enrollmentID: ControlID
        public let challenge: String
        public let expiresAt: ControlTimestamp
        public let authorization: DeviceAuthorization
        public let scope: String
        public let fingerprint: String
    }

    /// Steps 1 and 2: register the public key, then start the device grant for
    /// the Shell-specific `control.enroll:<enrollment_id>` scope.
    public func start(key: InMemoryDeviceKey, platform: PushRegistration.Platform, label: String) async throws -> StartedEnrollment {
        let jwk = key.publicJWK
        let enrollment = try await postJSON("/v1/enrollments", body: .object([
            "public_jwk": jwk.json,
            "platform": .string(platform.rawValue),
            "label": .string(label),
        ]))
        var reader = try JSONReader(enrollment)
        let enrollmentID = try reader.id("enrollment_id")
        let challenge = try reader.string("challenge", maxLength: 256)
        let expiresAt = try reader.timestamp("expires_at")
        let scope = "control.enroll:\(enrollmentID.rawValue)"
        let authorizationJSON = try await postForm("/v1/oauth/device_authorization", fields: ["scope": scope])
        return StartedEnrollment(
            enrollmentID: enrollmentID,
            challenge: challenge,
            expiresAt: expiresAt,
            authorization: try DeviceAuthorization(json: authorizationJSON, now: timestamp),
            scope: scope,
            fingerprint: try jwk.displayFingerprint()
        )
    }

    /// One RFC 8628 poll. `slow_down` widens the caller's interval; expiry and
    /// denial are terminal.
    public func poll(deviceCode: String) async throws -> String {
        let response = try await postFormRaw("/v1/oauth/token", fields: [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode,
        ])
        let value = try JSONValue.parse(response.body, limits: JSONLimits(maxDocumentBytes: 1 << 16))
        if response.isSuccess {
            var reader = try JSONReader(value)
            return try reader.string("access_token", maxLength: 4096)
        }
        let error = value["error"]?.stringValue ?? "server_error"
        switch error {
        case "authorization_pending": throw EnrollmentError.authorizationPending
        case "slow_down": throw EnrollmentError.slowDown
        case "access_denied": throw EnrollmentError.accessDenied
        case "expired_token": throw EnrollmentError.expired
        default: throw EnrollmentError.server(error)
        }
    }

    /// Step 3: complete with the authorized enrollment token and a signature
    /// over the server's enrollment challenge. The enrollment is one-use.
    public func complete(
        enrollmentID: ControlID,
        enrollmentToken: String,
        challenge: String,
        key: InMemoryDeviceKey
    ) async throws -> DeviceSession {
        guard let challengeBytes = Base64URL.decode(challenge) else { throw EnrollmentError.challengeMismatch }
        let signature = try key.signature(for: challengeBytes)
        let value = try await postJSON(
            "/v1/enrollments/\(enrollmentID.rawValue)/complete",
            body: .object(["challenge_signature": .string(Base64URL.encode(signature))]),
            headers: ["Authorization": "Bearer \(enrollmentToken)"]
        )
        return try DeviceSession(json: value)
    }

    /// Refresh with a rotating refresh token. Refresh endpoints verify
    /// revocation (spec.watch.md section 5).
    public func refresh(session: DeviceSession) async throws -> DeviceSession {
        let value = try await postFormJSON("/v1/oauth/token", fields: [
            "grant_type": "refresh_token",
            "refresh_token": session.refreshToken,
        ])
        return try DeviceSession(json: value)
    }

    // MARK: Plumbing

    private func postJSON(_ path: String, body: JSONValue, headers: [String: String] = [:]) async throws -> JSONValue {
        var allHeaders = headers
        allHeaders["Content-Type"] = "application/json"
        let response = try await transport.send(
            ControlHTTPRequest(method: "POST", path: path, headers: allHeaders, body: try JSONCanonicalization.canonicalize(body)),
            baseURL: baseURL
        )
        let value = try JSONValue.parse(response.body, limits: JSONLimits(maxDocumentBytes: 1 << 16))
        guard response.isSuccess else {
            if let error = try? ControlError(json: value) { throw error }
            throw EnrollmentError.server("HTTP \(response.status)")
        }
        return value
    }

    private func postForm(_ path: String, fields: [String: String]) async throws -> JSONValue {
        try await postFormJSON(path, fields: fields)
    }

    private func postFormJSON(_ path: String, fields: [String: String]) async throws -> JSONValue {
        let response = try await postFormRaw(path, fields: fields)
        let value = try JSONValue.parse(response.body, limits: JSONLimits(maxDocumentBytes: 1 << 16))
        guard response.isSuccess else {
            // A refresh that fails because the device was revoked must reach
            // the caller as `device_revoked`, not as an opaque server string:
            // one means re-enrol, the other means retry later
            // (spec.watch.md section 16).
            if let error = try? ControlError(json: value) { throw error }
            throw EnrollmentError.server(value["error"]?.stringValue ?? "HTTP \(response.status)")
        }
        return value
    }

    private func postFormRaw(_ path: String, fields: [String: String]) async throws -> ControlHTTPResponse {
        // The OAuth endpoints are the documented exception to JSON bodies; no
        // client secret is ever embedded in the app.
        let encoded = fields
            .map { "\(Self.formEscape($0.key))=\(Self.formEscape($0.value))" }
            .sorted()
            .joined(separator: "&")
        return try await transport.send(
            ControlHTTPRequest(
                method: "POST",
                path: path,
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: Data(encoded.utf8)
            ),
            baseURL: baseURL
        )
    }

    private static func formEscape(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
