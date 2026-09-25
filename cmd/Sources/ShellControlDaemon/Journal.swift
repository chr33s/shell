import Foundation
import ShellControlProtocol
import ShellControlHostSupport

/// The daemon's durable dispatch journal.
///
/// The immutable question is persisted before it is published, and dispatch
/// intent is recorded before the native permission gate is answered, so a crash
/// is recoverable rather than ambiguous (docs/specs/control-protocol.md sections 9.4 and 15).
public struct DispatchJournal: Sendable {
    public enum Entry: Sendable, Hashable {
        case runStarted(runID: ControlID, jobID: ControlID)
        case requestPersisted(requestID: ControlID, requestHash: String, runID: ControlID)
        case requestPublished(requestID: ControlID)
        case decisionObserved(requestID: ControlID, decisionID: ControlID, resolution: Resolution)
        /// The consume ID is persisted *before* the broker call, so a lost
        /// reply is retried with the same ID and the broker's idempotent
        /// consume returns the permit it already granted.
        case consumeIntent(requestID: ControlID, consumeID: ControlID, decisionID: ControlID)
        case claimed(requestID: ControlID, consumeID: ControlID, applyBefore: ControlTimestamp)
        case dispatchIntent(requestID: ControlID, consumeID: ControlID)
        case dispatchResult(requestID: ControlID, receiptID: ControlID, result: ReceiptResult)
        case withdrawn(requestID: ControlID)
        /// Captured exactly once at the process-start frontier, before new IPC
        /// work is admitted. Recurring workers consume this set; they never
        /// rediscover the growing live journal.
        case recoveryCandidate(requestID: ControlID, classification: String)
        case recoveryCandidateRetired(requestID: ControlID)
        /// Persist the recovery payload and mutation ID *before* the network write.
        case recoveryQueued(mutationID: ControlID, kind: String, requestID: ControlID, payload: String)
        case recoveryAcknowledged(mutationID: ControlID)
        /// `shell-agent/1` input records. The immutable input is persisted
        /// before it is published, the consume mutation ID before the claim,
        /// and every delivery state the adapter reports, so a crash leaves a
        /// withdrawal or an `unknown` receipt to send — never a replay
        /// (docs/specs/agent-relay.md section 8.3).
        case inputPersisted(requestID: ControlID, requestHash: String, runID: ControlID)
        case inputResolved(requestID: ControlID, resolution: String)
        case inputConsumeIntent(requestID: ControlID, mutationID: ControlID, commandID: ControlID)
        case inputClaimed(requestID: ControlID, permitID: ControlID, applyBefore: ControlTimestamp)
        case inputDelivery(requestID: ControlID, receiptID: ControlID, dispatch: String)

