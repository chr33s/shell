import Foundation
import UIKit
import Testing

/// UIView panes cannot cross out of the main actor. The box is created in
/// `setUp` on the main thread and only touched there.
private nonisolated final class ZoomPanes: @unchecked Sendable {
    var a: SplitPaneView!
    var b: SplitPaneView!
    var c: SplitPaneView!
    var inner: SplitTree<SplitPaneView>.Node!
    var root: SplitTree<SplitPaneView>.Node!
    func clear() {
        a = nil
        b = nil
        c = nil
        inner = nil
        root = nil
    }
}

@testable import Shell

/// Regression tests for restoring a zoomed split pane across a relaunch.
///
/// At quit, `SplitTree.serialize()` records the zoomed node as a path of
/// left/right turns from the root (`pathToNode`). At launch,
/// `SplitTree.init(root:restoringZoomedPath:)` walks that path back down the
/// rebuilt tree (`Node.node(at:)`) and re-applies the zoom.
///
/// Three properties matter, and each has its own failure mode:
///
/// * The path must resolve to the *same* pane — otherwise the wrong pane comes
///   back zoomed, which looks like the app silently swapped the user's panes.
/// * An **empty** path is not "nothing was zoomed": it is the root itself
///   zoomed, which is what zooming a sole pane records. Collapsing empty to nil
///   loses the zoom on exactly the simplest case.
/// * A path that no longer resolves — saved state written against a different
///   tree shape, or truncated — must yield nil, not a crash and not a
///   best-effort partial walk landing on some unrelated pane.
///
/// `SplitPaneView` is used directly rather than a terminal subclass: its init
/// is a plain `UIView` plus a `PanePresentationState`, with no surface, session
/// or renderer, so these tests construct real leaves and stay deterministic.
/// `SplitTree.Node` compares leaves by view object identity, so every assertion
/// below is exact about *which* pane came back.
@MainActor
@Suite
final class SplitZoomRestoreTests {

    // Tree shape shared by the tests:
    //
    //           root (horizontal)
    //          /                \
    //     leaf(a)          inner (vertical)
    //                      /            \
    //                  leaf(b)        leaf(c)
    private let panes = ZoomPanes()
    private var a: SplitPaneView! { panes.a }
    private var b: SplitPaneView! { panes.b }
    private var c: SplitPaneView! { panes.c }
    private var inner: SplitTree<SplitPaneView>.Node! {
        get { panes.inner }
        set { panes.inner = newValue }
    }
    private var root: SplitTree<SplitPaneView>.Node! {
        get { panes.root }
        set { panes.root = newValue }
    }

    init() {
        // Split panes are UIView subclasses. The runner calls init on the main thread.
        let panes = panes
        MainActor.assumeIsolated {
            panes.a = SplitPaneView()
            panes.b = SplitPaneView()
            panes.c = SplitPaneView()
            panes.inner = .split(.init(direction: .vertical, ratio: 0.5,
                                       left: .leaf(view: panes.b), right: .leaf(view: panes.c)))
            panes.root = .split(.init(direction: .horizontal, ratio: 0.5,
                                      left: .leaf(view: panes.a), right: panes.inner))
        }
    }

    deinit {
        panes.clear()
    }

    // MARK: - The zoom comes back

    /// A saved path resolves to the pane it was captured from — including a
    /// nested one two turns down.
    ///
    /// Reverting `init(root:restoringZoomedPath:)` to ignore the path (the
    /// plain `self.init(root: root, zoomed: nil)` it replaced) makes every
    /// assertion here nil out, which is the "pane came back un-zoomed" bug.
    @Test
    func testSavedPathRestoresTheZoomOntoTheSamePane() throws {
        #expect(SplitTree(root: root, restoringZoomedPath: [.left]).zoomed == .leaf(view: a))
        #expect(SplitTree(root: root, restoringZoomedPath: [.right]).zoomed == inner)
        #expect(SplitTree(root: root, restoringZoomedPath: [.right, .left]).zoomed == .leaf(view: b))
        #expect(SplitTree(root: root, restoringZoomedPath: [.right, .right]).zoomed == .leaf(view: c))
    }

    /// Capture and restore are inverses: whatever `pathToNode` writes for a
    /// zoomed node, `restoringZoomedPath` reads back as that same node.
    ///
    /// This is the property the persistence round trip actually depends on, so
    /// it fails if *either* half drifts — for instance if one side starts
    /// numbering children in the opposite order.
    @Test
    func testCaptureAndRestoreAreInversesForEveryNodeInTheTree() throws {
        let root = try #require(self.root)
        let tree = SplitTree<SplitPaneView>(root: root, zoomed: nil)

        for node in [SplitTree<SplitPaneView>.Node.leaf(view: a),
                     .leaf(view: b),
                     .leaf(view: c),
                     try #require(self.inner),
                     root] {
            let path = try #require(tree.pathToNode(node), "every node in the tree must have a path")
            #expect(SplitTree(root: root, restoringZoomedPath: path).zoomed == node)
        }
    }

