import Foundation
import SwifttyCore

/// A paste in flight: handed to the host as the clipboard request `state`
/// and returned through `ghostty_surface_complete_clipboard_request`.
final class ClipboardRequest {
    weak var surface: Surface?

    init(surface: Surface) {
        self.surface = surface
    }
}

extension Surface {
    /// Runs a Ghostty binding action (`name[:param]`); false when unknown or
    /// it had nothing to act on.
    func performBinding(_ spec: String) -> Bool {
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let param = parts.count > 1 ? String(parts[1]) : nil
        let rows = renderer.grid.rows
        switch name {
        case "copy_to_clipboard":
            guard let text = session.withState({ $0.selectionText }), !text.isEmpty else { return false }
            app.writeClipboard(self, text: text, location: GHOSTTY_CLIPBOARD_STANDARD)
        case "paste_from_clipboard":
            let request = Unmanaged.passRetained(ClipboardRequest(surface: self)).toOpaque()
            if !app.readClipboard(self, state: request) {
                Unmanaged<ClipboardRequest>.fromOpaque(request).release()
                return false
            }
        case "scroll_page_up": session.mutateAsync { $0.scrollViewport(by: rows) }
        case "scroll_page_down": session.mutateAsync { $0.scrollViewport(by: -rows) }
        case "scroll_page_lines":
            guard let n = param.flatMap(Int.init) else { return false }
            session.mutateAsync { $0.scrollViewport(by: -n) }
        case "scroll_to_top": session.mutateAsync { $0.scrollViewport(by: Int.max / 2) }
        case "scroll_to_bottom": session.mutateAsync { $0.scrollViewportToBottom() }
        case "scroll_to_row":
            guard let n = param.flatMap(Int.init) else { return false }
            session.mutateAsync { $0.scrollViewport(toTopRow: n) }
        case "select_all":
            session.mutateAsync { state in
                let first = state.firstAbsoluteRow
                let last = first + state.addressableRows - 1
                state.setSelection(Selection(
                    anchor: TerminalPoint(row: first, column: 0),
                    head: TerminalPoint(row: last, column: state.columns - 1),
                ))
            }
        case "clear_screen": session.mutateAsync { $0.clearScreenKeepingCursorLine() }
        case "reset": session.mutateAsync { $0.reset() }
        case "start_search":
            app.post(self, tag: GHOSTTY_ACTION_START_SEARCH) {
                $0.start_search = ghostty_action_start_search_s(needle: nil)
            }
        case "search":
            let needle = param ?? ""
            let result = session.mutate { state -> (Int, Int?) in
                state.search(needle)
                let selected = state.selectSearchMatch(forward: false)
                return (state.searchMatches.count, selected)
            }
            postSearch(total: needle.isEmpty ? nil : result.0, selected: result.1)
        case "navigate_search":
            // "next" walks towards older output, as Ghostty's search does.
            let forward = param == "previous"
            let result = session.mutate { state -> (Int, Int?) in
                (state.searchMatches.count, state.selectSearchMatch(forward: forward))
            }
            postSearch(total: result.0, selected: result.1)
        case "end_search":
            session.mutateAsync { $0.endSearch() }
            app.post(self, tag: GHOSTTY_ACTION_END_SEARCH)
        case "toggle_mouse_reporting":
            withInput { $0.mouseReportingDisabled.toggle() }
        case "increase_font_size":
            renderer.adjustFontSize(by: param.flatMap(Double.init) ?? 1)
        case "decrease_font_size":
            renderer.adjustFontSize(by: -(param.flatMap(Double.init) ?? 1))
        case "reset_font_size":
            renderer.adjustFontSize(by: nil)
        case "text":
            guard let param else { return false }
            sendRaw(Self.unescape(param))
        case "esc":
            guard let param else { return false }
            sendRaw([0x1B] + Array(param.utf8))
        case "csi":
            guard let param else { return false }
            sendRaw([0x1B, 0x5B] + Array(param.utf8))
        case "ignore":
            break
        default:
            return false
        }
        return true
    }

    private func postSearch(total: Int?, selected: Int?) {
        let t = total.map { Int($0) } ?? -1
        let s = selected.map { Int($0) } ?? -1
        app.post(self, tag: GHOSTTY_ACTION_SEARCH_TOTAL) { $0.search_total = ghostty_action_search_total_s(total: t) }
        app.post(self, tag: GHOSTTY_ACTION_SEARCH_SELECTED) { $0.search_selected = ghostty_action_search_selected_s(selected: s) }
    }

    /// Completes a paste the host was asked for.
    func completeClipboard(_ text: String, state: UnsafeMutableRawPointer?, confirmed: Bool) {
        if let state {
            Unmanaged<ClipboardRequest>.fromOpaque(state).release()
        }
        guard config.clipboardRead else { return }
        sendText(text)
    }

    /// Zig-style escapes in `text:` bindings: \n \r \t \e \\ \xNN.
    static func unescape(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var chars = Array(s.utf8)[...]
        while let c = chars.popFirst() {
            guard c == 0x5C, let n = chars.popFirst() else {
                out.append(c)
                continue
            }
            switch n {
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x65, 0x45: out.append(0x1B)
            case 0x78:
                let hex = String(decoding: chars.prefix(2), as: UTF8.self)
                if let v = UInt8(hex, radix: 16) {
                    out.append(v)
                    chars = chars.dropFirst(2)
                }
            default: out.append(n)
            }
        }
        return out
    }
}
