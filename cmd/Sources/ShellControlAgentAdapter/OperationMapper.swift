import Foundation
import ShellControlProtocol

/// What the adapter observed about the local context, committed into
/// `context_sha256` and rechecked before the native gate is answered
/// (docs/specs/agent-relay.md section 5.2).
public struct AdapterContext: Sendable, Hashable {
    public var providerBuild: String
    public var agentSessionID: ControlID
    public var nativeWaitID: ControlID
    public var effectiveUserID: UInt32
    public var policyFingerprint: String?
    /// Absolute path → SHA-256 of the file before the change, or nil when
    /// the path did not exist.
    public var fileBases: [String: String?] = [:]
    public var unavailable: [String] = []

    public init(providerBuild: String, agentSessionID: ControlID, nativeWaitID: ControlID, effectiveUserID: UInt32, policyFingerprint: String?) {
        self.providerBuild = providerBuild
        self.agentSessionID = agentSessionID
        self.nativeWaitID = nativeWaitID
        self.effectiveUserID = effectiveUserID
        self.policyFingerprint = policyFingerprint
    }

    /// The documented context material: the active wait, the provider
    /// identity and build, the effective user, the exact tool arguments, the
    /// observable policy, and the file preconditions.
    public func material(for input: NativeHookInput) -> JSONValue {
        JSONWriter.object([
            "v": 1,
            "provider": .string(input.provider.wireName),
            "provider_build": .string(providerBuild),
            "adapter_build": .string(AdapterManifest.adapterBuild),
            "agent_session_id": JSONValue(agentSessionID),
            "native_wait_id": JSONValue(nativeWaitID),
            "effective_uid": .number(.int(Int64(effectiveUserID))),
            "tool_name": .string(input.toolName),
            "tool_input": input.toolInput,
            "cwd": .string(input.cwd),
            "permission_mode": input.permissionMode.map { .string($0) },
            "policy_fingerprint": policyFingerprint.map { .string($0) },
            "file_bases": .object(fileBases.mapValues { $0.map { .string($0) } ?? .null }),
            "unavailable": JSONValue(strings: unavailable.sorted())
        ])
    }

    public func contextSHA256(for input: NativeHookInput) -> String {
        ContentDigest.sha256Hex((try? JSONCanonicalization.canonicalize(material(for: input))) ?? Data())
    }
}

/// Maps a native permission request onto `agent.tool.v1`, or refuses it. A
/// command string is never split into argv, a missing shell identity is named
/// rather than invented, and any authorization-relevant field the adapter does
/// not understand refuses remote approval (docs/specs/agent-relay.md 5.1–5.3).
public enum OperationMapper {
    /// Tool-input members each provider's shell tool may carry. Anything else
    /// could widen what the reviewer approves.
    static func shellMembers(_ provider: AgentProvider) -> Set<String> {
        switch provider {
        case .claudeCode: return ["command", "description", "timeout", "run_in_background"]
        case .codex: return ["command", "description"]
        }
    }

    public static let maximumFileBytes = 1 << 20
    public static let maximumDiffBytes = 24 * 1024

    public static func operation(
        for input: NativeHookInput,
        context: inout AdapterContext,
        fileSystem: any AdapterFileSystem = LocalFileSystem()
    ) throws -> AgentToolOperation {
        guard input.event == .permissionRequest, let route = input.route else {
            throw AdapterRefusal("unsupported_operation", "\(input.toolName) is not a supported permission route")
        }
        guard let members = input.toolInput.objectValue else {
            throw AdapterRefusal("unsupported_input_schema", "tool_input is not an object")
        }
        switch route {
        case .permissionShell:
            return try shell(input, members: members, context: &context)
        case .permissionFileChange:
            return try fileChange(input, members: members, context: &context, fileSystem: fileSystem)
        default:
            throw AdapterRefusal("unsupported_operation", "\(route.rawValue) is not a hook permission route")
        }
    }

