import Foundation
import Security
import ShellControlClient
import ShellControlHostSupport
import ShellControlSecurity

public struct InstallationStore: Sendable {
    public let paths: InstallationPaths
    public init(root: URL) { paths = InstallationPaths(root: root.standardizedFileURL) }

    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let explicit = environment["SHELL_CONTROL_STATE_DIR"] {
            guard explicit.hasPrefix("/") else { throw ManagementError.invalid("--state-dir and SHELL_CONTROL_STATE_DIR must be absolute") }
            return URL(fileURLWithPath: explicit).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/shell-control")
    }

    public func exists() -> Bool { FileManager.default.fileExists(atPath: paths.installation.path) }

    public func prepareRoot() throws {
        try SecureFileSystem.ensureDirectory(paths.root)
        for directory in [paths.credentials, paths.services, paths.launchd, paths.logs] {
            try SecureFileSystem.ensureDirectory(directory)
        }
    }

    public func lock(cancelled: @escaping @Sendable () -> Bool = { false }) throws -> FileLock {
        try prepareRoot()
        return try FileLock.acquire(path: paths.lock.path, cancelled: cancelled)
    }

    public func load() throws -> LoadedInstallation {
        guard exists() else { throw ManagementError.unavailable("no native installation — run shell-control setup first") }
        do {
            var installation = try SecureFileSystem.decode(Installation.self, from: paths.installation)
            guard installation.format == "shell-control.native/1" else {
                throw ManagementError.unsupported("unsupported installation format; refusing to import or reset it")
            }
            guard (1...65535).contains(installation.port), !installation.releaseID.isEmpty else {
                throw ManagementError.corrupt("installation.json is missing required fields")
            }
            let secrets = try SecureFileSystem.decode(InstallationSecrets.self, from: paths.secrets)
            guard !secrets.adminSecret.isEmpty, !secrets.cursorSecret.isEmpty,
                  (secrets.originID == nil) == (secrets.originSecret == nil) else {
                throw ManagementError.corrupt("native credentials are incomplete; refusing to regenerate identity")
            }
            let runtime: RuntimeState
            if FileManager.default.fileExists(atPath: paths.runtime.path) {
                runtime = try SecureFileSystem.decode(RuntimeState.self, from: paths.runtime)
            } else { runtime = RuntimeState() }
            if try SecureFileSystem.decode(SavedAddressMode.self, from: paths.installation).isLegacy {
                // A removed Cloudflare mode's route cannot be a tailnet
                // origin; drop it so setup can migrate the installation.
                installation.publicURL = nil
            } else if let saved = installation.publicURL {
                installation.publicURL = try AddressPolicy.validate(saved, mode: installation.addressMode)
            }
            return LoadedInstallation(installation: installation, secrets: secrets, runtime: runtime, paths: paths)
        } catch let error as ManagementError { throw error } catch { throw ManagementError.corrupt("native installation is malformed: \(error)") }
    }

    public func create(releaseID: String, mode: AddressMode, publicURL: String?, port: Int) throws -> LoadedInstallation {
        try prepareRoot()
        guard !exists() else { throw ManagementError.invalid("installation already exists") }
        let allowed = Set(["install.lock", "credentials", "services", "launchd", "logs", "guided-setup.json"])
        let entries = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        let unexplained = entries.filter { !allowed.contains($0) && !$0.hasPrefix(".installation.json.tmp-") }
        guard unexplained.isEmpty else {
            throw ManagementError.corrupt("state directory contains unrecognized state (\(unexplained.sorted().joined(separator: ", "))); refusing to adopt or delete it")
        }
        let installation = Installation(port: port, addressMode: mode, publicURL: publicURL, releaseID: releaseID)
        let secrets = InstallationSecrets(accountID: UUID(), adminSecret: try Self.secret(bytes: 32),
                                          cursorSecret: try Self.secret(bytes: 32), originID: nil, originSecret: nil)
        let runtime = RuntimeState()
        try save(installation); try save(secrets); try save(runtime)
        return LoadedInstallation(installation: installation, secrets: secrets, runtime: runtime, paths: paths)
    }

    public func save(_ value: Installation) throws { try SecureFileSystem.atomicWrite(value, to: paths.installation) }
    public func save(_ value: InstallationSecrets) throws { try SecureFileSystem.atomicWrite(value, to: paths.secrets) }
    public func save(_ value: RuntimeState) throws { try SecureFileSystem.atomicWrite(value, to: paths.runtime) }

    private static func secret(bytes count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw ManagementError.unavailable("secure random generation failed")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The raw `address_mode`, which `AddressMode` maps to `tailscale` when it
/// names a removed mode.
private struct SavedAddressMode: Decodable {
    let raw: String?
    var isLegacy: Bool { raw.map { AddressMode(rawValue: $0) == nil } ?? false }
    enum CodingKeys: String, CodingKey { case raw = "address_mode" }
}

public enum AddressPolicy {
    public static func validate(_ text: String, mode: AddressMode) throws -> String {
        guard let url = URL(string: text), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw ManagementError.invalid("public URL must be an origin with no credentials, path, query, or fragment")
        }
        if mode == .loopback {
            guard url.scheme == "http", ControlLoopback.isHost(host) else {
                throw ManagementError.invalid("loopback mode requires a loopback http origin")
            }
        } else {
            guard url.scheme == "https", OriginRoute.isTailnetHost(host), url.port == nil || url.port == 443 else {
                throw ManagementError.invalid("tailscale mode requires https://<machine>.<tailnet>.ts.net")
            }
        }
        guard let normalized = ControlBrokerAddress.normalize(url) else {
            throw ManagementError.invalid("invalid public URL")
        }
        return normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

public enum ControlLoopback {
    public static func isHost(_ host: String) -> Bool { ControlBrokerAddress.isLoopbackHost(host) }
    public static func url(port: Int) -> String { "http://127.0.0.1:\(port)" }
}
