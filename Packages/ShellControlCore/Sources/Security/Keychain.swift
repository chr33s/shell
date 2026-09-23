#if canImport(Security)
import Foundation
import Security

/// Shared Keychain primitives, so every store writes items the same way.
public enum Keychain {
    /// Updates the item matching `query` with `attributes`, or adds it — as
    /// `query` + `attributes` + `creationAttributes` — when there is none.
    ///
    /// `creationAttributes` apply only to a new item: use them for anything
    /// an existing item must keep (its accessibility class, say). An add that
    /// races another writer's add falls back to one more update. Returns the
    /// final status so each caller keeps its own error type and logging.
    @discardableResult
    public static func upsert(
        query: [String: Any],
        attributes: [String: Any],
        creationAttributes: [String: Any] = [:]
    ) -> OSStatus {
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updated == errSecItemNotFound else { return updated }
        var insert = query
        insert.merge(creationAttributes) { _, new in new }
        insert.merge(attributes) { _, new in new }
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecDuplicateItem else { return added }
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}
#endif
