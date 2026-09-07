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

    private let service: String
    private let accessGroup: String?
    private static let signingKeyAccount = "device-signing-key"
    private static let sessionAccount = "device-session"

    public init(service: String = "dev.chr33s.shell.control", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
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
            kSecAttrSynchronizable as String: false,
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
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    private func write(account: String, data: Data) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.status(updateStatus) }
        var insert = query
        insert.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }
}
#endif