    private static func shell(_ input: NativeHookInput, members: [String: JSONValue], context: inout AdapterContext) throws -> AgentToolOperation {
        let unknown = Set(members.keys).subtracting(shellMembers(input.provider))
        guard unknown.isEmpty else {
            throw AdapterRefusal("unsupported_operation", "unrecognized shell fields \(unknown.sorted().joined(separator: ", ")) may change the scope")
        }
        guard let command = members["command"]?.stringValue, !command.isEmpty else {
            throw AdapterRefusal("unsupported_input_schema", "command is missing")
        }
        var options: [String: AgentOptionValue] = [:]
        if let timeout = members["timeout"], !timeout.isNull {
            guard let value = timeout.int64Value else { throw AdapterRefusal("unsupported_input_schema", "timeout is not an integer") }
            options["timeout"] = .integer(value)
        }
        if let background = members["run_in_background"], !background.isNull {
            guard let flag = background.boolValue else { throw AdapterRefusal("unsupported_input_schema", "run_in_background is not a boolean") }
            options["run_in_background"] = .bool(flag)
        }
        let reason = try optionalText(members["description"], field: "description")
        context.unavailable = ["environment", "shell_identity"]
        return try build(input, context: context, kind: .shell, reason: reason,
                         shellRequest: try AgentShellRequest(representation: .commandString, command: command, shellIdentity: nil, options: options))
    }

    private static func fileChange(
        _ input: NativeHookInput,
        members: [String: JSONValue],
        context: inout AdapterContext,
        fileSystem: any AdapterFileSystem
    ) throws -> AgentToolOperation {
        let allowed: Set<String> = input.toolName == "Edit" ? ["file_path", "old_string", "new_string", "replace_all"] : ["file_path", "content"]
        let unknown = Set(members.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw AdapterRefusal("unsupported_operation", "unrecognized \(input.toolName) fields \(unknown.sorted().joined(separator: ", "))")
        }
        guard let path = members["file_path"]?.stringValue, path.hasPrefix("/"), !path.contains("\0") else {
            throw AdapterRefusal("unsupported_input_schema", "file_path is not an absolute path")
        }
        let current = try fileSystem.contents(of: path, limit: maximumFileBytes)
        let updated: String
        let change: AgentFileChange.Change
        if input.toolName == "Edit" {
            guard let current else { throw AdapterRefusal("native_context_changed", "the file to edit does not exist") }
            guard let old = members["old_string"]?.stringValue, let new = members["new_string"]?.stringValue, !old.isEmpty else {
                throw AdapterRefusal("unsupported_input_schema", "old_string and new_string are required")
            }
            let replaceAll = members["replace_all"].flatMap { $0.isNull ? false : $0.boolValue } ?? false
            guard let text = String(data: current, encoding: .utf8) else {
                throw AdapterRefusal("unsupported_operation", "the file is not UTF-8 text")
            }
            let occurrences = text.components(separatedBy: old).count - 1
            // The provider rejects a missing or ambiguous match itself; the
            // reviewer is never shown a change that would not happen.
            guard occurrences == 1 || (occurrences > 1 && replaceAll) else {
                throw AdapterRefusal("native_context_changed", "old_string matches \(occurrences) times")
            }
            updated = replaceAll ? text.replacingOccurrences(of: old, with: new) : text.replacingFirst(old, with: new)
            change = .modify
        } else {
            guard let content = members["content"]?.stringValue else {
                throw AdapterRefusal("unsupported_input_schema", "content is required")
            }
            updated = content
            change = current == nil ? .create : .modify
        }
        let before = current.flatMap { String(data: $0, encoding: .utf8) }
        if current != nil, before == nil {
            throw AdapterRefusal("unsupported_operation", "the file is not UTF-8 text")
        }
        let diff = UnifiedDiff.make(path: path, before: before, after: updated)
        guard diff.utf8.count <= maximumDiffBytes else {
            throw AdapterRefusal("limit_exceeded", "the diff exceeds the inline review limit")
        }
        let base = current.map { ContentDigest.sha256Hex($0) }
        context.fileBases = [path: base]
        context.unavailable = ["environment"]
        return try build(input, context: context, kind: .fileChange, reason: nil,
                         fileChanges: [try AgentFileChange(path: path, change: change, diff: diff, baseSHA256: base)])
    }

