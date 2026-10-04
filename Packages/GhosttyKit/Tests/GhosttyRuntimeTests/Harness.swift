import Foundation
import GhosttyKit
@testable import GhosttyRuntime

/// Actions seen by the test app, decoded while their payloads are valid.
enum Recorded: Equatable {
    case reconcile([String])
    case response(tag: UInt32, error: Bool, body: String)
    case ptyResize(rows: UInt32, cols: UInt32)
    case title(String)
    case other(UInt32)
}

final class Recorder: @unchecked Sendable {
    static let shared = Recorder()
    private let lock = NSLock()
    private var items: [Recorded] = []

    func append(_ r: Recorded) {
        lock.lock(); items.append(r); lock.unlock()
    }

    var all: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func clear() {
        lock.lock(); items = []; lock.unlock()
    }

    /// Waits until `predicate` holds over the recorded actions.
    @discardableResult
    func wait(timeout: TimeInterval = 10, _ predicate: ([Recorded]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(all) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return predicate(all)
    }
}

/// Describes a reconcile batch as strings, e.g. "pane @1 %0".
func describe(_ payload: UnsafeMutableRawPointer) -> [String] {
    var out: [String] = []
    for i in 0 ..< ghostty_tmux_reconcile_op_count(payload) {
        var op = ghostty_tmux_op_s()
        guard ghostty_tmux_reconcile_op(payload, i, &op) else { continue }
        switch op.tag {
        case GHOSTTY_TMUX_OP_SYNC_BEGIN: out.append("begin")
        case GHOSTTY_TMUX_OP_ENSURE_WINDOW: out.append("window @\(op.window_id) \(op.width)x\(op.height)")
        case GHOSTTY_TMUX_OP_ENSURE_PANE: out.append("pane @\(op.window_id) %\(op.pane_id)")
        case GHOSTTY_TMUX_OP_SET_LAYOUT:
            var info = ghostty_tmux_layout_info_s()
            ghostty_tmux_layout_info(op.layout, &info)
            out.append("layout @\(op.window_id) kind=\(info.kind.rawValue) children=\(info.child_count)")
        case GHOSTTY_TMUX_OP_SET_FOCUS: out.append("focus @\(op.window_id) %\(op.pane_id)")
        case GHOSTTY_TMUX_OP_PRUNE_ABSENT: out.append("prune windows=\(op.window_ids_len) panes=\(op.pane_ids_len)")
        case GHOSTTY_TMUX_OP_SYNC_END: out.append("end")
        case GHOSTTY_TMUX_OP_SET_TAB_TITLE:
            out.append("title @\(op.window_id) " + String(decoding: UnsafeRawBufferPointer(start: op.title, count: Int(op.title_len)), as: UTF8.self))
        default: out.append("op \(op.tag.rawValue)")
        }
    }
    return out
}

/// A runtime app with recording callbacks.
func makeApp(configText: String = "") -> ghostty_app_t {
    let config = ghostty_config_new()!
    Unmanaged<Config>.fromOpaque(config).takeUnretainedValue().load(text: configText)
    ghostty_config_finalize(config)
    var runtime = ghostty_runtime_config_s()
    runtime.action_cb = { _, _, action in
        switch action.tag {
        case GHOSTTY_ACTION_TMUX_RECONCILE:
            let payload = action.action.tmux_reconcile!
            Recorder.shared.append(.reconcile(describe(payload)))
            ghostty_tmux_reconcile_free(payload)
        case GHOSTTY_ACTION_TMUX_COMMAND_RESPONSE:
            let r = action.action.tmux_command_response
            let body = r.body.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(r.body_len)), as: UTF8.self) } ?? ""
            Recorder.shared.append(.response(tag: r.tag, error: r.is_err, body: body))
        case GHOSTTY_ACTION_PTY_RESIZE:
            Recorder.shared.append(.ptyResize(rows: action.action.pty_resize.rows, cols: action.action.pty_resize.cols))
        case GHOSTTY_ACTION_SET_TITLE:
            Recorder.shared.append(.title(String(cString: action.action.set_title.title)))
        default:
            Recorder.shared.append(.other(action.tag.rawValue))
        }
        return true
    }
    return ghostty_app_new(&runtime, config)!
}

func makeSurface(_ app: ghostty_app_t) -> ghostty_surface_t {
    var cfg = ghostty_surface_config_new()
    cfg.use_external_io = true
    cfg.scale_factor = 2
    return ghostty_surface_new(app, &cfg)!
}

/// Viewport text of a surface (rows `0..<rows`).
func screenText(_ s: ghostty_surface_t) -> [String] {
    let size = ghostty_surface_size(s)
    var sel = ghostty_selection_s()
    sel.top_left.tag = GHOSTTY_POINT_VIEWPORT
    sel.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
    sel.bottom_right.x = UInt32(max(1, size.columns) - 1)
    sel.bottom_right.y = UInt32(max(1, size.rows) - 1)
    var text = ghostty_text_s()
    guard ghostty_surface_read_text(s, sel, &text) else { return [] }
    defer { ghostty_surface_free_text(s, &text) }
    return String(cString: text.text).components(separatedBy: "\n")
}

func waitFor(timeout: TimeInterval = 10, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return predicate()
}

func write(_ fd: Int32, _ s: String) {
    let bytes = Array(s.utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
}

/// Reads whatever is available within `timeout`.
func drain(_ fd: Int32, timeout: TimeInterval = 1) -> String {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 { out += buf[0 ..< n] } else { Thread.sleep(forTimeInterval: 0.02) }
    }
    _ = fcntl(fd, F_SETFL, flags)
    return String(decoding: out, as: UTF8.self)
}
