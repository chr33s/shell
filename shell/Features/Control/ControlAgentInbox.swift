//
//  ControlAgentInbox.swift
//  shell
//
//  The phone's reconciled view of the optional `shell-agent/1` projection:
//  sessions, typed questions, detailed delivery of agent approvals and
//  managed-session commands, and recent turn outcomes. It is kept apart from the base approval inbox and
//  follows the same snapshot-then-changes pattern with its own cursor
//  namespace (docs/specs/agent-relay.md sections 11.2 and 14.6).
//

import Foundation
import ShellControlProtocol
import ShellControlClient

/// The reads the agent view needs. `ControlAPIClient` answers them over the
/// iPhone's own session; tests substitute a stub.
nonisolated protocol ControlAgentService: Sendable {
    func agentCapabilities() async throws -> AgentCapabilities
    /// `pendingOnly` lists only what can still be answered: active sessions,
    /// pending inputs, and pending agent approvals.
    func agentSnapshot(pageToken: String?, limit: Int, pendingOnly: Bool) async throws -> AgentSnapshotPage
    func agentChanges(after cursor: ChangeCursor, limit: Int) async throws -> AgentChangePage
}

nonisolated extension ControlAPIClient: ControlAgentService {}

/// The agent projection as last reconciled. Nothing here is a decision
/// basis: review always refetches the exact request (docs/specs/agent-relay.md 7.2).
struct ControlAgentInbox: Equatable {
    var sessions: [ControlID: AgentSessionProjection] = [:]
    var inputs: [ControlID: InputRecord] = [:]
    /// Inputs this build cannot parse. Listed so nothing silently vanishes;
    /// never answerable here (docs/specs/agent-relay.md 14.6).
    var unsupportedInputs: Set<ControlID> = []
    /// Session attribution and detailed delivery for agent approvals; the
    /// approvals themselves stay in the base inbox.
    var approvals: [ControlID: AgentApprovalReference] = [:]
    /// Informational turn outcomes, newest first. Agent-attributed text only;
    /// they can never enable an action (docs/specs/agent-relay.md 11.2).
    var turnEvents: [AgentEvent] = []
    /// Managed-session commands (new instructions, steering, cancellation)
    /// by command ID, as the broker records their delivery
    /// (docs/specs/agent-relay.md section 15).
    var sessionCommands: [ControlID: AgentSessionCommandRecord] = [:]
    var cursor: ChangeCursor?
    var lastRefreshedAt: ControlTimestamp?
    /// Set when the full snapshot had more history than one refresh lists
    /// and only pending work was loaded: older outcomes are not shown.
    var omitsOlderOutcomes = false

    static let maximumResolvedInputs = 64
    static let maximumTurnEvents = 20
    static let maximumSessionCommands = 64

    /// One consistent snapshot cut. Every page must carry the same snapshot
    /// token; a mismatch means the cut moved and the caller starts over.
    init(snapshot pages: [AgentSnapshotPage]) throws {
        guard let first = pages.first, let last = pages.last, last.isComplete else {
            throw ValidationError.invalid("agent snapshot", "incomplete")
        }
        guard pages.allSatisfy({ $0.snapshotToken == first.snapshotToken }) else {
            throw ValidationError.invalid("agent snapshot", "pages from different cuts")
        }
        for page in pages {
            for session in page.sessions { sessions[session.registration.agentSessionID] = session }
            for item in page.inputs {
                switch item {
                case .supported(let record): inputs[record.spec.requestID] = record
                case .unsupported(let id?, _): unsupportedInputs.insert(id)
                case .unsupported(nil, _): break
                }
            }
            for reference in page.approvals { approvals[reference.requestID] = reference }
        }
        cursor = last.cursor
        lastRefreshedAt = last.serverTime
        trim()
    }

    init() {}

    var pendingInputs: [InputRecord] {
        inputs.values
            .filter { $0.projection.resolution == .pending }
            .sorted { $0.spec.createdAt < $1.spec.createdAt }
    }

    /// Answered, declined, expired, or withdrawn questions, newest first.
    var resolvedInputs: [InputRecord] {
        inputs.values
            .filter { $0.projection.resolution.isTerminal }
            .sorted { ($0.projection.respondedAt ?? $0.spec.expiresAt) > ($1.projection.respondedAt ?? $1.spec.expiresAt) }
    }

    func session(_ id: ControlID) -> AgentSessionProjection? { sessions[id] }

    /// Applies one page of the agent change feed, in broker sequence order.
    mutating func apply(_ page: AgentChangePage) {
        for event in page.events { apply(event) }
        cursor = page.cursor
        lastRefreshedAt = page.serverTime
        trim()
    }