        var json: JSONValue {
            switch self {
            case .runStarted(let runID, let jobID):
                return .object(["kind": "run_started", "run_id": JSONValue(runID), "job_id": JSONValue(jobID)])
            case .requestPersisted(let requestID, let hash, let runID):
                return .object([
                    "kind": "request_persisted",
                    "request_id": JSONValue(requestID),
                    "request_hash": .string(hash),
                    "run_id": JSONValue(runID)
                ])
            case .requestPublished(let requestID):
                return .object(["kind": "request_published", "request_id": JSONValue(requestID)])
            case .decisionObserved(let requestID, let decisionID, let resolution):
                return .object([
                    "kind": "decision_observed",
                    "request_id": JSONValue(requestID),
                    "decision_id": JSONValue(decisionID),
                    "resolution": .string(resolution.rawValue)
                ])
            case .consumeIntent(let requestID, let consumeID, let decisionID):
                return .object([
                    "kind": "consume_intent",
                    "request_id": JSONValue(requestID),
                    "consume_id": JSONValue(consumeID),
                    "decision_id": JSONValue(decisionID)
                ])
            case .claimed(let requestID, let consumeID, let applyBefore):
                return .object([
                    "kind": "claimed",
                    "request_id": JSONValue(requestID),
                    "consume_id": JSONValue(consumeID),
                    "apply_before": JSONValue(applyBefore)
                ])
            case .dispatchIntent(let requestID, let consumeID):
                return .object([
                    "kind": "dispatch_intent",
                    "request_id": JSONValue(requestID),
                    "consume_id": JSONValue(consumeID)
                ])
            case .dispatchResult(let requestID, let receiptID, let result):
                return .object([
                    "kind": "dispatch_result",
                    "request_id": JSONValue(requestID),
                    "receipt_id": JSONValue(receiptID),
                    "result": .string(result.rawValue)
                ])
            case .withdrawn(let requestID):
                return .object(["kind": "withdrawn", "request_id": JSONValue(requestID)])
            case .recoveryCandidate(let requestID, let classification):
                return .object(["kind": "recovery_candidate", "request_id": JSONValue(requestID), "classification": .string(classification)])
            case .recoveryCandidateRetired(let requestID):
                return .object(["kind": "recovery_candidate_retired", "request_id": JSONValue(requestID)])
            case .recoveryQueued(let mutationID, let kind, let requestID, let payload):
                return .object([
                    "kind": "recovery_queued",
                    "mutation_id": JSONValue(mutationID),
                    "recovery_kind": .string(kind),
                    "request_id": JSONValue(requestID),
                    "payload": .string(payload)
                ])
            case .recoveryAcknowledged(let mutationID):
                return .object(["kind": "recovery_acknowledged", "mutation_id": JSONValue(mutationID)])
            case .inputPersisted(let requestID, let hash, let runID):
                return .object(["kind": "input_persisted", "request_id": JSONValue(requestID), "request_hash": .string(hash), "run_id": JSONValue(runID)])
            case .inputResolved(let requestID, let resolution):
                return .object(["kind": "input_resolved", "request_id": JSONValue(requestID), "resolution": .string(resolution)])
            case .inputConsumeIntent(let requestID, let mutationID, let commandID):
                return .object(["kind": "input_consume_intent", "request_id": JSONValue(requestID), "mutation_id": JSONValue(mutationID), "command_id": JSONValue(commandID)])
            case .inputClaimed(let requestID, let permitID, let applyBefore):
                return .object(["kind": "input_claimed", "request_id": JSONValue(requestID), "permit_id": JSONValue(permitID), "apply_before": JSONValue(applyBefore)])
            case .inputDelivery(let requestID, let receiptID, let dispatch):
                return .object(["kind": "input_delivery", "request_id": JSONValue(requestID), "receipt_id": JSONValue(receiptID), "dispatch": .string(dispatch)])
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
            case "consume_intent":
                return .consumeIntent(
                    requestID: try reader.id("request_id"),
                    consumeID: try reader.id("consume_id"),
                    decisionID: try reader.id("decision_id")
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
            case "recovery_candidate":
                let classification = try reader.string("classification", maxLength: 16)
                guard classification == "uncertain" || classification == "unresolved" else {
                    throw ValidationError.invalid("classification", "is not a recovery classification")
                }
                return .recoveryCandidate(requestID: try reader.id("request_id"), classification: classification)
            case "recovery_candidate_retired":
                return .recoveryCandidateRetired(requestID: try reader.id("request_id"))
            case "recovery_queued":
                return .recoveryQueued(
                    mutationID: try reader.id("mutation_id"),
                    kind: try reader.string("recovery_kind", maxLength: 32),
                    requestID: try reader.id("request_id"),
                    payload: try reader.string("payload", maxLength: 16_384)
                )
            case "recovery_acknowledged":
                return .recoveryAcknowledged(mutationID: try reader.id("mutation_id"))
            case "input_persisted":
                return .inputPersisted(requestID: try reader.id("request_id"), requestHash: try reader.string("request_hash", maxLength: 80), runID: try reader.id("run_id"))
            case "input_resolved":
                return .inputResolved(requestID: try reader.id("request_id"), resolution: try reader.string("resolution", maxLength: 16))
            case "input_consume_intent":
                return .inputConsumeIntent(requestID: try reader.id("request_id"), mutationID: try reader.id("mutation_id"), commandID: try reader.id("command_id"))
            case "input_claimed":
                return .inputClaimed(requestID: try reader.id("request_id"), permitID: try reader.id("permit_id"), applyBefore: try reader.timestamp("apply_before"))
            case "input_delivery":
                return .inputDelivery(requestID: try reader.id("request_id"), receiptID: try reader.id("receipt_id"), dispatch: try reader.string("dispatch", maxLength: 32))
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
    ///
    /// A write that fails part-way is cut back off: the next record must never
    /// be glued onto a torn one, which would corrupt the middle of the journal.
    public func append(_ entry: Entry) throws {
        var line = try JSONCanonicalization.canonicalize(entry.json)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let offset = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch {
            try? handle.truncate(atOffset: offset)
            try? handle.synchronize()
            throw error
        }
    }

    /// Every record, in order.
    ///
    /// An unterminated, unparseable final record is an `append` torn by a
    /// crash: that append never returned, so nothing acted on it, and it is not
    /// a record. Corruption anywhere else still fails closed; only
    /// `repairAtStartup` may set it aside (docs/specs/control-cli.md section 9.2).
    public func load() throws -> [Entry] {
        let scan = Self.scan(try Data(contentsOf: url))
        if let line = scan.corruptLines.first {
            throw ValidationError.invalid("journal", "has a corrupt record at line \(line)")
        }
        return scan.entries
    }

    struct Scan {
        var entries: [Entry] = []
        /// The byte ranges of the records that decoded, in order.
        var validRanges: [Range<Int>] = []
        /// 1-based line numbers of terminated records that do not decode.
        var corruptLines: [Int] = []
        /// Where an unterminated, unparseable final record begins.
        var tornTailOffset: Int?
        /// A final record that decodes but whose newline never landed.
        var unterminatedTail = false
    }

    static func scan(_ data: Data) -> Scan {
        var scan = Scan()
        let bytes = [UInt8](data)
        var start = 0
        var lineNumber = 0
        while start < bytes.count {
            lineNumber += 1
            let newline = bytes[start...].firstIndex(of: 0x0A)
            let end = newline ?? bytes.count
            let line = Data(bytes[start..<end])
            let entry = line.isEmpty ? nil : try? Entry.decode(try JSONValue.parse(line))
            if let entry {
                scan.entries.append(entry)
                scan.validRanges.append(start..<end)
                if newline == nil { scan.unterminatedTail = true }
            } else if newline == nil {
                scan.tornTailOffset = start
            } else {
                scan.corruptLines.append(lineNumber)
            }
            guard let newline else { break }
            start = newline + 1
        }
        return scan
    }

    /// What `repairAtStartup` had to do before the frontier could be read.
    public struct Repair: Sendable, Equatable {
        /// A crash tore the final `append`; its bytes were cut off.
        public var discardedTornTail = false
        /// A complete final record was missing its newline; one was added.
        public var terminatedFinalRecord = false
        /// Mid-file corruption: the original journal is preserved here, and
        /// the live journal holds only the records that still decode.
        public var quarantinedTo: URL?
        /// 1-based line numbers of the records that could not be kept.
        public var discardedLines: [Int] = []

        public var isEmpty: Bool { self == Repair() }
    }

    /// Makes the journal loadable before the startup frontier is captured, so
    /// a crash mid-`append` or a damaged record cannot crash-loop the daemon.
    ///
    /// A torn final record is dropped: its append never returned. Mid-file
    /// corruption is not silently skipped: the whole original file is kept as
    /// `<journal>.corrupt-<unix time>` and reported, and the live journal is
    /// rebuilt from every record that still decodes. Starting empty instead
    /// would also drop every readable obligation, and refusing to start would
    /// block all approvals until someone edits the file by hand.
    public func repairAtStartup(at date: Date = Date()) throws -> Repair {
        let data = try Data(contentsOf: url)
        let scan = Self.scan(data)
        var repair = Repair()
        guard scan.corruptLines.isEmpty else {
            let quarantine = try quarantineCopy(at: date)
            var salvaged = Data()
            for range in scan.validRanges {
                salvaged.append(data[data.startIndex + range.lowerBound ..< data.startIndex + range.upperBound])
                salvaged.append(0x0A)
            }
            try SecureFileSystem.atomicWrite(salvaged, to: url)
            repair.quarantinedTo = quarantine
            repair.discardedLines = scan.corruptLines
            repair.discardedTornTail = scan.tornTailOffset != nil
            return repair
        }
        if let torn = scan.tornTailOffset {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(torn))
            try handle.synchronize()
            repair.discardedTornTail = true
        } else if scan.unterminatedTail {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x0A]))
            try handle.synchronize()
            repair.terminatedFinalRecord = true
        }
        return repair
    }

