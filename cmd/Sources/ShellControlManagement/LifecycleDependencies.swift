import Foundation
import ShellControlHostSupport

/// Probe local/public broker identity and the origin daemon health socket.
public protocol ControlHealthChecking: Sendable {
    func broker(url: URL, expectedIdentity: String) async -> ComponentObservation
    func daemon(path: String) async -> ComponentObservation
}

/// Idempotent origin enrollment against the local broker admin API.
public protocol OriginProvisioning: Sendable {
    func provisionOrigin(port: Int, adminSecret: String, label: String, originID: UUID, originSecret: String) async throws
}

/// Managed-tunnel side effects that would otherwise shell out to cloudflared.
public protocol TunnelRuntime: Sendable {
    func discoverQuickURL(logURLs: [URL], generation: String) async throws -> String
    func validateNamedConfiguration(cloudflared: String, config: URL) async throws
}

public struct LiveControlHealth: ControlHealthChecking {
    public init() {}
    public func broker(url: URL, expectedIdentity: String) async -> ComponentObservation {
        await HealthChecks.broker(url: url, expectedIdentity: expectedIdentity)
    }
    public func daemon(path: String) async -> ComponentObservation {
        await HealthChecks.daemon(path: path)
    }
}

public struct LiveOriginProvisioning: OriginProvisioning {
    public init() {}
    public func provisionOrigin(port: Int, adminSecret: String, label: String, originID: UUID, originSecret: String) async throws {
        try await ControlAdminClient(port: port, adminSecret: adminSecret)
            .provisionOrigin(label: label, originID: originID, originSecret: originSecret)
    }
}

public struct LiveTunnelRuntime: TunnelRuntime {
    private let runner: ProcessRunner
    public init(runner: ProcessRunner = ProcessRunner()) { self.runner = runner }
    public func discoverQuickURL(logURLs: [URL], generation: String) async throws -> String {
        try await TunnelTools.discoverQuickURL(logURLs: logURLs, generation: generation)
    }
    public func validateNamedConfiguration(cloudflared: String, config: URL) async throws {
        try await TunnelTools.validateNamedConfiguration(cloudflared: cloudflared, config: config, runner: runner)
    }
}
