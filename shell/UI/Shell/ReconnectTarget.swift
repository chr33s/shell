//
//  ReconnectTarget.swift
//  shell
//
//  Stable identity for a reconnect that is deferred across the connection
//  sheet. The sheet stays open for as long as the user takes to fix the
//  credentials, and tabs can be reordered, closed, split, or moved to another
//  window meanwhile. The target used to be an array index checked only for
//  bounds, so Connect replaced whatever tab had since slid into that slot.
//

import SwiftUI

/// The pane whose session failed authentication, identified by its tab's UUID
/// and the exact pane instance. Holding the instance (weakly) rather than an
/// index or UUID also rejects a superseded incarnation: once the pane has been
/// reconnected, closed, or rebuilt, the old reference no longer resolves.
struct ReconnectTarget {
    let tabID: UUID
    weak var pane: SplitPaneView?

    init(tabID: UUID, pane: SplitPaneView) {
        self.tabID = tabID
        self.pane = pane
    }

    struct Resolved {
        let tabIndex: Int
        let tab: TabModel
        let pane: SplitPaneView
    }

    /// Resolve against this window's tabs immediately before acting. Returns
    /// nil — never a fallback tab — when the tab left this window (closed or
    /// transferred) or the pane is no longer in that tab.
    @MainActor
    func resolve(in tabs: [TabModel]) -> Resolved? {
        guard let pane,
              let tabIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let tab = tabs[tabIndex]
        guard tab.splitTree.contains(pane) else { return nil }
        return Resolved(tabIndex: tabIndex, tab: tab, pane: pane)
    }
}

extension SplitTree {
    /// Swap one leaf for another in place, keeping every sibling, the split
    /// geometry, and the zoom state. Zoom is carried by path, not node value:
    /// a zoomed ancestor split embeds the old leaf, so its old node value would
    /// no longer match anything in the rebuilt tree.
    func replacingLeaf(_ oldView: ViewType, with newView: ViewType) throws -> Self {
        guard let root,
              let node = root.node(view: oldView),
              let path = root.path(to: node) else { throw SplitError.viewNotFound }
        let zoomedPath = zoomed.flatMap { root.path(to: $0) }
        let newRoot = try root.replaceNode(at: path, with: .leaf(view: newView))
        return .init(root: newRoot, zoomed: zoomedPath.flatMap { newRoot.node(at: $0) })
    }
}