    private func quarantineCopy(at date: Date) throws -> URL {
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent("\(url.lastPathComponent).corrupt-\(Int(date.timeIntervalSince1970))")
        if FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(candidate.lastPathComponent)-\(UUID().uuidString.lowercased())")
        }
        try FileManager.default.copyItem(at: url, to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
        return candidate
    }

    /// Immutable process-start boundary. The caller captures this before
    /// accepting adapters and passes the value to recovery discovery once.
    public func startupFrontier() throws -> [Entry] { try load() }

    /// What the journal says is unfinished.
    public struct Recovery: Sendable {
        /// Claimed but never dispatched or receipted: the external effect is
        /// uncertain and must be reported `unknown`, never blindly replayed.
        public var uncertain: Set<ControlID> = []
        /// Persisted but never published, or published and still unresolved.
        public var unresolved: Set<ControlID> = []
        /// The journaled consume ID of each uncertain request, so recovery
        /// reuses it rather than minting one the broker would refuse.
        public var consumes: [ControlID: ConsumeRecord] = [:]
    }

    public struct ConsumeRecord: Sendable, Hashable {
        public var consumeID: ControlID
        /// Whether the broker's permit for this consume ID was ever recorded
        /// locally. Without it the permit never reached an adapter.
        public var claimRecorded: Bool
    }

