import Foundation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// A scripted iPhone gateway for the Watch app's tests.
///
/// It speaks `shell-watch-gateway/1` exactly as the phone's router does, and
/// can be made unreachable the way `WCSession.isReachable` goes false.
actor StubGateway: WatchGatewayLink {
    private(set) var requests: [WatchGatewayRequest] = []
    private(set) var submitted: [String] = []

    var reachable = true
    var approvals: [ApprovalRecord] = []
    /// When true, the first `changes.fetch` answers `cursor_expired`.
    var expireNextCursor = false
    /// What the Mac says about this Watch's enrollment.
    var reviewer: WatchReviewerStatus?
    var nextReviewerState: WatchReviewerStatus.State = .pending
    /// When set, the iPhone answers but cannot reach its Mac.
    var macUnavailable = false
    /// When set, the Mac no longer binds this Watch to this iPhone.
    var unbound = false
    /// When set, `sendMessageData` fails the way the WatchConnectivity link
    /// reports the iPhone dropping away mid-call.
    var deliveryFailure = false
    var results: [ControlID: CommandResult] = [:]
    /// `shell-watch-agent-gateway/1`. When false the iPhone is an older build
    /// that answers the extension with an uncorrelated error.
    var agentSupported = true
    /// When set, the Mac refuses agent reads for this Watch.
    var agentNotAuthorized = false
    var agentInputs: [InputRecord] = []
    /// Inputs per agent snapshot page; nil lists them all in one page.
    var agentSnapshotPageSize: Int?
    /// The `pending_only` flag of each agent snapshot request, in order.
    private(set) var agentSnapshotPendingOnly: [Bool] = []
    private(set) var agentRequests: [WatchAgentGatewayRequest] = []
    private(set) var agentSubmitted: [String] = []
    let accountID: ControlID
    var now: ControlTimestamp

    init(accountID: ControlID = .random(), now: ControlTimestamp) {
        self.accountID = accountID
        self.now = now
    }

    func setReachable(_ value: Bool) { reachable = value }
    func setApprovals(_ records: [ApprovalRecord]) { approvals = records }
    func setExpireNextCursor(_ value: Bool) { expireNextCursor = value }
    func setReviewer(_ status: WatchReviewerStatus?) { reviewer = status }
    func setNextReviewerState(_ state: WatchReviewerStatus.State) { nextReviewerState = state }
    func setMacUnavailable(_ value: Bool) { macUnavailable = value }
    func setUnbound(_ value: Bool) { unbound = value }
    func setDeliveryFailure(_ value: Bool) { deliveryFailure = value }
    func setResult(_ result: CommandResult) { results[result.commandID] = result }
    func setAgentSupported(_ value: Bool) { agentSupported = value }
    func setAgentNotAuthorized(_ value: Bool) { agentNotAuthorized = value }
    func setAgentInputs(_ records: [InputRecord]) { agentInputs = records }
    func setAgentSnapshotPageSize(_ size: Int?) { agentSnapshotPageSize = size }
    func agentRequestTypes() -> [WatchAgentGatewayMessageType] { agentRequests.map(\.type) }

    nonisolated func isReachable() async -> Bool { await reachable }

    func send(_ data: Data) async throws -> Data {
        guard reachable else { throw URLError(.notConnectedToInternet) }
        if deliveryFailure { throw WatchGatewayError.iPhoneUnreachable }
        if WatchAgentGatewayRequest.claims(data) { return try answerAgent(data) }
        let request = try WatchGatewayRequest(data: data)
        requests.append(request)
        let result: WatchGatewayResponse.Result
        if macUnavailable {
            result = .gatewayUnavailable("private Mac route unavailable")
        } else {
            do {
                result = .success(try answer(request))
            } catch let error as ControlError {
                result = .failure(error)
            }
        }
        return try WatchGatewayResponse(messageID: request.messageID, serverTime: now, result: result).encoded()
    }

    private func answer(_ request: WatchGatewayRequest) throws -> JSONValue {
        var body = try JSONReader(request.body)
        if unbound, request.type != .enrollmentRequest {
            throw ControlError(code: .reviewerNotBound, message: "no watch reviewer is bound to this iPhone under that id")
        }
        switch request.type {
        case .enrollmentRequest:
            let enrollment = try WatchEnrollmentRequest(json: request.body)
            try enrollment.verifySignature()
            let status = WatchReviewerStatus(
                watchDeviceID: reviewer?.watchDeviceID ?? .random(),
                state: .pending,
                gatewayDeviceID: .random(),
                fingerprint: enrollment.fingerprint,
                label: enrollment.label,
                userCode: "BCDF-GHJK"
            )
            reviewer = status
            return status.json
        case .enrollmentStatus:
            guard let reviewer, reviewer.watchDeviceID == request.watchDeviceID else {
                throw ControlError(code: .notFound, message: "no such watch reviewer")
            }
            let next = WatchReviewerStatus(
                watchDeviceID: reviewer.watchDeviceID,
                state: nextReviewerState,
                gatewayDeviceID: reviewer.gatewayDeviceID,
                fingerprint: reviewer.fingerprint,
                label: reviewer.label,
                userCode: nextReviewerState == .pending ? reviewer.userCode : nil,
                accountID: nextReviewerState == .active ? accountID : nil,
                grants: nextReviewerState == .active ? DeviceGrant.watchReviewerDefault : []
            )
            self.reviewer = next
            return next.json
        case .snapshotFetch:
            return SnapshotPage(
                approvals: approvals, notifications: [], snapshotToken: "s1.1.tag",
                nextPageToken: nil, cursor: ChangeCursor("c1.1.tag"), serverTime: now
            ).json
        case .changesFetch:
            if expireNextCursor {
                expireNextCursor = false
                throw ControlError(code: .cursorExpired, message: "cursor expired")
            }
            return ChangePage(events: [], cursor: ChangeCursor("c1.2.tag"), serverTime: now).json
        case .approvalFetch:
            let id = try body.id("request_id")
            guard let record = approvals.first(where: { $0.spec.requestID == id }) else {
                throw ControlError(code: .notFound, message: "no such request")
            }
            return record.json
        case .reviewChallenge:
            let challenge = try ReviewChallengeRequest(json: try body.value("request"))
            return ReviewChallenge(
                challengeID: "challenge-1", deviceID: try requireWatch(request),
                action: challenge.action, expiresAt: now.adding(ApprovalPolicy.challengeLifetime)
            ).json
        case .commandSubmit:
            let commandID = try body.id("command_id")
            submitted.append(try body.string("signed_command", maxLength: 8192))
            let result = CommandResult(
                recorded: true, commandID: commandID, decisionID: .random(), requestID: approvals.first?.spec.requestID,
                stateVersion: 2, resolution: .approved, dispatch: .awaitingOrigin, serverTime: now
            )
            results[commandID] = result
            return result.json
        case .commandQuery:
            let commandID = try body.id("command_id")
            guard let result = results[commandID] else { throw ControlError(code: .notFound, message: "no such command") }
            return result.json
        }
    }

    /// The agent extension, answered the way the phone's router relays it.
    private func answerAgent(_ data: Data) throws -> Data {
        // An older iPhone cannot parse the extension and answers with
        // nothing the Watch can correlate.
        guard agentSupported else { return Data("{}".utf8) }
        let request = try WatchAgentGatewayRequest(data: data)
        agentRequests.append(request)
        let result: WatchGatewayResponse.Result
        if macUnavailable {
            result = .gatewayUnavailable("private Mac route unavailable")
        } else {
            do {
                result = .success(try agentAnswer(request))
            } catch let error as ControlError {
                result = .failure(error)
            }
        }
        return try WatchGatewayResponse(messageID: request.messageID, serverTime: now, result: result).encoded()
    }

    private func agentAnswer(_ request: WatchAgentGatewayRequest) throws -> JSONValue {
        var body = try JSONReader(request.body)
        if agentNotAuthorized, request.type != .capabilitiesFetch {
            throw ControlError(code: .notAuthorized, message: "missing grant agent.inputs.read-via-gateway")
        }
        switch request.type {
        case .capabilitiesFetch:
            return AgentCapabilities(serverTime: now).json
        case .snapshotFetch:
            // Pending only lists what can still be answered, as the broker does.
            let pendingOnly = try body.optionalBool("pending_only") ?? false
            agentSnapshotPendingOnly.append(pendingOnly)
            let listed = pendingOnly ? agentInputs.filter { $0.projection.resolution == .pending } : agentInputs
            let offset = try body.optionalString("page_token", maxLength: 64).flatMap { Int($0) } ?? 0
            let size = agentSnapshotPageSize ?? max(listed.count, 1)
            return AgentSnapshotPage(
                sessions: [], inputs: listed.dropFirst(offset).prefix(size).map { .supported($0) }, approvals: [],
                snapshotToken: "a1.1.tag", nextPageToken: offset + size < listed.count ? String(offset + size) : nil,
                cursor: ChangeCursor("ac1.1.tag"), serverTime: now
            ).json
        case .changesFetch:
            return AgentChangePage(events: [], cursor: ChangeCursor("ac1.2.tag"), serverTime: now).json
        case .inputFetch:
            let id = try body.id("request_id")
            guard let record = agentInputs.first(where: { $0.spec.requestID == id }) else {
                throw ControlError(code: .notFound, message: "no such input")
            }
            return record.json
        case .reviewChallenge:
            return AgentReviewChallenge(
                challengeID: "agent-challenge-1", deviceID: request.watchDeviceID,
                action: .inputRespond, expiresAt: now.adding(ApprovalPolicy.challengeLifetime)
            ).json
        case .commandSubmit:
            let commandID = try body.id("command_id")
            agentSubmitted.append(try body.string("signed_command", maxLength: 16384))
            return AgentCommandResult(
                recorded: true, commandID: commandID, requestID: agentInputs.first?.spec.requestID,
                resolution: .answered, dispatch: .awaitingOrigin, serverTime: now
            ).json
        case .commandQuery:
            throw ControlError(code: .notFound, message: "no such command")
        }
    }

    private func requireWatch(_ request: WatchGatewayRequest) throws -> ControlID {
        guard let id = request.watchDeviceID else { throw ControlError(code: .notAuthorized, message: "unbound") }
        return id
    }

    func requestTypes() -> [WatchGatewayMessageType] { requests.map(\.type) }
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

    static func activeReviewer(
        accountID: ControlID,
        key: InMemoryDeviceKey,
        grants: Set<DeviceGrant> = DeviceGrant.watchReviewerDefault
    ) -> WatchReviewerStatus {
        WatchReviewerStatus(
            watchDeviceID: .random(),
            state: .active,
            gatewayDeviceID: .random(),
            fingerprint: (try? key.publicJWK.displayFingerprint()) ?? "",
            label: "Apple Watch",
            accountID: accountID,
            grants: grants
        )
    }

    /// A typed question. The defaults fit the Watch policy: one single-choice
    /// question with two choices, Watch review, and a waiting agent.
    static func makeInput(
        createdAt: ControlTimestamp,
        questions: [InputQuestion]? = nil,
        minimumReview: MinimumReview = .watch,
        allowedResponses: [InputAllowedResponse] = [.answer, .decline],
        presentAt: ControlTimestamp? = nil
    ) throws -> InputRecord {
        let hex = String(repeating: "c", count: 64)
        let spec = try InputSpec(
            requestID: .random(), originID: .random(), jobID: .random(), runID: .random(),
            createdAt: createdAt, expiresAt: createdAt.adding(AgentPolicy.defaultLifetime),
            summary: "Choose the test scope",
            source: try InputSource(
                provider: "codex", providerBuild: "tested", adapterBuild: "adapter",
                nativeRequestSHA256: hex, contextSHA256: hex, answerMappingSHA256: hex,
                agentSessionID: .random(), nativeWaitID: .random()
            ),
            questions: try questions ?? [InputQuestion(
                id: "test_scope", prompt: "Which tests should run next?",
                kind: .singleChoice(choices: [
                    try InputChoice(id: "focused", label: "Changed modules only"),
                    try InputChoice(id: "all", label: "Entire test suite")
                ]),
                required: true
            )],
            allowedResponses: allowedResponses,
            minimumReview: minimumReview
        )
        return try InputRecord(spec: spec, projection: InputProjection(
            presence: SourcePresence(lastSeenAt: presentAt, isWaiting: presentAt != nil)
        ))
    }
}
