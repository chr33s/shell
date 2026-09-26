import Foundation
import Testing
@testable import Shell

@MainActor
@Suite
final class TmuxLayoutTests {
    private func pane(_ id: Int, width: Int = 20, height: Int = 24) -> TmuxLayoutNode {
        .pane(paneId: id, width: width, height: height, x: 0, y: 0)
    }

    private func split(_ axis: TmuxLayoutNode.Direction, _ children: [TmuxLayoutNode]) -> TmuxLayoutNode {
        let width = axis == .horizontal ? children.reduce(0) { $0 + $1.width } + children.count - 1 : children.map(\.width).max() ?? 1
        let height = axis == .vertical ? children.reduce(0) { $0 + $1.height } + children.count - 1 : children.map(\.height).max() ?? 1
        return .split(direction: axis, children: children, width: width, height: height, x: 0, y: 0)
    }

    private func columns(width: Int = 20) -> TmuxLayoutNode {
        split(.horizontal, [[1, 10], [7, 13], [11, 12]].map { ids in
            split(.vertical, ids.map { pane($0, width: width) })
        })
    }

    private func pair(width: Int = 20) -> TmuxLayoutNode {
        split(.horizontal, [pane(0, width: width), pane(2, width: width)])
    }

    private var constrained: TmuxLayoutNode {
        split(.horizontal, [pane(0, width: 2, height: 5),
            split(.vertical, [
                split(.horizontal, [1, 2, 3].map { pane($0, width: 1, height: 2) }),
                pane(4, width: 5, height: 2)
            ])
        ])
    }

    private var issue475NestedColumns: TmuxLayoutNode { nestedColumns(equalized: false) }

    private func nestedColumns(equalized: Bool) -> TmuxLayoutNode {
        func column(_ top: Int, _ bottom: Int, width: Int, x: Int) -> TmuxLayoutNode {
            .split(direction: .vertical, children: [
                .pane(paneId: top, width: width, height: 38, x: x, y: 0),
                .pane(paneId: bottom, width: width, height: 38, x: x, y: 39)
            ], width: width, height: 77, x: x, y: 0)
        }
        let middle = column(10, 29, width: equalized ? 69 : 51, x: equalized ? 70 : 105)
        let right = column(26, 30, width: equalized ? 68 : 51, x: equalized ? 140 : 157)
        let nestedRight = TmuxLayoutNode.split(
            direction: .horizontal, children: [middle, right],
            width: equalized ? 138 : 103, height: 77, x: equalized ? 70 : 105, y: 0)
        return .split(direction: .horizontal, children: [
            column(24, 1, width: equalized ? 69 : 104, x: 0), nestedRight
        ], width: 208, height: 77, x: 0, y: 0)
    }

    private func wireLayout(_ node: TmuxLayoutNode) -> String {
        func body(_ node: TmuxLayoutNode) -> String {
            switch node {
            case let .pane(id, width, height, x, y):
                return "\(width)x\(height),\(x),\(y),\(id)"
            case let .split(axis, children, width, height, x, y):
                let brackets = axis == .horizontal ? ("{", "}") : ("[", "]")
                return "\(width)x\(height),\(x),\(y)" + brackets.0
                    + children.map(body).joined(separator: ",") + brackets.1
            }
        }
        let value = body(node)
        var sum: UInt16 = 0
        for byte in value.utf8 { sum = ((sum >> 1) | (sum << 15)) &+ UInt16(byte) }
        let hex = String(sum, radix: 16)
        return String(repeating: "0", count: 4 - hex.count) + hex + "," + value
    }

    private func reply(_ node: TmuxLayoutNode, zoom: Int? = nil, status: String = "off", scrollbars: String = "off") -> String {
        "\(wireLayout(node))|\(zoom == nil ? 0 : 1)|%\(zoom ?? node.paneIDs[0])|\(status)|\(scrollbars)\r\n"
    }

    private func nestedGroups(_ widths: [[Int]]) -> TmuxLayoutNode {
        var id = 0
        var x = 0
        let groups = widths.map { widths -> TmuxLayoutNode in
            let start = x
            let panes = widths.map { width -> TmuxLayoutNode in
                defer { id += 1; x += width + 1 }
                return .pane(paneId: id, width: width, height: 24, x: x, y: 0)
            }
            if panes.count == 1 { return panes[0] }
            return .split(direction: .horizontal, children: panes,
                          width: x - start - 1, height: 24, x: start, y: 0)
        }
        return .split(direction: .horizontal, children: groups, width: x - 1, height: 24, x: 0, y: 0)
    }

