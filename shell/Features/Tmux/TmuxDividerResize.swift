/// Converts a native divider drag into a resize of the matching server cell.
/// The UI right-folds n-ary tmux splits, so neither its ratio nor its first
/// leaf necessarily identifies a whole-window size or the correct boundary.
nonisolated enum TmuxDividerResize {
    struct Target: Equatable {
        let paneID: Int
        let size: Int
    }

    static func cellDelta(startRatio: Double, endRatio: Double,
                          extent: Double, divider: Double, cell: Double) -> Int? {
        guard startRatio.isFinite, endRatio.isFinite,
              (0...1).contains(startRatio), (0...1).contains(endRatio),
              extent.isFinite, divider.isFinite, cell.isFinite,
              divider >= 0, extent > divider, cell > 0 else { return nil }
        let delta = ((endRatio - startRatio) * (extent - divider) / cell).rounded()
        guard abs(delta) < Double(Int32.max) else { return nil }
        return Int(delta)
    }

    static func target(in layout: TmuxLayoutNode, horizontal: Bool,
                       leftPaneIDs: [Int], rightPaneIDs: [Int], delta: Int) -> Target? {
        guard !leftPaneIDs.isEmpty, !rightPaneIDs.isEmpty,
              delta > -Int(Int32.max), delta < Int(Int32.max) else { return nil }
        let axis: TmuxLayoutNode.Direction = horizontal ? .horizontal : .vertical
        return find(in: layout, axis: axis, left: leftPaneIDs, right: rightPaneIDs, delta: delta)
    }

    private static func find(in node: TmuxLayoutNode, axis: TmuxLayoutNode.Direction,
                             left: [Int], right: [Int], delta: Int) -> Target? {
        guard case let .split(direction, children, _, _, _, _) = node else { return nil }
        if direction == axis {
            for index in children.indices.dropLast() {
                guard children[index].paneIDs == left,
                      children.dropFirst(index + 1).flatMap(\.paneIDs) == right else { continue }
                // resize-pane acts on the nearest ancestor with this axis.
                // Prefer the cell before the divider, which grows with delta.
                if let paneID = representative(in: children[index], axis: axis) {
                    let size = axis == .horizontal ? children[index].width : children[index].height
                    return Target(paneID: paneID, size: max(1, size + delta))
                }
                // A last sibling can address its leading edge instead. This
                // handles (A | B) | C without accidentally resizing A | B.
                if index + 1 == children.count - 1,
                   let paneID = representative(in: children[index + 1], axis: axis) {
                    let size = axis == .horizontal ? children[index + 1].width : children[index + 1].height
                    return Target(paneID: paneID, size: max(1, size - delta))
                }
                // Neither side has a leaf targeting this server boundary.
                // Do not silently move a different nested divider.
                return nil
            }
        }
        for child in children {
            if let target = find(in: child, axis: axis, left: left, right: right, delta: delta) {
                return target
            }
        }
        return nil
    }

    private static func representative(in node: TmuxLayoutNode, axis: TmuxLayoutNode.Direction) -> Int? {
        switch node {
        case let .pane(id, _, _, _, _): return id
        case let .split(direction, children, _, _, _, _):
            guard direction != axis else { return nil }
            return children.lazy.compactMap { representative(in: $0, axis: axis) }.first
        }
    }
}
