import Foundation
import os
import QuartzCore
import SwifttyCore

/// Pointer, click and key-sequence state, guarded by `Surface.inputLock`.
struct InputState {
    var position = (x: 0.0, y: 0.0) // points
    var mods: Mods = []
    var leftDown = false
    var buttonsDown: Set<UInt32> = []
    var clickCount = 0
    var lastClickTime = 0.0
    var lastClickCell = (column: -1, row: -1)
    /// Word/line granularity of the current drag selection.
    var dragUnit = 1
    var dragAnchor: TerminalPoint?
    var handleDrag = false
    /// Repeats scrolling while a drag is held past the top or bottom edge.
    var autoScroll: DispatchSourceTimer?
    var scrollRemainder = 0.0
    var mouseReportingDisabled = false
    var pendingSequence: [Trigger] = []
    /// Keys whose press a keybinding consumed; their release is swallowed too.
    var consumedKeys: Set<UInt32> = []
    /// The encoded press of each held key: the host's releases carry no
    /// text or codepoint, so a release reuses its press.
    var heldKeys: [UInt32: KeyEvent] = [:]
    var hoveredLink: String?
}

extension Surface {
    static let inputLock = OSAllocatedUnfairLock()

    func withInput<R>(_ body: (inout InputState) -> R) -> R {
        Self.inputLock.withLockUnchecked { body(&input) }
    }

    // MARK: Coordinates

    /// Viewport cell under a point (rows may be outside the grid).
    func cell(atPoints x: Double, _ y: Double) -> (column: Int, row: Int) {
        let m = renderer.metrics
        let px = x * m.scale - m.paddingX
        let py = y * m.scale - m.paddingY + renderer.smoothScrollOffset
        let column = Int(floor(px / m.cellWidth))
        let row = Int(floor(py / m.cellHeight))
        let grid = renderer.grid
        return (min(max(column, 0), grid.columns - 1), row)
    }

    var mouseCaptured: Bool {
        let tracking = !mirror.modes.isDisjoint(with: Modes.mouseTracking)
        return tracking && !withInput { $0.mouseReportingDisabled }
    }

    // MARK: Keys

    func key(_ event: ghostty_input_key_s) -> Bool {
        let mods = Mods(rawValue: event.mods.rawValue)
        let named = NamedKey.from(keycode: event.keycode)
        let text = event.text.flatMap { String(validatingCString: $0) }
        if named?.isModifier == true {
            return false
        }
        let action: KeyEvent.Action = switch event.action {
        case GHOSTTY_ACTION_RELEASE: .release
        case GHOSTTY_ACTION_REPEAT: .repeat
        default: .press
        }
        if action == .release {
            if withInput({ $0.consumedKeys.remove(event.keycode) != nil }) {
                return true
            }
        } else if performKeybind(named: named, unshifted: event.unshifted_codepoint, text: text, mods: mods) {
            withInput { _ = $0.consumedKeys.insert(event.keycode) }
            return true
        }
        let resolved: KeyEvent? = if action == .release {
            withInput { $0.heldKeys.removeValue(forKey: event.keycode) }.map { press in
                var release = press
                release.action = .release
                return release
            }
        } else {
            keyEvent(named: named, unshifted: event.unshifted_codepoint, text: text, mods: mods, action: action)
        }
        guard let keyEvent = resolved else {
            return false
        }
        if action != .release {
            withInput { $0.heldKeys[event.keycode] = keyEvent }
        }
        if action != .release {
            renderer.noteInput()
        }
        // The encoder drops releases unless the application asked for them
        // (kitty keyboard protocol event types).
        sendInput(.key(keyEvent))
        return action != .release
    }

    private func performKeybind(named: NamedKey?, unshifted: UInt32, text: String?, mods: Mods) -> Bool {
        let binds = config.keybinds
        let pending = withInput { $0.pendingSequence }
        let depth = pending.count
        var prefixMatch = false
        for bind in binds where bind.sequence.count > depth && Array(bind.sequence.prefix(depth)) == pending {
            guard bind.sequence[depth].matches(key: named, unshifted: unshifted, text: text, mods: mods) else { continue }
            if bind.sequence.count == depth + 1 {
                withInput { $0.pendingSequence = [] }
                return performBinding(bind.action) || !bind.flags.contains("performable")
            }
            withInput { $0.pendingSequence = Array(bind.sequence.prefix(depth + 1)) }
            prefixMatch = true
            break
        }
        if !prefixMatch, depth > 0 {
            withInput { $0.pendingSequence = [] }
        }
        return prefixMatch
    }

