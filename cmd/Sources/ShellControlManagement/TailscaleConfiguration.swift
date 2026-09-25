import Foundation
import ShellControlHostSupport
import ShellControlProtocol
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
/// this node's name proxying to the loopback broker, and never Funnel. It also
/// inventories what else is served, so Shell never replaces another app's
/// handler (docs/specs/control-setup.md section 4.3).
public struct ServeState: Sendable, Equatable {
    public var proxies: [String: String]
    public var funnel: Set<String>
    /// `host:port` → mount paths other than `/`, which belong to other apps.
    public var otherMounts: [String: Set<String>]
    /// `host:port` whose `/` handler serves something other than a proxy
    /// (files, text, or a type this parser does not know).
    public var nonProxyRoots: Set<String>
    /// TCP ports Serve forwards as raw TCP rather than HTTPS.
    public var tcpForwards: Set<String>
    /// `host:port` whose `/` is held by a foreground `tailscale serve` or
    /// `tailscale funnel` session. Shell only ever configures `--bg`.
    public var foregroundRoots: Set<String> = []

    public init(proxies: [String: String] = [:], funnel: Set<String> = [],
                otherMounts: [String: Set<String>] = [:], nonProxyRoots: Set<String> = [], tcpForwards: Set<String> = []) {
        self.proxies = proxies
        self.funnel = funnel
        self.otherMounts = otherMounts
        self.nonProxyRoots = nonProxyRoots
        self.tcpForwards = tcpForwards
    }

    /// Parses `tailscale serve status --json` (an `ipn.ServeConfig`).
    public init(json data: Data) throws {
        self.init()
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else { return }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ManagementError.unavailable("tailscale serve status is not a JSON object")
        }
        apply(object, foreground: false)
        // Foreground sessions nest whole configurations under their session
        // IDs; they are served just the same and must not read as absent.
        for (_, session) in object["Foreground"] as? [String: Any] ?? [:] {
            if let config = session as? [String: Any] { apply(config, foreground: true) }
        }
    }

    private mutating func apply(_ object: [String: Any], foreground: Bool) {
        for (hostPort, value) in object["Web"] as? [String: Any] ?? [:] {
            let key = hostPort.lowercased()
            let handlers = (value as? [String: Any])?["Handlers"] as? [String: Any] ?? [:]
            for (path, handler) in handlers {
                if path == "/" {
                    if foreground {
                        foregroundRoots.insert(key)
                    } else if let proxy = (handler as? [String: Any])?["Proxy"] as? String {
                        proxies[key] = proxy
                    } else {
                        nonProxyRoots.insert(key)
                    }
                } else {
                    otherMounts[key, default: []].insert(path)
                }
            }
        }
        for (hostPort, value) in object["AllowFunnel"] as? [String: Any] ?? [:] where value as? Bool == true {
            funnel.insert(hostPort.lowercased())
        }
        for (port, value) in object["TCP"] as? [String: Any] ?? [:] {
            if let handler = value as? [String: Any], handler["TCPForward"] != nil { tcpForwards.insert(port) }
        }
    }

    /// Whether `https://<host>` is served privately by the loopback broker.
    public func servesBroker(host: String, port: Int) -> Bool {
        guard let proxy = proxies["\(host.lowercased()):443"] else { return false }
        return Self.normalizedTarget(proxy) == "127.0.0.1:\(port)"
    }

    public func isFunnelled(host: String) -> Bool { funnel.contains("\(host.lowercased()):443") }

    /// Who holds `https://<host>/`. Shell owns it only when it proxies to a
    /// loopback port this installation uses or used. Anything else — another
    /// proxy target, a file or text handler, raw TCP on 443 — is a conflict
    /// setup stops on rather than replacing.
    public func ownership(host: String, ownedPorts: Set<Int>) -> ServeOwnership {
        let key = "\(host.lowercased()):443"
        if tcpForwards.contains("443") { return .conflict("HTTPS 443 is forwarded as raw TCP by another Serve configuration") }
        if nonProxyRoots.contains(key) { return .conflict("https://\(host)/ is served by a non-proxy Serve handler") }
        if foregroundRoots.contains(key) { return .conflict("https://\(host)/ is held by a foreground tailscale serve or funnel session") }
        guard let proxy = proxies[key] else { return .absent }
        let target = Self.normalizedTarget(proxy)
        if ownedPorts.contains(where: { target == "127.0.0.1:\($0)" }) { return .shell(port: Int(target.split(separator: ":").last ?? "") ?? 0) }
        return .conflict("https://\(host)/ already proxies to \(DisplaySanitizer.sanitize(proxy, maxScalars: 200).text)")
    }

    static func normalizedTarget(_ proxy: String) -> String {
        var target = proxy.lowercased()
        for prefix in ["http://", "https+insecure://"] where target.hasPrefix(prefix) { target = String(target.dropFirst(prefix.count)) }
        while target.hasSuffix("/") { target.removeLast() }
        if target.hasPrefix("localhost:") { target = "127.0.0.1:" + target.dropFirst("localhost:".count) }
        if !target.contains(":") { target = "127.0.0.1:\(target)" }
        return target
    }
}

public enum ServeOwnership: Sendable, Equatable {
    /// Nothing is served at `https://<host>/`.
    case absent
    /// Shell's own loopback broker (at `port`) is served there.
    case shell(port: Int)
    /// Another application's handler; Shell must not replace it.
    case conflict(String)
}

/// Tailscale side effects, injectable so lifecycle tests never shell out.
public protocol TailnetRuntime: Sendable {
    func status(tailscale: String) async throws -> TailnetStatus
    func serveStatus(tailscale: String) async throws -> ServeState
    /// Points HTTPS 443 on this node at the loopback broker.
    func configureServe(tailscale: String, port: Int) async throws
    /// Removes the HTTPS 443 handler Shell configured. With `rootOnly`, only
    /// the `/` mount is removed and other apps' mounts on 443 stay.
    func disableServe(tailscale: String, rootOnly: Bool) async throws
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
        // the CLI syntax may evolve (docs/specs/control-protocol.md section 2.3).
        let result = try await runner.run(tailscale, ["serve", "--bg", "--https=443", "http://127.0.0.1:\(port)"], timeout: 30)
        if result.status != 0 {
            let detail = result.stderrString.prefix(500)
            if detail.localizedCaseInsensitiveContains("https") && detail.localizedCaseInsensitiveContains("enable") {
                throw ManagementError.unavailable("Tailscale HTTPS certificates are disabled for this tailnet; enable HTTPS in the Tailscale admin console, then rerun setup: \(detail)")
            }
            throw ManagementError.unavailable("tailscale serve failed: \(detail)")
        }
    }

    public func disableServe(tailscale: String, rootOnly: Bool) async throws {
        let arguments = rootOnly ? ["serve", "--https=443", "--set-path=/", "off"] : ["serve", "--https=443", "off"]
        _ = try await runner.run(tailscale, arguments, timeout: 15)
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

    /// The prerequisites of docs/specs/control-protocol.md section 4.1, reported
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