    public func recover() throws -> Recovery { try recover(at: startupFrontier()) }

    public func recover(at frontier: [Entry]) throws -> Recovery {
        var recovery = Recovery()
        var claimed: Set<ControlID> = []
        var intended: Set<ControlID> = []
        // A consume intent without a recorded claim: the broker may have
        // committed the claim and lost the reply.
        var consuming: Set<ControlID> = []
        for entry in frontier {
            switch entry {
            case .requestPersisted(let requestID, _, _):
                recovery.unresolved.insert(requestID)
            case .decisionObserved(let requestID, _, let resolution) where resolution != .pending:
                recovery.unresolved.remove(requestID)
            case .consumeIntent(let requestID, let consumeID, _):
                consuming.insert(requestID)
                recovery.consumes[requestID] = ConsumeRecord(consumeID: consumeID, claimRecorded: false)
            case .claimed(let requestID, let consumeID, _):
                claimed.insert(requestID)
                recovery.consumes[requestID] = ConsumeRecord(consumeID: consumeID, claimRecorded: true)
            case .dispatchIntent(let requestID, let consumeID):
                intended.insert(requestID)
                recovery.consumes[requestID] = ConsumeRecord(consumeID: consumeID, claimRecorded: true)
            case .dispatchResult(let requestID, _, _):
                claimed.remove(requestID)
                intended.remove(requestID)
                consuming.remove(requestID)
                recovery.unresolved.remove(requestID)
            case .withdrawn(let requestID):
                recovery.unresolved.remove(requestID)
                claimed.remove(requestID)
                consuming.remove(requestID)
            default:
                break
            }
        }
        recovery.uncertain = claimed.union(intended).union(consuming)
        recovery.consumes = recovery.consumes.filter { recovery.uncertain.contains($0.key) }
        return recovery
    }