    /// An empty path means the root is zoomed — the shape a sole zoomed pane
    /// records — and must not be read as "no zoom".
    ///
    /// `pathToNode` returns `[]` for the root, so a `zoomedPath?.isEmpty == true
    /// ? nil : …` short-circuit anywhere in the restore path silently drops the
    /// zoom on a single-pane tab. That is the whole reason `node(at:)` returns
    /// `self` for an empty path.
    @Test
    func testEmptyPathMeansTheRootIsZoomedNotThatNothingIs() throws {
        #expect(SplitTree(root: root, restoringZoomedPath: []).zoomed == root, "an empty path is the root itself, not the absence of a zoom")

        let sole = SplitTree<SplitPaneView>(root: .leaf(view: a), zoomed: .leaf(view: a))
        #expect(sole.pathToNode(.leaf(view: a)) == [], "zooming a sole pane records an empty path")
        #expect(SplitTree(root: .leaf(view: a), restoringZoomedPath: []).zoomed == .leaf(view: a), "…and that empty path restores the zoom")
    }

    /// No saved path means no zoom.
    @Test
    func testNilPathRestoresAnUnzoomedTree() throws {
        #expect((SplitTree(root: root, restoringZoomedPath: nil).zoomed) == nil)
    }

    // MARK: - Paths that no longer resolve

    /// A path that runs past a leaf yields nil rather than trapping or landing
    /// on the last node it managed to reach.
    ///
    /// `[.left, .left]` turns left into `leaf(a)` and then asks for a child it
    /// does not have; `[.right, .right, .right]` gets as far as `leaf(c)` and
    /// then over-runs. A "walk as far as you can" implementation would hand
    /// back `a` and `c` — the wrong pane, zoomed, with no sign anything went
    /// wrong. Both must be nil.
    @Test
    func testPathThatOverrunsALeafFallsBackToNoZoomRatherThanTheWrongPane() throws {
        let overrunsImmediately = SplitTree(root: root, restoringZoomedPath: [.left, .left])
        #expect((overrunsImmediately.zoomed) == nil)
        #expect(overrunsImmediately.root == root, "the tree itself still restores")

        #expect((SplitTree(root: root, restoringZoomedPath: [.right, .right, .right]).zoomed) == nil)
        #expect((SplitTree(root: root, restoringZoomedPath: [.left, .right, .left]).zoomed) == nil)
    }

    /// State saved from a split tab, restored into a tab that is now a single
    /// pane, restores un-zoomed instead of crashing.
    @Test
    func testPathSavedAgainstADeeperTreeIsDiscardedWhenTheShapeShrank() throws {
        let shrunk = SplitTree(root: SplitTree<SplitPaneView>.Node.leaf(view: a),
                               restoringZoomedPath: [.right, .left])
        #expect((shrunk.zoomed) == nil)
        #expect(shrunk.root == .leaf(view: a))
    }

    // MARK: - Persisted representation

    /// `zoomedPath` survives the JSON round trip with its turns in order, and
    /// the on-disk spelling of a turn is `"left"` / `"right"`.
    ///
    /// The path is written to disk by one build and read by the next, so
    /// renaming these raw values (or reordering the enum in a way that changes
    /// them) does not fail to decode — it decodes to a *different* pane. The
    /// literal below is the format already on users' disks.
    @Test
    func testZoomedPathKeepsItsOnDiskSpellingAndOrder() throws {
        let encoded = try JSONEncoder().encode(
            SerializableSplitTree(root: nil, zoomedPath: [.right, .left]))
        #expect(String(decoding: encoded, as: UTF8.self) == #"{"zoomedPath":["right","left"]}"#)

        let decoded = try JSONDecoder().decode(
            SerializableSplitTree.self,
            from: Data(#"{"zoomedPath":["right","left"]}"#.utf8))
        #expect(decoded.zoomedPath == [.right, .left])

        // …and that decoded path still selects the pane it was written for.
        #expect(SplitTree(root: root, restoringZoomedPath: decoded.zoomedPath).zoomed == .leaf(view: b))
    }

    /// A saved tree with no zoom decodes as no zoom, and stays distinct from
    /// the empty-path (root-zoomed) case above.
    @Test
    func testAbsentZoomedPathDecodesAsNoZoomAndEmptyArrayStaysDistinct() throws {
        let noZoom = try JSONDecoder().decode(
            SerializableSplitTree.self, from: Data(#"{}"#.utf8))
        #expect((noZoom.zoomedPath) == nil)
        #expect((SplitTree(root: root, restoringZoomedPath: noZoom.zoomedPath).zoomed) == nil)

        let rootZoomed = try JSONDecoder().decode(
            SerializableSplitTree.self, from: Data(#"{"zoomedPath":[]}"#.utf8))
        #expect(rootZoomed.zoomedPath == [])
        #expect(SplitTree(root: root, restoringZoomedPath: rootZoomed.zoomedPath).zoomed == root)
    }
}
