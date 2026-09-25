import Foundation
import ShellControlProtocol
import Synchronization

/// A command this device signed and whose outcome it has not yet confirmed.
///
/// Persisted separately from the projection cache, so a snapshot refresh cannot
/// erase an ambiguous submitted decision (spec.watch.md section 15).
public struct PendingCommand: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case sending
        case decisionRecorded = "decision_recorded"
        case outcomeUnknown = "outcome_unknown"
    }

    public let commandID: ControlID
    public let signedCommand: String
    /// The base command type, or nil for a `shell-agent/1` command.
    public let type: ControlCommandType?
    /// The agent command type; reconciled only through the agent endpoints
    /// (spec.agent-relay.md section 8.3).
    public let agentType: AgentCommandType?
    public let targetID: ControlID
    public let notAfter: ControlTimestamp
    public var status: Status

    public init(
        commandID: ControlID,
        signedCommand: String,
        type: ControlCommandType,
        targetID: ControlID,
        notAfter: ControlTimestamp,
        status: Status = .sending
    ) {
        self.commandID = commandID
        self.signedCommand = signedCommand
        self.type = type
        self.agentType = nil
        self.targetID = targetID
        self.notAfter = notAfter
        self.status = status
    }

    public init(
        commandID: ControlID,
        signedCommand: String,
        agentType: AgentCommandType,
        targetID: ControlID,
        notAfter: ControlTimestamp,
        status: Status = .sending
    ) {
        self.commandID = commandID
        self.signedCommand = signedCommand
        self.type = nil
        self.agentType = agentType
        self.targetID = targetID
        self.notAfter = notAfter
        self.status = status
    }

    public var isAgentCommand: Bool { agentType != nil }

    /// The identical command may be retried while its challenge and lifetime
    /// remain valid; a fresh signature is never generated automatically
    /// (spec.watch.md section 15).
    public func isRetryable(at now: ControlTimestamp) -> Bool { now < notAfter }

    public var json: JSONValue {
        .object([
            "command_id": JSONValue(commandID),
            "signed_command": .string(signedCommand),
            "type": .string(type?.rawValue ?? agentType?.rawValue ?? ""),
            "target_id": JSONValue(targetID),
            "not_after": JSONValue(notAfter),
            "status": .string(status.rawValue)
        ])
    }

    public init(json: JSONValue) throws {
        var reader = try JSONReader(json)
        commandID = try reader.id("command_id")
        signedCommand = try reader.string("signed_command", maxLength: 8192)
        let typeText = try reader.string("type", maxLength: 32)
        if let type = ControlCommandType(rawValue: typeText) {
            self.type = type
            self.agentType = nil
        } else if let agentType = AgentCommandType(rawValue: typeText) {
            self.type = nil
            self.agentType = agentType
        } else {
            throw ValidationError.unsupported("command type \(typeText)")
        }
        targetID = try reader.id("target_id")
        notAfter = try reader.timestamp("not_after")
        let statusText = try reader.string("status", maxLength: 32)
        guard let status = Status(rawValue: statusText) else {
            throw ValidationError.unsupported("status \(statusText)")
        }
        self.status = status
        try reader.rejectUnknownMembers()
    }
}

public protocol CommandJournalStore: Sendable {
    func load() throws -> [PendingCommand]
    func save(_ commands: [PendingCommand]) throws
}

public final class InMemoryCommandJournal: CommandJournalStore, Sendable {
    private let commands = Mutex<[PendingCommand]>([])

    public init() {}

    public func load() throws -> [PendingCommand] {
        commands.withLock { $0 }
    }

    public func save(_ commands: [PendingCommand]) throws {
        self.commands.withLock { $0 = commands }
    }
}

/// The journal's store could not be read, so nothing may be recorded until
/// it can be: a save now would overwrite the unread entries.
public struct CommandJournalUnavailable: Error, LocalizedError, Sendable {
    public let underlying: String

    public var errorDescription: String? {
        "Decisions are unavailable until this device's decision journal can be read (\(underlying))."
    }
}

