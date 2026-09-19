//
//  ControlRouteStore.swift
//  shell
//
//  Where the iPhone keeps the pinned Shell origin (identity plus cached
//  routes) and the Watch it gateways for. Routes change freely; the pinned
//  origin key changes only through an explicit new pairing
//  (spec.iphone-gateway.md sections 7.3 and 10.5).
//

import Foundation
import Security
import ShellControlProtocol
import ShellControlSecurity
import ShellControlClient

/// The pinned origin lives in the Keychain, device-only: it is the trust
/// anchor every route is checked against. It is readable after first unlock
/// so a background push can verify a route while the phone is locked.
final class KeychainPinnedOriginStore: PinnedOriginStore, @unchecked Sendable {
    private let service: String
    private static let account = "pinned-origin"

    init(service: String = "dev.chr33s.shell.control") {
        self.service = service
    }

    func load() throws -> PinnedOrigin? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainCredentialStore.KeychainError.malformedItem }
            return try PinnedOrigin(json: try JSONValue.parse(data))
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainCredentialStore.KeychainError.status(status)
        }
    }

    func store(_ origin: PinnedOrigin) throws {
        let data = try JSONCanonicalization.canonicalize(origin.json)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainCredentialStore.KeychainError.status(updated) }
        var insert = baseQuery
        insert.merge(attributes) { _, new in new }
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainCredentialStore.KeychainError.status(added) }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStore.KeychainError.status(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

/// The Watch this iPhone gateways for. The Mac enforces the binding on every
/// proxied call; this copy only lets the phone refuse early and show state.
///
/// It lives in the Keychain, readable after first unlock, because a Watch
/// message can launch the app while the phone is locked. Before first unlock
/// a read throws rather than returning nil, so the router answers "gateway
/// unavailable" instead of telling the Watch it is no longer bound — which
/// would make the Watch forget its reviewer identity.
final class KeychainWatchBindingStore: WatchBindingStore, @unchecked Sendable {
    private let service: String
    private let legacyDefaults: UserDefaults
    private static let account = "watch-binding"
    /// Where earlier builds kept the binding.
    private static let legacyKey = "dev.chr33s.shell.control.watch-binding"

    init(service: String = "dev.chr33s.shell.control", legacyDefaults: UserDefaults = .standard) {
        self.service = service
        self.legacyDefaults = legacyDefaults
    }

    func loadBoundWatch() throws -> WatchReviewerStatus? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainCredentialStore.KeychainError.malformedItem }
            return try WatchReviewerStatus(json: try JSONValue.parse(data))
        case errSecItemNotFound:
            return try migrateLegacy()
        default:
            throw KeychainCredentialStore.KeychainError.status(status)
        }
    }

    func storeBoundWatch(_ status: WatchReviewerStatus?) throws {
        legacyDefaults.removeObject(forKey: Self.legacyKey)
        guard let status else {
            let deleted = SecItemDelete(baseQuery as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
                throw KeychainCredentialStore.KeychainError.status(deleted)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONCanonicalization.canonicalize(status.json),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updated = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainCredentialStore.KeychainError.status(updated) }
        var insert = baseQuery
        insert.merge(attributes) { _, new in new }
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainCredentialStore.KeychainError.status(added) }
    }

    /// Moves a binding written by an earlier build into the Keychain. This
    /// only runs once the Keychain is readable, so the defaults are too.
    private func migrateLegacy() throws -> WatchReviewerStatus? {
        guard let text = legacyDefaults.string(forKey: Self.legacyKey) else { return nil }
        let status = try WatchReviewerStatus(json: try JSONValue.parse(text))
        try storeBoundWatch(status)
        return status
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
