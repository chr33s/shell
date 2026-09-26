import Foundation
import UIKit
import Testing

@testable import Shell

/// Regression tests for deferred reconnect targeting.
///
/// Authentication failure opens the connection sheet armed to reconnect the
/// failing pane. The target used to be the tab's array index, re-checked only
/// for bounds when the user pressed Connect — so a reorder or close while the
/// sheet was open made Connect replace an unrelated tab. The target is now a
/// tab UUID plus the exact pane instance, resolved at commit time.
///
/// Plain `SplitPaneView`s stand in for terminals: resolution and leaf
/// replacement are identity operations that never touch a session.
@MainActor
@Suite
struct ReconnectTargetTests {

    private func makeTab(_ pane: SplitPaneView = SplitPaneView()) -> TabModel {
        TabModel(paneView: pane, title: "t", windowId: "w")
    }

    // AC-01
    @Test func reorderDoesNotRetarget() throws {
        let a = makeTab()
        let bPane = SplitPaneView()
        let b = makeTab(bPane)
        let target = ReconnectTarget(tabID: b.id, pane: bPane)

        // [A, B] → [B, A]: B's old index 1 now addresses A.
        let resolved = try #require(target.resolve(in: [b, a]))
        #expect(resolved.tab === b)
        #expect(resolved.pane === bPane)
        #expect(resolved.tabIndex == 0)
    }

    // AC-02
    @Test func closedTargetDoesNotFallBack() {
        let a = makeTab()
        let bPane = SplitPaneView()
        let b = makeTab(bPane)
        let c = makeTab()
        let target = ReconnectTarget(tabID: b.id, pane: bPane)

        // Index 1 is still in bounds (it now holds C) but must not resolve.
        #expect(target.resolve(in: [a, c]) == nil)
        #expect(target.resolve(in: []) == nil)
    }

    // AC-02
    @Test func closingPrecedingTabKeepsTarget() throws {
        let a = makeTab()
        let bPane = SplitPaneView()
        let b = makeTab(bPane)
        let target = ReconnectTarget(tabID: b.id, pane: bPane)

        let resolved = try #require(target.resolve(in: [b]))
        #expect(resolved.tab === b)
        _ = a
    }

    // AC-05: a tab transferred to another window leaves this window's list.
    @Test func transferredTabIsNotActionableFromSourceWindow() throws {
        let pane = SplitPaneView()
        let tab = makeTab(pane)
        let target = ReconnectTarget(tabID: tab.id, pane: pane)
        let sourceWindowTabs = [makeTab()]
        let destinationWindowTabs = [tab]

        #expect(target.resolve(in: sourceWindowTabs) == nil)
        #expect(target.resolve(in: destinationWindowTabs) != nil)
    }

    // TAB-02: a superseded pane incarnation is rejected even though its tab
    // still exists at the same position.
    @Test func supersededPaneIsRejected() throws {
        let oldPane = SplitPaneView()
        let tab = makeTab(oldPane)
        let target = ReconnectTarget(tabID: tab.id, pane: oldPane)

        let newPane = SplitPaneView()
        tab.splitTree = try tab.splitTree.replacingLeaf(oldPane, with: newPane)

        #expect(target.resolve(in: [tab]) == nil)
    }

    @Test func releasedPaneIsRejected() {
        let tab = makeTab()
        var target: ReconnectTarget!
        autoreleasepool {
            let transient = SplitPaneView()
            target = ReconnectTarget(tabID: tab.id, pane: transient)
        }
        #expect(target.resolve(in: [tab]) == nil)
    }

    // AC-03: replacing one pane keeps its siblings and the split geometry.
    @Test func replacingLeafPreservesSiblings() throws {
        let left = SplitPaneView()
        let right = SplitPaneView()
        let replacement = SplitPaneView()
        var tree = SplitTree<SplitPaneView>(view: left)
        tree = try tree.insert(view: right, at: left, direction: .right)

        let replaced = try tree.replacingLeaf(right, with: replacement)

        let leaves = Array(replaced)
        #expect(leaves.count == 2)
        #expect(leaves.contains { $0 === left })
        #expect(leaves.contains { $0 === replacement })
        #expect(!leaves.contains { $0 === right })
        #expect(replaced.root?.path(to: .leaf(view: replacement)) != nil)
    }

    @Test func replacingZoomedLeafKeepsZoom() throws {
        let left = SplitPaneView()
        let right = SplitPaneView()
        let replacement = SplitPaneView()
        var tree = SplitTree<SplitPaneView>(view: left)
        tree = try tree.insert(view: right, at: left, direction: .right)
        tree = SplitTree(root: tree.root, zoomed: .leaf(view: right))

        let replaced = try tree.replacingLeaf(right, with: replacement)

        #expect(replaced.zoomed == .leaf(view: replacement))
    }

    /// A zoomed ancestor split embeds the replaced leaf; comparing node
    /// values used to drop the zoom.
    @Test func replacingLeafUnderZoomedAncestorKeepsZoom() throws {
        let a = SplitPaneView()
        let b = SplitPaneView()
        let c = SplitPaneView()
        let replacement = SplitPaneView()
        var tree = SplitTree<SplitPaneView>(view: a)
        tree = try tree.insert(view: b, at: a, direction: .right)
        tree = try tree.insert(view: c, at: b, direction: .down)
        // Shape: split(a, split(b, c)); zoom the inner split.
        guard case .split(let outer) = try #require(tree.root) else {
            Issue.record("expected a split root")
            return
        }
        let ancestor = outer.right
        #expect(ancestor.contains(b) && ancestor.contains(c))
        tree = SplitTree(root: tree.root, zoomed: ancestor)

        let replaced = try tree.replacingLeaf(c, with: replacement)

        let zoomed = try #require(replaced.zoomed)
        #expect(zoomed.contains(b))
        #expect(zoomed.contains(replacement))
        #expect(!zoomed.contains(a))
    }

    @Test func replacingUnrelatedNodeKeepsSiblingZoom() throws {
        let a = SplitPaneView()
        let b = SplitPaneView()
        let replacement = SplitPaneView()
        var tree = SplitTree<SplitPaneView>(view: a)
        tree = try tree.insert(view: b, at: a, direction: .right)
        tree = SplitTree(root: tree.root, zoomed: .leaf(view: a))

        let replaced = try tree.replace(node: .leaf(view: b), with: .leaf(view: replacement))

        #expect(replaced.zoomed == .leaf(view: a))
    }

    @Test func replacingMissingLeafThrows() {
        let tree = SplitTree<SplitPaneView>(view: SplitPaneView())
        #expect(throws: (any Error).self) {
            _ = try tree.replacingLeaf(SplitPaneView(), with: SplitPaneView())
        }
    }
}
