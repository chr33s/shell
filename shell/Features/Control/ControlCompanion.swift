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

extension Notification.Name {
    static let controlPairingReceived = Notification.Name("dev.chr33s.shell.control.pairingReceived")
}

@MainActor
@Observable
final class ControlCompanion {
    static let shared = ControlCompanion()

    enum Phase: Equatable {
        case notConfigured
        case needsEnrollment
        case ready
    }

    private(set) var phase: Phase = .notConfigured
    private(set) var pending: [ApprovalRecord] = []
    private(set) var lastRefreshedAt: ControlTimestamp?
    private(set) var statusMessage: String?
    private(set) var pairingToken: String?

    var isRuntimePaired: Bool {
        defaults.string(forKey: ControlBrokerAddress.runtimeDefaultsKey) != nil
    }

    private let credentials: any DeviceCredentialStore
    private let defaults: UserDefaults
    private let injectedBrokerURL: URL?
    private var client: ControlAPIClient?
    private var coordinator: DecisionCoordinator?
    private var session: DeviceSession?

    /// Baked into the binary. A pairing QR overrides it at runtime.
    static var bakedBrokerURL: URL? {
        ControlBrokerAddress.url(from: Bundle.main.object(forInfoDictionaryKey: "SHELLControlBrokerURL"))
    }


    var resolvedBrokerURL: URL? {
        injectedBrokerURL ?? ControlBrokerAddress.effective(
            runtime: defaults.string(forKey: ControlBrokerAddress.runtimeDefaultsKey),
            baked: ControlCompanion.bakedBrokerURL
        )
    }

    init(
        credentials: any DeviceCredentialStore = KeychainCredentialStore(service: "dev.chr33s.shell.control"),
        defaults: UserDefaults = .standard,
        brokerURL: URL? = nil
    ) {
        self.credentials = credentials
        self.defaults = defaults
        self.injectedBrokerURL = brokerURL
    }

    func start() async {
        guard let brokerURL = resolvedBrokerURL else {
            phase = .notConfigured
            return
        }
        if ControlBrokerAddress.hasChanged(
            from: defaults.string(forKey: ControlBrokerAddress.defaultsKey),
            to: brokerURL,
            hasCredentials: (try? credentials.loadSession()) != nil
        ) {
            try? credentials.removeAll()
            session = nil
            client = nil
            coordinator = nil
            pending = []
            lastRefreshedAt = nil
            statusMessage = nil
        }
        defaults.set(brokerURL.absoluteString, forKey: ControlBrokerAddress.defaultsKey)
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

    /// Accept a QR / paste / `shell-control://pair` broker URL. Private keys
    /// are never copied; a changed host wipes this device's session.
    func applyPairedBroker(_ url: URL) async -> Bool {
        // The same parse the paste field validates with, so the host that was
        // approved is the host that gets adopted: `normalize` first would
        // prefer the link's own host over its `broker=` parameter.
        guard let broker = ControlBrokerAddress.parsePairing(url) else {
            statusMessage = String(localized: "That is not an acceptable broker URL.")
            return false
        }
        pairingToken = ControlBrokerAddress.pairingToken(from: url)
        defaults.set(broker.absoluteString, forKey: ControlBrokerAddress.runtimeDefaultsKey)
        await start()
        ControlPairingSupport.publishBroker(brokerURL: broker, startEnrollment: true)
        return true
    }

    func forgetPairedBroker() async {
        defaults.removeObject(forKey: ControlBrokerAddress.runtimeDefaultsKey)
        pairingToken = nil
        try? credentials.removeAll()
        session = nil
        client = nil
        coordinator = nil
        pending = []
        lastRefreshedAt = nil
        statusMessage = nil
        await start()
        if let brokerURL = resolvedBrokerURL {
            ControlPairingSupport.publishBroker(brokerURL: brokerURL, startEnrollment: false)
        }
    }

    func signOut() {
        try? credentials.removeAll()
        session = nil
        client = nil
        coordinator = nil
        pending = []
        lastRefreshedAt = nil
        statusMessage = nil
        phase = resolvedBrokerURL == nil ? .notConfigured : .needsEnrollment
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
