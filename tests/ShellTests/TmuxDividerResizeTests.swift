import XCTest
@testable import Shell

final class TmuxDividerResizeTests: XCTestCase {
    private func pane(_ id: Int, _ size: Int = 40) -> TmuxLayoutNode {
        .pane(paneId: id, width: size, height: size, x: 0, y: 0)
    }

    private func split(_ axis: TmuxLayoutNode.Direction, _ children: [TmuxLayoutNode]) -> TmuxLayoutNode {
        .split(direction: axis, children: children, width: 122, height: 122, x: 0, y: 0)
    }

    func testInnerDividerUsesItsOwnRegionAndProducesNoResizeForAnUnmovedDrag() {
        // B | C occupies 802 points, including a 2-point native divider.
        // Moving from 50% to 60% means eight cells, not 60% of the window.
        XCTAssertEqual(TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: 0.6,
                       extent: 802, divider: 2, cell: 10), 8)
        XCTAssertEqual(TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: 0.5,
                       extent: 802, divider: 2, cell: 10), 0)
        XCTAssertEqual(TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: 0.4,
                       extent: 802, divider: 2, cell: 10), -8)
    }

    func testThreeColumnsAndRowsTargetTheMiddlePane() {
        for axis in [TmuxLayoutNode.Direction.horizontal, .vertical] {
            let layout = split(axis, [pane(0), pane(1), pane(2)])
            XCTAssertEqual(TmuxDividerResize.target(in: layout, horizontal: axis == .horizontal,
                           leftPaneIDs: [1], rightPaneIDs: [2], delta: 8),
                           .init(paneID: 1, size: 48))
        }
    }

    func testFourColumnsResolveTheRightFoldedSuffix() {
        let layout = split(.horizontal, [pane(0), pane(1), pane(2), pane(3)])
        XCTAssertEqual(TmuxDividerResize.target(in: layout, horizontal: true,
                       leftPaneIDs: [1], rightPaneIDs: [2, 3], delta: -8),
                       .init(paneID: 1, size: 32))
    }

    func testPerpendicularGroupUsesItsSharedExtent() {
        let rows = split(.vertical, [pane(0), pane(1)])
        let layout = split(.horizontal, [rows, pane(2)])
        XCTAssertEqual(TmuxDividerResize.target(in: layout, horizontal: true,
                       leftPaneIDs: [0, 1], rightPaneIDs: [2], delta: 8),
                       .init(paneID: 0, size: rows.width + 8))
    }

    func testNestedLeftGroupTargetsTheOppositePaneRatherThanItsInternalDivider() {
        let left = split(.horizontal, [pane(0), pane(1)])
        let layout = split(.horizontal, [left, pane(2)])
        XCTAssertEqual(TmuxDividerResize.target(in: layout, horizontal: true,
                       leftPaneIDs: [0, 1], rightPaneIDs: [2], delta: 8),
                       .init(paneID: 2, size: 32))
    }

    func testUnaddressableBoundaryAndStalePaneOrderAreRejected() {
        let layout = split(.horizontal, [
            split(.horizontal, [pane(0), pane(1)]),
            split(.horizontal, [pane(2), pane(3)])
        ])
        XCTAssertNil(TmuxDividerResize.target(in: layout, horizontal: true,
                     leftPaneIDs: [0, 1], rightPaneIDs: [2, 3], delta: 8))
        XCTAssertNil(TmuxDividerResize.target(in: layout, horizontal: true,
                     leftPaneIDs: [1, 0], rightPaneIDs: [2, 3], delta: 8))
    }

    func testInvalidMetricsCannotProduceACommand() {
        for cell in [0, -1, Double.nan, Double.infinity] {
            XCTAssertNil(TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: 0.6,
                         extent: 802, divider: 2, cell: cell))
        }
        XCTAssertNil(TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: .nan,
                     extent: 802, divider: 2, cell: 10))
        XCTAssertNil(TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: 0.6,
                     extent: 2, divider: 2, cell: 10))
    }
}
