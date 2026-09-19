import Foundation

/// How the iPhone reaches the broker. `tailscale` is the iPhone-gateway
/// profile: the broker stays on loopback and Tailscale Serve publishes it
/// inside the tailnet only (spec.iphone-gateway.md). `loopback` is local
/// development with the simulator.
public enum AddressMode: String, Codable, CaseIterable, Sendable {
    case tailscale, loopback

    /// Installations written by releases that also offered Cloudflare tunnel
    /// modes migrate to `tailscale`; setup then removes the old tunnel job.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AddressMode(rawValue: raw) ?? .tailscale
    }
}
public enum DesiredState: String, Codable, Sendable { case running, stopped }
public enum Component: String, Codable, CaseIterable, Sendable { case broker, daemon }

public struct PushConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var keyID: String?
    public var teamID: String?
    public var keyPath: String?
    public var topics: [String]
    /// The stateless Shell Push Relay. With it, the broker sends event hints
    /// and holds no APNs credentials (spec.iphone-gateway.md section 16).
    public var relayURL: String?
    public init(enabled: Bool = false, keyID: String? = nil, teamID: String? = nil,
                keyPath: String? = nil, topics: [String] = [], relayURL: String? = nil) {
        self.enabled = enabled; self.keyID = keyID; self.teamID = teamID; self.keyPath = keyPath; self.topics = topics
        self.relayURL = relayURL
    }
    public var usesDirectAPNs: Bool { enabled && keyID != nil && teamID != nil && keyPath != nil }
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
    public var push: PushConfiguration
    /// The Tailscale CLI used for Serve configuration in `tailscale` mode.
    public var tailscalePath: String?

    enum CodingKeys: String, CodingKey {
        case format, installationID = "installation_id", desiredState = "desired_state", persistent, port
        case addressMode = "address_mode", publicURL = "public_url", releaseID = "release_id", push
        case tailscalePath = "tailscale_path"
    }

    public init(installationID: UUID = UUID(), desiredState: DesiredState = .running,
                persistent: Bool = false, port: Int = 8443, addressMode: AddressMode = .tailscale,
                publicURL: String? = nil, releaseID: String, push: PushConfiguration = .init()) {
        format = "shell-control.native/1"; self.installationID = installationID
        self.desiredState = desiredState; self.persistent = persistent; self.port = port
        self.addressMode = addressMode; self.publicURL = publicURL; self.releaseID = releaseID
        self.push = push
    }
}

public struct InstallationSecrets: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var adminSecret: String
    public var cursorSecret: String
    public var originID: UUID?
    public var originSecret: String?
    /// Whether the broker has acknowledged `originID`. Absent on older
    /// installations, where an origin ID implies it was provisioned.
    public var originProvisioned: Bool?
    /// The origin signing key's fingerprint as first created. A missing key
    /// with a recorded fingerprint is never silently regenerated: replacing
    /// the origin key is a new trust relationship (spec.iphone-gateway.md 23).
    public var originKeyFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id", adminSecret = "admin_secret", cursorSecret = "cursor_secret"
        case originID = "origin_id", originSecret = "origin_secret"
        case originProvisioned = "origin_provisioned", originKeyFingerprint = "origin_key_fingerprint"
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
    public var originKey: URL { credentials.appendingPathComponent("origin-signing-key.pem") }
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
        switch self {
        case .invalid, .unsupported: 2
        case .unavailable, .corrupt: 1
        }
    }
}
