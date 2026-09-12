import Foundation
import ShellControlHostSupport
import ShellControlProtocol

public struct AdapterClient: Sendable {
    public let client: UnixSocketClient
    public init(stateDirectory: URL) { client = UnixSocketClient(path: stateDirectory.appendingPathComponent("control.sock").path) }

    public func hello(adapter: String, jobLabel: String, jobID: ControlID?, capabilities: [String]) async throws -> (String, ControlID) {
        let response = try await client.exchangeAsync(IPCRequest(messageID: .random(), type: .hello, runCapability: nil, body: JSONWriter.object([
            "protocol": .string(ServiceCapabilities.protocolName), "adapter": .string(adapter), "job_label": .string(jobLabel),
            "job_id": jobID.map(JSONValue.init), "capabilities": JSONValue(strings: capabilities),
            "operation_schemas": JSONValue(strings: [ExecOperation.schema]),
        ])), timeout: 8)
        guard response.ok else { throw ManagementError.unavailable(response.errorMessage ?? "adapter hello rejected") }
        var reader = try JSONReader(response.body)
        return (try reader.string("run_capability", maxLength: 128), try reader.id("run_id"))
    }

    public func notify(title: String, body: String?, kind: String, adapter: String, jobLabel: String?, jobID: ControlID?) async throws -> JSONValue {
        let (capability, _) = try await hello(adapter: adapter, jobLabel: jobLabel ?? title, jobID: jobID, capabilities: [])
        let response = try await client.exchangeAsync(IPCRequest(messageID: .random(), type: .notify, runCapability: capability, body: JSONWriter.object([
            "kind": .string(kind), "title": .string(title), "body": body.map(JSONValue.string),
        ])), timeout: 8)
        guard response.ok else { throw ManagementError.unavailable(response.errorMessage ?? "notification rejected") }
        return response.body
    }

    public func request(specURL: URL, wait: Bool, timeout: Int) async throws -> (JSONValue, Int32) {
        let attributes = try FileManager.default.attributesOfItem(atPath: specURL.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= JSONLimits.maxDocumentBytes else {
            throw ManagementError.invalid("request specification exceeds the JSON size limit")
        }
        let data = try Data(contentsOf: specURL); let value = try JSONValue.parse(data); var reader = try JSONReader(value)
        let summary = try reader.string("summary", maxLength: 200), operation = try reader.value("operation")
        _ = try ExecOperation(json: operation)
        let adapter = try reader.optionalString("adapter", maxLength: 64) ?? "cli"
        let jobLabel = try reader.optionalString("job_label", maxLength: 120) ?? summary
        let jobID = try reader.optionalID("job_id")
        let lifetime = try reader.optionalInteger("lifetime_seconds")
        if let lifetime, lifetime <= 0 || lifetime > Int64(ApprovalPolicy.maximumLifetime) {
            throw ManagementError.invalid("lifetime_seconds must be positive and no greater than \(Int(ApprovalPolicy.maximumLifetime))")
        }
        let minimumReview = try reader.optionalString("minimum_review", maxLength: 16)
        if let minimumReview, MinimumReview(rawValue: minimumReview) == nil {
            throw ManagementError.invalid("minimum_review is unsupported")
        }
        var capabilities: [String] = []
        if let rawCapabilities = reader.optionalValue("capabilities") {
            guard let array = rawCapabilities.arrayValue, array.count <= 64 else { throw ManagementError.invalid("capabilities must be a bounded string array") }
            capabilities = try array.map { value in
                guard let capability = value.stringValue, !capability.isEmpty, capability.count <= 128 else {
                    throw ManagementError.invalid("capabilities must contain bounded strings")
                }
                return capability
            }
        }
        try reader.rejectUnknownMembers()
        let (capability, _) = try await hello(adapter: adapter, jobLabel: jobLabel, jobID: jobID, capabilities: capabilities)
        let created = try await client.exchangeAsync(IPCRequest(messageID: .random(), type: .approvalRequest, runCapability: capability, body: JSONWriter.object([
            "summary": .string(summary), "operation": operation,
            "lifetime_seconds": lifetime.map { .number(.int($0)) },
            "minimum_review": minimumReview.map(JSONValue.string),
        ])), timeout: 8)
        guard created.ok else { throw ManagementError.unavailable(created.errorMessage ?? "request rejected") }
        guard wait else { return (created.body, 0) }
        var createdReader = try JSONReader(created.body)
        let id = try createdReader.id("request_id"), hash = try createdReader.string("request_hash", maxLength: 80)
        let waited = try await client.exchangeAsync(IPCRequest(messageID: .random(), type: .approvalWait, runCapability: capability, body: .object([
            "request_id": JSONValue(id), "request_hash": .string(hash), "timeout_seconds": .number(.int(Int64(timeout))),
        ])), timeout: TimeInterval(timeout + 30))
        guard waited.ok else { throw ManagementError.unavailable(waited.errorMessage ?? "wait failed") }
        let outcome = try ApprovalWaitOutcome(json: waited.body)
        return (.object(["result": waited.body, "request_id": JSONValue(id), "run_capability": .string(capability)]), outcome.exitCode.rawValue)
    }

    public func receipt(capability: String, result: String, request: ControlID?, decision: ControlID?, consume: ControlID?,
                        requestHash: String?, reason: String?) async throws -> JSONValue {
        let response = try await client.exchangeAsync(IPCRequest(messageID: .random(), type: .receipt, runCapability: capability, body: JSONWriter.object([
            "result": .string(result), "request_id": request.map(JSONValue.init), "decision_id": decision.map(JSONValue.init),
            "consume_id": consume.map(JSONValue.init), "request_hash": requestHash.map(JSONValue.string),
            "reason_code": reason.map(JSONValue.string),
        ])), timeout: 8)
        guard response.ok else { throw ManagementError.unavailable(response.errorMessage ?? "receipt rejected") }
        return response.body
    }
}
