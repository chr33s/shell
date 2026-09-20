import Foundation
import ShellControlProtocol
import ShellControlClient

/// Signed Watch commands whose outcome is not yet known: the exact command ID
/// and JWS, persisted before sending and separately from the inbox cache.
/// After an ambiguous failure the Watch asks about that command ID through
/// the gateway and may resend the identical JWS while it is still valid; it
/// never signs a replacement (spec.iphone-gateway.md section 15).
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

    /// The journal holds up to ``CommandJournal/maximumEntries`` entries, each
    /// carrying a JWS of up to 8 KiB, so it is read with limits sized to what
    /// it can legitimately contain. The 64 KiB control-document default is a
    /// wire limit, and applying it here made a full journal unreadable —
    /// losing every ambiguous decision rather than one.
    private static let limits = JSONLimits(
        maxDocumentBytes: CommandJournal.maximumEntries * 12 * 1024,
        maxStringCharacters: 8192,
        maxNestingDepth: 8,
        maxCollectionElements: CommandJournal.maximumEntries
    )

    func load() throws -> [PendingCommand] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let value = try JSONValue.parse(data, limits: Self.limits)
        return (value.arrayValue ?? []).compactMap { try? PendingCommand(json: $0) }
    }

    func save(_ commands: [PendingCommand]) throws {
        let data = try JSONCanonicalization.canonicalize(.array(commands.map(\.json)))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