    private func transposed(_ node: TmuxLayoutNode) -> TmuxLayoutNode {
        switch node {
        case let .pane(id, w, h, x, y):
            return .pane(paneId: id, width: h, height: w, x: y, y: x)
        case let .split(axis, children, w, h, x, y):
            return .split(direction: axis == .horizontal ? .vertical : .horizontal,
                          children: children.map(transposed), width: h, height: w, x: y, y: x)
        }
    }

    @Test
    func testNestedGroupsUseNativeSpreadWhenLeafResizesCannotReachRoot() async throws {
        let columns = nestedGroups([[75, 75], [25, 25]])
        for original in [columns, transposed(columns)] {
            let target = try #require(original.equalizationTarget())
            #expect(target.hasSameTopology(as: original))
            #expect(target.leaves == original.equalizedLayout()?.leaves)
            #expect((original.resizePlan(to: target)) == nil)
            #expect(original.nativeEqualizationProducesEqualLeaves)
            var current = original
            var spreads = 0
            try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                if command.hasPrefix("display-message") { return self.reply(current) }
                #expect(command.hasPrefix("select-layout -E -t @1.%"))
                spreads += 1
                current = target
                return ""
            }
            #expect(spreads > 0)
            #expect(current == target)
        }
    }

    @Test
    func testUnequalNestedGroupsAreRejectedBeforeMutatingOrUnzooming() async throws {
        let columns = nestedGroups([[75, 75], [16, 16, 17]])
        for original in [columns, transposed(columns)] {
            let target = try #require(original.equalizationTarget())
            #expect((original.resizePlan(to: target)) == nil)
            #expect(!(original.nativeEqualizationProducesEqualLeaves))
            for zoom in [nil, 0] as [Int?] {
                var commands: [String] = []
                do {
                    try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                        commands.append(command)
                        return self.reply(original, zoom: zoom)
                    }
                    Issue.record("Unreachable targets must fail preflight")
                } catch TmuxSplitEqualizer.Failure.unsafeLayout {
                    #expect(commands.count == 1)
                    #expect(commands[0].hasPrefix("display-message"))
                }
            }
        }
    }

    @Test
    func testResizePlanUsesLastChildToReachBoundaryBeforeNestedGroup() throws {
        let left = TmuxLayoutNode.split(direction: .horizontal, children: [
            .pane(paneId: 0, width: 25, height: 24, x: 0, y: 0),
            .pane(paneId: 1, width: 25, height: 24, x: 26, y: 0)
        ], width: 51, height: 24, x: 0, y: 0)
        let columns = TmuxLayoutNode.split(direction: .horizontal, children: [
            left, .pane(paneId: 2, width: 101, height: 24, x: 52, y: 0)
        ], width: 153, height: 24, x: 0, y: 0)
        for original in [columns, transposed(columns)] {
            let target = try #require(original.equalizationTarget())
            let plan = try #require(original.resizePlan(to: target))
            #expect(plan.map(\.paneID) == [2, 0])
            #expect(plan.map(\.size) == [50, 51])
            #expect(plan.map(\.direction) == Array(repeating: original == columns ? .horizontal : .vertical, count: 2))
        }
    }

    @Test
    func testNativeFallbackAllowsRoundingCellsInDifferentGroups() throws {
        let original = nestedGroups([[25, 25], [8, 8]])
        // 69 columns: native -E yields 17/16/17/16, while the flattened
        // sizing model chooses 17/17/16/16. Both are valid equalization.
        #expect(original.width == 69)
        #expect(original.nativeEqualizationProducesEqualLeaves)
        #expect(transposed(original).nativeEqualizationProducesEqualLeaves)
    }

    @Test
    func testUnreachableBoundaryCanStayPutWhenItsGroupsAlreadyHaveTargetSizes() throws {
        let columns = nestedGroups([[60, 20], [60, 30, 28]])
        // The 81/120 group widths are already correct for five columns in 202
        // cells. Only the dividers inside those groups need to move.
        for original in [columns, transposed(columns)] {
            let target = try #require(original.equalizationTarget())
            #expect(!(original.nativeEqualizationProducesEqualLeaves))
            let plan = try #require(original.resizePlan(to: target))
            #expect(plan.map(\.paneID) == [0, 2, 3])
            #expect(plan.map(\.size) == [40, 40, 39])
        }
    }

    @Test
    func testCorrectUnreachableBoundaryDoesNotBlockUnrelatedResize() async throws {
        let columns = nestedGroups([[50, 50], [80], [20]])
        #expect(columns.width == 203)
        for original in [columns, transposed(columns)] {
            let target = try #require(original.equalizationTarget())
            let direction: TmuxLayoutNode.Direction = original == columns ? .horizontal : .vertical
            #expect(original.resizePlan(to: target) == [
                TmuxLayoutNode.PaneResize(paneID: 2, direction: direction, size: 50)
            ])
            var current = original
            var resizes = 0
            try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                if command.hasPrefix("display-message") { return self.reply(current) }
                let flag = direction == .horizontal ? "-x" : "-y"
                #expect(command == "resize-pane -t @1.%2 \(flag) 50")
                resizes += 1
                current = target
                return ""
            }
            #expect(resizes == 1)
            #expect(current.leaves == target.leaves)
        }
    }

    @Test
    func testEarlierShrinkCanPutAnUnreachableBoundaryAtItsTarget() throws {
        let columns = nestedGroups([[80], [35, 35], [20], [80]])
        for original in [columns, transposed(columns)] {
            let target = try #require(original.equalizationTarget())
            // Shrinking pane 0 gives 30 cells to the nested group, making its
            // width 101. Its outer boundary then needs no command. Pane 3 can
            // grow into pane 4 without touching that group again.
            let plan = try #require(original.resizePlan(to: target))
            #expect(plan.map(\.paneID) == [0, 3, 1])
            #expect(plan.map(\.size) == [50, 50, 50])
        }
    }

    @Test
    func testEarlierGrowthInvalidatesAnOtherwiseCorrectUnreachableBoundary() async throws {
        let columns = nestedGroups([[20], [50, 50], [80], [50]])
        for original in [columns, transposed(columns)] {
            let target = try #require(original.equalizationTarget())
            // Growing pane 0 takes 30 cells from the initially correct nested
            // group. Its next boundary is not addressable, so reject the whole
            // plan before issuing the otherwise reachable first resize.
            #expect((original.resizePlan(to: target)) == nil)
            #expect(!(original.nativeEqualizationProducesEqualLeaves))
            var commands: [String] = []
            do {
                try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                    commands.append(command)
                    return self.reply(original, zoom: 0)
                }
                Issue.record("Expected preflight to account for the first resize")
            } catch TmuxSplitEqualizer.Failure.unsafeLayout {
                #expect(commands.count == 1)
                #expect(commands[0].hasPrefix("display-message"))
            }
        }
    }

    @Test
    func testAlreadyEqualNestedGroupsNeedNoMutation() async throws {
        let original = nestedGroups([[50, 50], [50, 50]])
        var commands: [String] = []
        try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
            commands.append(command)
            return self.reply(original, zoom: 0)
        }
        #expect(commands.count == 1)
        #expect(commands[0].hasPrefix("display-message"))
    }

    @Test
    func testTopologyAllowsGeometryChangesButRejectsMovedOrReplacedPanes() throws {
        let original = pair()
        #expect(original.hasSameTopology(as: pair(width: 60)))
        #expect(!(original.hasSameTopology(as: split(.horizontal, [pane(2), pane(0)]))))
        #expect(!(original.hasSameTopology(as: split(.horizontal, [pane(0), pane(8)]))))
        #expect(!(original.hasSameTopology(as: split(.vertical, [pane(0), pane(2)]))))
        #expect(!(original.hasSameTopology(as: pane(0))))
    }

    @Test
    func testServerLayoutParserRejectsUncheckedGeometry() throws {
        #expect(TmuxLayoutNode.parseServerLayout("b25d,80x24,0,0,0") == pane(0, width: 80, height: 24))
        #expect((TmuxLayoutNode.parseServerLayout("0000,80x24,0,0,0")) == nil)
        #expect((TmuxLayoutNode.parseServerLayout("unknown-format")) == nil)
        #expect(TmuxLayoutNode.parseServerLayout(wireLayout(constrained)) == constrained)
        #expect((TmuxLayoutNode.parseServerLayout(wireLayout(split(.horizontal, [pane(0), pane(0)])))) == nil)
        let malformed = TmuxLayoutNode.split(direction: .horizontal, children: [pane(0), pane(2)], width: 2, height: 24, x: 0, y: 0)
        #expect((TmuxLayoutNode.parseServerLayout(wireLayout(malformed))) == nil)
    }

    @Test
    func testIssue475NestedColumnsFlattenToEqualLeafWidths() throws {
        let original = issue475NestedColumns
        #expect(original.hasNestedSameAxisSplit)
        let equalized = try #require(original.equalizedLayout())
        #expect(equalized.paneIDs == [24, 1, 10, 29, 26, 30])
        guard case let .split(.horizontal, columns, width, height, x, y) = equalized else {
            Issue.record("Expected flattened horizontal root")
return
        }
        #expect(width == 208)
        #expect(height == 77)
        #expect(x == 0)
        #expect(y == 0)
        #expect(columns.count == 3)
        #expect(columns.map(\.width) == [69, 69, 68])
        #expect(TmuxLayoutNode.parseServerLayout(equalized.serverLayoutString) == equalized)
    }

    @Test
    func testIssue475NestedColumnsResizeWithoutImportingLayout() async throws {
        let original = issue475NestedColumns
        let equalized = try #require(original.equalizedLayout())
        var current = original
        var commands: [String] = []
        try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
            commands.append(command)
            if command.hasPrefix("display-message") { return self.reply(current) }
            if command.hasPrefix("resize-pane -t @1.%24 -x 69") {
                current = self.nestedColumns(equalized: true)
            } else { Issue.record("Unexpected command: \(command)") }
            return ""
        }
        #expect(current.leaves == equalized.leaves)
        #expect(current.hasSameTopology(as: original))
        #expect(commands.filter { $0.hasPrefix("resize-pane") }.count == 1)
        #expect(!(commands.contains { $0.hasPrefix("select-layout") }))
    }

    @Test
    func testNestedResizeStopsWhenTopologyChangesWithSamePaneOrder() async throws {
        let original = issue475NestedColumns
        let changed = try #require(original.equalizedLayout())
        var current = original
        var commands: [String] = []
        do {
            try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                commands.append(command)
                if command.hasPrefix("display-message") { return self.reply(current) }
                if command.hasPrefix("resize-pane") {
                    current = changed
                    return ""
                }
                Issue.record("Unexpected command: \(command)")
                return ""
            }
            Issue.record("Expected topology mismatch")
        } catch TmuxSplitEqualizer.Failure.layoutChanged {
            #expect(commands.filter { $0.hasPrefix("resize-pane") }.count == 1)
            #expect(!(commands.contains { $0.hasPrefix("select-layout") }))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func testPerpendicularGroupRetainsMinimumWidth() async throws {
        #expect(constrained.width == 8)
        #expect(!(constrained.permitsNativeEqualization))
        var commands: [String] = []
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: constrained) { command in
                commands.append(command)
                return self.reply(self.constrained, zoom: 0)
            }
            Issue.record("Root spreading would shrink the five-column subtree to three")
        } catch TmuxSplitEqualizer.Failure.unsafeLayout {
            #expect(commands.count == 1)
            #expect(commands[0].hasPrefix("display-message"))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test
    func testSafetyIncludesAncestorShrinkAndBothAxes() throws {
        let deep = split(.vertical, [constrained, pane(5, width: 8, height: 5)])
        #expect(!(deep.permitsNativeEqualization))
        func transpose(_ node: TmuxLayoutNode) -> TmuxLayoutNode {
            switch node {
            case let .pane(id, w, h, _, _): return pane(id, width: h, height: w)
            case let .split(axis, children, _, _, _, _):
                return split(axis == .horizontal ? .vertical : .horizontal, children.map(transpose))
            }
        }
        #expect(!(transpose(constrained).permitsNativeEqualization))
        #expect(columns().permitsNativeEqualization)
    }

    @Test
    func testSixPaneLayoutWaitsForServerGeometryToSettle() async throws {
        var spreads = 0
        var commands: [String] = []
        try await TmuxSplitEqualizer.run(windowID: 4, layout: columns()) { command in
            commands.append(command)
            if command.hasPrefix("display-message") {
                return self.reply(self.columns(width: 20 + min((spreads + 5) / 6, 2)))
            }
            spreads += 1
            return ""
        }
        #expect(spreads == 18)
        #expect(commands.filter { $0.hasPrefix("select-layout") } == Array(repeating: [1, 10, 7, 13, 11, 12].map {
            "select-layout -E -t @4.%\($0)"
        }, count: 3).flatMap { $0 })
        #expect(commands.allSatisfy { !$0.contains(";") && !$0.contains("\n") })
        #expect(commands.filter { $0.hasPrefix("display-message") }.count == spreads + 1)
    }

    @Test
    func testZoomedPaneZeroIsRestoredWithItsOwnCommandAfterConvergence() async throws {
        var commands: [String] = []
        try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { command in
            commands.append(command)
            return command.hasPrefix("display-message") ? self.reply(self.pair(), zoom: commands.count == 1 ? 0 : nil) : ""
        }
        #expect(commands.last == "resize-pane -Z -t @9.%0")
        #expect(commands.filter { $0.hasPrefix("resize-pane") }.count == 1)
        #expect(commands.allSatisfy { !$0.contains(";") && !$0.contains("\n") })
    }

    @Test
    func testExistingZoomIsNotToggledOffDuringRestoration() async throws {
        var reads = 0
        try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { command in
            #expect(!(command.hasPrefix("resize-pane")))
            guard command.hasPrefix("display-message") else { return "" }
            reads += 1
            return self.reply(self.pair(), zoom: reads == 1 ? 0 : (reads == 4 ? 2 : nil))
        }
        #expect(reads == 4)
    }

    @Test
    func testFailureStopsSpreadingAndRestoresZoom() async throws {
        var reads = 0
        var commands: [String] = []
        do {
            try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { command in
                commands.append(command)
                if command.hasPrefix("display-message") {
                    reads += 1
                    return self.reply(self.pair(), zoom: reads == 1 ? 0 : nil)
                }
                if command.hasPrefix("select-layout") { throw TmuxSplitEqualizer.Failure.layoutChanged }
                return ""
            }
            Issue.record("Expected failure")
        } catch TmuxSplitEqualizer.Failure.layoutChanged {
            #expect(commands.filter { $0.hasPrefix("select-layout") }.count == 1)
            #expect(commands.last == "resize-pane -Z -t @9.%0")
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test
    func testServerGeometryIsRecheckedBeforeEverySpread() async throws {
        let roomy = TmuxLayoutNode.split(direction: .horizontal,
            children: [pane(0, width: 6, height: 5), split(.vertical, [
                split(.horizontal, [1, 2, 3].map { pane($0, width: 2, height: 2) }),
                pane(4, width: 8, height: 2)
            ])], width: 15, height: 5, x: 0, y: 0)
        #expect(roomy.permitsNativeEqualization)
        var spreads = 0
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: roomy) { command in
                if command.hasPrefix("display-message") { return self.reply(spreads == 0 ? roomy : self.constrained) }
                spreads += 1
                return ""
            }
            Issue.record("Must stop when the server layout becomes constrained")
        } catch TmuxSplitEqualizer.Failure.unsafeLayout {
            #expect(spreads == 1)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test
    func testDecorationsFailClosedInsteadOfUndercountingMinimumCells() async throws {
        for (status, scrollbars) in [("top", "off"), ("off", "on")] {
            var calls = 0
            do {
                try await TmuxSplitEqualizer.run(windowID: 0, layout: pair()) { _ in
                    calls += 1
                    return self.reply(self.pair(), status: status, scrollbars: scrollbars)
                }
                Issue.record("Decoration minima must not be ignored")
            } catch TmuxSplitEqualizer.Failure.unsafeLayout {
                #expect(calls == 1)
            } catch { Issue.record("Unexpected error: \(error)") }
        }
    }

    @Test
    func testInvalidSnapshotDoesNotMutateServer() async throws {
        var calls = 0
        do {
            try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { _ in calls += 1; return "malformed" }
            Issue.record("Expected invalid snapshot")
        } catch TmuxSplitEqualizer.Failure.invalidSnapshot {
            #expect(calls == 1)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test
    func testConcurrentResizesCannotLoopForever() async throws {
        var reads = 0
        let layout = pair()
        do {
            try await TmuxSplitEqualizer.run(windowID: 9, layout: layout) { command in
                guard command.hasPrefix("display-message") else { return "" }
                reads += 1
                return self.reply(self.pair(width: 20 + reads))
            }
            Issue.record("Expected bounded failure")
        } catch TmuxSplitEqualizer.Failure.didNotConverge {
            #expect(reads == 1 + layout.paneIDs.count * (2 * layout.depth + 1))
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test
    func testSinglePaneNeedsNoCommands() async throws {
        try await TmuxSplitEqualizer.run(windowID: 0, layout: pane(0)) { _ in
            Issue.record("A single pane is already equalized")
            return ""
        }
    }

    @Test
    func testDuplicatePaneIDsAreRejectedBeforeSending() async throws {
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: split(.horizontal, [pane(0), pane(0)])) { _ in
                Issue.record("Malformed topology must not reach the server")
                return ""
            }
            Issue.record("Expected malformed topology to fail")
        } catch TmuxSplitEqualizer.Failure.layoutChanged {
        } catch { Issue.record("Unexpected error: \(error)") }
    }
}