    /// The key as swiftty sees it; the session encodes it for the
    /// application's keyboard mode (xterm or kitty).
    private func keyEvent(named: NamedKey?, unshifted: UInt32, text: String?, mods: Mods, action: KeyEvent.Action) -> KeyEvent? {
        var keyMods: KeyModifiers = []
        if mods.contains(.shift) { keyMods.insert(.shift) }
        if mods.contains(.ctrl) { keyMods.insert(.control) }
        let altIsMeta: Bool = switch config.optionAsAlt {
        case .both: true
        case .none: false
        case .left: !mods.contains(.altRight)
        case .right: mods.contains(.altRight)
        }
        if mods.contains(.alt), altIsMeta { keyMods.insert(.alt) }
        // Unbound Command shortcuts belong to the host.
        if mods.contains(.superKey) {
            return nil
        }
        let special: Key? = switch named {
        case .enter: .enter
        case .tab: .tab
        case .backspace: .backspace
        case .escape: .escape
        case .arrowUp: .up
        case .arrowDown: .down
        case .arrowLeft: .left
        case .arrowRight: .right
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .insert: .insert
        case .delete: .delete
        case .f1: .function(1)
        case .f2: .function(2)
        case .f3: .function(3)
        case .f4: .function(4)
        case .f5: .function(5)
        case .f6: .function(6)
        case .f7: .function(7)
        case .f8: .function(8)
        case .f9: .function(9)
        case .f10: .function(10)
        case .f11: .function(11)
        case .f12: .function(12)
        default: nil
        }
        if let special {
            return KeyEvent(special, modifiers: keyMods, action: action)
        }
        // Printable: the unshifted key, plus the text it typed (an Option
        // composition when Option is not Meta).
        var cp = unshifted
        if cp == 0, let s = text?.unicodeScalars.first { cp = s.value }
        if cp == 0, named == .space { cp = 0x20 }
        guard cp != 0, let scalar = Unicode.Scalar(cp) else { return nil }
        // The text (Shell sends the shifted character for Meta keys) is what
        // legacy Meta encoding emits after ESC; kitty keeps the unshifted key
        // plus the Shift bit.
        let typed = text.flatMap { $0.isEmpty ? nil : $0 } ?? (named == .space ? " " : nil)
        return KeyEvent(.character(scalar), modifiers: keyMods, action: action, text: typed)
    }

    /// Delivers encoded input (to the application or, for tmux panes, the gateway).
    func sendInput(_ input: TerminalInput) {
        session.send(input)
    }

    func sendText(_ text: String) {
        renderer.noteInput()
        session.send(.paste(text))
    }

    func sendRaw(_ bytes: [UInt8]) {
        renderer.noteInput()
        session.send(.bytes(bytes))
    }

    // MARK: Mouse

    func mousePos(x: Double, y: Double, mods rawMods: UInt32) {
        let mods = Mods(rawValue: rawMods)
        let previous = withInput { s -> (Int, Int) in
            let old = s.position
            s.position = (x, y)
            s.mods = mods
            return (Int(old.x), Int(old.y))
        }
        _ = previous
        let c = cell(atPoints: x, y)
        let state = withInput { ($0.leftDown, $0.buttonsDown, $0.handleDrag) }
        if mouseCaptured, !mods.contains(.shift) {
            let modes = mirror.modes
            let button = state.1.min()
            if button != nil || modes.contains(.mouseAny) {
                let b: MouseEvent.Button = switch button {
                case GHOSTTY_MOUSE_LEFT.rawValue: .left
                case GHOSTTY_MOUSE_RIGHT.rawValue: .right
                case GHOSTTY_MOUSE_MIDDLE.rawValue: .middle
                default: .none
                }
                let grid = renderer.grid
                sendInput(.mouse(MouseEvent(.motion, b, column: c.column, row: min(max(c.row, 0), grid.rows - 1), modifiers: keyModifiers(mods))))
            }
        } else if state.0 || state.2 {
            extendSelection(to: c)
        }
        updateLinkHover(cell: c, mods: mods)
    }

    func mouseButton(state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e, mods rawMods: UInt32) -> Bool {
        let mods = Mods(rawValue: rawMods)
        let press = state == GHOSTTY_MOUSE_PRESS
        let pos = withInput { s -> (x: Double, y: Double) in
            if press { s.buttonsDown.insert(button.rawValue) } else { s.buttonsDown.remove(button.rawValue) }
            s.mods = mods
            return s.position
        }
        let c = cell(atPoints: pos.x, pos.y)
        if mouseCaptured, !mods.contains(.shift) {
            let b: MouseEvent.Button
            switch button {
            case GHOSTTY_MOUSE_LEFT: b = .left
            case GHOSTTY_MOUSE_RIGHT: b = .right
            case GHOSTTY_MOUSE_MIDDLE: b = .middle
            default: return false
            }
            let grid = renderer.grid
            sendInput(.mouse(MouseEvent(press ? .press : .release, b, column: c.column, row: min(max(c.row, 0), grid.rows - 1), modifiers: keyModifiers(mods))))
            return true
        }
        guard button == GHOSTTY_MOUSE_LEFT else { return false }
        if press {
            leftPress(at: c, mods: mods)
        } else {
            leftRelease(at: c, mods: mods)
        }
        return true
    }

