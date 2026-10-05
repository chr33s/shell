import Foundation
import os
import SwifttyCore

/// `swiftty_surface_t`: one terminal, its renderer, and its I/O.
///
/// Normal surfaces take program output from the host through `ExternalIO`;
/// tmux pane surfaces are fed by their gateway's control-mode viewer and turn
/// input into `send-keys`.
final class Surface: @unchecked Sendable {
    let app: App
    let userdata: UnsafeMutableRawPointer?
    let session: TerminalSession
    let renderer: SurfaceRenderer
    private(set) var io: ExternalIO?
    /// Set for a tmux pane surface: where its input goes.
    var paneInput: (@Sendable ([UInt8]) -> Void)?
    private weak var pane: TmuxPane?
    /// Control-mode viewer, when this surface is a tmux gateway.
    var tmux: TmuxViewer? {
        get { lock.withLockUnchecked { _tmux } }
        set { lock.withLockUnchecked { _tmux = newValue } }
    }

    private let lock = OSAllocatedUnfairLock()
    private var _tmux: TmuxViewer?
    private var _config: Config
    private var _mirror = Mirror()
    private var _freed = false
    private var lastContentEvent: UInt64 = 0
    private var contentEventPending = false
    var input = InputState()

    /// Values read from the main thread without waiting on the terminal queue.
    struct Mirror {
        var modes: Modes = .initial
        var isAlternate = false
        var scrollbar = (total: 0, offset: 0, len: 0)
        var columns = 0
        var rows = 0
        var cursor = (x: 0, y: 0)
        var hasSelection = false
        var selectionVisible = (start: false, end: false)
    }

    var mirror: Mirror {
        lock.withLockUnchecked { _mirror }
    }

    var config: Config {
        lock.withLockUnchecked { _config }
    }

    var isFreed: Bool {
        lock.withLockUnchecked { _freed }
    }

    var opaque: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    static func from(_ p: UnsafeMutableRawPointer?) -> Surface? {
        p.map { Unmanaged<Surface>.fromOpaque($0).takeUnretainedValue() }
    }

    /// - Parameter pane: a tmux pane to render instead of a new terminal.
    init(app: App, config cfg: swiftty_surface_config_s, pane: (TmuxPane, TmuxViewer)? = nil) {
        self.app = app
        userdata = cfg.userdata
        let config = app.config
        _config = config
        if let (pane, viewer) = pane {
            session = pane.session
            self.pane = pane
            let id = pane.id
            paneInput = { [weak viewer] bytes in viewer?.sendKeys(pane: id, bytes) }
            let palette = config.palette, scheme = config.colorScheme
            session.mutateAsync { $0.setDefaultPalette(palette); $0.setColorScheme(scheme) }
        } else {
            var sessionConfig = SessionConfiguration()
            sessionConfig.palette = config.palette
            sessionConfig.scrollbackLimitBytes = Int.max / 4
            sessionConfig.scrollbackLimitRows = max(1, config.scrollbackLines)
            session = TerminalSession(columns: 80, rows: 24, configuration: sessionConfig)
            let scheme = config.colorScheme
            session.mutateAsync { $0.setColorScheme(scheme) }
        }
        let view = cfg.platform.ios.uiview.map { Unmanaged<PlatformView>.fromOpaque($0).takeUnretainedValue() }
        renderer = SurfaceRenderer(
            view: view, scale: cfg.scale_factor > 0 ? cfg.scale_factor : 2, config: config,
            visible: cfg.initially_visible,
        )
        renderer.surface = self
        if pane == nil {
            io = ExternalIO { [weak self] bytes in self?.session.receive(bytes) }
        }
        session.onWrite = { [weak self] bytes in
            guard let self else { return }
            if let paneInput { paneInput(bytes) } else { io?.write(bytes) }
        }
        session.onStateChange = { [weak self] state in self?.stateChanged(state) }
        session.onUpdate = { [weak self] in self?.renderer.setNeedsDisplay() }
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.onControlModeData = { [weak self] data in self?.tmux?.receive(data) }
        self.pane?.surface = self
        app.register(self)
    }

    /// Program input for the gateway's transport (tmux commands).
    func writeToTransport(_ bytes: [UInt8]) {
        io?.write(bytes)
    }

    var isTmuxPane: Bool {
        paneInput != nil
    }

