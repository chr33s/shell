//
//  ControlAgentCenter.swift
//  shell
//
//  The phone's state for the optional agent integration: whether the Mac
//  offers `shell-agent/1` and this iPhone may use it, the reconciled agent
//  projection, and the local state of each typed answer. A Mac without the
//  extension answers `not_found` on discovery; that hides the section rather
//  than reporting an error (spec.agent-relay.md sections 13.1 and 15.1).
//

import Foundation
import Observation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@MainActor
@Observable
final class ControlAgentCenter {
    enum Availability: Equatable {
        /// Not asked yet.
        case unknown
        /// The Mac has no agent extension. Nothing agent-related is shown.
        case unsupported
        /// The Mac has it, but this iPhone was not granted agent reads.
        case notEnabled
        case available(AgentCapabilities)
    }

    private(set) var availability: Availability = .unknown
    private(set) var inbox = ControlAgentInbox()
    /// This iPhone's grants as its session last reported them.
    private(set) var grants: Set<DeviceGrant> = []
    /// Local state of a typed answer this iPhone sent, by request ID.
    private(set) var submissions: [ControlID: AgentSubmissionState] = [:]
    /// Why the last answer to a request was not sent, by request ID.
    private(set) var problems: [ControlID: String] = [:]
    /// The last agent refresh failure, shown in the section; never retried
    /// faster than the poll floor.
    private(set) var problem: String?
    /// Managed-session commands this iPhone signed, by command ID.
    private(set) var sessionCommands: [ControlID: AgentLocalSessionCommand] = [:]
    /// Sessions with a command being signed and sent right now.
    private(set) var sendingSessions: Set<ControlID> = []
    /// Why the last command for a session was not sent, by session ID.
    private(set) var sessionProblems: [ControlID: String] = [:]

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var lastProbe: Date?
    @ObservationIgnored private var isRefreshing = false

    /// Refreshes run no faster than the broker's advertised poll floor.
    static let minimumInterval = ApprovalPolicy.minimumPollInterval
    /// A Mac without the extension, or an iPhone without the grant, is asked
    /// again only this rarely: an older Mac is not an error loop.
    static let reprobeInterval: TimeInterval = 300
    private static let maxChangePagesPerRefresh = 10
    /// Pages one refresh reads of a snapshot cut before it falls back to
    /// pending work only.
    static let maxSnapshotPages = 64

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    /// Answers need their own grant, separately revocable from reads
    /// (spec.agent-relay.md section 17.1).
    var canRespond: Bool { grants.contains(.agentInputsRespond) }

    /// Managed sessions this iPhone may see (spec.agent-relay.md 16).
    var managedSessions: [AgentSessionProjection] {
        AgentSessionControls.visibleSessions(inbox.sessions.values, grants: grants)
    }

    func controls(for session: AgentSessionProjection) -> AgentSessionControls {
        AgentSessionControls(session: session, grants: grants)
    }

    /// This iPhone's commands and the broker's records for one session.
    func commandOutcomes(for sessionID: ControlID) -> [AgentSessionCommandOutcome] {
        AgentSessionCommandOutcome.merge(sessionID: sessionID, local: sessionCommands, records: inbox.sessionCommands)
    }

    /// Discovery, then snapshot-then-changes. `force` skips only the poll
    /// floor and the reprobe delay, for an explicit user refresh.
    func refresh(using service: any ControlAgentService, grants: Set<DeviceGrant>, force: Bool = false) async {
        self.grants = grants
        guard !isRefreshing else { return }
        let date = now()
        if !force, let lastAttempt, date.timeIntervalSince(lastAttempt) < Self.minimumInterval { return }
        switch availability {
        case .unsupported, .notEnabled:
            if !force, let lastProbe, date.timeIntervalSince(lastProbe) < Self.reprobeInterval { return }
        case .unknown, .available:
            break
        }
        isRefreshing = true
        defer { isRefreshing = false }
        lastAttempt = date
        do {
            if !isAvailable {
                lastProbe = date
                // Discovery needs no grant, so an older Mac is told apart
                // from an iPhone that simply was not granted agent reads.
                let capabilities = try await service.agentCapabilities()
                guard capabilities.isCompatible else {
                    availability = .unsupported
                    inbox = ControlAgentInbox()
                    return
                }
                availability = .available(capabilities)
            }
            guard grants.contains(.agentInputsRead) else {
                availability = .notEnabled
                inbox = ControlAgentInbox()
                problem = nil
                return
            }
            inbox = try await Self.reconcile(inbox, using: service)
            problem = nil
        } catch let error as ControlError where error.code == .notFound {
            availability = .unsupported
            inbox = ControlAgentInbox()
            problem = nil
        } catch let error as ControlError where error.code == .notAuthorized {
            availability = .notEnabled
            inbox = ControlAgentInbox()
            problem = nil
        } catch {
            // Connectivity is reported by the base refresh; this stays a
            // quiet note on the agent section.
            problem = String(describing: error)
        }
    }

