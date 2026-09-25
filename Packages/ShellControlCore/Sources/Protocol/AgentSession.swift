import Foundation

/// How an adapter reaches the provider (docs/specs/agent-relay.md section 3.1).
public enum AgentIntegrationProfile: String, Sendable, Hashable, CaseIterable {
    /// The ordinary provider CLI with a synchronous native hook. Its safety
    /// claim is limited to responses delivered through that hook.
    case hook
    /// The adapter owns the provider connection. Experimental, opt-in.
    case managed
    /// Attention and status only; never an approve or reply control.
    case informational
}

/// How strong the compatibility evidence for a provider build is. Setup never
/// reports "Ready" from `documented` alone (docs/specs/agent-relay.md 3.3).
public enum AgentCompatibilityEvidence: String, Sendable, Hashable, CaseIterable, Comparable {
    case none
    case documented
    /// The user explicitly allowed an untested local build; shown as such.
    case userAttested = "user_attested"
    case contractTested = "contract_tested"
    case deviceValidated = "device_validated"

    private var rank: Int {
        switch self {
        case .none: return 0
        case .documented: return 1
        case .userAttested: return 2
        case .contractTested: return 3
        case .deviceValidated: return 4
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// Whether a native gate may be answered remotely at all.
    public var permitsRemoteResponse: Bool { self >= .userAttested }
}

/// Non-authorizing navigation metadata: where the agent's terminal was last
/// seen. It is never a substitute for native wait identity and never a
/// remote command endpoint (docs/specs/agent-relay.md section 13.1).
public struct TerminalLocation: Sendable, Hashable {
    /// A digest identifying the tmux server instance (socket and server
    /// process), never the socket path itself.
    public let serverInstance: String
    public let sessionID: String
    public let windowID: String
    public let paneID: String
    public let observedAt: ControlTimestamp

    public init(serverInstance: String, sessionID: String, windowID: String, paneID: String, observedAt: ControlTimestamp) throws {
        guard ASCIIHex.isSHA256(serverInstance) else {
            throw ValidationError.invalid("terminal_location.server_instance", "must be 64 lowercase hex characters")
        }
        for (field, text, sigil) in [("session_id", sessionID, "$"), ("window_id", windowID, "@"), ("pane_id", paneID, "%")] {
            guard text.hasPrefix(sigil), text.count >= 2, text.count <= 16,
                  text.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else {
                throw ValidationError.invalid("terminal_location.\(field)", "must be \(sigil)<digits>")
            }
        }
        self.serverInstance = serverInstance
        self.sessionID = sessionID
        self.windowID = windowID
        self.paneID = paneID
        self.observedAt = observedAt
    }

    public var json: JSONValue {
        .object([
            "server_instance": .string(serverInstance),
            "session_id": .string(sessionID),
            "window_id": .string(windowID),
            "pane_id": .string(paneID),
            "observed_at": JSONValue(observedAt)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let server = try reader.string("server_instance", maxLength: 64)
        let session = try reader.string("session_id", maxLength: 16)
        let window = try reader.string("window_id", maxLength: 16)
        let pane = try reader.string("pane_id", maxLength: 16)
        let observed = try reader.timestamp("observed_at")
        try reader.rejectUnknownMembers()
        try self.init(serverInstance: server, sessionID: session, windowID: window, paneID: pane, observedAt: observed)
    }
}

/// `POST /v1/agent/sessions`: idempotent registration of one provider
/// session instance, bound to a registered run (docs/specs/agent-relay.md 4.2).
///
/// The run capability and the owned process identity stay on the host; only
/// what a reviewer needs is published.
public struct AgentSessionRegistration: Sendable, Hashable {
    public let agentSessionID: ControlID
    public let runID: ControlID
    public let provider: String
    public let providerBuild: String
    public let adapterBuild: String
    public let profile: AgentIntegrationProfile
    public let evidence: AgentCompatibilityEvidence
    /// Operation kinds and input features this session may publish.
    public let operations: [String]
    public let providerSessionID: String?
    public let policyFingerprint: String?
    public let terminalLocation: TerminalLocation?
    public let startedAt: ControlTimestamp

    public init(
        agentSessionID: ControlID,
        runID: ControlID,
        provider: String,
        providerBuild: String,
        adapterBuild: String,
        profile: AgentIntegrationProfile,
        evidence: AgentCompatibilityEvidence,
        operations: [String],
        providerSessionID: String? = nil,
        policyFingerprint: String? = nil,
        terminalLocation: TerminalLocation? = nil,
        startedAt: ControlTimestamp
    ) throws {
        try AgentIdentifier.require(provider, field: "provider")
        for (field, text) in [("provider_build", providerBuild), ("adapter_build", adapterBuild)] {
            guard !text.isEmpty, text.utf8Count <= 64 else { throw ValidationError.invalid(field, "must be 1...64 bytes") }
        }
        guard operations.count <= 16, Set(operations).count == operations.count,
              operations.allSatisfy({ !$0.isEmpty && $0.utf8Count <= 64 }) else {
            throw ValidationError.invalid("operations", "must list at most 16 distinct features")
        }
        if let policyFingerprint, !ASCIIHex.isSHA256(policyFingerprint) {
            throw ValidationError.invalid("policy_fingerprint", "must be 64 lowercase hex characters")
        }
        // Session commands exist only for a managed session.
        if profile != .managed, operations.contains(AgentFeature.messages) || operations.contains(AgentFeature.turnCancel) {
            throw ValidationError.invalid("operations", "messages and cancellation need a managed session")
        }
        // An informational session never offers an answerable operation.
        if profile == .informational, !operations.isEmpty {
            throw ValidationError.invalid("operations", "an informational session publishes no operations")
        }
        if !evidence.permitsRemoteResponse, !operations.isEmpty {
            throw ValidationError.invalid("operations", "\(evidence.rawValue) evidence permits no remote response")
        }
        self.agentSessionID = agentSessionID
        self.runID = runID
        self.provider = provider
        self.providerBuild = providerBuild
        self.adapterBuild = adapterBuild
        self.profile = profile
        self.evidence = evidence
        self.operations = operations
        self.providerSessionID = providerSessionID
        self.policyFingerprint = policyFingerprint
        self.terminalLocation = terminalLocation
        self.startedAt = startedAt
    }

    public var json: JSONValue {
        JSONWriter.object([
            "agent_session_id": JSONValue(agentSessionID),
            "run_id": JSONValue(runID),
            "provider": .string(provider),
            "provider_build": .string(providerBuild),
            "adapter_build": .string(adapterBuild),
            "profile": .string(profile.rawValue),
            "evidence": .string(evidence.rawValue),
            "operations": JSONValue(strings: operations),
            "provider_session_id": providerSessionID.map { .string($0) },
            "policy_fingerprint": policyFingerprint.map { .string($0) },
            "terminal_location": terminalLocation?.json,
            "started_at": JSONValue(startedAt)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        let sessionID = try reader.id("agent_session_id")
        let runID = try reader.id("run_id")
        let provider = try reader.string("provider", maxLength: 64)
        let providerBuild = try reader.string("provider_build", maxLength: 64)
        let adapterBuild = try reader.string("adapter_build", maxLength: 64)
        let profileText = try reader.string("profile", maxLength: 32)
        guard let profile = AgentIntegrationProfile(rawValue: profileText) else { throw ValidationError.unsupported("profile \(profileText)") }
        let evidenceText = try reader.string("evidence", maxLength: 32)
        guard let evidence = AgentCompatibilityEvidence(rawValue: evidenceText) else { throw ValidationError.unsupported("evidence \(evidenceText)") }
        let operations = try reader.stringArray("operations", maxCount: 16, maxLength: 64)
        let providerSessionID = try reader.optionalString("provider_session_id", maxLength: 256)
        let fingerprint = try reader.optionalString("policy_fingerprint", maxLength: 64)
        let location = try reader.optionalValue("terminal_location").map(TerminalLocation.init(json:))
        let startedAt = try reader.timestamp("started_at")
        try reader.rejectUnknownMembers()
        try self.init(
            agentSessionID: sessionID, runID: runID, provider: provider, providerBuild: providerBuild,
            adapterBuild: adapterBuild, profile: profile, evidence: evidence, operations: operations,
            providerSessionID: providerSessionID, policyFingerprint: fingerprint,
            terminalLocation: location, startedAt: startedAt
        )
    }
}

public enum AgentSessionState: String, Sendable, Hashable {
    case active
    case ended
}

/// A registered session as a device sees it: identity, current state, and
/// non-authorizing location. Trusted host identity is separate from anything
/// the agent supplied.
public struct AgentSessionProjection: Sendable, Hashable {
    public let registration: AgentSessionRegistration
    public var state: AgentSessionState
    public var sessionVersion: Int64
    public var lastSeenAt: ControlTimestamp?
    public var endedAt: ControlTimestamp?
    public var status: String?
    /// Managed sessions only: whether a turn is running, and which.
    public var turnState: AgentTurnState?
    public var activeTurnID: String?

    public init(
        registration: AgentSessionRegistration,
        state: AgentSessionState = .active,
        sessionVersion: Int64 = 1,
        lastSeenAt: ControlTimestamp? = nil,
        endedAt: ControlTimestamp? = nil,
        status: String? = nil,
        turnState: AgentTurnState? = nil,
        activeTurnID: String? = nil
    ) {
        self.turnState = turnState
        self.activeTurnID = activeTurnID
        self.registration = registration
        self.state = state
        self.sessionVersion = sessionVersion
        self.lastSeenAt = lastSeenAt
        self.endedAt = endedAt
        self.status = status
    }

    public var json: JSONValue {
        JSONWriter.object([
            "registration": registration.json,
            "state": .string(state.rawValue),
            "session_version": .number(.int(sessionVersion)),
            "last_seen_at": lastSeenAt.map { JSONValue($0) },
            "ended_at": endedAt.map { JSONValue($0) },
            "status": status.map { .string($0) },
            "turn_state": turnState.map { .string($0.rawValue) },
            "active_turn_id": activeTurnID.map { .string($0) }
        ])
    }

    /// Whether this session accepts `feature` (`agent.messages.v1`,
    /// `agent.turn.cancel.v1`) at all.
    public func offers(_ feature: String) -> Bool {
        state == .active && registration.profile == .managed && registration.operations.contains(feature)
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        registration = try AgentSessionRegistration(json: try reader.value("registration"))
        turnState = try reader.optionalString("turn_state", maxLength: 16).map { text in
            guard let state = AgentTurnState(rawValue: text) else { throw ValidationError.unsupported("turn state \(text)") }
            return state
        }
        activeTurnID = try reader.optionalString("active_turn_id", maxLength: 256)
        let stateText = try reader.string("state", maxLength: 16)
        guard let state = AgentSessionState(rawValue: stateText) else { throw ValidationError.unsupported("session state \(stateText)") }
        self.state = state
        sessionVersion = try reader.integer("session_version")
        lastSeenAt = try reader.optionalTimestamp("last_seen_at")
        endedAt = try reader.optionalTimestamp("ended_at")
        status = try reader.optionalString("status", maxLength: AgentPolicy.maximumSummaryScalars)
        try reader.rejectUnknownMembers()
    }
}

/// `GET /v1/agent/capabilities`. Discovery is not authorization.
public struct AgentCapabilities: Sendable, Hashable {
    public let protocolName: String
    public let features: [String]
    public let commandTypes: [String]
    public let supportedKinds: [String]
    public let enabledProfiles: [String]
    public let limits: JSONValue
    public let serverTime: ControlTimestamp

    public init(
        features: [String] = AgentFeature.supported.sorted(),
        commandTypes: [String] = AgentCommandType.allCases.filter(\.isSupported).map(\.rawValue),
        supportedKinds: [String] = ["file_change", "shell"],
        enabledProfiles: [String] = AgentIntegrationProfile.allCases.map(\.rawValue),
        limits: JSONValue = AgentCapabilities.defaultLimits,
        serverTime: ControlTimestamp
    ) {
        self.protocolName = AgentProtocol.name
        self.features = features
        self.commandTypes = commandTypes
        self.supportedKinds = supportedKinds
        self.enabledProfiles = enabledProfiles
        self.limits = limits
        self.serverTime = serverTime
    }

    public static var defaultLimits: JSONValue {
        func number(_ value: Int) -> JSONValue { .number(.int(Int64(value))) }
        return .object([
            "default_lifetime_seconds": number(Int(AgentPolicy.defaultLifetime)),
            "max_lifetime_seconds": number(Int(AgentPolicy.maximumLifetime)),
            "challenge_ttl_seconds": number(Int(ApprovalPolicy.challengeLifetime)),
            "permit_ttl_seconds": number(Int(ApprovalPolicy.permitLifetime)),
            "max_operation_bytes": number(AgentPolicy.maximumOperationBytes),
            "max_input_spec_bytes": number(AgentPolicy.maximumInputSpecBytes),
            "max_answer_bytes": number(AgentPolicy.maximumAnswerBytes),
            "max_questions": number(AgentPolicy.maximumQuestions),
            "max_choices": number(AgentPolicy.maximumChoices),
            "watch_max_questions": number(AgentPolicy.watchMaximumQuestions),
            "watch_max_choices": number(AgentPolicy.watchMaximumChoices),
            "watch_max_text_bytes": number(AgentPolicy.watchMaximumTextBytes),
            "max_pending_per_run": number(AgentPolicy.maximumPendingPerRun),
            "max_pending_per_origin": number(AgentPolicy.maximumPendingPerOrigin),
            "min_poll_interval_seconds": number(Int(ApprovalPolicy.minimumPollInterval))
        ])
    }

    public var json: JSONValue {
        .object([
            "protocol": .string(protocolName),
            "features": JSONValue(strings: features),
            "command_types": JSONValue(strings: commandTypes),
            "supported_kinds": JSONValue(strings: supportedKinds),
            "enabled_profiles": JSONValue(strings: enabledProfiles),
            "limits": limits,
            "server_time": JSONValue(serverTime)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        protocolName = try reader.string("protocol", maxLength: 32)
        features = try reader.stringArray("features", maxCount: 32, maxLength: 64)
        commandTypes = try reader.stringArray("command_types", maxCount: 16, maxLength: 48)
        supportedKinds = try reader.stringArray("supported_kinds", maxCount: 16, maxLength: 32)
        enabledProfiles = try reader.stringArray("enabled_profiles", maxCount: 8, maxLength: 32)
        limits = try reader.value("limits")
        serverTime = try reader.timestamp("server_time")
        try reader.rejectUnknownMembers()
    }

    public var isCompatible: Bool { protocolName == AgentProtocol.name }
}
