import Foundation
import Testing
@testable import Shell

@Suite
final class TmuxDividerResizeTests {
    private func pane(_ id: Int, _ size: Int = 40) -> TmuxLayoutNode {
        .pane(paneId: id, width: size, height: size, x: 0, y: 0)
    }

    private func split(_ axis: TmuxLayoutNode.Direction, _ children: [TmuxLayoutNode]) -> TmuxLayoutNode {
        .split(direction: axis, children: children, width: 122, height: 122, x: 0, y: 0)
    }

    @Test
    func testInnerDividerUsesItsOwnRegionAndProducesNoResizeForAnUnmovedDrag() throws {
        // B | C occupies 802 points, including a 2-point native divider.
        // Moving from 50% to 60% means eight cells, not 60% of the window.
        #expect(TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: 0.6,
                       extent: 802, divider: 2, cell: 10) == 8)
        #expect(TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: 0.5,
                       extent: 802, divider: 2, cell: 10) == 0)
        #expect(TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: 0.4,
                       extent: 802, divider: 2, cell: 10) == -8)
    }

    @Test
    func testThreeColumnsAndRowsTargetTheMiddlePane() throws {
        for axis in [TmuxLayoutNode.Direction.horizontal, .vertical] {
            let layout = split(axis, [pane(0), pane(1), pane(2)])
            #expect(TmuxDividerResize.target(in: layout, horizontal: axis == .horizontal,
                           leftPaneIDs: [1], rightPaneIDs: [2], delta: 8) == .init(paneID: 1, size: 48))
        }
    }

    @Test
    func testFourColumnsResolveTheRightFoldedSuffix() throws {
        let layout = split(.horizontal, [pane(0), pane(1), pane(2), pane(3)])
        #expect(TmuxDividerResize.target(in: layout, horizontal: true,
                       leftPaneIDs: [1], rightPaneIDs: [2, 3], delta: -8) == .init(paneID: 1, size: 32))
    }

    @Test
    func testPerpendicularGroupUsesItsSharedExtent() throws {
        let rows = split(.vertical, [pane(0), pane(1)])
        let layout = split(.horizontal, [rows, pane(2)])
        #expect(TmuxDividerResize.target(in: layout, horizontal: true,
                       leftPaneIDs: [0, 1], rightPaneIDs: [2], delta: 8) == .init(paneID: 0, size: rows.width + 8))
    }

    @Test
    func testNestedLeftGroupTargetsTheOppositePaneRatherThanItsInternalDivider() throws {
        let left = split(.horizontal, [pane(0), pane(1)])
        let layout = split(.horizontal, [left, pane(2)])
        #expect(TmuxDividerResize.target(in: layout, horizontal: true,
                       leftPaneIDs: [0, 1], rightPaneIDs: [2], delta: 8) == .init(paneID: 2, size: 32))
    }

    @Test
    func testUnaddressableBoundaryAndStalePaneOrderAreRejected() throws {
        let layout = split(.horizontal, [
            split(.horizontal, [pane(0), pane(1)]),
            split(.horizontal, [pane(2), pane(3)])
        ])
        #expect((TmuxDividerResize.target(in: layout, horizontal: true,
                     leftPaneIDs: [0, 1], rightPaneIDs: [2, 3], delta: 8)) == nil)
        #expect((TmuxDividerResize.target(in: layout, horizontal: true,
                     leftPaneIDs: [1, 0], rightPaneIDs: [2, 3], delta: 8)) == nil)
    }

    @Test
    func testInvalidMetricsCannotProduceACommand() throws {
        for cell in [0, -1, Double.nan, Double.infinity] {
            #expect((TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: 0.6,
                         extent: 802, divider: 2, cell: cell)) == nil)
        }
        #expect((TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: .nan,
                     extent: 802, divider: 2, cell: 10)) == nil)
        #expect((TmuxDividerResize.cellDelta(startRatio: 0.5, endRatio: 0.6,
                     extent: 2, divider: 2, cell: 10)) == nil)
    }
}
