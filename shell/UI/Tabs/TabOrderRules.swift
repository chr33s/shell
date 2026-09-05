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

    /// Applies the currently-live section permutation to remembered slots while
    /// leaving temporarily unresolved identities exactly where they were.
    /// Newly discovered live identities that have no remembered slot append.
    static func mergingLivePermutation<ID: Hashable>(
        _ liveOrder: [ID],
        into rememberedOrder: [ID]
    ) -> [ID] {
        let liveSet = Set(liveOrder)
        var nextLiveIndex = liveOrder.startIndex
        var result = rememberedOrder

        for index in result.indices where liveSet.contains(result[index]) {
            guard nextLiveIndex < liveOrder.endIndex else { break }
            result[index] = liveOrder[nextLiveIndex]
            liveOrder.formIndex(after: &nextLiveIndex)
        }
        if nextLiveIndex < liveOrder.endIndex {
            result.append(contentsOf: liveOrder[nextLiveIndex...])
        }
        return result
    }

    /// The shortest trailing path whose components distinguish `path` from
    /// all peers. Useful when project label + host are still ambiguous.
    static func shortestUniquePathSuffix(
        for path: String,
        among paths: [String]
    ) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return path }

        for length in 1...components.count {
            let candidate = components.suffix(length).joined(separator: "/")
            let matchCount = paths.reduce(into: 0) { count, peer in
                let peerComponents = peer.split(separator: "/").map(String.init)
                if peerComponents.suffix(length).joined(separator: "/") == candidate {
                    count += 1
                }
            }
            if matchCount == 1 { return candidate }
        }
        return path
    }

    /// Selects the section containing the current identity. A stable first
    /// section fallback keeps restoration usable while selection catches up.
    static func activeSectionIndex<ID: Equatable>(
        containing selectedID: ID?,
        in sections: [[ID]]
    ) -> Int? {
        if let selectedID,
           let index = sections.firstIndex(where: { $0.contains(selectedID) }) {
            return index
        }
        return sections.isEmpty ? nil : sections.startIndex
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