    func free() {
        lock.withLockUnchecked { _freed = true }
        stopAutoScroll()
        if isTmuxPane, pane?.surface === self || pane == nil {
            // The pane's terminal outlives this surface (the viewer keeps
            // feeding it); detach our callbacks unless a newer surface took over.
            session.onWrite = nil
            session.onStateChange = nil
            session.onUpdate = nil
            session.onEvent = nil
        }
        app.unregister(self)
        tmux?.close()
        tmux = nil
        renderer.teardown()
        io?.close()
        io = nil
    }

    // MARK: Config

    func update(config: Config) {
        let old = lock.withLockUnchecked {
            let old = _config
            _config = config
            return old
        }
        if old.palette != config.palette {
            let palette = config.palette, scheme = config.colorScheme
            session.mutateAsync { $0.setDefaultPalette(palette); $0.setColorScheme(scheme) }
        }
        renderer.update(config: config)
    }

    // MARK: State

    /// Runs on the terminal queue after every batch of changes.
    private func stateChanged(_ state: borrowing TerminalState) {
        let scrollbar = (total: state.scrollbackCount + state.rows, offset: state.scrollbackCount - state.viewportOffset, len: state.rows)
        var selectionVisible = (start: false, end: false)
        if let s = state.selection {
            let top = state.absoluteRow(viewportRow: 0)
            selectionVisible = (s.start.row >= top && s.start.row < top + state.rows, s.end.row >= top && s.end.row < top + state.rows)
        }
        let (scrollChanged, gridChanged) = lock.withLockUnchecked {
            let alt = state.isAlternateScreen
            let scrollChanged = _mirror.scrollbar != scrollbar
            let gridChanged = _mirror.columns != state.columns || _mirror.rows != state.rows
            _mirror.modes = state.modes
            _mirror.isAlternate = alt
            _mirror.scrollbar = scrollbar
            _mirror.columns = state.columns
            _mirror.rows = state.rows
            _mirror.cursor = (state.cursor.x, state.cursor.y)
            _mirror.hasSelection = state.selection != nil
            _mirror.selectionVisible = selectionVisible
            return (scrollChanged, gridChanged)
        }
        if scrollChanged {
            let (total, offset, len) = (UInt64(scrollbar.total), UInt64(scrollbar.offset), UInt64(scrollbar.len))
            app.post(self, tag: SWIFTTY_ACTION_SCROLLBAR) {
                $0.scrollbar = swiftty_action_scrollbar_s(total: total, offset: offset, len: len)
            }
        }
        if gridChanged, !isTmuxPane {
            let size = renderer.metrics
            let (rows, cols) = (UInt32(state.rows), UInt32(state.columns))
            let (w, h) = (UInt32(size.cellWidth) * cols, UInt32(size.cellHeight) * rows)
            app.post(self, tag: SWIFTTY_ACTION_PTY_RESIZE) {
                $0.pty_resize = swiftty_action_pty_resize_s(rows: rows, cols: cols, width_px: w, height_px: h)
            }
        }
        if !state.damage.isEmpty {
            contentChanged()
        }
    }

