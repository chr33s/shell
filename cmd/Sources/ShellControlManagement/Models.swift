import Foundation

public enum AddressMode: String, Codable, CaseIterable, Sendable { case quick, named, externalProxy = "external-proxy", loopback }
public enum DesiredState: String, Codable, Sendable { case running, stopped }
public enum Component: String, Codable, CaseIterable, Sendable { case broker, daemon, tunnel }

public struct TunnelConfiguration: Codable, Equatable, Sendable {
    public var id: UUID?
    public var credentialsPath: String?
    public var cloudflaredPath: String?
    public init(id: UUID? = nil, credentialsPath: String? = nil, cloudflaredPath: String? = nil) {
        self.id = id; self.credentialsPath = credentialsPath; self.cloudflaredPath = cloudflaredPath
    }
}

public struct PushConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var keyID: String?
    public var teamID: String?
    public var keyPath: String?
    public var topics: [String]
    public init(enabled: Bool = false, keyID: String? = nil, teamID: String? = nil,
                keyPath: String? = nil, topics: [String] = []) {
        self.enabled = enabled; self.keyID = keyID; self.teamID = teamID; self.keyPath = keyPath; self.topics = topics
    }
}

public struct Installation: Codable, Equatable, Sendable {
    public var format: String
    public var installationID: UUID
    public var desiredState: DesiredState
    public var persistent: Bool
    public var port: Int
    public var addressMode: AddressMode
    public var publicURL: String?
    public var releaseID: String
    public var tunnel: TunnelConfiguration
    public var push: PushConfiguration

    enum CodingKeys: String, CodingKey {
        case format, installationID = "installation_id", desiredState = "desired_state", persistent, port
        case addressMode = "address_mode", publicURL = "public_url", releaseID = "release_id", tunnel, push
    }

    public init(installationID: UUID = UUID(), desiredState: DesiredState = .running,
                persistent: Bool = false, port: Int = 8443, addressMode: AddressMode = .quick,
                publicURL: String? = nil, releaseID: String, tunnel: TunnelConfiguration = .init(),
                push: PushConfiguration = .init()) {
        format = "shell-control.native/1"; self.installationID = installationID
        self.desiredState = desiredState; self.persistent = persistent; self.port = port
        self.addressMode = addressMode; self.publicURL = publicURL; self.releaseID = releaseID
        self.tunnel = tunnel; self.push = push
    }
}

public struct InstallationSecrets: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var adminSecret: String
    public var cursorSecret: String
    public var pairingToken: String
    public var originID: UUID?
    public var originSecret: String?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id", adminSecret = "admin_secret", cursorSecret = "cursor_secret"
        case pairingToken = "pairing_token", originID = "origin_id", originSecret = "origin_secret"
    }
}

public struct ManagementOperation: Codable, Equatable, Sendable {
    public var id: UUID
    public var command: String
    public var plan: [String]
    public var pendingStep: String?
    public var createdResources: [Component]
    public init(command: String, plan: [String]) {
        id = UUID(); self.command = command; self.plan = plan; pendingStep = plan.first; createdResources = []
    }
}

public struct RuntimeState: Codable, Equatable, Sendable {
    public var generation: Int
    public var operation: ManagementOperation?
    public init(generation: Int = 0, operation: ManagementOperation? = nil) {
        self.generation = generation; self.operation = operation
    }
}

public struct InstallationPaths: Sendable {
    public let root: URL
    public var installation: URL { root.appendingPathComponent("installation.json") }
    public var secrets: URL { root.appendingPathComponent("secrets.json") }
    public var runtime: URL { root.appendingPathComponent("runtime.json") }
    public var lock: URL { root.appendingPathComponent("install.lock") }
    public var credentials: URL { root.appendingPathComponent("credentials") }
    public var services: URL { root.appendingPathComponent("services") }
    public var launchd: URL { root.appendingPathComponent("launchd") }
    public var logs: URL { root.appendingPathComponent("logs") }
    public var brokerLedger: URL { root.appendingPathComponent("broker.json") }
    public var journal: URL { root.appendingPathComponent("dispatch-journal.ndjson") }
    public var controlSocket: URL { root.appendingPathComponent("control.sock") }
    public var healthSocket: URL { root.appendingPathComponent("health.sock") }
    public init(root: URL) { self.root = root }
}

public struct LoadedInstallation: Sendable {
    public var installation: Installation
    public var secrets: InstallationSecrets
    public var runtime: RuntimeState
    public let paths: InstallationPaths
}

public enum ManagementError: Error, CustomStringConvertible, Sendable {
    case invalid(String), unavailable(String), corrupt(String), unsupported(String)
    public var description: String {
        switch self {
        case .invalid(let text), .unavailable(let text), .corrupt(let text), .unsupported(let text): text
        }
    }
    public var exitCode: Int32 {
        switch self { case .invalid, .unsupported: 2; case .unavailable, .corrupt: 1 }
    }
}
