import Foundation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// A scripted control service for the Watch app's tests.
///
/// It answers the endpoints the app actually calls, and enforces the one rule
/// the credential tests are about: a request presenting a stale access token
/// gets `401 invalid_token`, exactly as the broker would.
actor StubControlService: ControlHTTPTransport {
    struct Recorded: Sendable {
        let method: String
        let path: String
        let authorization: String?
    }

    private(set) var requests: [Recorded] = []
    private(set) var refreshCount = 0

    var validAccessToken: String
    var refreshToken: String
    var nextAccessToken: String
    var deviceID: ControlID
    var accountID: ControlID
    var approvals: [ApprovalRecord] = []
    var notifications: [InformationalEvent] = []
    /// When set, every call throws it instead of answering.
    var transportFailure: TransportError?
    /// When set, the refresh endpoint fails with this error.
    var refreshFailure: ControlError?
    /// When true, the first `/v1/changes` call answers `410 cursor_expired`.
    var expireNextCursor = false
    /// Artificial delay on refresh so concurrent callers can overlap.
    var tokenDelayNanoseconds: UInt64 = 0
    var now: ControlTimestamp

    init(
        validAccessToken: String,
        refreshToken: String,
        nextAccessToken: String,
        deviceID: ControlID,
        accountID: ControlID,
        now: ControlTimestamp
    ) {
        self.validAccessToken = validAccessToken
        self.refreshToken = refreshToken
        self.nextAccessToken = nextAccessToken
        self.deviceID = deviceID
        self.accountID = accountID
        self.now = now
    }

    func setApprovals(_ approvals: [ApprovalRecord]) { self.approvals = approvals }
    /// Rotates the accepted token, so a request presenting the previous one is
    /// refused exactly as an expired session would be.
    func setValidToken(_ token: String) {
        nextAccessToken = token
        validAccessToken = "\(token)-not-yet-issued"
    }
    func setTransportFailure(_ failure: TransportError?) { transportFailure = failure }
    func setRefreshFailure(_ failure: ControlError?) { refreshFailure = failure }
    func setExpireNextCursor(_ flag: Bool) { expireNextCursor = flag }
    func setTokenDelay(_ nanoseconds: UInt64) { tokenDelayNanoseconds = nanoseconds }
    func setNow(_ value: ControlTimestamp) { now = value }

    func send(_ request: ControlHTTPRequest, baseURL: URL) async throws -> ControlHTTPResponse {
        if let transportFailure { throw transportFailure }
        let authorization = request.headers["Authorization"]
        requests.append(Recorded(method: request.method, path: request.path, authorization: authorization))

        func json(_ status: Int, _ value: JSONValue) throws -> ControlHTTPResponse {
            ControlHTTPResponse(status: status, body: try JSONCanonicalization.canonicalize(value))
        }

        // The OAuth token endpoint is the documented form-encoded exception.
        if request.path == "/v1/oauth/token" {
            if tokenDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: tokenDelayNanoseconds)
            }
            refreshCount += 1
            if let refreshFailure { return try json(refreshFailure.code.httpStatus, refreshFailure.json) }
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            guard body.contains("refresh_token=\(refreshToken)") else {
                return try json(401, ControlError(code: .invalidToken, message: "unknown refresh token").json)
            }
            validAccessToken = nextAccessToken
            refreshToken = "\(refreshToken)-rotated"
            return try json(200, session().json)
        }

        guard authorization == "Bearer \(validAccessToken)" else {
            return try json(401, ControlError(code: .invalidToken, message: "token expired").json)
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/snapshot"):
            return try json(200, SnapshotPage(
                approvals: approvals,
                notifications: notifications,
                snapshotToken: "s1.1.tag",
                nextPageToken: nil,
                cursor: ChangeCursor("c1.1.tag"),
                serverTime: now
            ).json)
        case ("GET", "/v1/changes"):
            if expireNextCursor {
                expireNextCursor = false
                return try json(410, ControlError(code: .cursorExpired, message: "cursor expired").json)
            }
            return try json(200, ChangePage(events: [], cursor: ChangeCursor("c1.2.tag"), serverTime: now).json)
        case ("PUT", "/v1/devices/me/push"):
            return try json(200, .object(["ok": true]))
        default:
            break
        }
        if request.method == "GET", request.path.hasPrefix("/v1/approvals/") {
            let id = ControlID(String(request.path.dropFirst("/v1/approvals/".count)))
            guard let id, let record = approvals.first(where: { $0.spec.requestID == id }) else {
                return try json(404, ControlError(code: .notFound, message: "no such request").json)
            }
            return try json(200, record.json)
        }
        return try json(404, ControlError(code: .notFound, message: "no such endpoint").json)
    }

    func session(accessTokenExpiresAt: ControlTimestamp? = nil) -> DeviceSession {
        DeviceSession(
            deviceID: deviceID,
            accountID: accountID,
            accessToken: validAccessToken,
            accessTokenExpiresAt: accessTokenExpiresAt ?? now.adding(10 * 60),
            refreshToken: refreshToken,
            grants: DeviceGrant.watchDefault
        )
    }

    func authorizationHeaders() -> [String?] { requests.map(\.authorization) }
}

enum WatchTestFixtures {
    static func makeRecord(
        requestID: ControlID = .random(),
        createdAt: ControlTimestamp,
        resolution: Resolution = .pending,
        minimumReview: MinimumReview = .watch,
        presentAt: ControlTimestamp? = nil
    ) throws -> ApprovalRecord {
        let spec = try ApprovalSpec(
            requestID: requestID,
            originID: .random(),
            jobID: .random(),
            runID: .random(),
            createdAt: createdAt,
            expiresAt: createdAt.adding(ApprovalPolicy.defaultLifetime),
            summary: "Push feature branch",
            operation: .exec(try ExecOperation(
                argv: ["/usr/bin/git", "push", "origin", "feature/watch-controls"],
                cwd: "/srv/work/shell",
                contextSHA256: String(repeating: "0", count: 64)
            )),
            minimumReview: minimumReview,
            requiredFeatures: [ExecOperation.schema, ControlFeature.consume]
        )
        return try ApprovalRecord(
            spec: spec,
            projection: ApprovalProjection(
                resolution: resolution,
                presence: SourcePresence(lastSeenAt: presentAt, isWaiting: presentAt != nil)
            )
        )
    }
}
