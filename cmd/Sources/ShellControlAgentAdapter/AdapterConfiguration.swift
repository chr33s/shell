import Foundation
import ShellControlProtocol
import ShellControlHostSupport

/// Per-provider adapter settings written by `shell-control agent install`.
/// It holds no capability or credential: the hook authenticates through the
/// per-user daemon socket at run time.
public struct AdapterConfiguration: Codable, Sendable, Equatable {
    public var provider: AgentProvider
    /// The verified provider executable used for build detection.
    public var executablePath: String?
    /// Routes the user enabled. A route still needs build evidence.
    public var routes: [NativeRoute]
    /// Opt-in narrow Watch policy for short single-line shell commands; off
    /// by default (docs/specs/agent-relay.md section 5.3).
    public var watchShellApproval: Bool
    /// Builds the user explicitly allowed without contract evidence. Shown as
    /// `user_attested`, never "Ready".
    public var userAttestedBuilds: [String]

    public init(provider: AgentProvider, executablePath: String? = nil, routes: [NativeRoute]? = nil,
                watchShellApproval: Bool = false, userAttestedBuilds: [String] = []) {
        self.provider = provider
        self.executablePath = executablePath
        self.routes = routes ?? provider.manifest.routes.filter(\.enabledByDefault).map(\.route)
        self.watchShellApproval = watchShellApproval
        self.userAttestedBuilds = userAttestedBuilds
    }

    public static func url(root: URL, provider: AgentProvider) -> URL {
        root.appendingPathComponent("agent").appendingPathComponent("\(provider.rawValue).json")
    }

    public static func load(root: URL, provider: AgentProvider) -> AdapterConfiguration? {
        let url = url(root: root, provider: provider)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(AdapterConfiguration.self, from: Data(contentsOf: url))
    }

    public func save(root: URL) throws {
        let url = Self.url(root: root, provider: provider)
        try SecureFileSystem.ensureDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try SecureFileSystem.atomicWrite(try encoder.encode(self), to: url)
    }

    /// The evidence for `route` on `build`: the manifest's tested ranges, or
    /// the user's explicit attestation, or documentation only.
    public func evidence(for build: String?, route: NativeRoute) -> AgentCompatibilityEvidence {
        guard let build, BuildVersion(build) != nil else { return .none }
        let manifest = provider.manifest.evidence(for: build, route: route)
        if manifest >= .contractTested { return manifest }
        if userAttestedBuilds.contains(build) { return .userAttested }
        return manifest
    }
}

/// Detects the installed provider build by running its version command with
/// a short timeout, cached by executable identity so a hook invocation does
/// not pay for it every time. A build that cannot be read is `nil`, and an
/// unknown build is informational only (docs/specs/agent-relay.md 3.3).
public struct ProviderBuildDetector: Sendable {
    public let root: URL
    public let runner: any ProcessRunning

    public init(root: URL, runner: any ProcessRunning = ProcessRunner(outputLimit: 4096)) {
        self.root = root
        self.runner = runner
    }

    struct Cache: Codable {
        var path: String
        var modified: Double
        var size: Int64
        var build: String
        /// When the probe ran; a failed probe is trusted only briefly.
        var checkedAt: Double?
    }

    /// How long a failed probe is remembered. The executable does not change
    /// when the user answers a Gatekeeper first-launch prompt, so a failure
    /// must not be cached for the binary's lifetime.
    public static let failedProbeLifetime: TimeInterval = 10 * 60

    public func build(provider: AgentProvider, executable: String?) async -> String? {
        guard let path = executable ?? Self.locate(provider.manifest.executable), path.hasPrefix("/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: (path as NSString).resolvingSymlinksInPath) else {
            return nil
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let cacheURL = root.appendingPathComponent("agent").appendingPathComponent("\(provider.rawValue).build.json")
        if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.path == path, cache.modified == modified, cache.size == size {
            // An empty build records a recent failed probe for this exact
            // executable, so a hung version command costs one timeout per
            // interval, not one per hook invocation.
            if !cache.build.isEmpty { return cache.build }
            if Date().timeIntervalSince1970 - (cache.checkedAt ?? 0) < Self.failedProbeLifetime { return nil }
        }
        let result = try? await runner.run(path, provider.manifest.versionArguments, timeout: 3)
        let build = result.flatMap { $0.status == 0 ? Self.parseBuild($0.stdoutString) : nil }
        if let data = try? JSONEncoder().encode(Cache(path: path, modified: modified, size: size, build: build ?? "", checkedAt: Date().timeIntervalSince1970)) {
            try? SecureFileSystem.ensureDirectory(cacheURL.deletingLastPathComponent())
            try? SecureFileSystem.atomicWrite(data, to: cacheURL)
        }
        return build
    }

    /// The first dotted numeric version in the output, e.g. `2.1.281`.
    public static func parseBuild(_ output: String) -> String? {
        let pattern = #"(\d+\.\d+(?:\.\d+){0,2})"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    public static func locate(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for directory in path.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// The observable provider permission policy: a digest of the settings files
/// the provider reads for permission rules and hooks, so a policy change
/// between review and dispatch is detected (docs/specs/agent-relay.md 5.2).
public enum PolicyFingerprint {
    public static func files(for provider: AgentProvider, cwd: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch provider {
        case .claudeCode:
            let project = environment["CLAUDE_PROJECT_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? cwd
            return [
                "\(home)/.claude/settings.json",
                "\(project)/.claude/settings.json",
                "\(project)/.claude/settings.local.json",
                "/Library/Application Support/ClaudeCode/managed-settings.json"
            ]
        case .codex:
            return ["\(home)/.codex/config.toml", "\(home)/.codex/hooks.json", "\(cwd)/.codex/config.toml", "\(cwd)/.codex/hooks.json"]
        }
    }

    public static func compute(for provider: AgentProvider, cwd: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var members: [String: JSONValue] = [:]
        for path in files(for: provider, cwd: cwd, environment: environment) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 4 << 20 {
                members[path] = .string(ContentDigest.sha256Hex(data))
            } else {
                members[path] = .null
            }
        }
        return ContentDigest.sha256Hex((try? JSONCanonicalization.canonicalize(.object(members))) ?? Data())
    }
}

/// Non-authorizing tmux navigation metadata, read from the pane the agent
/// runs in. The socket path is hashed, never published
/// (docs/specs/agent-relay.md section 13.1).
public enum TerminalLocator {
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any ProcessRunning = ProcessRunner(outputLimit: 4096),
        now: ControlTimestamp = ControlTimestamp(Date())
    ) async -> TerminalLocation? {
        guard let tmux = environment["TMUX"], !tmux.isEmpty, let pane = environment["TMUX_PANE"], pane.hasPrefix("%"),
              let executable = ProviderBuildDetector.locate("tmux", environment: environment) else { return nil }
        guard let result = try? await runner.run(executable, ["display-message", "-p", "-t", pane, "#{session_id} #{window_id} #{pane_id} #{pid} #{socket_path}"], timeout: 1),
              result.status == 0 else { return nil }
        let fields = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 4).map(String.init)
        guard fields.count == 5 else { return nil }
        let instance = ContentDigest.sha256Hex(Data("tmux:\(fields[4]):\(fields[3])".utf8))
        return try? TerminalLocation(serverInstance: instance, sessionID: fields[0], windowID: fields[1], paneID: fields[2], observedAt: now)
    }
}