    private func keyModifiers(_ mods: Mods) -> KeyModifiers {
        var k: KeyModifiers = []
        if mods.contains(.shift) { k.insert(.shift) }
        if mods.contains(.alt) { k.insert(.alt) }
        if mods.contains(.ctrl) { k.insert(.control) }
        return k
    }

    private func leftPress(at c: (column: Int, row: Int), mods: Mods) {
        let now = CACurrentMediaTime()
        let count = withInput { s -> Int in
            let near = abs(s.lastClickCell.column - c.column) <= 1 && s.lastClickCell.row == c.row
            s.clickCount = (now - s.lastClickTime < 0.5 && near) ? min(s.clickCount + 1, 3) : 1
            s.lastClickTime = now
            s.lastClickCell = c
            s.leftDown = true
            s.dragUnit = s.clickCount
            return s.clickCount
        }
        let extend = mods.contains(.shift) && mirror.hasSelection
        session.mutate { state in
            let p = state.clamp(TerminalPoint(row: state.absoluteRow(viewportRow: c.row), column: c.column))
            if extend, var sel = state.selection {
                sel.head = p
                state.setSelection(sel)
                return
            }
            switch count {
            case 2:
                let w = state.wordRange(at: p)
                state.setSelection(Selection(anchor: w.start, head: w.end))
            case 3:
                let l = state.lineRange(at: p)
                state.setSelection(Selection(anchor: l.start, head: l.end))
            default:
                state.setSelection(nil)
            }
        }
        withInput { s in
            s.dragAnchor = count == 1 && !extend ? nil : s.dragAnchor
        }
        if count == 1, !extend {
            let anchor = session.withState { state in
                state.clamp(TerminalPoint(row: state.absoluteRow(viewportRow: c.row), column: c.column))
            }
            withInput { $0.dragAnchor = anchor }
        }
    }

    private func leftRelease(at c: (column: Int, row: Int), mods: Mods) {
        let handle = withInput { s -> Bool in
            let h = s.handleDrag
            s.leftDown = false
            s.handleDrag = false
            s.dragAnchor = nil
            return h
        }
        stopAutoScroll()
        _ = handle
        if mods.contains(.superKey), let url = link(at: c)?.url {
            openURL(url)
            return
        }
        if config.copyOnSelect, let text = session.withState({ $0.selectionText }), !text.isEmpty {
            app.writeClipboard(self, text: text, location: GHOSTTY_CLIPBOARD_SELECTION)
        }
    }

    /// Drag (or handle drag) to `c`, scrolling when past an edge.
    private func extendSelection(to c: (column: Int, row: Int)) {
        let (anchor, unit, handle) = withInput { ($0.dragAnchor, $0.dragUnit, $0.handleDrag) }
        let rows = renderer.grid.rows
        updateAutoScroll(outside: c.row < 0 || c.row >= rows)
        session.mutate { state in
            let point = state.clamp(TerminalPoint(row: state.absoluteRow(viewportRow: min(max(c.row, 0), rows - 1)), column: c.column))
            if handle, var sel = state.selection {
                sel.head = point
                state.setSelection(sel)
                return
            }
            guard let anchor else { return }
            switch unit {
            case 2:
                let a = state.wordRange(at: anchor), h = state.wordRange(at: point)
                state.setSelection(point < anchor ? Selection(anchor: a.end, head: h.start) : Selection(anchor: a.start, head: h.end))
            case 3:
                let a = state.lineRange(at: anchor), h = state.lineRange(at: point)
                state.setSelection(point < anchor ? Selection(anchor: a.end, head: h.start) : Selection(anchor: a.start, head: h.end))
            default:
                if point == anchor, state.selection == nil { return }
                state.setSelection(Selection(anchor: anchor, head: point))
            }
        }
    }

