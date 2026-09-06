//
//  TabOrderRules.swift
//  shell
//
//  Pure identity-order operations shared by the tab projections. Keeping
//  these independent of SwiftUI and TabModel makes the invariants cheap to
//  exercise without launching the app.
//

nonisolated enum TabOrderRules {
    /// Retains live IDs in their remembered order, drops stale/duplicate IDs,
    /// then appends newly-discovered IDs in their current stable order.
    static func applyingPreferredOrder<ID: Hashable>(
        _ preferred: [ID],
        to live: [ID]
    ) -> [ID] {
        let liveSet = Set(live)
        var seen = Set<ID>()
        var result = preferred.filter {
            liveSet.contains($0) && seen.insert($0).inserted
        }
        result.append(contentsOf: live.filter { seen.insert($0).inserted })
        return result
    }

    /// Moves one identity to another identity's position without consulting a
    /// separate/raw array whose ordering may belong to a different mode.
    static func moving<ID: Equatable>(
        _ movingID: ID,
        to targetID: ID,
        in order: [ID]
    ) -> [ID]? {
        guard movingID != targetID,
              let from = order.firstIndex(of: movingID),
              let to = order.firstIndex(of: targetID) else { return nil }
        var result = order
        let moved = result.remove(at: from)
        result.insert(moved, at: to)
        return result
    }

    /// Replaces only the slots occupied by `orderedIDs`, preserving every
    /// unrelated identity's position.
    static func replacingSubsequence<ID: Hashable>(
        _ orderedIDs: [ID],
        in fullOrder: [ID]
    ) -> [ID]? {
        let idSet = Set(orderedIDs)
        guard idSet.count == orderedIDs.count else { return nil }
        let slots = fullOrder.indices.filter { idSet.contains(fullOrder[$0]) }
        guard slots.count == orderedIDs.count else { return nil }
        var result = fullOrder
        for (slot, id) in zip(slots, orderedIDs) {
            result[slot] = id
        }
        return result
    }

    /// Shared title composition for group switchers and sidebar headers.
    /// Empty metadata never displaces the explicit structural fallback.
    static func scopeTitle(
        components: [String?],
        fallback: String
    ) -> String {
        let title = components.compactMap { component -> String? in
            guard let component, !component.isEmpty else { return nil }
            return component
        }.joined(separator: " · ")
        return title.isEmpty ? fallback : title
    }
}
