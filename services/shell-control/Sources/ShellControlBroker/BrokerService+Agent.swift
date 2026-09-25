import Foundation
import ShellControlProtocol
import ShellControlSecurity

/// `/v1/agent/*` routes and their gateway counterparts
/// (spec.agent-relay.md section 15.2). The signed command is the only
/// authoritative mutation payload; a user-supplied origin or device ID never
/// determines authorization.
extension BrokerService {
    func routeAgent(_ request: HTTPServer.Request, principal: Principal) async throws -> HTTPServer.Response {
        let parts = request.path.dropFirst("/v1/agent/".count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch (request.method, parts.first, parts.count) {
        case ("GET", "capabilities", 1):
            return json(status: 200, await store.agentCapabilities().json, headers: ["Cache-Control": "no-store"])

        case ("POST", "sessions", 1):
            let registration = try AgentSessionRegistration(json: try body(request))
            return json(status: 201, try await store.registerAgentSession(principal: principal, registration: registration).json)

        case ("GET", "sessions", 3) where parts[2] == "commands":
            guard let id = ControlID(parts[1]) else { throw ControlError(code: .notFound, message: "no such agent session") }
            let pending = try await store.pendingSessionCommands(principal: principal, sessionID: id)
            return json(status: 200, .object(["commands": .array(pending.map(\.json))]))

        case ("POST", "sessions", 5) where parts[2] == "commands" && parts[4] == "claim":
            guard let id = ControlID(parts[1]), let commandID = ControlID(parts[3]) else {
                throw ControlError(code: .notFound, message: "no such session command")
            }
            let claim = try AgentSessionClaimRequest(json: try body(request))
            guard claim.commandID == commandID else { throw ControlError(code: .invalidPayload, message: "command id mismatch") }
            return json(status: 201, try await store.claimSessionCommand(principal: principal, sessionID: id, request: claim).json)

        case ("GET", "sessions", 2):
            guard let id = ControlID(parts[1]) else { throw ControlError(code: .notFound, message: "no such agent session") }
            if principal.deviceID != nil { try principal.requireGrant(.agentSessionsRead) }
            return json(status: 200, try await store.agentSession(id, principal: principal).json)

        case ("GET", "snapshot", 1):
            try requireAgentRead(principal)
            let page = try await store.agentSnapshot(
                principal: principal,
                pageToken: request.query["page"],
                limit: Int(request.query["limit"] ?? "") ?? AgentSnapshotPage.maximumItems,
                pendingOnly: request.query["pending"] == "1"
            )
            return json(status: 200, page.json)

        case ("GET", "changes", 1):
            try requireAgentRead(principal)
            guard let cursor = request.query["cursor"] else { throw ControlError(code: .invalidPayload, message: "cursor is required") }
            let page = try await store.agentChanges(
                principal: principal,
                cursor: ChangeCursor(cursor),
                limit: Int(request.query["limit"] ?? "") ?? AgentChangePage.maximumEvents
            )
            return json(status: 200, page.json)

        case ("POST", "inputs", 1):
            let spec: InputSpec
            do { spec = try InputSpec(json: try body(request)) } catch let error as ControlError { throw error } catch {
                throw ControlError(code: .unsupportedInputSchema, message: "\(error)")
            }
            return json(status: 201, try await store.createInput(principal: principal, spec: spec).json)

        case ("GET", "inputs", 2):
            guard let id = ControlID(parts[1]) else { throw ControlError(code: .notFound, message: "no such input") }
            try requireAgentRead(principal)
            return json(status: 200, try await store.input(id, principal: principal).json)

        case ("POST", "inputs", 3) where parts[2] == "withdraw":
            guard let id = ControlID(parts[1]) else { throw ControlError(code: .notFound, message: "no such input") }
            var reader = try JSONReader(try body(request))
            let mutationID = try reader.id("mutation_id")
            let runID = try reader.id("run_id")
            let hash = try reader.string("request_hash", maxLength: 80)
            try reader.rejectUnknownMembers()
            return json(status: 200, try await store.withdrawInput(
                principal: principal, requestID: id, mutationID: mutationID, runID: runID, requestHash: hash
            ).json)

        case ("POST", "inputs", 3) where parts[2] == "consume":
            guard let id = ControlID(parts[1]) else { throw ControlError(code: .notFound, message: "no such input") }
            let consume = try InputConsumeRequest(json: try body(request))
            return json(status: 201, try await store.consumeInput(principal: principal, requestID: id, request: consume).json)

        case ("POST", "review-challenges", 1):
            let challenge = try AgentReviewChallengeRequest(json: try body(request))
            return json(status: 201, try await store.createAgentChallenge(principal: principal, request: challenge).json)

        case ("POST", "commands", 1):
            return try await submitAgent(request, principal: principal)

        case ("GET", "commands", 2):
            guard let id = ControlID(parts[1]) else { throw ControlError(code: .notFound, message: "no such command") }
            return json(status: 200, try await store.agentCommandResult(id, principal: principal).json)

        case ("POST", "receipts", 1):
            let receipt = try AgentDeliveryReceipt(json: try body(request))
            try await store.recordAgentReceipt(principal: principal, receipt: receipt)
            return json(status: 201, .object(["ok": true]))

        case ("POST", "events", 1):
            let event = try AgentEvent(json: try body(request))
            try await store.recordAgentEvent(principal: principal, event: event)
            return json(status: 201, .object(["ok": true]))

        default:
            throw ControlError(code: .notFound, message: "no such endpoint")
        }
    }

    /// Proxied agent calls for a Watch bound to this iPhone. The allowlist is
    /// the extension's: capability, snapshot/changes, input fetch, review
    /// challenge, signed submit, and command query — nothing else
    /// (spec.agent-relay.md section 15.5).
    func routeGatewayAgent(_ request: HTTPServer.Request, principal: Principal, watchID: ControlID, rest: [String]) async throws -> HTTPServer.Response {
        switch (request.method, rest.first, rest.count) {
        case ("GET", "capabilities", 1):
            _ = try await store.gatewayPrincipal(principal, watchID: watchID, requiring: nil)
            return json(status: 200, await store.agentCapabilities().json, headers: ["Cache-Control": "no-store"])
        case ("GET", "snapshot", 1):
            let watch = try await store.gatewayPrincipal(principal, watchID: watchID, requiring: .agentInputsReadViaGateway)
            let page = try await store.agentSnapshot(
                principal: watch,
                pageToken: request.query["page"],
                limit: Int(request.query["limit"] ?? "") ?? AgentSnapshotPage.maximumItems,
                pendingOnly: request.query["pending"] == "1"
            )
            return json(status: 200, page.json)
        case ("GET", "changes", 1):
            let watch = try await store.gatewayPrincipal(principal, watchID: watchID, requiring: .agentInputsReadViaGateway)
            guard let cursor = request.query["cursor"] else { throw ControlError(code: .invalidPayload, message: "cursor is required") }
            let page = try await store.agentChanges(
                principal: watch,
                cursor: ChangeCursor(cursor),
                limit: Int(request.query["limit"] ?? "") ?? AgentChangePage.maximumEvents
            )
            return json(status: 200, page.json)
        case ("GET", "inputs", 2):
            let watch = try await store.gatewayPrincipal(principal, watchID: watchID, requiring: .agentInputsReadViaGateway)
            guard let id = ControlID(rest[1]) else { throw ControlError(code: .notFound, message: "no such input") }
            return json(status: 200, try await store.input(id, principal: watch).json)
        case ("POST", "review-challenges", 1):
            let watch = try await store.gatewayPrincipal(principal, watchID: watchID, requiring: nil)
            let challenge = try AgentReviewChallengeRequest(json: try body(request))
            return json(status: 201, try await store.createAgentChallenge(principal: watch, request: challenge).json)
        case ("POST", "commands", 1):
            // The JWS must verify under the Watch's own key: the iPhone cannot
            // re-sign a Watch reply as itself.
            let watch = try await store.gatewayPrincipal(principal, watchID: watchID, requiring: nil)
            return try await submitAgent(request, principal: watch)
        case ("GET", "commands", 2):
            let watch = try await store.gatewayPrincipal(principal, watchID: watchID, requiring: nil)
            guard let id = ControlID(rest[1]) else { throw ControlError(code: .notFound, message: "no such command") }
            return json(status: 200, try await store.agentCommandResult(id, principal: watch).json)
        default:
            throw ControlError(code: .notFound, message: "no such endpoint")
        }
    }

    private func submitAgent(_ request: HTTPServer.Request, principal: Principal) async throws -> HTTPServer.Response {
        guard let key = request.header("Idempotency-Key").flatMap(ControlID.init) else {
            throw ControlError(code: .invalidPayload, message: "Idempotency-Key is required")
        }
        var reader = try JSONReader(try body(request))
        let signed = try reader.string("signed_command", maxLength: 16384)
        // A duplicate unsigned copy of any answer or decision field is refused.
        try reader.rejectUnknownMembers()
        let outcome = try await store.submitAgentCommand(principal: principal, signedCommand: signed, idempotencyKey: key)
        return json(status: outcome.isReplay ? 200 : 201, outcome.result.json)
    }

    private func requireAgentRead(_ principal: Principal) throws {
        if principal.deviceID != nil { try principal.requireGrant(.agentInputsRead) }
    }
}
