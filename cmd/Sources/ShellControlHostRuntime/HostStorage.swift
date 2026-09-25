import Foundation
import ShellControlHostSupport

/// Where the bundled host keeps its state (spec.agent-relay.md section 19.5).
///
/// The authoritative ledger, journal, and secrets live in the host's private,
/// sandbox-protected container; the App Group container holds only the
/// deliberately shared adapter ingress socket. Both are resolved through
/// platform APIs by ``resolve(fileManager:)``; nothing here hard-codes a home
/// path, and tests inject temporary directories.
public struct HostStorageLayout: Sendable, Equatable {
    /// Private, 0700: ledger, journal, lock, identity, configuration.
    public let privateDirectory: URL
    /// The adapter ingress socket. In the sandboxed profile it is placed in
    /// the App Group container — a candidate mechanism that the distribution
    /// spike must validate (spec 19.6).
    public let adapterSocketPath: String

    public init(privateDirectory: URL, adapterSocketPath: String) {
        self.privateDirectory = privateDirectory.standardizedFileURL
        self.adapterSocketPath = adapterSocketPath
    }

    /// A layout rooted entirely in one directory, for tests and for running
    /// the host binary outside launchd during development.
    public init(developmentRoot: URL) {
        let root = developmentRoot.standardizedFileURL
        self.init(privateDirectory: root.appendingPathComponent("private"),
                  adapterSocketPath: root.appendingPathComponent("group").appendingPathComponent(ControlHostWire.adapterSocketName).path)
    }

    public enum ResolutionError: Error, CustomStringConvertible, Sendable {
        case noApplicationSupport
        case noAppGroupContainer(String)

        public var description: String {
            switch self {
            case .noApplicationSupport:
                "the host's Application Support directory is unavailable"
            case .noAppGroupContainer(let group):
                "the App Group container \(group) is unavailable; the host is not provisioned for it"
            }
        }
    }

    /// The production layout. Inside the App Sandbox, Application Support
    /// resolves to the host's own container; the group container is available
    /// only when the host is provisioned for `group.dev.chr33s.shell.control`.
    public static func resolve(fileManager: FileManager = .default) throws -> HostStorageLayout {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ResolutionError.noApplicationSupport
        }
        guard let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: ControlHostWire.appGroupIdentifier) else {
            throw ResolutionError.noAppGroupContainer(ControlHostWire.appGroupIdentifier)
        }
        return HostStorageLayout(
            privateDirectory: support.appendingPathComponent("ShellControlHost", isDirectory: true),
            adapterSocketPath: group.appendingPathComponent(ControlHostWire.adapterSocketName).path
        )
    }

    public var lockPath: String { privateDirectory.appendingPathComponent("host.lock").path }
    public var ledgerURL: URL { privateDirectory.appendingPathComponent("broker.json") }
    public var journalURL: URL { privateDirectory.appendingPathComponent("dispatch-journal.ndjson") }
    public var identityURL: URL { privateDirectory.appendingPathComponent("host-identity.json") }
    public var originKeyURL: URL { privateDirectory.appendingPathComponent("origin-key.pem") }
    public var settingsURL: URL { privateDirectory.appendingPathComponent("host-settings.json") }
    /// Recorded by the daemon configuration only; the host reports health
    /// over XPC instead of a second socket.
    public var healthSocketPath: String { privateDirectory.appendingPathComponent("health.sock").path }

    /// Creates the private directory 0700 and the socket's directory.
    public func prepare() throws {
        try SecureFileSystem.ensureDirectory(privateDirectory)
        let socketDirectory = URL(fileURLWithPath: adapterSocketPath).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: socketDirectory.path) {
            try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }
}

/// User-visible host settings that survive restarts. Stopped intent is kept
/// here as well as in the UI, so a launchd restart before unregistration
/// completes still accepts no new work (spec 19.4).
public struct HostSettings: Codable, Sendable, Equatable {
    public var acceptingWork: Bool
    public var brokerPort: UInt16
    /// The MagicDNS HTTPS route the user configured in Tailscale Serve.
    public var routeURL: String?

    public init(acceptingWork: Bool = true, brokerPort: UInt16 = ControlHostWire.defaultBrokerPort, routeURL: String? = nil) {
        self.acceptingWork = acceptingWork
        self.brokerPort = brokerPort
        self.routeURL = routeURL
    }

    enum CodingKeys: String, CodingKey {
        case acceptingWork = "accepting_work", brokerPort = "broker_port", routeURL = "route_url"
    }

    public static func load(_ url: URL) throws -> HostSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return HostSettings() }
        return try SecureFileSystem.decode(HostSettings.self, from: url)
    }

    public func save(_ url: URL) throws {
        try SecureFileSystem.atomicWrite(self, to: url)
    }
}
