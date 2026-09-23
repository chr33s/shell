#if canImport(Security)
import Foundation
import Security
import ShellControlProtocol

/// Keychain-backed credentials for the Watch.
///
/// Items are stored with `kSecAttrSynchronizable=false` and
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so the key is device-local
/// and unavailable until the device is unlocked: a locked or freshly restarted
/// Watch cannot sign, and nothing depends on the phone being unlocked
/// (spec.watch.md section 5).
public final class KeychainCredentialStore: DeviceCredentialStore, @unchecked Sendable {
    public enum KeychainError: Error, Equatable, Sendable {
        case status(OSStatus)
        case malformedItem
    }

    /// When the items can be read. The Watch keeps the default: it signs only
    /// while unlocked and on the wrist. The iPhone gateway needs its session
    /// after first unlock, so it can relay for the Watch from a locked pocket
    /// (spec.iphone-gateway.md section 4.5).
    public enum Accessibility: Sendable {
        case whenUnlocked
        case afterFirstUnlock

        var attribute: CFString {
            switch self {
            case .whenUnlocked: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    private let service: String
    private let accessGroup: String?
    private let accessibility: Accessibility
    private let lock = NSLock()
    /// Accounts whose items may still carry an older, stricter class. Each is
    /// rewritten the first time it is read successfully, so a store created
    /// while the device was locked still migrates once it unlocks.
    private var unmigrated: Set<String> = []
    private static let signingKeyAccount = "device-signing-key"
    private static let sessionAccount = "device-session"

    public init(service: String = "dev.chr33s.shell.control", accessGroup: String? = nil, accessibility: Accessibility = .whenUnlocked) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility
    }

    /// Rewrites existing items with this store's accessibility, for items
    /// created under an older, stricter class. It needs the items readable:
    /// what cannot be read now is migrated on its first successful read.
    public func migrateAccessibility() {
        let accounts = [Self.signingKeyAccount, Self.sessionAccount]
        lock.withLock { unmigrated.formUnion(accounts) }
        for account in accounts { _ = try? read(account: account) }
    }

    public func loadSigningKey() throws -> (any DeviceSigningKey)? {
        guard let data = try read(account: Self.signingKeyAccount) else { return nil }
        return try InMemoryDeviceKey(rawRepresentation: data)
    }

    public func storeSigningKey(_ key: InMemoryDeviceKey) throws {
        try write(account: Self.signingKeyAccount, data: key.rawRepresentation)
    }

    public func loadSession() throws -> DeviceSession? {
        guard let data = try read(account: Self.sessionAccount) else { return nil }
        return try DeviceSession(json: try JSONValue.parse(data))
    }

    public func storeSession(_ session: DeviceSession) throws {
        try write(account: Self.sessionAccount, data: try JSONCanonicalization.canonicalize(session.json))
    }

    public func removeAll() throws {
        for account in [Self.signingKeyAccount, Self.sessionAccount] {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.status(status)
            }
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.malformedItem }
            if lock.withLock({ unmigrated.contains(account) }), (try? write(account: account, data: data)) != nil {
                lock.withLock { _ = unmigrated.remove(account) }
            }
            return data
        case errSecItemNotFound:
            lock.withLock { _ = unmigrated.remove(account) }
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    private func write(account: String, data: Data) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.attribute
        ]
        // The accessibility class goes in the update too: rewriting it is
        // how an item created under an older, stricter class migrates.
        let status = Keychain.upsert(query: query, attributes: attributes)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        lock.withLock { _ = unmigrated.remove(account) }
    }
}
#endif