    public func pendingStartupCandidates() throws -> [ControlID: String] {
        var candidates: [ControlID: String] = [:]
        for entry in try load() {
            switch entry {
            case .recoveryCandidate(let requestID, let classification): candidates[requestID] = classification
            case .recoveryCandidateRetired(let requestID): candidates[requestID] = nil
            default: break
            }
        }
        return candidates
    }

    public struct QueuedRecovery: Sendable {
        public var mutationID: ControlID
        public var kind: String
        public var requestID: ControlID
        public var payload: String
    }

    public func pendingRecoveries() throws -> [QueuedRecovery] {
        var queued: [ControlID: QueuedRecovery] = [:]
        var acknowledged: Set<ControlID> = []
        for entry in try load() {
            switch entry {
            case .recoveryQueued(let mutationID, let kind, let requestID, let payload):
                queued[mutationID] = QueuedRecovery(
                    mutationID: mutationID,
                    kind: kind,
                    requestID: requestID,
                    payload: payload
                )
            case .recoveryAcknowledged(let mutationID):
                acknowledged.insert(mutationID)
            default:
                break
            }
        }
        return queued.values.filter { !acknowledged.contains($0.mutationID) }
    }

    /// What the journal says about agent inputs after a restart.
    public struct InputRecovery: Sendable {
        public struct Item: Sendable, Hashable {
            public var requestHash: String
            public var runID: ControlID
            public var permitID: ControlID?
            public var commandID: ControlID?
            public var consumeMutationID: ControlID?
            /// The last delivery state the adapter reported, if any.
            public var dispatch: String?
        }
        /// Published and never observed resolved: the adapter that waited on
        /// it is gone with the old process, so it is withdrawn.
        public var pending: [ControlID: Item] = [:]
        /// Claimed, with no terminal delivery: the effect is uncertain and is
        /// reported `unknown`, never replayed.
        public var uncertain: [ControlID: Item] = [:]
        /// A consume intent with no recorded claim: the broker may hold a
        /// claim whose reply was lost. Nothing was dispatched.
        public var stranded: [ControlID: Item] = [:]
    }

    public func recoverInputs(at frontier: [Entry]) -> InputRecovery {
        var items: [ControlID: InputRecovery.Item] = [:]
        var resolved: Set<ControlID> = []
        var terminal: Set<ControlID> = []
        for entry in frontier {
            switch entry {
            case .inputPersisted(let requestID, let hash, let runID):
                items[requestID] = .init(requestHash: hash, runID: runID)
            case .inputResolved(let requestID, _):
                resolved.insert(requestID)
            case .inputConsumeIntent(let requestID, let mutationID, let commandID):
                items[requestID]?.commandID = commandID
                items[requestID]?.consumeMutationID = mutationID
            case .inputClaimed(let requestID, let permitID, _):
                items[requestID]?.permitID = permitID
            case .inputDelivery(let requestID, _, let dispatch):
                items[requestID]?.dispatch = dispatch
                if let state = AgentDispatch(rawValue: dispatch), state.isTerminal || state == .nativeResponseWritten {
                    terminal.insert(requestID)
                }
            case .withdrawn(let requestID):
                terminal.insert(requestID)
            default:
                break
            }
        }
        var recovery = InputRecovery()
        for (requestID, item) in items where !terminal.contains(requestID) {
            if item.permitID != nil {
                recovery.uncertain[requestID] = item
            } else if item.consumeMutationID != nil {
                recovery.stranded[requestID] = item
            } else if !resolved.contains(requestID) {
                recovery.pending[requestID] = item
            }
        }
        return recovery
    }
}
