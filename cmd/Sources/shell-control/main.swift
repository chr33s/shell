import Foundation
import ShellControlDaemon
import ShellControlProtocol

// The CLI adapters call. stdout is machine-readable JSON only; diagnostics go
// to stderr, and a nonzero exit never authorizes anything
// (spec.watch.md section 17).
struct CLI {
    let socketPath: String
    let client: UnixSocketClient

    init() {
        let environment = ProcessInfo.processInfo.environment
        let stateDirectory = environment["SHELL_CONTROL_STATE_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/shell-control").path
        socketPath = environment["SHELL_CONTROL_SOCKET"] ?? "\(stateDirectory)/control.sock"
        client = UnixSocketClient(path: socketPath)
    }

    static func fail(_ message: String, code: ControlExitCode = .unavailable) -> Never {
        FileHandle.standardError.write(Data("shell-control: \(message)\n".utf8))
        exit(code.rawValue)
    }

    static func emit(_ value: JSONValue) {
        let data = (try? JSONCanonicalization.canonicalize(value)) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    func hello(adapter: String, jobLabel: String, jobID: ControlID?, capabilities: [String]) throws -> (capability: String, runID: ControlID, jobID: ControlID) {
        let response = try client.exchange(IPCRequest(
            messageID: .random(),
            type: .hello,
            runCapability: nil,
            body: JSONWriter.object([
                "protocol": .string(ServiceCapabilities.protocolName),
                "adapter": .string(adapter),
                "job_label": .string(jobLabel),
                "job_id": jobID.map { JSONValue($0) },
                "capabilities": JSONValue(strings: capabilities),
                "operation_schemas": JSONValue(strings: [ExecOperation.schema]),
            ])
        ))
        guard response.ok else {
            CLI.fail(response.errorMessage ?? "hello rejected")
        }
        var reader = try JSONReader(response.body)
        return (
            try reader.string("run_capability", maxLength: 128),
            try reader.id("run_id"),
            try reader.id("job_id")
        )
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let subcommand = arguments.first else {
    CLI.fail("usage: shell-control <notify|request|receipt> [options]")
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let cli = CLI()

switch subcommand {
case "notify":
    guard let title = option("title") else { CLI.fail("--title is required") }
    let jobID = option("job").flatMap(ControlID.init)
    let binding = try cli.hello(
        adapter: option("adapter") ?? "cli",
        jobLabel: option("job-label") ?? title,
        jobID: jobID,
        capabilities: []
    )
    let response = try cli.client.exchange(IPCRequest(
        messageID: .random(),
        type: .notify,
        runCapability: binding.capability,
        body: JSONWriter.object([
            "kind": .string(option("kind") ?? NotificationKind.attention.rawValue),
            "title": .string(title),
            "body": option("body").map { .string($0) },
        ])
    ))
    guard response.ok else { CLI.fail(response.errorMessage ?? "notify failed") }
    CLI.emit(response.body)
    exit(0)

case "request":
    guard let specPath = option("spec-file") else { CLI.fail("--spec-file is required") }
    guard let data = FileManager.default.contents(atPath: specPath) else { CLI.fail("cannot read \(specPath)") }
    let specValue = try JSONValue.parse(data)
    var specReader = try JSONReader(specValue)
    let summary = try specReader.string("summary", maxLength: 200)
    let operation = try specReader.value("operation")
    let jobID = try specReader.optionalID("job_id")
    let binding = try cli.hello(
        adapter: try specReader.optionalString("adapter", maxLength: 64) ?? "cli",
        jobLabel: try specReader.optionalString("job_label", maxLength: 120) ?? summary,
        jobID: jobID,
        capabilities: try specReader.optionalValue("capabilities").flatMap { $0.arrayValue?.compactMap(\.stringValue) } ?? []
    )
    let created = try cli.client.exchange(IPCRequest(
        messageID: .random(),
        type: .approvalRequest,
        runCapability: binding.capability,
        body: JSONWriter.object([
            "summary": .string(summary),
            "operation": operation,
            "lifetime_seconds": try specReader.optionalInteger("lifetime_seconds").map { .number(.int($0)) },
            "minimum_review": try specReader.optionalString("minimum_review", maxLength: 16).map { .string($0) },
        ])
    ))
    guard created.ok else { CLI.fail(created.errorMessage ?? "request rejected") }
    var createdReader = try JSONReader(created.body)
    let requestID = try createdReader.id("request_id")
    let requestHash = try createdReader.string("request_hash", maxLength: 80)
    guard arguments.contains("--wait") else {
        CLI.emit(created.body)
        exit(0)
    }
    let waited = try cli.client.exchange(
        IPCRequest(
            messageID: .random(),
            type: .approvalWait,
            runCapability: binding.capability,
            body: .object([
                "request_id": JSONValue(requestID),
                "request_hash": .string(requestHash),
                "timeout_seconds": .number(.int(Int64(option("timeout").flatMap(Int.init) ?? 600))),
            ])
        ),
        timeout: TimeInterval((option("timeout").flatMap(Int.init) ?? 600) + 30)
    )
    guard waited.ok else { CLI.fail(waited.errorMessage ?? "wait failed") }
    let outcome = try ApprovalWaitOutcome(json: waited.body)
    // The caller must still validate this structured result and report what it
    // actually applied by receipt; the exit code alone is not permission.
    CLI.emit(.object([
        "result": waited.body,
        "request_id": JSONValue(requestID),
        "run_capability": .string(binding.capability),
    ]))
    exit(outcome.exitCode.rawValue)

case "receipt":
    guard let capability = option("run-capability") else { CLI.fail("--run-capability is required") }
    guard let result = option("result") else { CLI.fail("--result is required") }
    let response = try cli.client.exchange(IPCRequest(
        messageID: .random(),
        type: .receipt,
        runCapability: capability,
        body: JSONWriter.object([
            "result": .string(result),
            "request_id": option("request").flatMap(ControlID.init).map { JSONValue($0) },
            "decision_id": option("decision").flatMap(ControlID.init).map { JSONValue($0) },
            "consume_id": option("consume").flatMap(ControlID.init).map { JSONValue($0) },
            "request_hash": option("request-hash").map { .string($0) },
            "reason_code": option("reason").map { .string($0) },
        ])
    ))
    guard response.ok else { CLI.fail(response.errorMessage ?? "receipt rejected") }
    CLI.emit(response.body)
    exit(0)

default:
    CLI.fail("unknown subcommand \(subcommand)")
}
