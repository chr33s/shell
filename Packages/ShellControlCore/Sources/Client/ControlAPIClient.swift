import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// Credentials the client presents. The account/tenant is always derived by the
/// server from these, never from a caller-supplied account ID
/// (spec.watch.md section 4).
public enum ControlCredential: Sendable {
    /// A device-scoped bearer access token.
    case device(String)
    /// A per-origin, separately provisioned high-entropy credential. It is
    /// never distributed to watchOS clients (spec.watch.md section 10).
    case origin(originID: ControlID, secret: String)
    case none

    var headers: [String: String] {
        switch self {
        case .device(let token): return ["Authorization": "Bearer \(token)"]
        case .origin(let originID, let secret):
            return ["Authorization": "Origin \(originID.rawValue):\(secret)"]
        case .none: return [:]
        }
    }
}

/// Typed access to the `/v1` runtime endpoints (spec.watch.md section 10).
public actor ControlAPIClient {
    public let baseURL: URL
    private let transport: any ControlHTTPTransport
    private var credential: ControlCredential

    public init(baseURL: URL, transport: any ControlHTTPTransport = URLSessionTransport(), credential: ControlCredential = .none) {
        self.baseURL = baseURL
        self.transport = transport
        self.credential = credential
    }

    public func updateCredential(_ credential: ControlCredential) {
        self.credential = credential
    }

    // MARK: Discovery and device registration

    public func capabilities() async throws -> ServiceCapabilities {
        try ServiceCapabilities(json: try await get("/v1/capabilities"))
    }

    public func registerPush(_ registration: PushRegistration) async throws {
        _ = try await send(method: "PUT", path: "/v1/devices/me/push", body: registration.json)
    }

    // MARK: Reads

    public func snapshot(pageToken: String? = nil, limit: Int = SnapshotPage.maximumItems) async throws -> SnapshotPage {
        var query = [("limit", String(min(limit, SnapshotPage.maximumItems)))]
        if let pageToken { query.append(("page", pageToken)) }
        return try SnapshotPage(json: try await get("/v1/snapshot", query: query))
    }

    public func changes(after cursor: ChangeCursor, limit: Int = ChangePage.maximumEvents, wait: Int = 0) async throws -> ChangePage {
        let query = [
            ("cursor", cursor.rawValue),
            ("limit", String(min(limit, ChangePage.maximumEvents))),
            ("wait", String(wait)),
        ]
        // A long poll needs a transport timeout beyond the server's wait window.
        return try ChangePage(json: try await get("/v1/changes", query: query, timeout: wait > 0 ? TimeInterval(wait) + 10 : 15))
    }

    public func approval(_ requestID: ControlID) async throws -> ApprovalRecord {
        try ApprovalRecord(json: try await get("/v1/approvals/\(requestID.rawValue)"))
    }

    // MARK: Device mutations

    public func reviewChallenge(_ request: ReviewChallengeRequest) async throws -> ReviewChallenge {
        try ReviewChallenge(json: try await send(method: "POST", path: "/v1/review-challenges", body: request.json))
    }

    /// Submits a signed mutation. `Idempotency-Key` equals the command ID, so a
    /// retry retrieves the recorded result instead of deciding twice
    /// (spec.watch.md section 11).
    public func submit(signedCommand: String, commandID: ControlID) async throws -> CommandResult {
        let value = try await send(
            method: "POST",
            path: "/v1/commands",
            body: .object(["signed_command": .string(signedCommand)]),
            headers: ["Idempotency-Key": commandID.rawValue]
        )
        return try CommandResult(json: value)
    }

    public func commandResult(_ commandID: ControlID) async throws -> CommandResult {
        try CommandResult(json: try await get("/v1/commands/\(commandID.rawValue)"))
    }

    // MARK: Origin mutations

    public func registerRun(_ run: RunRegistration) async throws {
        _ = try await send(method: "PUT", path: "/v1/origins/me/runs/\(run.runID.rawValue)", body: run.json)
    }

    public func heartbeat(runIDs: [ControlID], waitingRequestIDs: [ControlID] = []) async throws {
        _ = try await send(
            method: "POST",
            path: "/v1/origins/me/heartbeat",
            body: .object([
                "run_ids": JSONValue(strings: runIDs.map(\.rawValue)),
                "waiting_request_ids": JSONValue(strings: waitingRequestIDs.map(\.rawValue)),
            ])
        )
    }

    public func createNotification(_ event: InformationalEvent) async throws {
        _ = try await send(method: "POST", path: "/v1/notifications", body: event.json)
    }

    @discardableResult
    public func createApproval(_ spec: ApprovalSpec) async throws -> ApprovalRecord {
        try ApprovalRecord(json: try await send(method: "POST", path: "/v1/approvals", body: spec.json))
    }

    public func withdrawApproval(
        _ requestID: ControlID,
        mutationID: ControlID,
        runID: ControlID,
        requestHash: String
    ) async throws -> ApprovalProjection {
        let value = try await send(
            method: "POST",
            path: "/v1/approvals/\(requestID.rawValue)/withdraw",
            body: .object([
                "mutation_id": JSONValue(mutationID),
                "run_id": JSONValue(runID),
                "request_hash": .string(requestHash),
            ])
        )
        return try ApprovalProjection(json: value["projection"] ?? value)
    }

    public func consumeApproval(_ requestID: ControlID, request: ConsumeRequest) async throws -> ConsumePermit {
        try ConsumePermit(json: try await send(
            method: "POST",
            path: "/v1/approvals/\(requestID.rawValue)/consume",
            body: request.json
        ))
    }

    public func postReceipt(_ receipt: Receipt) async throws {
        _ = try await send(method: "POST", path: "/v1/receipts", body: receipt.json)
    }

    // MARK: Plumbing

    private func get(_ path: String, query: [(String, String)] = [], timeout: TimeInterval = 15) async throws -> JSONValue {
        try await perform(ControlHTTPRequest(
            method: "GET",
            path: path,
            query: query,
            headers: credential.headers,
            timeout: timeout
        ))
    }

    @discardableResult
    private func send(
        method: String,
        path: String,
        body: JSONValue,
        headers: [String: String] = [:]
    ) async throws -> JSONValue {
        var allHeaders = credential.headers
        allHeaders["Content-Type"] = "application/json"
        for (name, value) in headers { allHeaders[name] = value }
        let encoded = try JSONCanonicalization.canonicalize(body)
        guard encoded.count <= JSONLimits.maxDocumentBytes else {
            throw ControlError(code: .invalidPayload, message: "document exceeds 64 KiB")
        }
        return try await perform(ControlHTTPRequest(method: method, path: path, headers: allHeaders, body: encoded))
    }

    private func perform(_ request: ControlHTTPRequest) async throws -> JSONValue {
        let response = try await transport.send(request, baseURL: baseURL)
        if response.body.isEmpty && response.isSuccess { return .object([:]) }
        let value = try JSONValue.parse(response.body, limits: JSONLimits(maxDocumentBytes: 1 << 20))
        guard response.isSuccess else {
            if let error = try? ControlError(json: value) { throw error }
            throw ControlError(
                code: response.status >= 500 ? .temporarilyUnavailable : .invalidPayload,
                message: "unexpected HTTP \(response.status)"
            )
        }
        return value
    }
}