    mutating func apply(_ event: AgentChangeEvent) {
        switch event.type {
        case .inputCreated, .requestResolved, .deliveryUpdated, .approvalCreated:
            // Input events carry the full record; approval events carry the
            // agent reference. The projection itself says which.
            // Session-command delivery carries the command record. Anything
            // else unreadable is skipped without breaking the page.
            if let record = try? InputRecord(json: event.projection) {
                upsert(record)
            } else if let reference = try? AgentApprovalReference(json: event.projection) {
                if let existing = approvals[reference.requestID], existing.version > reference.version { return }
                approvals[reference.requestID] = reference
            } else if let command = try? AgentSessionCommandRecord(json: event.projection) {
                if let existing = sessionCommands[command.commandID], existing.version > command.version { return }
                sessionCommands[command.commandID] = command
            } else if event.type == .inputCreated {
                unsupportedInputs.insert(event.resourceID)
            }
        case .sessionStarted, .sessionEnded, .statusChanged, .turnStarted, .turnCompleted, .turnFailed:
            if let projection = try? AgentSessionProjection(json: event.projection) {
                adopt(projection)
            } else if let informational = try? AgentEvent(json: event.projection) {
                apply(informational, sessionVersion: event.resourceVersion)
            }
        case .unknown:
            // A newer peer's event type is carried by the feed and ignored.
            break
        }
    }

    private mutating func upsert(_ record: InputRecord) {
        let id = record.spec.requestID
        if let existing = inputs[id], existing.projection.stateVersion > record.projection.stateVersion { return }
        inputs[id] = record
        unsupportedInputs.remove(id)
    }

    /// A session projection replaces an older one only; its version is what
    /// a session command is bound to.
    mutating func adopt(_ projection: AgentSessionProjection) {
        let id = projection.registration.agentSessionID
        if let existing = sessions[id], existing.sessionVersion > projection.sessionVersion { return }
        sessions[id] = projection
    }

    /// Informational events only annotate a session or list an outcome; they
    /// never resolve a request (docs/specs/agent-relay.md 11.1). The broker applies
    /// the same turn transitions and reports the resulting session version,
    /// so this mirror stays comparable; sending still refetches the session.
    private mutating func apply(_ event: AgentEvent, sessionVersion: Int64) {
        switch event.type {
        case .turnCompleted, .turnFailed:
            if !turnEvents.contains(where: { $0.eventID == event.eventID }) { turnEvents.insert(event, at: 0) }
        default:
            break
        }
        guard var session = sessions[event.agentSessionID], sessionVersion > session.sessionVersion else { return }
        let managed = session.registration.profile == .managed
        switch event.type {
        case .sessionEnded:
            session.state = .ended
            session.endedAt = event.observedAt
        case .statusChanged:
            session.status = event.summary
        case .turnStarted:
            guard managed, let turnID = event.providerTurnID else { return }
            session.turnState = .active
            session.activeTurnID = turnID
        case .turnCompleted, .turnFailed:
            guard managed, event.providerTurnID == nil || event.providerTurnID == session.activeTurnID else { break }
            session.turnState = .idle
            session.activeTurnID = nil
        default:
            return
        }
        session.sessionVersion = sessionVersion
        sessions[event.agentSessionID] = session
    }

    /// The reconciler keeps every resolved question otherwise; a long-running
    /// app keeps only the newest.
    private mutating func trim() {
        for record in resolvedInputs.dropFirst(Self.maximumResolvedInputs) {
            inputs.removeValue(forKey: record.spec.requestID)
        }
        if turnEvents.count > Self.maximumTurnEvents {
            turnEvents.removeLast(turnEvents.count - Self.maximumTurnEvents)
        }
        if sessionCommands.count > Self.maximumSessionCommands {
            let oldest = sessionCommands.values.sorted { $0.recordedAt > $1.recordedAt }.dropFirst(Self.maximumSessionCommands)
            for record in oldest { sessionCommands.removeValue(forKey: record.commandID) }
        }
    }
}

/// A request ID from a notification or link names either an approval or a
/// typed question: both reuse the same `approval.created` hint. The approval
/// is tried first; only its `not_found` sends the lookup to the input
/// endpoint (docs/specs/agent-relay.md section 11.3).
enum ControlRequestLookup {
    enum Found: Equatable {
        case approval(ApprovalRecord)
        case input(InputRecord)
    }

    static func resolve(
        approval: () async throws -> ApprovalRecord,
        input: (() async throws -> InputRecord)?
    ) async throws -> Found {
        do {
            return .approval(try await approval())
        } catch let error as ControlError where error.code == .notFound {
            guard let input else { throw error }
            do {
                return .input(try await input())
            } catch let fallback as ControlError where fallback.code == .notFound || fallback.code == .notAuthorized {
                // Neither endpoint knows it, or this iPhone may not read
                // inputs: report the approval's answer, not the fallback's.
                throw error
            }
        }
    }
}
