import Foundation
import ShellControlProtocol

/// Signed commands whose outcome is not yet known: the exact command ID and
/// JWS, persisted before sending and separately from any inbox cache. After an
/// ambiguous failure the device asks about that command ID and may resend the
/// identical JWS while it is still valid; it never signs a replacement
/// (spec.iphone-gateway.md section 15).
public final class FileCommandJournalStore: CommandJournalStore, @unchecked Sendable {
    private let url: URL
    private let protection: Data.WritingOptions

    /// - Parameter protection: the file protection class. The iPhone uses
    ///   `.completeFileProtectionUntilFirstUserAuthentication`, because an
    ///   approval hint can wake it in a locked pocket and reconciling then
    ///   must not fail; the Watch keeps `.completeFileProtection`.
    public init(
        directory: URL? = nil,
        protection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication
    ) throws {
        let base = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("control-commands.json")
        self.protection = protection
    }

    /// Sized to what a full journal can legitimately hold: up to
    /// ``CommandJournal/maximumEntries`` entries, each with a JWS of up to
    /// 8 KiB. The 64 KiB control-document default is a wire limit, and
    /// applying it here made a full journal unreadable.
    private static let limits = JSONLimits(
        maxDocumentBytes: CommandJournal.maximumEntries * 12 * 1024,
        maxStringCharacters: 8192,
        maxNestingDepth: 8,
        maxCollectionElements: CommandJournal.maximumEntries
    )

    /// A missing file is an empty journal. A read failure throws — it may be
    /// a protected file before first unlock — so ``CommandJournal`` retries
    /// instead of letting the next save overwrite entries that were merely
    /// unreadable. Bytes that read but do not parse will never parse: they are
    /// set aside beside the journal and the journal starts empty, rather than
    /// blocking every future decision.
    public func load() throws -> [PendingCommand] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        guard !data.isEmpty else { return [] }
        let value: JSONValue
        do {
            value = try JSONValue.parse(data, limits: Self.limits)
        } catch {
            let aside = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.moveItem(at: url, to: aside)
            return []
        }
        return (value.arrayValue ?? []).compactMap { try? PendingCommand(json: $0) }
    }

    public func save(_ commands: [PendingCommand]) throws {
        let data = try JSONCanonicalization.canonicalize(.array(commands.map(\.json)))
        try data.write(to: url, options: [.atomic, protection])
    }
}
