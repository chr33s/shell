import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// Routes `/v1` HTTP requests onto ``BrokerStore``.
///
/// Every endpoint enforces authenticated account and object scope; the
/// enrollment and discovery exceptions are the ones the spec names
/// (spec.watch.md section 10).
public struct BrokerService: Sendable {
    public struct Configuration: Sendable {
        public var verificationURI: String
        public var allowedAPNsTopics: Set<String>
        /// A high-entropy administration credential. Device enrollment and
        /// policy changes require it; decision credentials never suffice.
        public var adminSecret: String
        public var adminAccountID: ControlID

        public init(
            verificationURI: String,
            allowedAPNsTopics: Set<String>,
            adminSecret: String,
            adminAccountID: ControlID
        ) {
            self.verificationURI = verificationURI
            self.allowedAPNsTopics = allowedAPNsTopics
            self.adminSecret = adminSecret
            self.adminAccountID = adminAccountID
        }
    }

    let store: BrokerStore
    let configuration: Configuration
    let limiter: RateLimiter

    public init(store: BrokerStore, configuration: Configuration) {
        self.store = store
        self.configuration = configuration
        self.limiter = RateLimiter()
    }

    public func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        do {
            return try await route(request)
        } catch let error as ControlError {
            return respond(error)
        } catch let error as OAuthError {
            let status = error == .slowDown || error == .authorizationPending ? 400 : 400
            return json(status: status, .object(["error": .string(error.rawValue)]))
        } catch {
            return respond(ControlError(code: .invalidPayload, message: String(describing: error)))
        }
    }

    private func route(_ request: HTTPServer.Request) async throws -> HTTPServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/v1/capabilities"):
            return json(status: 200, await store.capabilities().json)

        // MARK: Enrollment (no control authority)

        case ("POST", "/v1/enrollments"):
            try await limiter.check(bucket: "enroll", limit: 30)
            var reader = try JSONReader(try body(request))
            let jwk = try DeviceJWK(json: try reader.value("public_jwk"))
            let platformText = try reader.string("platform", maxLength: 16)
            guard let platform = PushRegistration.Platform(rawValue: platformText) else {
                throw ControlError(code: .invalidPayload, message: "unknown platform")
            }
            let label = try reader.string("label", maxLength: 120)
            let created = try await store.createEnrollment(publicJWK: jwk, platform: platform, label: label)
            return json(status: 201, .object([
                "enrollment_id": JSONValue(created.enrollmentID),
                "challenge": .string(created.challenge),
                "expires_at": JSONValue(created.expiresAt),
            ]))

        case ("POST", "/v1/oauth/device_authorization"):
            try await limiter.check(bucket: "device_authorization", limit: 30)
            let fields = formFields(request)
            guard let scope = fields["scope"] else {
                throw ControlError(code: .invalidPayload, message: "scope is required")
            }
            return json(status: 200, try await store.startDeviceAuthorization(
                scope: scope,
                verificationURI: configuration.verificationURI
            ))

        case ("POST", "/v1/oauth/token"):
            try await limiter.check(bucket: "token", limit: 120)
            let fields = formFields(request)
            switch fields["grant_type"] {
            case "urn:ietf:params:oauth:grant-type:device_code":
                guard let deviceCode = fields["device_code"] else { throw OAuthError.invalidGrant }
                return json(status: 200, try await store.pollDeviceToken(deviceCode: deviceCode))
            case "refresh_token":
                guard let refresh = fields["refresh_token"] else { throw OAuthError.invalidGrant }
                return json(status: 200, try await store.refreshSession(refreshToken: refresh).json)
            default:
                throw OAuthError.invalidGrant
            }

        case ("GET", "/v1/oauth/confirm"):
            // This is the surface the device sends the user to, so a browser
            // gets a page it can act on. Nothing about the enrollment is shown
            // until the operator authenticates: the details appear only after
            // the credential is accepted.
            let userCode = request.query["user_code"] ?? ""
            guard let principal = try? administrator(request) else {
                guard wantsHTML(request) else {
                    throw ControlError(code: .notAuthorized, message: "account administration required")
                }
                return html(status: 401, ConfirmationPage.form(userCode: userCode, message: nil))
            }
            _ = principal
            guard !userCode.isEmpty else {
                throw ControlError(code: .invalidPayload, message: "user_code is required")
            }
            let described = try await store.describeUserCode(userCode)
            if wantsHTML(request) {
                return html(status: 200, ConfirmationPage.details(described, userCode: userCode))
            }
            return json(status: 200, described)

        case ("POST", "/v1/oauth/confirm"):
            // Two shapes: a JSON API call carrying the admin credential in a
            // header, and a browser form carrying it in the body. Both require
            // account administration; a decision credential never suffices.
            let isForm = (request.header("Content-Type") ?? "").hasPrefix("application/x-www-form-urlencoded")
            let fields = isForm ? formFields(request) : [:]
            let principal = try administrator(request, formSecret: fields["admin_secret"])
            let userCode: String
            let approve: Bool
            var grants: Set<DeviceGrant>?
            if isForm {
                userCode = fields["user_code"] ?? ""
                approve = fields["approve"] != "false"
            } else {
                var reader = try JSONReader(try body(request))
                userCode = try reader.string("user_code", maxLength: 16)
                approve = try reader.optionalBool("approve") ?? true
                grants = (try? reader.stringArray("grants", maxCount: 16, maxLength: 32))
                    .map { Set($0.compactMap(DeviceGrant.init(rawValue:))) }
            }
            guard !userCode.isEmpty else {
                throw ControlError(code: .invalidPayload, message: "user_code is required")
            }
            if approve {
                try await store.approveDeviceAuthorization(userCode: userCode, principal: principal, grants: grants)
            } else {
                try await store.denyDeviceAuthorization(userCode: userCode)
            }
            if isForm {
                return html(status: 200, ConfirmationPage.outcome(approved: approve, userCode: userCode))
            }
            return json(status: 200, .object(["ok": true]))

        default:
            break
        }

        if request.method == "POST", request.path.hasPrefix("/v1/enrollments/"), request.path.hasSuffix("/complete") {
            let idText = request.path
                .replacingOccurrences(of: "/v1/enrollments/", with: "")
                .replacingOccurrences(of: "/complete", with: "")
            guard let enrollmentID = ControlID(idText) else {
                throw ControlError(code: .notFound, message: "no such enrollment")
            }
            guard let token = bearerToken(request) else {
                throw ControlError(code: .invalidToken, message: "enrollment token required")
            }
            var reader = try JSONReader(try body(request))
            let signature = try reader.string("challenge_signature", maxLength: 200)
            let session = try await store.completeEnrollment(
                enrollmentID: enrollmentID,
                enrollmentToken: token,
                challengeSignature: signature
            )
            return json(status: 201, session.json)
        }

        return try await routeAuthenticated(request)
    }

    // MARK: Authenticated routes

    private func routeAuthenticated(_ request: HTTPServer.Request) async throws -> HTTPServer.Response {
        let principal = try await authenticate(request)

        switch (request.method, request.path) {
        case ("PUT", "/v1/devices/me/push"):
            let registration = try PushRegistration(json: try body(request))
            try await store.registerPush(
                principal: principal,
                registration: registration,
                allowedTopics: configuration.allowedAPNsTopics
            )
            return json(status: 200, .object(["ok": true]))

        case ("GET", "/v1/snapshot"):
            try principal.requireGrant(.requestsRead)
            let page = try await store.snapshot(
                principal: principal,
                pageToken: request.query["page"],
                limit: Int(request.query["limit"] ?? "") ?? SnapshotPage.maximumItems
            )
            return json(status: 200, page.json)

        case ("GET", "/v1/changes"):
            // The deltas carry full approval projections, so this needs the
            // same grant as /v1/snapshot: a device whose grants were reduced
            // must not keep reading request content through the stream.
            if principal.deviceID != nil {
                try principal.requireGrant(.requestsRead)
            }
            guard let cursorText = request.query["cursor"] else {
                throw ControlError(code: .invalidPayload, message: "cursor is required")
            }
            let cursor = ChangeCursor(cursorText)
            let limit = Int(request.query["limit"] ?? "") ?? ChangePage.maximumEvents
            let wait = min(Int(request.query["wait"] ?? "0") ?? 0, 30)
            var page = try await store.changes(principal: principal, cursor: cursor, limit: limit)
            if page.events.isEmpty, wait > 0 {
                // Long polling for origins: bounded, and it never becomes an
                // always-open socket for the Watch (spec.watch.md section 7).
                let deadline = Date().addingTimeInterval(TimeInterval(wait))
                while page.events.isEmpty, Date() < deadline {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    page = try await store.changes(principal: principal, cursor: cursor, limit: limit)
                }
            }
            return json(status: 200, page.json)

        case ("POST", "/v1/review-challenges"):
            let challengeRequest = try ReviewChallengeRequest(json: try body(request))
            let challenge = try await store.createChallenge(principal: principal, request: challengeRequest)
            return json(status: 201, challenge.json)

        case ("POST", "/v1/commands"):
            guard let key = request.header("Idempotency-Key").flatMap(ControlID.init) else {
                throw ControlError(code: .invalidPayload, message: "Idempotency-Key is required")
            }
            var reader = try JSONReader(try body(request))
            let signed = try reader.string("signed_command", maxLength: 8192)
            try reader.rejectUnknownMembers()
            let outcome = try await store.submitCommand(principal: principal, signedCommand: signed, idempotencyKey: key)
            // A first record is 201; an identical retry returns 200 with the
            // original recorded result (spec.watch.md section 11).
            return json(status: outcome.isReplay ? 200 : 201, outcome.result.json)

        case ("POST", "/v1/origins/me/heartbeat"):
            var reader = try JSONReader(try body(request))
            let runIDs = try reader.stringArray("run_ids", maxCount: 256, maxLength: 36).compactMap(ControlID.init)
            let waiting = try reader.stringArray("waiting_request_ids", maxCount: 1024, maxLength: 36).compactMap(ControlID.init)
            try await store.heartbeat(principal: principal, runIDs: runIDs, waitingRequestIDs: waiting)
            return json(status: 200, .object(["ok": true]))

        case ("POST", "/v1/notifications"):
            let event = try InformationalEvent(json: try body(request))
            let stored = try await store.createNotification(principal: principal, event: event)
            return json(status: 201, stored.json)

        case ("POST", "/v1/approvals"):
            let spec = try ApprovalSpec(json: try body(request))
            let record = try await store.createApproval(principal: principal, spec: spec)
            return json(status: 201, record.json)

        case ("POST", "/v1/receipts"):
            let receipt = try Receipt(json: try body(request))
            try await store.recordReceipt(principal: principal, receipt: receipt)
            return json(status: 201, .object(["ok": true]))

        default:
            break
        }

        if request.method == "GET", request.path.hasPrefix("/v1/approvals/") {
            guard let requestID = ControlID(String(request.path.dropFirst("/v1/approvals/".count))) else {
                throw ControlError(code: .notFound, message: "no such request")
            }
            try principal.requireGrant(.requestsRead)
            return json(status: 200, try await store.approval(requestID, principal: principal).json)
        }
        if request.method == "GET", request.path.hasPrefix("/v1/commands/") {
            guard let commandID = ControlID(String(request.path.dropFirst("/v1/commands/".count))) else {
                throw ControlError(code: .notFound, message: "no such command")
            }
            return json(status: 200, try await store.commandResult(commandID, principal: principal).json)
        }
        if request.method == "PUT", request.path.hasPrefix("/v1/origins/me/runs/") {
            let registration = try RunRegistration(json: try body(request))
            guard let runID = ControlID(String(request.path.dropFirst("/v1/origins/me/runs/".count))),
                  runID == registration.runID
            else {
                throw ControlError(code: .invalidPayload, message: "run id mismatch")
            }
            try await store.registerRun(principal: principal, registration: registration)
            return json(status: 200, .object(["ok": true]))
        }
        if request.method == "POST", request.path.hasPrefix("/v1/approvals/"), request.path.hasSuffix("/withdraw") {
            let idText = String(request.path.dropFirst("/v1/approvals/".count).dropLast("/withdraw".count))
            guard let requestID = ControlID(idText) else {
                throw ControlError(code: .notFound, message: "no such request")
            }
            var reader = try JSONReader(try body(request))
            let record = try await store.withdrawApproval(
                principal: principal,
                requestID: requestID,
                mutationID: try reader.id("mutation_id"),
                runID: try reader.id("run_id"),
                requestHash: try reader.string("request_hash", maxLength: 80)
            )
            return json(status: 200, .object(["projection": record.json]))
        }
        if request.method == "POST", request.path.hasPrefix("/v1/approvals/"), request.path.hasSuffix("/consume") {
            let idText = String(request.path.dropFirst("/v1/approvals/".count).dropLast("/consume".count))
            guard let requestID = ControlID(idText) else {
                throw ControlError(code: .notFound, message: "no such request")
            }
            let consume = try ConsumeRequest(json: try body(request))
            let permit = try await store.consumeApproval(principal: principal, requestID: requestID, request: consume)
            return json(status: 201, permit.json)
        }

        throw ControlError(code: .notFound, message: "no such endpoint")
    }

    // MARK: Helpers

    private func authenticate(_ request: HTTPServer.Request) async throws -> Principal {
        guard let authorization = request.header("Authorization") else {
            throw ControlError(code: .invalidToken, message: "authorization required")
        }
        if authorization.hasPrefix("Bearer ") {
            return try await store.authenticate(bearer: String(authorization.dropFirst("Bearer ".count)))
        }
        if authorization.hasPrefix("Origin ") {
            let value = authorization.dropFirst("Origin ".count)
            let parts = value.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let originID = ControlID(String(parts[0])) else {
                throw ControlError(code: .invalidToken, message: "origin credential malformed")
            }
            return try await store.authenticateOrigin(originID: originID, secret: String(parts[1]))
        }
        throw ControlError(code: .invalidToken, message: "unsupported authorization scheme")
    }

    /// Accepts the admin credential from the `Authorization` header or, for the
    /// browser form, from the submitted body. Compared by digest so the check
    /// does not leak the secret's length or a prefix through timing.
    private func administrator(_ request: HTTPServer.Request, formSecret: String? = nil) throws -> Principal {
        let header = request.header("Authorization")
        let presented: String?
        if let header, header.hasPrefix("Admin ") {
            presented = String(header.dropFirst("Admin ".count))
        } else {
            presented = formSecret
        }
        guard let presented, !presented.isEmpty,
              ContentDigest.matches(
                  ContentDigest.digest(of: Data(presented.utf8)),
                  ContentDigest.digest(of: Data(configuration.adminSecret.utf8))
              )
        else {
            throw ControlError(code: .notAuthorized, message: "account administration required")
        }
        return .admin(accountID: configuration.adminAccountID)
    }

    private func wantsHTML(_ request: HTTPServer.Request) -> Bool {
        (request.header("Accept") ?? "").contains("text/html")
    }

    private func html(status: Int, _ body: String) -> HTTPServer.Response {
        HTTPServer.Response(
            status: status,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                // The page carries a credential field, so it is never cached or
                // framed, and it references nothing off-origin.
                "Cache-Control": "no-store",
                "X-Frame-Options": "DENY",
                "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
                "Referrer-Policy": "no-referrer",
            ],
            body: Data(body.utf8)
        )
    }

    private func bearerToken(_ request: HTTPServer.Request) -> String? {
        guard let authorization = request.header("Authorization"), authorization.hasPrefix("Bearer ") else { return nil }
        return String(authorization.dropFirst("Bearer ".count))
    }

    private func body(_ request: HTTPServer.Request) throws -> JSONValue {
        guard request.body.count <= JSONLimits.maxDocumentBytes else {
            throw ControlError(code: .invalidPayload, message: "document exceeds 64 KiB")
        }
        do {
            return try JSONValue.parse(request.body)
        } catch {
            throw ControlError(code: .invalidPayload, message: "\(error)")
        }
    }

    static func parseFormBody(_ body: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            // A body of "=" splits into nothing; indexing it would trap on an
            // unauthenticated request.
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let rawName = parts.first else { continue }
            let name = String(rawName).removingPercentEncoding ?? String(rawName)
            let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
            fields[name] = value
        }
        return fields
    }

    private func formFields(_ request: HTTPServer.Request) -> [String: String] {
        BrokerService.parseFormBody(request.body)
    }

    private func json(status: Int, _ value: JSONValue) -> HTTPServer.Response {
        let data = (try? JSONCanonicalization.canonicalize(value)) ?? Data("{}".utf8)
        return HTTPServer.Response(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    private func respond(_ error: ControlError) -> HTTPServer.Response {
        json(status: error.code.httpStatus, error.json)
    }
}

/// A coarse per-bucket limiter. The enrollment and token endpoints rate-limit
/// attempts (spec.watch.md section 5).
actor RateLimiter {
    private var counters: [String: (windowStart: Date, count: Int)] = [:]

    func check(bucket: String, limit: Int, window: TimeInterval = 60) throws {
        let now = Date()
        var entry = counters[bucket] ?? (now, 0)
        if now.timeIntervalSince(entry.windowStart) > window { entry = (now, 0) }
        entry.count += 1
        counters[bucket] = entry
        guard entry.count <= limit else {
            throw ControlError(code: .rateLimited, message: "too many attempts")
        }
    }
}
