import Foundation
import ShellControlHostSupport

public enum TunnelTools {
    private struct Credential: Decodable { var TunnelID: String?; var tunnelID: String? }

    public static func resolveCloudflared(explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let explicit {
            try SecureFileSystem.validateAbsolute(explicit)
            guard FileManager.default.isExecutableFile(atPath: explicit) else { throw ManagementError.invalid("cloudflared is not executable: \(explicit)") }
            return explicit
        }
        for directory in (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin").split(separator: ":") {
            let candidate = "\(directory)/cloudflared"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw ManagementError.unavailable("cloudflared is required for managed tunnel mode; install it or select loopback/external-proxy")
    }

    public static func validateCloudflared(_ path: String) throws {
        try SecureFileSystem.validateAbsolute(path)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ManagementError.unavailable("configured cloudflared is missing or no longer executable: \(path)")
        }
    }

    public static func validateNamedCredential(source: String, tunnelID: UUID) throws {
        try SecureFileSystem.validateAbsolute(source)
        try SecureFileSystem.validateOwnedPath(source, type: .typeRegular)
        let attributes = try FileManager.default.attributesOfItem(atPath: source)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard mode & 0o077 == 0 else { throw ManagementError.invalid("tunnel credentials must not be group/world accessible") }
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let identity = (object?["TunnelID"] as? String) ?? (object?["tunnel_id"] as? String)
        guard identity?.lowercased() == tunnelID.uuidString.lowercased() else {
            throw ManagementError.invalid("tunnel credentials do not match --tunnel-id")
        }
    }

    public static func installNamedCredential(source: String, tunnelID: UUID, paths: InstallationPaths) throws -> URL {
        try validateNamedCredential(source: source, tunnelID: tunnelID)
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        let target = paths.credentials.appendingPathComponent("tunnel.json")
        try SecureFileSystem.atomicWrite(data, to: target)
        return target
    }

    public static func writeNamedConfiguration(publicURL: String, port: Int, tunnelID: UUID,
                                               credential: URL, paths: InstallationPaths) throws -> URL {
        guard let host = URL(string: publicURL)?.host else { throw ManagementError.invalid("named tunnel public URL has no host") }
        func quoted(_ value: String) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        let tunnel = try quoted(tunnelID.uuidString.lowercased())
        let credentials = try quoted(credential.path)
        let hostname = try quoted(host.lowercased())
        let service = try quoted("http://127.0.0.1:\(port)")
        let catchAll = try quoted("http_status:404")
        let yaml = """
        tunnel: \(tunnel)
        credentials-file: \(credentials)
        ingress:
          - hostname: \(hostname)
            service: \(service)
          - service: \(catchAll)
        """ + "\n"
        let target = paths.services.appendingPathComponent("tunnel.yml")
        try SecureFileSystem.atomicWrite(Data(yaml.utf8), to: target)
        return target
    }

    public static func validateNamedConfiguration(cloudflared: String, config: URL, runner: ProcessRunner) async throws {
        let result = try await runner.run(cloudflared, ["tunnel", "--config", config.path, "ingress", "validate"], timeout: 15)
        guard result.status == 0 else {
            throw ManagementError.invalid("cloudflared rejected generated ingress: \(result.stderrString.prefix(500))")
        }
    }

    public static func discoverQuickURL(logURLs: [URL], generation: String, timeout: TimeInterval = 30) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var offsets = Dictionary(uniqueKeysWithValues: logURLs.map { ($0, UInt64(0)) })
        var partials = Dictionary(uniqueKeysWithValues: logURLs.map { ($0, "") })
        var marked = Set<URL>()
        let regex = try NSRegularExpression(pattern: #"https://[a-z0-9-]+\.trycloudflare\.com"#)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            for url in logURLs where FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                if size < offsets[url, default: 0] { offsets[url] = 0; partials[url] = ""; marked.remove(url) }
                guard size > offsets[url, default: 0] else { continue }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                try handle.seek(toOffset: offsets[url, default: 0])
                let data = try handle.read(upToCount: min(Int(size - offsets[url, default: 0]), 65_536)) ?? Data()
                offsets[url, default: 0] += UInt64(data.count)
                let combined = partials[url, default: ""] + String(decoding: data, as: UTF8.self)
                var lines = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                partials[url] = String(lines.removeLast().suffix(8192))
                for line in lines {
                    if line.contains(generation) { marked.insert(url) }
                    guard marked.contains(url) else { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    if let match = regex.firstMatch(in: line, range: range), let swiftRange = Range(match.range, in: line) {
                        return String(line[swiftRange])
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ManagementError.unavailable("cloudflared did not publish a quick-tunnel URL within 30 seconds")
    }
}
