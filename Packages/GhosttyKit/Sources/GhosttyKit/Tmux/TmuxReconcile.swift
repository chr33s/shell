import Foundation

/// One reconcile op as the host reads it (`ghostty_tmux_op_s`).
enum TmuxOp {
    case syncBegin
    case ensureWindow(window: Int, width: Int, height: Int, index: Int)
    case ensurePane(window: Int, pane: TmuxPane)
    case setLayout(window: Int, layout: TmuxLayout, zoomedPane: Int?)
    case setFocus(window: Int, pane: Int)
    case pruneAbsent(windows: [Int], panes: [Int])
    case syncEnd
    case setTabTitle(window: Int, title: String)
}

/// The opaque `tmux_reconcile` payload. Owned by the host from delivery
/// until `ghostty_tmux_reconcile_free`; it keeps every pointer it hands
/// out (panes, layout nodes, id arrays, titles) alive until then.
final class TmuxReconcilePayload: @unchecked Sendable {
    let ops: [TmuxOp]
    /// The viewer generation that produced the batch.
    let generation: UInt64
    private var buffers: [UnsafeMutableRawPointer] = []

    init(ops: [TmuxOp], generation: UInt64 = 0) {
        self.ops = ops
        self.generation = generation
    }

    deinit {
        for b in buffers {
            b.deallocate()
        }
    }

    /// Fills `out` for op `index`; false for an out-of-range index.
    func fill(_ index: Int, _ out: inout ghostty_tmux_op_s) -> Bool {
        guard index >= 0, index < ops.count else { return false }
        out = ghostty_tmux_op_s()
        switch ops[index] {
        case .syncBegin:
            out.tag = GHOSTTY_TMUX_OP_SYNC_BEGIN
        case let .ensureWindow(window, width, height, windowIndex):
            out.tag = GHOSTTY_TMUX_OP_ENSURE_WINDOW
            setWindow(&out, window)
            out.width = UInt(width)
            out.height = UInt(height)
            out.window_index = UInt(windowIndex)
        case let .ensurePane(window, pane):
            out.tag = GHOSTTY_TMUX_OP_ENSURE_PANE
            setWindow(&out, window)
            out.pane_id = UInt(pane.id)
            out.viewer_terminal = Unmanaged.passUnretained(pane.session).toOpaque()
            out.viewer_pane = Unmanaged.passUnretained(pane).toOpaque()
        case let .setLayout(window, layout, zoomed):
            out.tag = GHOSTTY_TMUX_OP_SET_LAYOUT
            setWindow(&out, window)
            out.layout = UnsafeRawPointer(Unmanaged.passUnretained(layout).toOpaque())
            if let zoomed {
                out.zoomed_pane_id = UInt(zoomed)
                out.has_zoomed_pane_id = true
            }
        case let .setFocus(window, pane):
            out.tag = GHOSTTY_TMUX_OP_SET_FOCUS
            setWindow(&out, window)
            out.pane_id = UInt(pane)
        case let .pruneAbsent(windows, panes):
            out.tag = GHOSTTY_TMUX_OP_PRUNE_ABSENT
            out.window_ids = UnsafePointer(store(windows.sorted().map(UInt.init)))
            out.window_ids_len = UInt(windows.count)
            out.pane_ids = UnsafePointer(store(panes.sorted().map(UInt.init)))
            out.pane_ids_len = UInt(panes.count)
        case .syncEnd:
            out.tag = GHOSTTY_TMUX_OP_SYNC_END
        case let .setTabTitle(window, title):
            out.tag = GHOSTTY_TMUX_OP_SET_TAB_TITLE
            setWindow(&out, window)
            let bytes = Array(title.utf8)
            let p = store(bytes + [0]).assumingMemoryBound(to: CChar.self)
            out.title = UnsafePointer(p)
            out.title_len = UInt(bytes.count)
        }
        return true
    }

    private func setWindow(_ out: inout ghostty_tmux_op_s, _ window: Int) {
        out.window_id = UInt(window)
        out.has_window_id = true
    }

    private func store<T>(_ values: [T]) -> UnsafeMutablePointer<T> {
        let p = UnsafeMutablePointer<T>.allocate(capacity: max(1, values.count))
        p.initialize(from: values, count: values.count)
        buffers.append(UnsafeMutableRawPointer(p))
        return p
    }

    private func store(_ bytes: [UInt8]) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(store(bytes) as UnsafeMutablePointer<UInt8>)
    }
}

public func ghostty_tmux_reconcile_op_count(_ p: UnsafeMutableRawPointer?) -> UInt {
    guard let p else { return 0 }
    return UInt(Unmanaged<TmuxReconcilePayload>.fromOpaque(p).takeUnretainedValue().ops.count)
}

public func ghostty_tmux_reconcile_op(_ p: UnsafeMutableRawPointer?, _ index: UInt, _ out: UnsafeMutablePointer<ghostty_tmux_op_s>?) -> Bool {
    guard let p, let out else { return false }
    return Unmanaged<TmuxReconcilePayload>.fromOpaque(p).takeUnretainedValue().fill(Int(index), &out.pointee)
}

/// The viewer generation (one per control-mode stream) of a batch.
public func ghostty_tmux_reconcile_generation(_ p: UnsafeMutableRawPointer?) -> UInt64 {
    guard let p else { return 0 }
    return Unmanaged<TmuxReconcilePayload>.fromOpaque(p).takeUnretainedValue().generation
}

public func ghostty_tmux_reconcile_free(_ p: UnsafeMutableRawPointer?) {
    p.map { Unmanaged<TmuxReconcilePayload>.fromOpaque($0).release() }
}

public func ghostty_tmux_layout_info(_ node: UnsafeRawPointer?, _ out: UnsafeMutablePointer<ghostty_tmux_layout_info_s>?) {
    guard let node, let out else { return }
    let layout = Unmanaged<TmuxLayout>.fromOpaque(node).takeUnretainedValue()
    out.pointee = ghostty_tmux_layout_info_s(
        kind: ghostty_tmux_layout_kind_e(layout.kind.rawValue),
        width: UInt(layout.width), height: UInt(layout.height), x: UInt(layout.x), y: UInt(layout.y),
        pane_id: UInt(layout.paneID), child_count: UInt(layout.children.count),
    )
}

public func ghostty_tmux_layout_child(_ node: UnsafeRawPointer?, _ index: UInt) -> UnsafeRawPointer? {
    guard let node else { return nil }
    let layout = Unmanaged<TmuxLayout>.fromOpaque(node).takeUnretainedValue()
    guard Int(index) < layout.children.count else { return nil }
    return UnsafeRawPointer(Unmanaged.passUnretained(layout.children[Int(index)]).toOpaque())
}