public actor CommandJournal {
    /// How long past its deadline an unreconciled command is kept. Past
    /// `not_after` it can never be retried, so it is only held to answer
    /// "what happened to this?" on the next reconnection.
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// A hard ceiling on journal entries. Without it, commands whose outcome
    /// is never learned — the Watch stayed offline, the app was killed —
    /// accumulate until the persisted file no longer parses within the
    /// protocol's document limits and the whole journal is lost.
    public static let maximumEntries = 256

    private let store: any CommandJournalStore
    private let now: @Sendable () -> Date
    /// Nil until the store has been read. A read can fail for a while — a
    /// protected file before first unlock — and is retried on every use
    /// rather than replaced by an empty journal.
    private var commands: [ControlID: PendingCommand]?

    public init(
        store: any CommandJournalStore = InMemoryCommandJournal(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
        self.commands = try? Self.read(store, now: now())
    }

    /// Whether the store has been read. False while it is unreadable; every
    /// write refuses until it becomes true.
    public var isAvailable: Bool { (try? loaded()) != nil }

    public var pending: [PendingCommand] {
        ((try? loaded()) ?? [:]).values.sorted { $0.notAfter < $1.notAfter }
    }

    /// Records the exact command ID and JWS *before* it is sent, so a
    /// connection loss after submission still leaves a retrievable identity.
    public func record(_ command: PendingCommand) throws {
        var commands = try loaded()
        commands[command.commandID] = command
        try commit(commands)
    }

    public func update(_ commandID: ControlID, status: PendingCommand.Status) throws {
        var commands = try loaded()
        guard var command = commands[commandID] else { return }
        command.status = status
        commands[commandID] = command
        try commit(commands)
    }

    public func resolve(_ commandID: ControlID) throws {
        var commands = try loaded()
        commands.removeValue(forKey: commandID)
        try commit(commands)
    }

    public func command(_ commandID: ControlID) -> PendingCommand? { (try? loaded())?[commandID] }

    /// Drops every journalled command. Used when the device identity that
    /// signed them is discarded: a command signed by a key this device no
    /// longer holds can never be retried or reconciled, and leaving it behind
    /// only produces confusing failures under the next identity. Unlike the
    /// other writes it needs no prior read: nothing it would keep.
    public func clear() throws {
        try store.save([])
        commands = [:]
    }

    private func loaded() throws -> [ControlID: PendingCommand] {
        if let commands { return commands }
        do {
            let commands = try Self.read(store, now: now())
            self.commands = commands
            return commands
        } catch {
            throw CommandJournalUnavailable(underlying: String(describing: error))
        }
    }

    private func commit(_ updated: [ControlID: PendingCommand]) throws {
        let kept = Self.pruned(updated, now: now())
        try store.save(Array(kept.values))
        commands = kept
    }

    private static func read(_ store: any CommandJournalStore, now: Date) throws -> [ControlID: PendingCommand] {
        let stored = try store.load()
        let loaded = Dictionary(stored.map { ($0.commandID, $0) }, uniquingKeysWith: { _, last in last })
        let kept = pruned(loaded, now: now)
        // Pruning on load is housekeeping; failing to write it back loses
        // nothing, so it never makes the journal unavailable.
        if kept.count != stored.count { try? store.save(Array(kept.values)) }
        return kept
    }

    /// Drops what can no longer be acted on: entries whose deadline passed
    /// longer ago than ``retention``, then the oldest deadlines beyond
    /// ``maximumEntries``.
    private static func pruned(
        _ commands: [ControlID: PendingCommand],
        now: Date
    ) -> [ControlID: PendingCommand] {
        let cutoff = ControlTimestamp(now.addingTimeInterval(-retention))
        var kept = commands.filter { $0.value.notAfter > cutoff }
        if kept.count > maximumEntries {
            let newest = kept.values.sorted { $0.notAfter > $1.notAfter }.prefix(maximumEntries)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.commandID, $0) })
        }
        return kept
    }
}