    /// Starts or stops edge auto-scroll. While running, each tick scrolls
    /// towards the pointer (faster the further out it is) and re-extends
    /// the selection to the newly revealed row.
    private func updateAutoScroll(outside: Bool) {
        let running = withInput { $0.autoScroll != nil }
        if outside, !running {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(60), repeating: .milliseconds(60))
            timer.setEventHandler { [weak self] in self?.autoScrollTick() }
            withInput { $0.autoScroll = timer }
            timer.resume()
        } else if !outside, running {
            stopAutoScroll()
        }
    }

    func stopAutoScroll() {
        let timer = withInput { s -> DispatchSourceTimer? in
            let t = s.autoScroll
            s.autoScroll = nil
            return t
        }
        timer?.cancel()
    }

    private func autoScrollTick() {
        let (pos, dragging) = withInput { ($0.position, $0.leftDown || $0.handleDrag) }
        let c = cell(atPoints: pos.x, pos.y)
        let rows = renderer.grid.rows
        // Stop when the drag ended or the application took the mouse.
        guard dragging, !mouseCaptured, c.row < 0 || c.row >= rows else {
            stopAutoScroll()
            return
        }
        let lines = c.row < 0 ? min(-c.row, 5) : -min(c.row - rows + 1, 5)
        session.mutate { $0.scrollViewport(by: lines) }
        extendSelection(to: c)
    }

    /// Begins dragging one end of the selection; the other end stays put.
    func beginHandleDrag(draggingStart: Bool) -> Bool {
        let ok = session.mutate { state -> Bool in
            guard var sel = state.selection else { return false }
            let start = sel.start, end = sel.end
            sel = draggingStart ? Selection(anchor: end, head: start) : Selection(anchor: start, head: end)
            state.setSelection(sel)
            return true
        }
        if ok {
            withInput { $0.handleDrag = true }
        }
        return ok
    }

    func mouseScroll(dx: Double, dy: Double, scrollMods: Int32) {
        let precision = scrollMods & 1 != 0
        let m = renderer.metrics
        let cellPoints = max(1, m.cellHeight / m.scale)
        let lines: Int = withInput { s in
            let delta = precision ? dy / cellPoints : dy
            s.scrollRemainder += delta
            let whole = s.scrollRemainder.rounded(.towardZero)
            s.scrollRemainder -= whole
            return Int(whole)
        }
        guard lines != 0 else { return }
        let pos = withInput { $0.position }
        let c = cell(atPoints: pos.x, pos.y)
        let modes = mirror.modes
        if mouseCaptured {
            let rows = renderer.grid.rows
            for _ in 0 ..< min(abs(lines), 20) {
                sendInput(.mouse(MouseEvent(.press, lines > 0 ? .wheelUp : .wheelDown, column: c.column, row: min(max(c.row, 0), rows - 1))))
            }
        } else if mirror.isAlternate, modes.contains(.alternateScroll) {
            for _ in 0 ..< min(abs(lines), 20) {
                sendInput(.key(KeyEvent(lines > 0 ? .up : .down)))
            }
        } else {
            session.mutateAsync { $0.scrollViewport(by: lines) }
        }
    }

    // MARK: Links

    private static let urlPattern = try? NSRegularExpression(
        pattern: #"(?:https?|ftp|file|ssh|mailto):[^\s<>"'`()\[\]{}]*[^\s<>"'`()\[\]{}.,;:!?]"#,
    )

    /// URL under a viewport cell: its OSC 8 target, else one detected in
    /// its logical line.
    /// The URL plus its OSC 8 id (0 when detected from the text).
    func link(at c: (column: Int, row: Int)) -> (url: String, id: UInt8)? {
        session.withState { state -> (url: String, id: UInt8)? in
            guard c.row >= 0, c.row < state.rows else { return nil }
            let p = TerminalPoint(row: state.absoluteRow(viewportRow: c.row), column: c.column)
            // An OSC 8 hyperlink wins over URL detection.
            if let (cells, _) = state.line(absoluteRow: p.row), c.column < cells.count,
               let target = state.hyperlink(cells[c.column].attributes.link) {
                return (target, cells[c.column].attributes.link)
            }
            let line = state.lineRange(at: p)
            var scalars: [Unicode.Scalar] = []
            var points: [TerminalPoint] = []
            for row in line.start.row ... line.end.row {
                guard let (cells, _) = state.line(absoluteRow: row) else { continue }
                for x in 0 ..< cells.count where !cells[x].isSpacer {
                    let content = state.scalars(of: cells[x])
                    for s in content.isEmpty ? [" "] : content {
                        scalars.append(s); points.append(TerminalPoint(row: row, column: x))
                    }
                }
            }
            var text = String.UnicodeScalarView()
            text.append(contentsOf: scalars)
            let string = String(text)
            let ns = string as NSString
            guard let pattern = Self.urlPattern else { return nil }
            for match in pattern.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
                // Map the UTF-16 range back to scalar indices.
                let prefix = ns.substring(to: match.range.location).unicodeScalars.count
                let length = ns.substring(with: match.range).unicodeScalars.count
                guard prefix + length <= points.count else { continue }
                if p >= points[prefix], p <= points[prefix + length - 1] {
                    return (ns.substring(with: match.range), 0)
                }
            }
            return nil
        }
    }

    private func updateLinkHover(cell c: (column: Int, row: Int), mods: Mods) {
        let hit = mods.contains(.superKey) ? link(at: c) : nil
        let url = hit?.url
        renderer.setHoveredLink(hit?.id ?? 0)
        let changed = withInput { s -> Bool in
            guard s.hoveredLink != url else { return false }
            s.hoveredLink = url
            return true
        }
        guard changed else { return }
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_MOUSE_OVER_LINK
        if let url {
            url.withCString { ptr in
                action.action.mouse_over_link = ghostty_action_mouse_over_link_s(url: ptr, len: strlen(ptr))
                app.perform(action, surface: self)
            }
        } else {
            action.action.mouse_over_link = ghostty_action_mouse_over_link_s(url: nil, len: 0)
            app.perform(action, surface: self)
        }
    }

    private func openURL(_ url: String) {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        url.withCString { ptr in
            action.action.open_url = ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, url: ptr, len: UInt(strlen(ptr)))
            app.perform(action, surface: self)
        }
    }

    // MARK: Reading text

    /// `ghostty_surface_read_selection`: the selection text plus where it
    /// starts. Endpoints are clamped to the viewport plus two overscan rows.
    func readSelection() -> (text: String, startColumn: Int, startRow: Int, startOffset: Int, length: Int)? {
        let grid = renderer.grid
        return session.withState { state in
            guard let sel = state.selection, let text = state.selectionText else { return nil }
            let top = state.absoluteRow(viewportRow: 0)
            let maxRow = grid.rows + 1
            func clamp(_ p: TerminalPoint, toStart: Bool) -> (row: Int, column: Int) {
                let row = p.row - top
                if row < 0 { return (0, 0) }
                if row > maxRow { return (maxRow, grid.columns - 1) }
                return (row, p.column)
            }
            let s = clamp(sel.start, toStart: true), e = clamp(sel.end, toStart: false)
            let startIndex = s.row * grid.columns + s.column
            let endIndex = e.row * grid.columns + e.column
            return (text, s.column, s.row, startIndex, max(0, endIndex - startIndex))
        }
    }

    /// `ghostty_surface_read_text` over a viewport rectangle or span.
    func readText(_ sel: ghostty_selection_s) -> String? {
        session.withState { state in
            let viewportTop = state.absoluteRow(viewportRow: 0)
            let screenTop = viewportTop + (state.isAlternateScreen ? 0 : state.viewportOffset)
            let base = (viewport: viewportTop, screen: state.firstAbsoluteRow, active: screenTop)
            let a = Self.point(sel.top_left, base), b = Self.point(sel.bottom_right, base)
            return state.text(from: a, to: b, rectangle: sel.rectangle)
        }
    }

    private static func point(_ p: ghostty_point_s, _ base: (viewport: Int, screen: Int, active: Int)) -> TerminalPoint {
        let top = switch p.tag {
        case GHOSTTY_POINT_VIEWPORT: base.viewport
        case GHOSTTY_POINT_SCREEN: base.screen
        default: base.active
        }
        return TerminalPoint(row: top + Int(p.y), column: Int(p.x))
    }

    /// Caret geometry for IME placement: x = caret cell centre, y = cell
    /// bottom, height = cell height (points); width = preedit width (pixels).
    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        let m = renderer.metrics
        let cursor = mirror.cursor
        let preeditColumns = renderer.preedit.map { $0.unicodeScalars.reduce(0) { $0 + max(1, Int(UnicodeWidth.width($1.value))) } } ?? 0
        let x = (m.paddingX + Double(cursor.x) * m.cellWidth + m.cellWidth / 2) / m.scale
        let y = (m.paddingY + Double(cursor.y + 1) * m.cellHeight) / m.scale
        return (x, y, Double(preeditColumns) * m.cellWidth, m.cellHeight / m.scale)
    }
}

extension App {
    func writeClipboard(_ surface: Surface, text: String, location: ghostty_clipboard_e) {
        guard let cb = runtime.write_clipboard_cb else { return }
        "text/plain".withCString { mime in
            text.withCString { data in
                var content = ghostty_clipboard_content_s(mime: mime, data: data)
                cb(surface.userdata, location, &content, 1, false)
            }
        }
    }
}
