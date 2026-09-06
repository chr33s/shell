import Foundation
import UIKit
import XCTest

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
final class SplitZoomRestoreTests: XCTestCase {

    // Tree shape shared by the tests:
    //
    //           root (horizontal)
    //          /                \
    //     leaf(a)          inner (vertical)
    //                      /            \
    //                  leaf(b)        leaf(c)
    private var a: SplitPaneView!
    private var b: SplitPaneView!
    private var c: SplitPaneView!
    private var inner: SplitTree<SplitPaneView>.Node!
    private var root: SplitTree<SplitPaneView>.Node!

    override func setUp() {
        super.setUp()
        a = SplitPaneView()
        b = SplitPaneView()
        c = SplitPaneView()
        inner = .split(.init(direction: .vertical, ratio: 0.5,
                             left: .leaf(view: b), right: .leaf(view: c)))
        root = .split(.init(direction: .horizontal, ratio: 0.5,
                            left: .leaf(view: a), right: inner))
    }

    override func tearDown() {
        a = nil
        b = nil
        c = nil
        inner = nil
        root = nil
        super.tearDown()
    }

    // MARK: - The zoom comes back

    /// A saved path resolves to the pane it was captured from — including a
    /// nested one two turns down.
    ///
    /// Reverting `init(root:restoringZoomedPath:)` to ignore the path (the
    /// plain `self.init(root: root, zoomed: nil)` it replaced) makes every
    /// assertion here nil out, which is the "pane came back un-zoomed" bug.
    func testSavedPathRestoresTheZoomOntoTheSamePane() {
        XCTAssertEqual(SplitTree(root: root, restoringZoomedPath: [.left]).zoomed,
                       .leaf(view: a))
        XCTAssertEqual(SplitTree(root: root, restoringZoomedPath: [.right]).zoomed,
                       inner)
        XCTAssertEqual(SplitTree(root: root, restoringZoomedPath: [.right, .left]).zoomed,
                       .leaf(view: b))
        XCTAssertEqual(SplitTree(root: root, restoringZoomedPath: [.right, .right]).zoomed,
                       .leaf(view: c))
    }

    /// Capture and restore are inverses: whatever `pathToNode` writes for a
    /// zoomed node, `restoringZoomedPath` reads back as that same node.
    ///
    /// This is the property the persistence round trip actually depends on, so
    /// it fails if *either* half drifts — for instance if one side starts
    /// numbering children in the opposite order.
    func testCaptureAndRestoreAreInversesForEveryNodeInTheTree() throws {
        let root = try XCTUnwrap(self.root)
        let tree = SplitTree<SplitPaneView>(root: root, zoomed: nil)

        for node in [SplitTree<SplitPaneView>.Node.leaf(view: a),
                     .leaf(view: b),
                     .leaf(view: c),
                     try XCTUnwrap(self.inner),
                     root] {
            let path = try XCTUnwrap(tree.pathToNode(node),
                                     "every node in the tree must have a path")
            XCTAssertEqual(SplitTree(root: root, restoringZoomedPath: path).zoomed, node)
        }
    }

    /// An empty path means the root is zoomed — the shape a sole zoomed pane
    /// records — and must not be read as "no zoom".
    ///
    /// `pathToNode` returns `[]` for the root, so a `zoomedPath?.isEmpty == true
    /// ? nil : …` short-circuit anywhere in the restore path silently drops the
    /// zoom on a single-pane tab. That is the whole reason `node(at:)` returns
    /// `self` for an empty path.
    func testEmptyPathMeansTheRootIsZoomedNotThatNothingIs() {
        XCTAssertEqual(SplitTree(root: root, restoringZoomedPath: []).zoomed, root,
                       "an empty path is the root itself, not the absence of a zoom")

        let sole = SplitTree<SplitPaneView>(root: .leaf(view: a), zoomed: .leaf(view: a))
        XCTAssertEqual(sole.pathToNode(.leaf(view: a)), [],
                       "zooming a sole pane records an empty path")
        XCTAssertEqual(SplitTree(root: .leaf(view: a), restoringZoomedPath: []).zoomed,
                       .leaf(view: a),
                       "…and that empty path restores the zoom")
    }

    /// No saved path means no zoom.
    func testNilPathRestoresAnUnzoomedTree() {
        XCTAssertNil(SplitTree(root: root, restoringZoomedPath: nil).zoomed)
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
    func testPathThatOverrunsALeafFallsBackToNoZoomRatherThanTheWrongPane() {
        let overrunsImmediately = SplitTree(root: root, restoringZoomedPath: [.left, .left])
        XCTAssertNil(overrunsImmediately.zoomed)
        XCTAssertEqual(overrunsImmediately.root, root, "the tree itself still restores")

        XCTAssertNil(SplitTree(root: root, restoringZoomedPath: [.right, .right, .right]).zoomed)
        XCTAssertNil(SplitTree(root: root, restoringZoomedPath: [.left, .right, .left]).zoomed)
    }

    /// State saved from a split tab, restored into a tab that is now a single
    /// pane, restores un-zoomed instead of crashing.
    func testPathSavedAgainstADeeperTreeIsDiscardedWhenTheShapeShrank() {
        let shrunk = SplitTree(root: SplitTree<SplitPaneView>.Node.leaf(view: a),
                               restoringZoomedPath: [.right, .left])
        XCTAssertNil(shrunk.zoomed)
        XCTAssertEqual(shrunk.root, .leaf(view: a))
    }

    // MARK: - Persisted representation

    /// `zoomedPath` survives the JSON round trip with its turns in order, and
    /// the on-disk spelling of a turn is `"left"` / `"right"`.
    ///
    /// The path is written to disk by one build and read by the next, so
    /// renaming these raw values (or reordering the enum in a way that changes
    /// them) does not fail to decode — it decodes to a *different* pane. The
    /// literal below is the format already on users' disks.
    func testZoomedPathKeepsItsOnDiskSpellingAndOrder() throws {
        let encoded = try JSONEncoder().encode(
            SerializableSplitTree(root: nil, zoomedPath: [.right, .left]))
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self),
                       #"{"zoomedPath":["right","left"]}"#)

        let decoded = try JSONDecoder().decode(
            SerializableSplitTree.self,
            from: Data(#"{"zoomedPath":["right","left"]}"#.utf8))
        XCTAssertEqual(decoded.zoomedPath, [.right, .left])

        // …and that decoded path still selects the pane it was written for.
        XCTAssertEqual(SplitTree(root: root, restoringZoomedPath: decoded.zoomedPath).zoomed,
                       .leaf(view: b))
    }

    /// A saved tree with no zoom decodes as no zoom, and stays distinct from
    /// the empty-path (root-zoomed) case above.
    func testAbsentZoomedPathDecodesAsNoZoomAndEmptyArrayStaysDistinct() throws {
        let noZoom = try JSONDecoder().decode(
            SerializableSplitTree.self, from: Data(#"{}"#.utf8))
        XCTAssertNil(noZoom.zoomedPath)
        XCTAssertNil(SplitTree(root: root, restoringZoomedPath: noZoom.zoomedPath).zoomed)

        let rootZoomed = try JSONDecoder().decode(
            SerializableSplitTree.self, from: Data(#"{"zoomedPath":[]}"#.utf8))
        XCTAssertEqual(rootZoomed.zoomedPath, [])
        XCTAssertEqual(SplitTree(root: root, restoringZoomedPath: rootZoomed.zoomedPath).zoomed,
                       root)
    }
}
