import ArgumentParser
import Foundation
import ShellControlManagement
import ShellControlProtocol

struct NotifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "notify")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Option var title: String
    @Option var body: String?
    @Option var kind = "attention"
    @Option var adapter = "cli"
    @Option(name: .customLong("job-label")) var jobLabel: String?
    @Option var job: String?
    mutating func validate() throws {
        guard !title.isEmpty, title.count <= 120 else { throw ValidationError("--title must contain 1 through 120 characters") }
        guard body?.count ?? 0 <= 1000 else { throw ValidationError("--body must not exceed 1000 characters") }
        guard NotificationKind(rawValue: kind) != nil else { throw ValidationError("--kind is unsupported") }
        guard !adapter.isEmpty, adapter.count <= 64, jobLabel?.count ?? 0 <= 120 else { throw ValidationError("adapter metadata is invalid") }
        if let job, ControlID(job) == nil { throw ValidationError("--job must be a lowercase UUID") }
    }
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state
        let title = title, body = body, kind = kind, adapter = adapter, label = jobLabel, job = job
        try await execute {
            let root = try state.root(inherited)
            let id = try job.map { value -> ControlID in
                guard let id = ControlID(value) else { throw ManagementError.invalid("--job must be a lowercase UUID") }
                return id
            }
            try emitJSON(await AdapterClient(stateDirectory: root).notify(
                title: title, body: body, kind: kind, adapter: adapter, jobLabel: label, jobID: id
            ))
        }
    }
}

struct RequestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "request")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Option(help: "Absolute approval specification JSON.") var specFile: String
    @Flag var wait = false
    @Option(help: "Wait timeout in seconds.") var timeout = 600
    @Option(help: "Output format (json).") var output = "json"
    mutating func validate() throws {
        guard specFile.hasPrefix("/") else { throw ValidationError("--spec-file must be absolute") }
        guard (1...86_400).contains(timeout) else { throw ValidationError("--timeout must be from 1 through 86400") }
        guard output == "json" else { throw ValidationError("--output must be json") }
    }
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state, file = specFile, waiting = wait, timeout = timeout
        try await execute {
            let result = try await AdapterClient(stateDirectory: try state.root(inherited)).request(
                specURL: URL(fileURLWithPath: file), wait: waiting, timeout: timeout
            )
            try emitJSON(result.0)
            if result.1 != 0 { throw ExitCode(result.1) }
        }
    }
}

struct ReceiptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "receipt")
    @ParentCommand var parent: ShellControlCommand
    @OptionGroup var state: StateOptions
    @Option var runCapability: String
    @Option var result: String
    @Option var request: String?
    @Option var decision: String?
    @Option var consume: String?
    @Option var requestHash: String?
    @Option var reason: String?
    mutating func validate() throws {
        guard !runCapability.isEmpty, runCapability.count <= 128 else { throw ValidationError("--run-capability is invalid") }
        guard ReceiptResult(rawValue: result) != nil else { throw ValidationError("--result is unsupported") }
        if let requestHash, requestHash.count > 80 { throw ValidationError("--request-hash is too long") }
        if let reason, reason.count > 64 { throw ValidationError("--reason is too long") }
        for value in [request, decision, consume].compactMap({ $0 }) where ControlID(value) == nil {
            throw ValidationError("receipt identifiers must be lowercase UUIDs")
        }
    }
    mutating func run() async throws {
        let inherited = parent.state.stateDirectory, state = state
        let capability = runCapability, result = result, values = [request, decision, consume]
        let hash = requestHash, reason = reason
        try await execute {
            let root = try state.root(inherited)
            let ids = try values.map { value -> ControlID? in
                guard let value else { return nil }
                guard let id = ControlID(value) else { throw ManagementError.invalid("receipt identifiers must be lowercase UUIDs") }
                return id
            }
            try emitJSON(await AdapterClient(stateDirectory: root).receipt(
                capability: capability, result: result, request: ids[0], decision: ids[1], consume: ids[2],
                requestHash: hash, reason: reason
            ))
        }
    }
}
