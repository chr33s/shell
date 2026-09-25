import Foundation
import ShellControlProtocol
import ShellControlHostSupport

/// Merges only Shell's own hook stanzas into a provider's hook settings,
/// preserving every other hook and setting, writing atomically, and keeping a
/// recoverable backup (spec.agent-relay.md sections 10.1 and 19.7).
public struct HookInstaller: Sendable {
    public let provider: AgentProvider
    /// The file the provider reads hooks from.
    public let settingsURL: URL
    /// The exact command the provider runs; its marker identifies Shell's
    /// stanzas on uninstall. It carries no capability or secret.
    public let command: String

    public static let marker = "agent hook"

    public init(provider: AgentProvider, settingsURL: URL? = nil, command: String) {
        self.provider = provider
        self.settingsURL = settingsURL ?? Self.defaultSettingsURL(provider)
        self.command = command
    }

    public static func defaultSettingsURL(_ provider: AgentProvider) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch provider {
        case .claudeCode: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        }
    }

    /// The command for `executable`, quoted for the provider's shell.
    public static func command(executable: String, provider: AgentProvider, stateDirectory: String?) -> String {
        var parts = [shellQuote(executable)]
        if let stateDirectory { parts += ["--state-dir", shellQuote(stateDirectory)] }
        parts += ["agent", "hook", provider.rawValue]
        return parts.joined(separator: " ")
    }

    static func shellQuote(_ text: String) -> String {
        if text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+:@".contains($0)) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The owned stanzas for the enabled routes, with the tested timeout.
    public func stanzas(routes: [NativeRoute]) -> [(event: String, matcher: String)] {
        var entries: [(String, String)] = []
        let permissionTools = routes.flatMap { route -> [String] in
            switch route {
            case .permissionShell: return ["Bash"]
            case .permissionFileChange: return provider == .claudeCode ? ["Edit", "Write"] : []
            case .askUserQuestion: return []
            default: return []
            }
        }
        // Exact-match matchers: tool names joined by `|`, no regex.
        if !permissionTools.isEmpty { entries.append(("PermissionRequest", permissionTools.joined(separator: "|"))) }
        if provider == .claudeCode, routes.contains(.askUserQuestion) { entries.append(("PreToolUse", "AskUserQuestion")) }
        // Session end withdraws what is still pending for the session.
        entries.append(("SessionEnd", ""))
        return entries
    }

    public struct Plan: Sendable {
        public let before: Data?
        public let after: Data
        public var changed: Bool {
            guard let before else { return true }
            return canonical(before) != canonical(after)
        }

        /// Formatting-independent comparison, so an unchanged install is a
        /// no-op rather than a rewrite.
        private func canonical(_ data: Data) -> Data? {
            guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }

    /// The settings with Shell's stanzas replaced by the current ones.
    public func plan(routes: [NativeRoute]) throws -> Plan {
        let before = try currentSettings()
        var root = try parse(before)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        hooks = removingOwned(from: hooks)
        for (event, matcher) in stanzas(routes: routes) {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var hook: [String: Any] = ["type": "command", "command": command]
            if event != "SessionEnd" { hook["timeout"] = AgentPolicy.hookOuterTimeout }
            var group: [String: Any] = ["hooks": [hook]]
            if !matcher.isEmpty { group["matcher"] = matcher }
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return Plan(before: before, after: try serialize(root))
    }

    /// The settings with only Shell's stanzas removed.
    public func uninstallPlan() throws -> Plan {
        let before = try currentSettings()
        var root = try parse(before)
        let hooks = removingOwned(from: root["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return Plan(before: before, after: try serialize(root))
    }

    /// Writes `plan`, keeping the previous file as a timestamped backup.
    @discardableResult
    public func apply(_ plan: Plan, now: Date = Date()) throws -> URL? {
        guard plan.changed else { return nil }
        try SecureFileSystem.ensureDirectory(settingsURL.deletingLastPathComponent(), permissions: 0o700)
        var backup: URL?
        if let before = plan.before {
            let url = settingsURL.deletingLastPathComponent()
                .appendingPathComponent("\(settingsURL.lastPathComponent).shell-control-backup-\(Int(now.timeIntervalSince1970))")
            try SecureFileSystem.atomicWrite(before, to: url)
            backup = url
        }
        try SecureFileSystem.atomicWrite(plan.after, to: settingsURL)
        return backup
    }

    /// Whether the current settings contain exactly the stanzas for `routes`
    /// with this command.
    public func isInstalled(routes: [NativeRoute]) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL), let root = try? parse(data),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return stanzas(routes: routes).allSatisfy { event, matcher in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["matcher"] as? String ?? "") == matcher
                    && (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String) == command }
            }
        }
    }

    /// Any Shell stanza, whatever its command path.
    public func hasOwnedStanza() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL), let root = try? parse(data),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isOwned)
            }
        }
    }

    private func isOwned(_ hook: [String: Any]) -> Bool {
        guard let command = hook["command"] as? String else { return false }
        return command.contains(" \(Self.marker) \(provider.rawValue)") && command.contains("shell-control")
    }

    private func removingOwned(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { result[event] = value; continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = entries.filter { !isOwned($0) }
                guard !remaining.isEmpty else { return nil }
                var copy = group
                copy["hooks"] = remaining
                return copy
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    /// The file's bytes, or nil only when it does not exist. A file that
    /// exists but cannot be read is an error: treating it as empty would
    /// replace the user's settings with Shell's stanzas and no backup.
    private func currentSettings() throws -> Data? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        do {
            return try Data(contentsOf: settingsURL)
        } catch {
            throw AdapterRefusal("unsupported_input_schema", "\(settingsURL.path) exists but cannot be read; not changing it (\(error.localizedDescription))")
        }
    }

    private func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AdapterRefusal("unsupported_input_schema", "\(settingsURL.path) is not a JSON object; not changing it")
        }
        return object
    }

    private func serialize(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}
