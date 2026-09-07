import Foundation
import ShellControlProtocol
import ShellControlClient

/// The Watch's small protected local cache.
///
/// Written with complete file protection so it is unreadable while the device
/// is locked, and cleared on logout or account change
/// (spec.watch.md section 7).
final class ProtectedInboxCache: InboxCacheStore, @unchecked Sendable {
    private let url: URL

    init(directory: URL? = nil) throws {
        let base = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("control-inbox.json")
    }

    func load() throws -> InboxState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return nil }
        return try ProtectedInboxCache.decode(try JSONValue.parse(data, limits: JSONLimits(
            maxDocumentBytes: 4 << 20,
            maxStringCharacters: 1 << 16,
            maxNestingDepth: 32,
            maxCollectionElements: 4096
        )))
    }

    func commit(_ state: InboxState) throws {
        let data = try JSONCanonicalization.canonicalize(ProtectedInboxCache.encode(state))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    func clear() throws {
        try? FileManager.default.removeItem(at: url)
    }

    static func encode(_ state: InboxState) -> JSONValue {
        JSONWriter.object([
            "approvals": .array(state.approvals.values.map(\.json)),
            "notifications": .array(state.notifications.values.map(\.json)),
            "cursor": state.cursor.map { .string($0.rawValue) },
            "last_refreshed_at": state.lastRefreshedAt.map { JSONValue($0) },
            "seen_event_ids": JSONValue(strings: state.seenEventIDs.map(\.rawValue).sorted()),
        ])
    }

    static func decode(_ value: JSONValue) throws -> InboxState {
        var reader = try JSONReader(value)
        var state = InboxState()
        for element in try reader.value("approvals").arrayValue ?? [] {
            // A cached record whose digest no longer verifies is dropped rather
            // than shown: stale display is fine, unverifiable display is not.
            if let record = try? ApprovalRecord(json: element) {
                state.approvals[record.spec.requestID] = record
            }
        }
        for element in try reader.value("notifications").arrayValue ?? [] {
            if let event = try? InformationalEvent(json: element) {
                state.notifications[event.eventID] = event
            }
        }
        state.cursor = try reader.optionalString("cursor", maxLength: 512).map(ChangeCursor.init)
        state.lastRefreshedAt = try reader.optionalTimestamp("last_refreshed_at")
        state.seenEventIDs = Set(try reader.stringArray("seen_event_ids", maxCount: 5000, maxLength: 36).compactMap(ControlID.init))
        return state
    }
}

/// Unresolved local command IDs, persisted separately from the projection cache
/// so a snapshot refresh cannot erase an ambiguous submitted decision
/// (spec.watch.md section 15).
final class FileCommandJournalStore: CommandJournalStore, @unchecked Sendable {
    private let url: URL

    init(directory: URL? = nil) throws {
        let base = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("control-commands.json")
    }

    func load() throws -> [PendingCommand] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let value = try JSONValue.parse(data)
        return (value.arrayValue ?? []).compactMap { try? PendingCommand(json: $0) }
    }

    func save(_ commands: [PendingCommand]) throws {
        let data = try JSONCanonicalization.canonicalize(.array(commands.map(\.json)))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
