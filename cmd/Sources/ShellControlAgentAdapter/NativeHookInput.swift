import Foundation
import ShellControlProtocol

/// Why an adapter hands a native prompt back to the terminal instead of
/// publishing it. The terminal prompt is then the only review.
public struct AdapterRefusal: Error, Sendable, Hashable, CustomStringConvertible {
    public let code: String
    public let detail: String

    public init(_ code: String, _ detail: String) {
        self.code = code
        self.detail = detail
    }

    public var description: String { "\(code): \(detail)" }
}

/// One decoded native hook invocation. Input is parsed, never evaluated.
public struct NativeHookInput: Sendable, Hashable {
    public enum Event: String, Sendable, Hashable {
        case permissionRequest = "PermissionRequest"
        case preToolUse = "PreToolUse"
    }

    public let provider: AgentProvider
    public let event: Event
    public let sessionID: String?
    public let turnID: String?
    public let cwd: String
    public let permissionMode: String?
    public let toolName: String
    public let toolInput: JSONValue
    /// Never fabricated when the provider does not send one.
    public let toolUseID: String?
    /// The exact parsed input, retained host-local for the native request
    /// commitment and the response.
    public let raw: JSONValue

    /// SHA-256 over the canonical native input (spec.agent-relay.md 6.2).
    public var nativeRequestSHA256: String {
        ContentDigest.sha256Hex((try? JSONCanonicalization.canonicalize(raw)) ?? Data())
    }

    /// The limits a hook input is parsed under: the 256 KiB host cap, and
    /// strings long enough for a real diff or command.
    public static let limits = JSONLimits(
        maxDocumentBytes: AgentPolicy.maximumNativeInputBytes,
        maxStringCharacters: AgentPolicy.maximumNativeInputBytes,
        maxNestingDepth: 32,
        maxCollectionElements: 4096
    )

    /// Decodes one provider's hook input. Each provider has its own decoder:
    /// they share normalized types, not assumptions about field coverage
    /// (spec.agent-relay.md 11.1).
    public static func decode(_ data: Data, provider: AgentProvider) throws -> NativeHookInput {
        guard data.count <= AgentPolicy.maximumNativeInputBytes else {
            throw AdapterRefusal("limit_exceeded", "native input exceeds \(AgentPolicy.maximumNativeInputBytes) bytes")
        }
        let raw: JSONValue
        do { raw = try JSONValue.parse(data, limits: limits) } catch {
            throw AdapterRefusal("unsupported_input_schema", "native input is not strict JSON: \(error)")
        }
        guard let members = raw.objectValue else { throw AdapterRefusal("unsupported_input_schema", "native input is not an object") }
        func string(_ name: String, required: Bool = false) throws -> String? {
            guard let value = members[name], !value.isNull else {
                if required { throw AdapterRefusal("unsupported_input_schema", "missing \(name)") }
                return nil
            }
            guard let text = value.stringValue else { throw AdapterRefusal("unsupported_input_schema", "\(name) is not a string") }
            return text
        }
        let eventText = try string("hook_event_name", required: true) ?? ""
        guard let event = Event(rawValue: eventText) else {
            throw AdapterRefusal("unsupported_operation", "hook event \(eventText) is not handled")
        }
        let cwd = try string("cwd", required: true) ?? ""
        guard cwd.hasPrefix("/") else { throw AdapterRefusal("unsupported_input_schema", "cwd is not absolute") }
        let toolName = try string("tool_name", required: true) ?? ""
        guard let toolInput = members["tool_input"], toolInput.objectValue != nil else {
            throw AdapterRefusal("unsupported_input_schema", "tool_input is not an object")
        }
        switch provider {
        case .claudeCode:
            break
        case .codex:
            // Codex hooks answer permission requests only in this build.
            guard event == .permissionRequest else {
                throw AdapterRefusal("unsupported_operation", "Codex \(eventText) is not handled")
            }
        }
        return NativeHookInput(
            provider: provider,
            event: event,
            sessionID: try string("session_id"),
            turnID: try string("turn_id"),
            cwd: cwd,
            permissionMode: try string("permission_mode"),
            toolName: toolName,
            toolInput: toolInput,
            toolUseID: try string("tool_use_id"),
            raw: raw
        )
    }

    /// The native route this input belongs to, if any.
    public var route: NativeRoute? {
        switch (event, toolName) {
        case (.permissionRequest, "Bash"): return .permissionShell
        case (.permissionRequest, "Edit"), (.permissionRequest, "Write"):
            return provider == .claudeCode ? .permissionFileChange : nil
        case (.preToolUse, "AskUserQuestion"):
            return provider == .claudeCode ? .askUserQuestion : nil
        default: return nil
        }
    }
}
