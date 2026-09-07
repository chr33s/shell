//
//  ControlCompanion.swift
//  shell
//
//  The phone's optional half of the control companion: setup assistance, the
//  larger review surface, and a handoff hint. The Watch never depends on any
//  of it (spec.watch.md sections 1 and 13).
//

import Foundation
import Observation
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

@MainActor
@Observable
final class ControlCompanion {
    enum Phase: Equatable {
        case notConfigured
        case needsEnrollment
        case ready
    }

    private(set) var phase: Phase = .notConfigured
    private(set) var pending: [ApprovalRecord] = []
    private(set) var lastRefreshedAt: ControlTimestamp?
    private(set) var statusMessage: String?

    private let credentials: any DeviceCredentialStore
    private var client: ControlAPIClient?
    private var coordinator: DecisionCoordinator?
    private var session: DeviceSession?

    /// The broker address is a deployment choice; without one the companion
    /// stays inert and the terminal app behaves exactly as before.
    static var brokerURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "SHELLControlBrokerURL") as? String else { return nil }
        return URL(string: text)
    }

    init(credentials: any DeviceCredentialStore = KeychainCredentialStore(service: "dev.chr33s.shell.control")) {
        self.credentials = credentials
    }

    func start() async {
        guard let brokerURL = ControlCompanion.brokerURL else {
            phase = .notConfigured
            return
        }
        guard let session = try? credentials.loadSession(), let key = try? credentials.loadSigningKey() else {
            phase = .needsEnrollment
            return
        }
        self.session = session
        let client = ControlAPIClient(baseURL: brokerURL, credential: .device(session.accessToken))
        self.client = client
        let journal = try? CommandJournal()
        if let journal {
            coordinator = DecisionCoordinator(client: client, journal: journal, key: key, session: session)
        }
        phase = .ready
        await refresh()
    }

    func refresh() async {
        guard let client else { return }
        do {
            let page = try await client.snapshot()
            pending = page.approvals.filter { $0.projection.resolution == .pending }
            lastRefreshedAt = page.serverTime
            statusMessage = nil
        } catch {
            statusMessage = String(describing: error)
        }
    }

    /// Always re-fetches: the phone is a fuller review surface, not a cache the
    /// user decides from.
    func fetch(_ requestID: ControlID) async throws -> ApprovalRecord {
        guard let client else { throw TransportError.offline }
        return try await client.approval(requestID)
    }

    func decide(_ decision: ControlDecision, on record: ApprovalRecord) async {
        guard let coordinator else { return }
        do {
            let state = try await coordinator.decide(decision, reviewed: record)
            statusMessage = ControlCompanion.describe(state)
        } catch {
            statusMessage = String(describing: error)
        }
        await refresh()
    }

    static func describe(_ state: SubmissionState) -> String {
        switch state {
        case .sending: return String(localized: "Sending")
        case .decisionRecorded: return String(localized: "Decision recorded")
        case .waitingForHost: return String(localized: "Waiting for host")
        case .hostAccepted: return String(localized: "Host accepted")
        case .notApplied: return String(localized: "Not applied")
        case .outcomeUnknown: return String(localized: "Outcome unknown")
        }
    }

    /// A handoff hint carries identity and expiry only. It cannot force a
    /// device to open, cannot authorize work, and no execution adapter accepts
    /// it (spec.watch.md section 13).
    func handoffHint(for record: ApprovalRecord) -> JSONValue {
        .object([
            "v": 1,
            "type": .string(ControlCommandType.handoffRequest.rawValue),
            "request_id": JSONValue(record.spec.requestID),
            "job_id": JSONValue(record.spec.jobID),
            "expires_at": JSONValue(record.spec.expiresAt),
        ])
    }
}
