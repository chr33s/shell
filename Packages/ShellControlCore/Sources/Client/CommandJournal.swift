import Foundation
import ShellControlProtocol

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
    public let type: ControlCommandType
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
        self.targetID = targetID
        self.notAfter = notAfter
        self.status = status
    }

    /// The identical command may be retried while its challenge and lifetime
    /// remain valid; a fresh signature is never generated automatically
    /// (spec.watch.md section 15).
    public func isRetryable(at now: ControlTimestamp) -> Bool { now < notAfter }

    public var json: JSONValue {
        .object([
            "command_id": JSONValue(commandID),
            "signed_command": .string(signedCommand),
            "type": .string(type.rawValue),
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
        guard let type = ControlCommandType(rawValue: typeText) else {
            throw ValidationError.unsupported("command type \(typeText)")
        }
        self.type = type
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

public final class InMemoryCommandJournal: CommandJournalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [PendingCommand] = []

    public init() {}

    public func load() throws -> [PendingCommand] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }

    public func save(_ commands: [PendingCommand]) throws {
        lock.lock(); defer { lock.unlock() }
        self.commands = commands
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
    private var commands: [ControlID: PendingCommand]

    public init(
        store: any CommandJournalStore = InMemoryCommandJournal(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.store = store
        self.now = now
        let loaded = Dictionary(uniqueKeysWithValues: try store.load().map { ($0.commandID, $0) })
        self.commands = Self.pruned(loaded, now: now())
        if commands.count != loaded.count { try store.save(Array(commands.values)) }
    }

    public var pending: [PendingCommand] {
        commands.values.sorted { $0.notAfter < $1.notAfter }
    }

    /// Records the exact command ID and JWS *before* it is sent, so a
    /// connection loss after submission still leaves a retrievable identity.
    public func record(_ command: PendingCommand) throws {
        commands[command.commandID] = command
        try commit()
    }

    public func update(_ commandID: ControlID, status: PendingCommand.Status) throws {
        guard var command = commands[commandID] else { return }
        command.status = status
        commands[commandID] = command
        try commit()
    }

    public func resolve(_ commandID: ControlID) throws {
        commands.removeValue(forKey: commandID)
        try commit()
    }

    public func command(_ commandID: ControlID) -> PendingCommand? { commands[commandID] }

    /// Drops every journalled command. Used when the device identity that
    /// signed them is discarded: a command signed by a key this device no
    /// longer holds can never be retried or reconciled, and leaving it behind
    /// only produces confusing failures under the next identity.
    public func clear() throws {
        commands = [:]
        try store.save([])
    }

    private func commit() throws {
        commands = Self.pruned(commands, now: now())
        try store.save(Array(commands.values))
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
