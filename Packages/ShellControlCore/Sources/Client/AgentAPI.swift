import Foundation
import ShellControlProtocol

/// Typed access to the optional `shell-agent/1` endpoints. A broker without
/// the extension answers `not_found` on discovery, which clients treat as
/// "agent integrations unsupported" (spec.agent-relay.md section 15).
extension ControlAPIClient {
    // MARK: Devices

    public func agentCapabilities() async throws -> AgentCapabilities {
        try AgentCapabilities(json: try await get(AgentProtocol.Path.capabilities))
    }

    public func agentSession(_ id: ControlID) async throws -> AgentSessionProjection {
        try AgentSessionProjection(json: try await get(AgentProtocol.Path.session(id)))
    }

    /// `pendingOnly` limits the page to what can still be answered: active
    /// sessions, pending inputs, and agent approvals still pending.
    public func agentSnapshot(pageToken: String? = nil, limit: Int = AgentSnapshotPage.maximumItems, pendingOnly: Bool = false) async throws -> AgentSnapshotPage {
        var query = [("limit", String(max(1, min(limit, AgentSnapshotPage.maximumItems))))]
        if let pageToken { query.append(("page", pageToken)) }
        if pendingOnly { query.append(("pending", "1")) }
        return try AgentSnapshotPage(json: try await get(AgentProtocol.Path.snapshot, query: query))
    }

    public func agentChanges(after cursor: ChangeCursor, limit: Int = AgentChangePage.maximumEvents) async throws -> AgentChangePage {
        try AgentChangePage(json: try await get(AgentProtocol.Path.changes, query: [
            ("cursor", cursor.rawValue),
            ("limit", String(max(1, min(limit, AgentChangePage.maximumEvents))))
        ]))
    }

    /// The full spec with an independently recomputed digest.
    public func input(_ requestID: ControlID) async throws -> InputRecord {
        try InputRecord(json: try await get(AgentProtocol.Path.input(requestID)))
    }

    public func agentReviewChallenge(_ request: AgentReviewChallengeRequest) async throws -> AgentReviewChallenge {
        try AgentReviewChallenge(json: try await send(method: "POST", path: AgentProtocol.Path.reviewChallenges, body: request.json))
    }

    /// The signed command is the only mutation payload; `Idempotency-Key`
    /// equals its command ID.
    public func submitAgent(signedCommand: String, commandID: ControlID) async throws -> AgentCommandResult {
        try AgentCommandResult(json: try await send(
            method: "POST",
            path: AgentProtocol.Path.commands,
            body: .object(["signed_command": .string(signedCommand)]),
            headers: ["Idempotency-Key": commandID.rawValue]
        ))
    }

    public func agentCommandResult(_ commandID: ControlID) async throws -> AgentCommandResult {
        try AgentCommandResult(json: try await get(AgentProtocol.Path.command(commandID)))
    }

    // MARK: Origins

    @discardableResult
    public func registerAgentSession(_ registration: AgentSessionRegistration) async throws -> AgentSessionProjection {
        try AgentSessionProjection(json: try await send(method: "POST", path: AgentProtocol.Path.sessions, body: registration.json))
    }

    @discardableResult
    public func createInput(_ spec: InputSpec) async throws -> InputRecord {
        try InputRecord(json: try await send(method: "POST", path: AgentProtocol.Path.inputs, body: spec.json))
    }

    public func withdrawInput(_ requestID: ControlID, mutationID: ControlID, runID: ControlID, requestHash: String) async throws -> InputRecord {
        try InputRecord(json: try await send(method: "POST", path: AgentProtocol.Path.withdrawInput(requestID), body: .object([
            "mutation_id": JSONValue(mutationID),
            "run_id": JSONValue(runID),
            "request_hash": .string(requestHash)
        ])))
    }

    public func consumeInput(_ requestID: ControlID, request: InputConsumeRequest) async throws -> InputConsumePermit {
        try InputConsumePermit(json: try await send(method: "POST", path: AgentProtocol.Path.consumeInput(requestID), body: request.json))
    }

    public func postAgentReceipt(_ receipt: AgentDeliveryReceipt) async throws {
        _ = try await send(method: "POST", path: AgentProtocol.Path.receipts, body: receipt.json)
    }

    /// The session's unclaimed commands, oldest first.
    public func pendingSessionCommands(_ sessionID: ControlID) async throws -> [AgentSessionCommandRecord] {
        let value = try await get(AgentProtocol.Path.sessionCommands(sessionID))
        return try (value["commands"]?.arrayValue ?? []).map(AgentSessionCommandRecord.init(json:))
    }

    public func claimSessionCommand(_ sessionID: ControlID, request: AgentSessionClaimRequest) async throws -> AgentSessionPermit {
        try AgentSessionPermit(json: try await send(
            method: "POST",
            path: AgentProtocol.Path.claimSessionCommand(sessionID, command: request.commandID),
            body: request.json
        ))
    }

    public func postAgentEvent(_ event: AgentEvent) async throws {
        _ = try await send(method: "POST", path: AgentProtocol.Path.events, body: event.json)
    }

    // MARK: Gateway: a Watch reviewer's agent calls

    /// Proxied through this iPhone; the broker checks the binding, grant, and
    /// the Watch's own signature on every call (spec.agent-relay.md 15.5).
    public func gatewayAgentCapabilities(watch watchID: ControlID) async throws -> JSONValue {
        try await get("\(Self.reviewerPath(watchID))/agent/capabilities")
    }

    public func gatewayAgentSnapshot(watch watchID: ControlID, pageToken: String?, limit: Int, pendingOnly: Bool = false) async throws -> JSONValue {
        var query = [("limit", String(max(1, min(limit, AgentSnapshotPage.maximumItems))))]
        if let pageToken { query.append(("page", pageToken)) }
        if pendingOnly { query.append(("pending", "1")) }
        return try await get("\(Self.reviewerPath(watchID))/agent/snapshot", query: query)
    }

    public func gatewayAgentChanges(watch watchID: ControlID, cursor: ChangeCursor, limit: Int) async throws -> JSONValue {
        try await get("\(Self.reviewerPath(watchID))/agent/changes", query: [
            ("cursor", cursor.rawValue),
            ("limit", String(max(1, min(limit, AgentChangePage.maximumEvents))))
        ])
    }

    public func gatewayInput(watch watchID: ControlID, requestID: ControlID) async throws -> JSONValue {
        try await get("\(Self.reviewerPath(watchID))/agent/inputs/\(requestID.rawValue)")
    }

    public func gatewayAgentReviewChallenge(watch watchID: ControlID, request: JSONValue) async throws -> JSONValue {
        try await send(method: "POST", path: "\(Self.reviewerPath(watchID))/agent/review-challenges", body: request)
    }

    /// Forwards the Watch's JWS unchanged.
    public func gatewayAgentSubmit(watch watchID: ControlID, signedCommand: String, commandID: ControlID) async throws -> JSONValue {
        try await send(
            method: "POST",
            path: "\(Self.reviewerPath(watchID))/agent/commands",
            body: .object(["signed_command": .string(signedCommand)]),
            headers: ["Idempotency-Key": commandID.rawValue]
        )
    }

    public func gatewayAgentCommandResult(watch watchID: ControlID, commandID: ControlID) async throws -> JSONValue {
        try await get("\(Self.reviewerPath(watchID))/agent/commands/\(commandID.rawValue)")
    }
}
