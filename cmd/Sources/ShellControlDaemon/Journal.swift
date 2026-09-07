import Foundation
import ShellControlProtocol

/// The daemon's durable dispatch journal.
///
/// The immutable question is persisted before it is published, and dispatch
/// intent is recorded before the native permission gate is answered, so a crash
/// is recoverable rather than ambiguous (spec.watch.md sections 12 and 17).
public struct DispatchJournal: Sendable {
    public enum Entry: Sendable, Hashable {
        case runStarted(runID: ControlID, jobID: ControlID)
        case requestPersisted(requestID: ControlID, requestHash: String, runID: ControlID)
        case requestPublished(requestID: ControlID)
        case decisionObserved(requestID: ControlID, decisionID: ControlID, resolution: Resolution)
        case claimed(requestID: ControlID, consumeID: ControlID, applyBefore: ControlTimestamp)
        case dispatchIntent(requestID: ControlID, consumeID: ControlID)
        case dispatchResult(requestID: ControlID, receiptID: ControlID, result: ReceiptResult)
        case withdrawn(requestID: ControlID)

        var json: JSONValue {
            switch self {
            case .runStarted(let runID, let jobID):
                return .object(["kind": "run_started", "run_id": JSONValue(runID), "job_id": JSONValue(jobID)])
            case .requestPersisted(let requestID, let hash, let runID):
                return .object([
                    "kind": "request_persisted",
                    "request_id": JSONValue(requestID),
                    "request_hash": .string(hash),
                    "run_id": JSONValue(runID),
                ])
            case .requestPublished(let requestID):
                return .object(["kind": "request_published", "request_id": JSONValue(requestID)])
            case .decisionObserved(let requestID, let decisionID, let resolution):
                return .object([
                    "kind": "decision_observed",
                    "request_id": JSONValue(requestID),
                    "decision_id": JSONValue(decisionID),
                    "resolution": .string(resolution.rawValue),
                ])
            case .claimed(let requestID, let consumeID, let applyBefore):
                return .object([
                    "kind": "claimed",
                    "request_id": JSONValue(requestID),
                    "consume_id": JSONValue(consumeID),
                    "apply_before": JSONValue(applyBefore),
                ])
            case .dispatchIntent(let requestID, let consumeID):
                return .object([
                    "kind": "dispatch_intent",
                    "request_id": JSONValue(requestID),
                    "consume_id": JSONValue(consumeID),
                ])
            case .dispatchResult(let requestID, let receiptID, let result):
                return .object([
                    "kind": "dispatch_result",
                    "request_id": JSONValue(requestID),
                    "receipt_id": JSONValue(receiptID),
                    "result": .string(result.rawValue),
                ])
            case .withdrawn(let requestID):
                return .object(["kind": "withdrawn", "request_id": JSONValue(requestID)])
            }
        }

        static func decode(_ value: JSONValue) throws -> Entry {
            var reader = try JSONReader(value)
            switch try reader.string("kind", maxLength: 32) {
            case "run_started":
                return .runStarted(runID: try reader.id("run_id"), jobID: try reader.id("job_id"))
            case "request_persisted":
                return .requestPersisted(
                    requestID: try reader.id("request_id"),
                    requestHash: try reader.string("request_hash", maxLength: 80),
                    runID: try reader.id("run_id")
                )
            case "request_published":
                return .requestPublished(requestID: try reader.id("request_id"))
            case "decision_observed":
                let resolutionText = try reader.string("resolution", maxLength: 16)
                return .decisionObserved(
                    requestID: try reader.id("request_id"),
                    decisionID: try reader.id("decision_id"),
                    resolution: Resolution(rawValue: resolutionText) ?? .pending
                )
            case "claimed":
                return .claimed(
                    requestID: try reader.id("request_id"),
                    consumeID: try reader.id("consume_id"),
                    applyBefore: try reader.timestamp("apply_before")
                )
            case "dispatch_intent":
                return .dispatchIntent(requestID: try reader.id("request_id"), consumeID: try reader.id("consume_id"))
            case "dispatch_result":
                let resultText = try reader.string("result", maxLength: 24)
                return .dispatchResult(
                    requestID: try reader.id("request_id"),
                    receiptID: try reader.id("receipt_id"),
                    result: ReceiptResult(rawValue: resultText) ?? .unknown
                )
            case "withdrawn":
                return .withdrawn(requestID: try reader.id("request_id"))
            default:
                throw ValidationError.unsupported("journal entry")
            }
        }
    }

    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    /// Appends and fsyncs, so the record survives the crash it exists for.
    public func append(_ entry: Entry) throws {
        var line = try JSONCanonicalization.canonicalize(entry.json)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    public func load() throws -> [Entry] {
        let data = try Data(contentsOf: url)
        return data.split(separator: 0x0A).compactMap { line in
            guard let value = try? JSONValue.parse(Data(line)) else { return nil }
            return try? Entry.decode(value)
        }
    }

    /// What the journal says is unfinished.
    public struct Recovery: Sendable {
        /// Claimed but never dispatched or receipted: the external effect is
        /// uncertain and must be reported `unknown`, never blindly replayed.
        public var uncertain: Set<ControlID> = []
        /// Persisted but never published, or published and still unresolved.
        public var unresolved: Set<ControlID> = []
    }

    public func recover() throws -> Recovery {
        var recovery = Recovery()
        var claimed: Set<ControlID> = []
        var intended: Set<ControlID> = []
        for entry in try load() {
            switch entry {
            case .requestPersisted(let requestID, _, _):
                recovery.unresolved.insert(requestID)
            case .decisionObserved(let requestID, _, let resolution) where resolution != .pending:
                recovery.unresolved.remove(requestID)
            case .claimed(let requestID, _, _):
                claimed.insert(requestID)
            case .dispatchIntent(let requestID, _):
                intended.insert(requestID)
            case .dispatchResult(let requestID, _, _):
                claimed.remove(requestID)
                intended.remove(requestID)
                recovery.unresolved.remove(requestID)
            case .withdrawn(let requestID):
                recovery.unresolved.remove(requestID)
                claimed.remove(requestID)
            default:
                break
            }
        }
        recovery.uncertain = claimed.union(intended)
        return recovery
    }
}
