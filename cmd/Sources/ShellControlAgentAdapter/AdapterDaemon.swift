import Foundation
import ShellControlProtocol
import ShellControlHostSupport

/// The adapter's view of `shell-controld`: authenticated per-user IPC and a
/// per-run capability that never leaves this process — not in tmux options,
/// arguments, hook configuration, or logs (docs/specs/agent-relay.md 4.2).
public protocol AdapterDaemon: Sendable {
    func exchange(_ type: IPCMessageType, capability: String?, body: JSONValue, timeout: TimeInterval) async throws -> JSONValue
}

public struct AdapterDaemonError: Error, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
}

/// Unix-socket transport: one connection per message, so the socket held
/// open by a wait is the native wait's liveness signal to the daemon.
public struct SocketAdapterDaemon: AdapterDaemon {
    let client: UnixSocketClient

    public init(socketPath: String) { client = UnixSocketClient(path: socketPath) }

    public func exchange(_ type: IPCMessageType, capability: String?, body: JSONValue, timeout: TimeInterval) async throws -> JSONValue {
        let response = try await client.exchangeAsync(
            IPCRequest(messageID: .random(), type: type, runCapability: capability, body: body),
            timeout: timeout
        )
        guard response.ok else {
            throw AdapterDaemonError(code: response.errorCode ?? "unavailable", message: response.errorMessage ?? "rejected")
        }
        return response.body
    }
}

/// One registered run of an adapter: the capability plus the agent session
/// it is bound to.
public struct AdapterRun: Sendable {
    public let daemon: any AdapterDaemon
    public let capability: String
    public let runID: ControlID
    public var agentSessionID: ControlID?

    public static func start(daemon: any AdapterDaemon, adapter: String, jobLabel: String) async throws -> AdapterRun {
        let body = try await daemon.exchange(.hello, capability: nil, body: .object([
            "protocol": .string(ServiceCapabilities.protocolName),
            "adapter": .string(adapter),
            "job_label": .string(String(jobLabel.unicodeScalars.prefix(120))),
            "capabilities": JSONValue(strings: [ControlFeature.consume]),
            "operation_schemas": JSONValue(strings: [AgentToolOperation.schema])
        ]), timeout: 8)
        var reader = try JSONReader(body)
        return AdapterRun(
            daemon: daemon,
            capability: try reader.string("run_capability", maxLength: 128),
            runID: try reader.id("run_id"),
            agentSessionID: nil
        )
    }

    public mutating func register(_ body: JSONValue) async throws {
        var reader = try JSONReader(try await send(.agentRegister, body))
        agentSessionID = try reader.id("agent_session_id")
    }

    public func send(_ type: IPCMessageType, _ body: JSONValue, timeout: TimeInterval = 8) async throws -> JSONValue {
        try await daemon.exchange(type, capability: capability, body: body, timeout: timeout)
    }
}
