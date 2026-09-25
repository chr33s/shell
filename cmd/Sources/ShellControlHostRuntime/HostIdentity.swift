import Foundation
import ShellControlHostSupport
import ShellControlProtocol
import ShellControlSecurity

/// The host's durable identity: the account its broker administers, the
/// origin credential its daemon half presents to its broker half, the cursor
/// secret, and the origin signing key that pairing pins.
///
/// Created once, on first start, in the private container. It survives
/// compatible updates and is never regenerated because registration, a route,
/// or a bundle path changed (docs/specs/agent-relay.md section 18.5). If the key
/// disappears after the identity was committed, startup stops instead of
/// minting a new one: every paired device would silently stop trusting it.
public struct HostIdentity: Sendable, Equatable {
    public let accountID: ControlID
    public let adminSecret: String
    public let cursorSecret: Data
    public let originID: ControlID
    public let originSecret: String
    public let originKey: OriginSigningKey

    public static func == (lhs: HostIdentity, rhs: HostIdentity) -> Bool {
        lhs.accountID == rhs.accountID && lhs.originID == rhs.originID
            && lhs.originKey.publicJWK == rhs.originKey.publicJWK
    }

    public var origin: OriginIdentity { OriginIdentity(originID: originID, publicJWK: originKey.publicJWK) }

    public enum LoadError: Error, CustomStringConvertible, Sendable, Equatable {
        case originKeyMissing
        case unreadable(String)

        public var description: String {
            switch self {
            case .originKeyMissing:
                "the origin signing key is missing; it is never regenerated silently because paired devices pin it"
            case .unreadable(let detail):
                "the host identity is unreadable: \(detail)"
            }
        }
    }

    struct Document: Codable {
        var accountID: String
        var adminSecret: String
        var cursorSecret: String
        var originID: String
        var originSecret: String
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case accountID = "account_id", adminSecret = "admin_secret", cursorSecret = "cursor_secret"
            case originID = "origin_id", originSecret = "origin_secret", createdAt = "created_at"
        }
    }

    /// Loads the committed identity, or creates it when none was ever
    /// committed. The identity file is the commit marker: the key is written
    /// first, so a crash in between leaves a key that is reused, not replaced.
    public static func loadOrCreate(layout: HostStorageLayout, now: Date = Date()) throws -> HostIdentity {
        let identityURL = layout.identityURL, keyURL = layout.originKeyURL
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: identityURL.path) {
            guard fileManager.fileExists(atPath: keyURL.path) else { throw LoadError.originKeyMissing }
            return try load(identityURL: identityURL, keyURL: keyURL)
        }
        let key: OriginSigningKey
        if fileManager.fileExists(atPath: keyURL.path) {
            key = try loadKey(keyURL)
        } else {
            key = OriginSigningKey()
            try SecureFileSystem.atomicWrite(Data(key.pemRepresentation.utf8), to: keyURL)
        }
        let document = Document(
            accountID: ControlID.random().rawValue,
            adminSecret: randomHex(32),
            cursorSecret: randomHex(32),
            originID: ControlID.random().rawValue,
            originSecret: randomHex(32),
            createdAt: now
        )
        try SecureFileSystem.atomicWrite(document, to: identityURL)
        return try load(identityURL: identityURL, keyURL: keyURL)
    }

    static func load(identityURL: URL, keyURL: URL) throws -> HostIdentity {
        let document: Document
        do {
            document = try SecureFileSystem.decode(Document.self, from: identityURL)
        } catch {
            throw LoadError.unreadable("\(error)")
        }
        guard let accountID = ControlID(document.accountID), let originID = ControlID(document.originID),
              let cursorSecret = Data(hex: document.cursorSecret), cursorSecret.count >= 32,
              document.adminSecret.utf8.count >= 32, document.originSecret.utf8.count >= 32
        else { throw LoadError.unreadable("malformed identity document") }
        return HostIdentity(
            accountID: accountID,
            adminSecret: document.adminSecret,
            cursorSecret: cursorSecret,
            originID: originID,
            originSecret: document.originSecret,
            originKey: try loadKey(keyURL)
        )
    }

    static func loadKey(_ url: URL) throws -> OriginSigningKey {
        do {
            try SecureFileSystem.validateOwnedPath(url.path, type: .typeRegular)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            guard mode & 0o077 == 0 else { throw LoadError.unreadable("origin key must be owner-only") }
            return try OriginSigningKey(pemRepresentation: try String(contentsOf: url, encoding: .utf8))
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.unreadable("origin key: \(error)")
        }
    }

    static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