    private static func build(
        _ input: NativeHookInput,
        context: AdapterContext,
        kind: AgentToolKind,
        reason: String?,
        shellRequest: AgentShellRequest? = nil,
        fileChanges: [AgentFileChange]? = nil
    ) throws -> AgentToolOperation {
        do {
            return try AgentToolOperation(
                provider: input.provider.wireName,
                providerBuild: context.providerBuild,
                adapterBuild: AdapterManifest.adapterBuild,
                agentSessionID: context.agentSessionID,
                nativeWaitID: context.nativeWaitID,
                providerSessionID: input.sessionID,
                providerTurnID: input.turnID,
                providerToolUseID: input.toolUseID,
                kind: kind,
                toolName: input.toolName,
                cwd: input.cwd,
                reason: reason,
                shellRequest: shellRequest,
                fileChanges: fileChanges,
                unavailable: context.unavailable.sorted(),
                nativeRequestSHA256: input.nativeRequestSHA256,
                contextSHA256: context.contextSHA256(for: input)
            )
        } catch let error as ValidationError {
            throw AdapterRefusal("limit_exceeded", error.description)
        }
    }

    private static func optionalText(_ value: JSONValue?, field: String) throws -> String? {
        guard let value, !value.isNull else { return nil }
        guard let text = value.stringValue else { throw AdapterRefusal("unsupported_input_schema", "\(field) is not a string") }
        return text.isEmpty ? nil : String(text.unicodeScalars.prefix(2048))
    }

    /// Rechecks what is locally observable before the gate is answered: the
    /// working directory and every committed file precondition.
    public static func recheck(_ operation: AgentToolOperation, fileSystem: any AdapterFileSystem = LocalFileSystem()) throws {
        if let cwd = operation.cwd, !fileSystem.isDirectory(cwd) {
            throw AdapterRefusal("native_context_changed", "the working directory is gone")
        }
        for change in operation.fileChanges ?? [] {
            let current = try fileSystem.contents(of: change.path, limit: maximumFileBytes)
            guard current.map({ ContentDigest.sha256Hex($0) }) == change.baseSHA256 else {
                throw AdapterRefusal("native_context_changed", "\(change.path) changed after review")
            }
        }
    }
}

extension String {
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = range(of: target) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}

/// Read-only file access for the mapper, injectable for tests.
public protocol AdapterFileSystem: Sendable {
    /// The file's bytes, nil when it does not exist; throws for anything that
    /// is not a regular file within `limit`.
    func contents(of path: String, limit: Int) throws -> Data?
    func isDirectory(_ path: String) -> Bool
}

public struct LocalFileSystem: AdapterFileSystem {
    public init() {}

    public func contents(of path: String, limit: Int) throws -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AdapterRefusal("unsupported_operation", "\(path) is not a regular file")
        }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= limit else {
            throw AdapterRefusal("limit_exceeded", "\(path) is too large to review inline")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// A single-hunk unified diff between the first and last differing lines.
/// It shows every changed line; it is complete rather than minimal.
public enum UnifiedDiff {
    public static func make(path: String, before: String?, after: String, context: Int = 3) -> String {
        let old = before.map(lines) ?? []
        let new = lines(after)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let start = max(0, prefix - context)
        let oldEnd = min(old.count, old.count - suffix + context)
        let newEnd = min(new.count, new.count - suffix + context)
        var output = "--- \(before == nil ? "/dev/null" : "a\(path)")\n+++ b\(path)\n"
        guard prefix < old.count || prefix < new.count else {
            // Identical lines can still differ in the final newline; that is
            // a change the reviewer must see.
            if let before, before != after { output += "\\ final newline \(after.hasSuffix("\n") ? "added" : "removed")\n" }
            return output
        }
        output += "@@ -\(start + (oldEnd > start ? 1 : 0)),\(oldEnd - start) +\(start + (newEnd > start ? 1 : 0)),\(newEnd - start) @@\n"
        for line in old[start..<prefix] { output += " \(line)\n" }
        for line in old[prefix..<(old.count - suffix)] { output += "-\(line)\n" }
        for line in new[prefix..<(new.count - suffix)] { output += "+\(line)\n" }
        for line in old[(old.count - suffix)..<oldEnd] { output += " \(line)\n" }
        if let before, before.hasSuffix("\n") != after.hasSuffix("\n") {
            output += "\\ final newline \(after.hasSuffix("\n") ? "added" : "removed")\n"
        }
        return output
    }

    private static func lines(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