    /// Coalesced SURFACE_CONTENT_CHANGED (at most every 100 ms).
    private func contentChanged() {
        guard app.contentEventsEnabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let delay = lock.withLockUnchecked { () -> UInt64? in
            guard !contentEventPending else { return nil }
            contentEventPending = true
            let wait = lastContentEvent + 100_000_000 > now ? lastContentEvent + 100_000_000 - now : 0
            return wait
        }
        guard let delay else { return }
        app.actionQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [self] in
            lock.withLockUnchecked {
                contentEventPending = false
                lastContentEvent = DispatchTime.now().uptimeNanoseconds
            }
            guard !isFreed else { return }
            var action = swiftty_action_s()
            action.tag = SWIFTTY_ACTION_SURFACE_CONTENT_CHANGED
            app.perform(action, surface: self)
        }
    }

    private func handle(_ event: TerminalEvent) {
        switch event {
        case let .title(title):
            app.post(self, tag: SWIFTTY_ACTION_SET_TITLE, string: title) { $0.set_title = swiftty_action_set_title_s(title: $1) }
        case let .workingDirectory(path):
            app.post(self, tag: SWIFTTY_ACTION_PWD, string: path) { $0.pwd = swiftty_action_pwd_s(pwd: $1) }
        case .bell:
            app.post(self, tag: SWIFTTY_ACTION_RING_BELL)
        case let .clipboard(text):
            if config.clipboardWrite {
                app.actionQueue.async { [self] in app.writeClipboard(self, text: text) }
            }
        case let .notification(title, body):
            app.post(self) { send in
                title.withCString { t in
                    body.withCString { b in
                        var action = swiftty_action_s()
                        action.tag = SWIFTTY_ACTION_DESKTOP_NOTIFICATION
                        action.action.desktop_notification = swiftty_action_desktop_notification_s(title: t, body: b)
                        send(action)
                    }
                }
            }
        case let .progress(state, percent):
            let s = swiftty_action_progress_report_state_e(UInt32(min(max(state, 0), 4)))
            let p = Int8(percent ?? -1)
            app.post(self, tag: SWIFTTY_ACTION_PROGRESS_REPORT) {
                $0.progress_report = swiftty_action_progress_report_s(state: s, progress: p)
            }
        case .controlModeStarted:
            if tmux == nil {
                tmux = TmuxViewer(gateway: self)
            }
            tmux?.start()
        case .controlModeEnded:
            tmux?.controlModeEnded()
        case let .pointerShape(name):
            let shape = Self.mouseShape(name)
            app.post(self, tag: SWIFTTY_ACTION_MOUSE_SHAPE) { $0.mouse_shape = shape }
        case .exited, .commandFinished:
            break
        }
    }

    /// OSC 22 pointer names (CSS cursor keywords); unknown names fall back
    /// to the default shape.
    private static func mouseShape(_ name: String) -> swiftty_action_mouse_shape_e {
        switch name {
        case "context-menu": SWIFTTY_MOUSE_SHAPE_CONTEXT_MENU
        case "pointer": SWIFTTY_MOUSE_SHAPE_POINTER
        case "crosshair": SWIFTTY_MOUSE_SHAPE_CROSSHAIR
        case "text": SWIFTTY_MOUSE_SHAPE_TEXT
        case "vertical-text": SWIFTTY_MOUSE_SHAPE_VERTICAL_TEXT
        case "not-allowed", "no-drop": SWIFTTY_MOUSE_SHAPE_NOT_ALLOWED
        case "grab": SWIFTTY_MOUSE_SHAPE_GRAB
        case "grabbing": SWIFTTY_MOUSE_SHAPE_GRABBING
        case "n-resize": SWIFTTY_MOUSE_SHAPE_N_RESIZE
        case "e-resize": SWIFTTY_MOUSE_SHAPE_E_RESIZE
        case "s-resize": SWIFTTY_MOUSE_SHAPE_S_RESIZE
        case "w-resize": SWIFTTY_MOUSE_SHAPE_W_RESIZE
        case "ew-resize", "col-resize": SWIFTTY_MOUSE_SHAPE_EW_RESIZE
        case "ns-resize", "row-resize": SWIFTTY_MOUSE_SHAPE_NS_RESIZE
        default: SWIFTTY_MOUSE_SHAPE_DEFAULT
        }
    }

    // MARK: Size

    /// `swiftty_surface_set_size`: framebuffer pixels.
    func setSize(width: UInt32, height: UInt32) {
        let grid = renderer.resize(width: Double(width), height: Double(height))
        resizeGrid(grid)
    }

    func resizeGrid(_ grid: (columns: Int, rows: Int)) {
        // A tmux pane's grid is tmux's; the host reports the size that fits
        // to tmux, which answers with a layout change.
        guard !isTmuxPane else { return }
        let cell = renderer.metrics
        session.setCellPixelSize(width: Int(cell.cellWidth), height: Int(cell.cellHeight))
        session.mutateAsync { $0.resize(columns: grid.columns, rows: grid.rows) }
    }

    var size: swiftty_surface_size_s {
        let m = renderer.metrics
        let g = renderer.grid
        return swiftty_surface_size_s(
            columns: UInt16(clamping: g.columns), rows: UInt16(clamping: g.rows),
            width_px: UInt32(m.width), height_px: UInt32(m.height),
            cell_width_px: UInt32(m.cellWidth), cell_height_px: UInt32(m.cellHeight),
        )
    }

    /// Emits CELL_SIZE synchronously (the host re-sizes in response).
    func cellSizeChanged() {
        let m = renderer.metrics
        var action = swiftty_action_s()
        action.tag = SWIFTTY_ACTION_CELL_SIZE
        action.action.cell_size = swiftty_action_cell_size_s(width: UInt32(m.cellWidth), height: UInt32(m.cellHeight))
        if Thread.isMainThread {
            app.perform(action, surface: self)
        } else {
            let a = action
            DispatchQueue.main.async { [self] in
                guard !isFreed else { return }
                app.perform(a, surface: self)
            }
        }
    }
}
