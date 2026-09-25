import Foundation
import ShellControlHostSupport
import ShellControlProtocol
import ShellControlSecurity

/// Probe local/public broker identity and the origin daemon health socket.
public protocol ControlHealthChecking: Sendable {
    func broker(url: URL, expectedIdentity: String) async -> ComponentObservation
    func daemon(path: String) async -> ComponentObservation
    /// Enrolled iPhones and Watch reviewers, as the loopback admin API reports.
    func enrollment(port: Int, adminSecret: String) async -> EnrollmentSummary?
}

extension ControlHealthChecking {
    public func enrollment(port: Int, adminSecret: String) async -> EnrollmentSummary? { nil }
}

/// Mints one-use pairings on the loopback admin API.
public protocol PairingAdministration: Sendable {
    func createPairing(port: Int, adminSecret: String) async throws -> (pairingID: ControlID, secret: String, expiresAt: ControlTimestamp)
}

public struct LivePairingAdministration: PairingAdministration {
    public init() {}
    public func createPairing(port: Int, adminSecret: String) async throws -> (pairingID: ControlID, secret: String, expiresAt: ControlTimestamp) {
        var reader = try JSONReader(try await ControlAdminClient(port: port, adminSecret: adminSecret).send(method: "POST", path: "/v1/admin/pairings"))
        return (try reader.id("pairing_id"), try reader.string("pairing_secret", maxLength: 128), try reader.timestamp("expires_at"))
    }
}

/// The origin signing key on disk: PEM, owner-only, never copied off the Mac
/// (docs/specs/control-protocol.md section 4.2).
public enum OriginKeyFile {
    public static func load(_ url: URL) throws -> OriginSigningKey {
        try SecureFileSystem.validateOwnedPath(url.path, type: .typeRegular)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard mode & 0o077 == 0 else { throw ManagementError.corrupt("origin signing key must not be group/world accessible") }
        do {
            return try OriginSigningKey(pemRepresentation: try String(contentsOf: url, encoding: .utf8))
        } catch {
            throw ManagementError.corrupt("origin signing key is unreadable: \(error)")
        }
    }

    public static func write(_ key: OriginSigningKey, to url: URL) throws {
        try SecureFileSystem.atomicWrite(Data(key.pemRepresentation.utf8), to: url)
    }
}

/// Idempotent origin enrollment against the local broker admin API.
public protocol OriginProvisioning: Sendable {
    func provisionOrigin(port: Int, adminSecret: String, label: String, originID: UUID, originSecret: String) async throws
}

public struct LiveControlHealth: ControlHealthChecking {
    public init() {}
    public func broker(url: URL, expectedIdentity: String) async -> ComponentObservation {
        await HealthChecks.broker(url: url, expectedIdentity: expectedIdentity)
    }
    public func daemon(path: String) async -> ComponentObservation {
        await HealthChecks.daemon(path: path)
    }
    public func enrollment(port: Int, adminSecret: String) async -> EnrollmentSummary? {
        guard let value = try? await ControlAdminClient(port: port, adminSecret: adminSecret).send(method: "GET", path: "/v1/admin/devices") else { return nil }
        return EnrollmentSummary(adminDevices: value)
    }
}

public struct LiveOriginProvisioning: OriginProvisioning {
    public init() {}
    public func provisionOrigin(port: Int, adminSecret: String, label: String, originID: UUID, originSecret: String) async throws {
        try await ControlAdminClient(port: port, adminSecret: adminSecret)
            .provisionOrigin(label: label, originID: originID, originSecret: originSecret)
    }
}