    /// One full snapshot, then only the agent change log after its cursor.
    /// An expired cursor falls back to a fresh snapshot.
    static func reconcile(_ current: ControlAgentInbox, using service: any ControlAgentService) async throws -> ControlAgentInbox {
        var inbox = current
        if let cursor = inbox.cursor {
            do {
                var next = cursor
                for _ in 0..<maxChangePagesPerRefresh {
                    let page = try await service.agentChanges(after: next, limit: AgentChangePage.maximumEvents)
                    inbox.apply(page)
                    next = page.cursor
                    if page.events.count < AgentChangePage.maximumEvents { break }
                }
                return inbox
            } catch let error as ControlError where error.code == .cursorExpired {
                // A fresh snapshot removes anything no longer visible.
            }
        }
        var fresh: ControlAgentInbox
        if let pages = try await snapshotPages(using: service, pendingOnly: false) {
            fresh = try ControlAgentInbox(snapshot: pages)
        } else if let pages = try await snapshotPages(using: service, pendingOnly: true) {
            // More history than the page cap: what can still be answered
            // loads, and the section says older outcomes are left out
            // rather than failing every refresh.
            fresh = try ControlAgentInbox(snapshot: pages)
            fresh.omitsOlderOutcomes = true
        } else {
            throw ValidationError.invalid("agent snapshot", "more pending requests than one refresh can list")
        }
        // A snapshot lists no command records; keep the bounded ones known.
        fresh.sessionCommands = current.sessionCommands
        return fresh
    }

    /// Every page of one snapshot cut, or nil when the cut does not end
    /// within `maxSnapshotPages`: a partial cut is never adopted.
    private static func snapshotPages(using service: any ControlAgentService, pendingOnly: Bool) async throws -> [AgentSnapshotPage]? {
        var pages = [try await service.agentSnapshot(pageToken: nil, limit: AgentSnapshotPage.maximumItems, pendingOnly: pendingOnly)]
        while let token = pages.last?.nextPageToken {
            guard pages.count < maxSnapshotPages else { return nil }
            pages.append(try await service.agentSnapshot(pageToken: token, limit: AgentSnapshotPage.maximumItems, pendingOnly: pendingOnly))
        }
        return pages
    }

    // MARK: Answers

    func noteSending(_ requestID: ControlID) {
        submissions[requestID] = .sending
        problems[requestID] = nil
    }

    func note(_ state: AgentSubmissionState, for requestID: ControlID) {
        submissions[requestID] = state
    }

    /// Nothing was recorded: the answer is dropped locally too, and the
    /// reason is shown so the user reviews afresh.
    func noteNotSent(_ reason: String, for requestID: ControlID) {
        submissions[requestID] = nil
        problems[requestID] = reason
    }

    /// Adopts a freshly fetched record, so review shows current state.
    func adopt(_ record: InputRecord) {
        guard let existing = inbox.inputs[record.spec.requestID],
              existing.projection.stateVersion > record.projection.stateVersion else {
            inbox.inputs[record.spec.requestID] = record
            return
        }
    }

    /// Adopts a freshly fetched session, so review shows current state.
    func adopt(_ session: AgentSessionProjection) {
        inbox.adopt(session)
    }

    // MARK: Session commands

    func noteSessionSending(_ sessionID: ControlID) {
        sendingSessions.insert(sessionID)
        sessionProblems[sessionID] = nil
    }

    /// A signed command's state, from sending, following, or the journal.
    func noteSessionCommand(_ state: AgentSubmissionState, commandID: ControlID, sessionID: ControlID,
                            action: AgentSessionAction? = nil) {
        sendingSessions.remove(sessionID)
        if var existing = sessionCommands[commandID] {
            existing.state = state
            sessionCommands[commandID] = existing
        } else {
            sessionCommands[commandID] = AgentLocalSessionCommand(
                sessionID: sessionID, action: action, state: state, at: ControlTimestamp(now())
            )
        }
    }

    /// Nothing was sent, or the command was refused before it was recorded.
    func noteSessionNotSent(_ reason: String, sessionID: ControlID) {
        sendingSessions.remove(sessionID)
        sessionProblems[sessionID] = reason
    }

    /// Commands for `sessionID` whose outcome is still being followed.
    func pendingSessionCommands(_ sessionID: ControlID) -> [ControlID] {
        commandOutcomes(for: sessionID).filter { !$0.isSettled }.map(\.commandID)
    }

    /// Signing out or forgetting the Mac drops everything agent-related.
    func reset() {
        availability = .unknown
        inbox = ControlAgentInbox()
        grants = []
        submissions = [:]
        problems = [:]
        sessionCommands = [:]
        sendingSessions = []
        sessionProblems = [:]
        problem = nil
        lastAttempt = nil
        lastProbe = nil
    }
}
