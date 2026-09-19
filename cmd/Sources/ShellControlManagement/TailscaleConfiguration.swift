import Foundation
import ShellControlHostSupport
import ShellControlSecurity

/// What `tailscale status --json` says about this Mac.
public struct TailnetStatus: Sendable, Equatable {
    public var backendState: String
    /// MagicDNS name without the trailing dot, e.g. `macbook.example.ts.net`.
    public var dnsName: String?
    public var magicDNSEnabled: Bool
    public var online: Bool

    public init(backendState: String, dnsName: String?, magicDNSEnabled: Bool, online: Bool) {
        self.backendState = backendState
        self.dnsName = dnsName
        self.magicDNSEnabled = magicDNSEnabled
        self.online = online
    }

    public var isConnected: Bool { backendState == "Running" }

    /// Parses the subset of `tailscale status --json` Shell depends on.
    public init(json data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagementError.unavailable("tailscale status is not a JSON object")
        }
        backendState = object["BackendState"] as? String ?? "Unknown"
        let me = object["Self"] as? [String: Any]
        let name = (me?["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        dnsName = name?.isEmpty == false ? name : nil
        online = me?["Online"] as? Bool ?? false
        let tailnet = object["CurrentTailnet"] as? [String: Any]
        magicDNSEnabled = tailnet?["MagicDNSEnabled"] as? Bool ?? (dnsName?.hasSuffix(".ts.net") ?? false)
    }
}

/// The part of Tailscale Serve's configuration Shell verifies: HTTPS 443 on
/// this node's name proxying to the loopback broker, and never Funnel.
public struct ServeState: Sendable, Equatable {
    public var proxies: [String: String]
    public var funnel: Set<String>

    public init(proxies: [String: String] = [:], funnel: Set<String> = []) {
        self.proxies = proxies
        self.funnel = funnel
    }

    /// Parses `tailscale serve status --json` (an `ipn.ServeConfig`).
    public init(json data: Data) throws {
        proxies = [:]
        funnel = []
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else { return }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagementError.unavailable("tailscale serve status is not a JSON object")
        }
        for (hostPort, value) in object["Web"] as? [String: Any] ?? [:] {
            let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any]
            if let proxy = (handlers?["/"] as? [String: Any])?["Proxy"] as? String {
                proxies[hostPort.lowercased()] = proxy
            }
        }
        for (hostPort, value) in object["AllowFunnel"] as? [String: Any] ?? [:] where value as? Bool == true {
            funnel.insert(hostPort.lowercased())
        }
    }

    /// Whether `https://<host>` is served privately by the loopback broker.
    public func servesBroker(host: String, port: Int) -> Bool {
        guard let proxy = proxies["\(host.lowercased()):443"] else { return false }
        return Self.normalizedTarget(proxy) == "127.0.0.1:\(port)"
    }

    public func isFunnelled(host: String) -> Bool { funnel.contains("\(host.lowercased()):443") }

    static func normalizedTarget(_ proxy: String) -> String {
        var target = proxy.lowercased()
        for prefix in ["http://", "https+insecure://"] where target.hasPrefix(prefix) { target = String(target.dropFirst(prefix.count)) }
        while target.hasSuffix("/") { target.removeLast() }
        if target.hasPrefix("localhost:") { target = "127.0.0.1:" + target.dropFirst("localhost:".count) }
        if !target.contains(":") { target = "127.0.0.1:\(target)" }
        return target
    }
}

/// Tailscale side effects, injectable so lifecycle tests never shell out.
public protocol TailnetRuntime: Sendable {
    func status(tailscale: String) async throws -> TailnetStatus
    func serveStatus(tailscale: String) async throws -> ServeState
    /// Points HTTPS 443 on this node at the loopback broker.
    func configureServe(tailscale: String, port: Int) async throws
    /// Removes the HTTPS 443 handler Shell configured.
    func disableServe(tailscale: String) async throws
}

public struct LiveTailnetRuntime: TailnetRuntime {
    private let runner: ProcessRunner
    public init(runner: ProcessRunner = ProcessRunner()) { self.runner = runner }

    public func status(tailscale: String) async throws -> TailnetStatus {
        let result = try await runner.run(tailscale, ["status", "--json"], timeout: 10)
        // A stopped backend still prints JSON with BackendState; only an
        // unusable CLI is an error here.
        guard !result.stdout.isEmpty else {
            throw ManagementError.unavailable("tailscale status failed: \(result.stderrString.prefix(300))")
        }
        return try TailnetStatus(json: result.stdout)
    }

    public func serveStatus(tailscale: String) async throws -> ServeState {
        let result = try await runner.run(tailscale, ["serve", "status", "--json"], timeout: 10)
        guard result.status == 0 else {
            throw ManagementError.unavailable("tailscale serve status failed: \(result.stderrString.prefix(300))")
        }
        return try ServeState(json: result.stdout)
    }

    public func configureServe(tailscale: String, port: Int) async throws {
        // Success is judged by the resulting Serve state, not this exit code:
        // the CLI syntax may evolve (spec.iphone-gateway.md section 4.4).
        let result = try await runner.run(tailscale, ["serve", "--bg", "--https=443", "http://127.0.0.1:\(port)"], timeout: 30)
        if result.status != 0 {
            let detail = result.stderrString.prefix(500)
            if detail.localizedCaseInsensitiveContains("https") && detail.localizedCaseInsensitiveContains("enable") {
                throw ManagementError.unavailable("Tailscale HTTPS certificates are disabled for this tailnet; enable HTTPS in the Tailscale admin console, then rerun setup: \(detail)")
            }
            throw ManagementError.unavailable("tailscale serve failed: \(detail)")
        }
    }

    public func disableServe(tailscale: String) async throws {
        _ = try await runner.run(tailscale, ["serve", "--https=443", "off"], timeout: 15)
    }
}

public enum TailscaleTools {
    /// Where the CLI lives: explicit, `PATH`, the App Store / standalone app
    /// bundle, then Homebrew.
    public static func resolve(explicit: String?, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if let explicit {
            try SecureFileSystem.validateAbsolute(explicit)
            guard FileManager.default.isExecutableFile(atPath: explicit) else {
                throw ManagementError.invalid("tailscale is not executable: \(explicit)")
            }
            return explicit
        }
        var candidates = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map { "\($0)/tailscale" }
        candidates += [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        throw ManagementError.unavailable("Tailscale is required on this Mac: install it from https://tailscale.com/download/mac, sign in, then rerun setup")
    }

    /// The prerequisites of spec.iphone-gateway.md section 6.1, reported
    /// precisely rather than assumed.
    public static func requireReady(_ status: TailnetStatus) throws -> String {
        guard status.isConnected else {
            throw ManagementError.unavailable("Tailscale is not connected (state: \(status.backendState)); run `tailscale up` and rerun setup")
        }
        guard status.magicDNSEnabled, let name = status.dnsName, OriginRoute.isTailnetHost(name) else {
            throw ManagementError.unavailable("MagicDNS is not available for this Mac; enable MagicDNS in the Tailscale admin console and rerun setup")
        }
        return name
    }
}
